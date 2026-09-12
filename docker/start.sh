#!/bin/bash
set -euo pipefail

#############################################
# Validate Environment Variables
#############################################
if [ -z "${VIDEO_URL:-}" ]; then
    echo "ERROR: VIDEO_URL is not set"
    exit 1
fi
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
    echo "ERROR: YOUTUBE_STREAM_KEY is not set"
    exit 1
fi

# Subscriber count + live viewer count are optional — if the API creds
# aren't provided, those panel elements just stay blank instead of
# failing the whole stream.
SHOW_STATS=true
if [ -z "${YOUTUBE_API_KEY:-}" ] || [ -z "${YOUTUBE_CHANNEL_ID:-}" ]; then
    echo "NOTICE: YOUTUBE_API_KEY / YOUTUBE_CHANNEL_ID not set — subscriber/viewer stats will be hidden."
    SHOW_STATS=false
fi

echo "========================================"
echo "Starting 24/7 YouTube Stream (Documentary Overlay)"
echo "Output Resolution : 1280x720 (720p — sized for a 2-core CI runner)"
echo "FPS               : 30"
echo "========================================"

FONT="font.ttf"
# Premium NASA/documentary palette: deep space navy panel, a cooler
# refined gold (less "orange", more brushed-metal), a muted signal red
# for the LIVE indicator, and a cool silver-blue for secondary/technical
# text (timestamps, labels, dividers) so the panel reads less like a
# generic banner and more like a broadcast graphics package.
GOLD="0xC9A227"
GOLD_DIM="0x8C7220"
RED="0xD64545"
NAVY="0x0A0E16"
SILVER="0x9FB3C8"
ASSET_DIR="panel_assets"
INFO_FILE="galaxy_info.txt"
SLOT=6            # seconds each headline is shown
FACT_SLOT=8       # seconds each fun fact is shown
TICKER_SPEED=110  # pixels/second for the bottom ticker scroll
CHANNEL_NAME="Technical Talk India"
SHADOW="shadowcolor=black@0.6:shadowx=1:shadowy=1"
HEADLINE_FONTSIZE=21
HEADLINE_LINE_SPACING=9
HEADLINE_LINE_H=$((HEADLINE_FONTSIZE + HEADLINE_LINE_SPACING))

# Don't show "N watching now" until the live viewer count reaches this
# many — a very low number (e.g. "5 watching") reads worse to a new
# visitor than showing nothing at all. Raise/lower to taste.
VIEWER_MIN_TO_SHOW=10

# Approximate center + radius (in 1280x720 output coordinates) of the
# subscribe icon baked into overlay.png, used to draw a pulsing gold
# ring around it every few seconds so it catches the eye. Adjust these
# three numbers to match the icon's actual position in your overlay.png
# — the defaults below are an estimate for the bottom-right corner.
SUB_ICON_X=1249
SUB_ICON_Y=677
SUB_ICON_R=20

# Real wall-clock start of the whole broadcast (not any single video).
# Each video runs as its own ffmpeg process, so `t` resets to 0 every
# time — anything that needs to stay in sync across video boundaries
# (like the poll/info panel switch below) has to add this offset back
# in rather than relying on `t` alone. See VIDEO_START_OFFSET in
# run_video().
STREAM_START_EPOCH=$(date +%s)

#############################################
# Live audience poll (alternates with the info
# panel below): minutes 0-5 of every 10-minute
# cycle show a poll question with live vote-bar
# percentages; minutes 5-10 show the regular
# headline/fact info panel. Votes are tallied
# from the YouTube live chat (`!vote 1` /
# `!vote 2`) by the background poller further
# down. Falls back gracefully with 0% bars if
# API creds aren't configured — the question
# still rotates either way.
#############################################
POLL_CYCLE=300     # a new poll question every 5 min
POLL_WINDOW=45     # poll panel is only visible for the final 45s of
                    # each cycle (a "reveal" moment) — the info panel
                    # runs the rest of the time, and votes cast via
                    # chat during that stretch are what the reveal
                    # shows. Voting itself isn't gated by visibility:
                    # `!vote 1`/`!vote 2` count for the whole 5-minute
                    # window even while the info panel is on screen.
BAR_CHARS=24       # width of the text-based vote bar, in characters
POLLS_FILE="polls.txt"

DEFAULT_POLLS=(
    "Which target next?|Carina Nebula|Pillars of Creation"
    "Favorite JWST image so far?|Southern Ring Nebula|Stephan's Quintet"
    "What should we explore next?|Exoplanet atmospheres|Black hole jets"
    "Which mission excites you more?|Euclid|Vera Rubin Observatory"
)

#############################################
# Up-next bumper (shown between videos)
#############################################
ENABLE_BUMPER=true
BUMPER_DURATION=5   # seconds
BUMPER_MESSAGES=(
    "Stay tuned as the James Webb Space Telescope reveals more of the Universe."
    "A new window into the cosmos is coming up next."
    "Journey deeper into space as Webb explores distant cosmic worlds."
    "From ancient galaxies to stellar nurseries, more discoveries await."
    "The Universe is still unfolding. Stay with us for the next view."
    "See the cosmos in extraordinary detail through the eyes of Webb."
    "Every new observation brings another piece of our cosmic story."
    "Look deeper into space and further back in cosmic time."
    "More distant galaxies, brilliant stars, and hidden cosmic structures are ahead."
    "The next chapter of our journey through the Universe begins shortly."
)

#############################################
# Auto-restart on failure
#############################################
MAX_RETRIES=5       # per-video retry attempts before moving on
RETRY_DELAY=5        # seconds between retries

mkdir -p "$ASSET_DIR"

#############################################
# Generate the coordinate-label marker dot once
# at startup: a small transparent PNG with a
# gold-filled center and white ring, matching
# the panel's gold accent color. Used by
# build_labels_chain() as ffmpeg input index 2.
# Always generated (cheap, one frame, 20x20) —
# harmless/unused by ffmpeg on videos that don't
# have a matching .labels.txt file.
#############################################
DOT_MARKER="dot_marker.png"
GOLD_R=201; GOLD_G=162; GOLD_B=39
DOT_VF="format=rgba,geq=r=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_R}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):g=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_G}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):b=(if(lte(hypot(X-10\,Y-10)\,5)\,${GOLD_B}\,if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))):a=(if(lte(hypot(X-10\,Y-10)\,8)\,255\,0))"
ffmpeg -y -f lavfi -i "color=c=black@0.0:s=20x20" -vf "$DOT_VF" -frames:v 1 "$DOT_MARKER" -loglevel error
if [ ! -s "$DOT_MARKER" ]; then
    # Guarantee the file always exists and is a valid PNG, even in the
    # unlikely case the geq-based generation above fails — this is what
    # gets passed to ffmpeg as a real input on every stream start, so it
    # must never be missing. Falls back to an invisible 1x1 transparent
    # pixel (labels would render without a visible dot, but the stream
    # itself keeps running instead of crashing on a missing input file).
    echo "WARNING: geq-based marker generation failed — using a blank 1x1 fallback."
    echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" | base64 -d > "$DOT_MARKER"
fi

#############################################
# Background clock writer (avoids fragile
# drawtext %{gmtime} expansion syntax)
#############################################
date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt"
(
    while true; do
        date -u +'%d %b %Y  •  %H:%M:%S UTC' > "$ASSET_DIR/clock.txt.tmp"
        mv -f "$ASSET_DIR/clock.txt.tmp" "$ASSET_DIR/clock.txt"
        sleep 1
    done
) &
CLOCK_PID=$!

#############################################
# Background subscriber-count writer
# (polls YouTube Data API every 60s — subs
# don't change second to second, and this
# respects API quota)
#############################################
printf ' ' > "$ASSET_DIR/subs.txt"
SUBS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        WARNED_ONCE=false
        while true; do
            RESP=$(curl -s "https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}" || true)
            COUNT=$(echo "$RESP" | grep -o '"subscriberCount"[^"]*"[0-9]*"' | grep -oE '[0-9]+')
            if [ -n "$COUNT" ]; then
                # Manual comma insertion — locale-independent, so it works
                # the same regardless of the container's default locale
                # (printf "%'d" silently fails to group digits under the
                # bare "C" locale that Ubuntu containers ship with).
                FORMATTED=$(echo "$COUNT" | rev | sed 's/\(...\)/\1,/g' | rev | sed 's/^,//')
                printf '%s subscribers' "$FORMATTED" > "$ASSET_DIR/subs.txt.tmp"
                mv -f "$ASSET_DIR/subs.txt.tmp" "$ASSET_DIR/subs.txt"
                WARNED_ONCE=false
            elif [ "$WARNED_ONCE" = false ]; then
                # Log the raw response once so it shows up in the Actions
                # log — this tells us exactly why the count isn't parsing
                # (bad channel ID, disabled API, quota, key restrictions, etc.)
                echo "WARNING: could not parse subscriberCount from API response. Raw response:"
                echo "$RESP"
                WARNED_ONCE=true
            fi
            sleep 60
        done
    ) &
    SUBS_PID=$!
fi

#############################################
# Background live-viewer-count writer
# Strategy: find the channel's currently-live
# video once (search.list — costs more quota,
# so only called when we don't already have an
# id), then poll videos.list (cheap, 1 unit)
# every 30s for concurrentViewers. If the
# broadcast ends/restarts, re-search.
#############################################
printf ' ' > "$ASSET_DIR/viewers.txt"
VIEWERS_PID=""
if [ "$SHOW_STATS" = true ]; then
    (
        LIVE_VIDEO_ID=""
        while true; do
            if [ -z "$LIVE_VIDEO_ID" ]; then
                SEARCH_RESP=$(curl -s "https://www.googleapis.com/youtube/v3/search?part=id&channelId=${YOUTUBE_CHANNEL_ID}&eventType=live&type=video&key=${YOUTUBE_API_KEY}" || true)
                LIVE_VIDEO_ID=$(echo "$SEARCH_RESP" | grep -o '"videoId": *"[^"]*"' | head -1 | sed -E 's/.*"videoId": *"([^"]*)".*/\1/')
                if [ -n "$LIVE_VIDEO_ID" ]; then
                    printf '%s' "$LIVE_VIDEO_ID" > "$ASSET_DIR/live_video_id.txt.tmp"
                    mv -f "$ASSET_DIR/live_video_id.txt.tmp" "$ASSET_DIR/live_video_id.txt"
                fi
            fi
            if [ -n "$LIVE_VIDEO_ID" ]; then
                VRESP=$(curl -s "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${LIVE_VIDEO_ID}&key=${YOUTUBE_API_KEY}" || true)
                VIEWERS=$(echo "$VRESP" | grep -o '"concurrentViewers": *"[0-9]*"' | grep -o '[0-9]*')
                if [ -n "$VIEWERS" ] && [ "$VIEWERS" -ge "$VIEWER_MIN_TO_SHOW" ]; then
                    printf '%s watching now' "$VIEWERS" > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                elif [ -n "$VIEWERS" ]; then
                    # Below the display threshold — keep the panel blank
                    # rather than showing a small/discouraging number.
                    printf ' ' > "$ASSET_DIR/viewers.txt.tmp"
                    mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
                else
                    # Broadcast ended or hasn't registered yet — clear and re-search.
                    LIVE_VIDEO_ID=""
                    printf ' ' > "$ASSET_DIR/viewers.txt"
                    rm -f "$ASSET_DIR/live_video_id.txt"
                fi
            fi
            sleep 30
        done
    ) &
    VIEWERS_PID=$!
fi

trap 'kill "$CLOCK_PID" 2>/dev/null || true; [ -n "$SUBS_PID" ] && kill "$SUBS_PID" 2>/dev/null || true; [ -n "$VIEWERS_PID" ] && kill "$VIEWERS_PID" 2>/dev/null || true; [ -n "$POLL_PID" ] && kill "$POLL_PID" 2>/dev/null || true' EXIT

#############################################
# Background poll writer: rotates the question
# every POLL_CYCLE seconds on wall-clock time
# (independent of which video is currently
# playing) and, when API creds are available,
# tallies `!vote 1` / `!vote 2` chat messages
# into live percentage bars.
#
# The question/option rotation always runs (no
# API needed for that part); only the chat
# lookup itself is gated behind SHOW_STATS, so
# without credentials the poll panel still shows
# a rotating question with bars parked at 0%
# instead of disappearing entirely.
#
# Vote bars are rendered as plain text (a string
# of '#' and '.' characters via drawtext, same
# reload=1 technique as clock.txt/subs.txt)
# rather than a dynamically-sized drawbox,
# because ffmpeg's filter graph has no way to
# feed a live external number into another
# filter's numeric parameters each frame short
# of an expensive per-pixel filter — and we
# already paid for that mistake once with the
# panel-entrance blend filter. Text is cheap and
# reload=1 already proven reliable here.
#############################################
mkdir -p "$ASSET_DIR"
printf ' ' > "$ASSET_DIR/poll_question.txt"
printf ' ' > "$ASSET_DIR/poll_opt1.txt"
printf ' ' > "$ASSET_DIR/poll_opt2.txt"
printf '%0.s.' $(seq 1 "$BAR_CHARS") > "$ASSET_DIR/poll_bar1.txt"
printf '%0.s.' $(seq 1 "$BAR_CHARS") > "$ASSET_DIR/poll_bar2.txt"
printf 'Vote in chat: !vote 1 or !vote 2' > "$ASSET_DIR/poll_votes.txt"

POLL_PID=""
(
    POLLS=()
    if [ -f "$POLLS_FILE" ]; then
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && POLLS+=("$line")
        done < "$POLLS_FILE"
    fi
    [ "${#POLLS[@]}" -eq 0 ] && POLLS=("${DEFAULT_POLLS[@]}")
    NUM_POLLS=${#POLLS[@]}

    # Prints a BAR_CHARS-wide bar of '#' (filled) / '.' (empty) for a
    # given 0-100 percentage.
    render_bar() {
        local pct="$1" filled empty
        filled=$(( (pct * BAR_CHARS + 50) / 100 ))
        [ "$filled" -lt 0 ] && filled=0
        [ "$filled" -gt "$BAR_CHARS" ] && filled=$BAR_CHARS
        empty=$((BAR_CHARS - filled))
        [ "$filled" -gt 0 ] && printf '%0.s#' $(seq 1 "$filled")
        [ "$empty" -gt 0 ] && printf '%0.s.' $(seq 1 "$empty")
    }

    LAST_WINDOW_IDX=-1
    VOTES1=0
    VOTES2=0
    LIVE_CHAT_ID=""
    NEXT_PAGE_TOKEN=""
    CHAT_POLL_INTERVAL=10

    while true; do
        NOW=$(date +%s)
        ELAPSED=$((NOW - STREAM_START_EPOCH))
        WINDOW_IDX=$(( (ELAPSED / POLL_CYCLE) % NUM_POLLS ))

        if [ "$WINDOW_IDX" -ne "$LAST_WINDOW_IDX" ]; then
            # New 10-minute cycle — new question, reset the tally.
            LAST_WINDOW_IDX=$WINDOW_IDX
            VOTES1=0
            VOTES2=0
            NEXT_PAGE_TOKEN=""
            IFS='|' read -r Q O1 O2 <<< "${POLLS[$WINDOW_IDX]}"
            echo "$Q" | fold -s -w 25 > "$ASSET_DIR/poll_question.txt.tmp" && mv -f "$ASSET_DIR/poll_question.txt.tmp" "$ASSET_DIR/poll_question.txt"
            printf '[1] %s' "$O1" > "$ASSET_DIR/poll_opt1.txt.tmp" && mv -f "$ASSET_DIR/poll_opt1.txt.tmp" "$ASSET_DIR/poll_opt1.txt"
            printf '[2] %s' "$O2" > "$ASSET_DIR/poll_opt2.txt.tmp" && mv -f "$ASSET_DIR/poll_opt2.txt.tmp" "$ASSET_DIR/poll_opt2.txt"
            render_bar 0 > "$ASSET_DIR/poll_bar1.txt.tmp" && mv -f "$ASSET_DIR/poll_bar1.txt.tmp" "$ASSET_DIR/poll_bar1.txt"
            render_bar 0 > "$ASSET_DIR/poll_bar2.txt.tmp" && mv -f "$ASSET_DIR/poll_bar2.txt.tmp" "$ASSET_DIR/poll_bar2.txt"
            printf 'Vote in chat: !vote 1 or !vote 2' > "$ASSET_DIR/poll_votes.txt.tmp" && mv -f "$ASSET_DIR/poll_votes.txt.tmp" "$ASSET_DIR/poll_votes.txt"
            echo "NOTICE: New poll: ${Q} (1: ${O1} / 2: ${O2})"
        fi

        if [ "$SHOW_STATS" = true ]; then
            if [ -z "$LIVE_CHAT_ID" ]; then
                VIDEO_ID=""
                [ -f "$ASSET_DIR/live_video_id.txt" ] && VIDEO_ID="$(cat "$ASSET_DIR/live_video_id.txt" 2>/dev/null)"
                if [ -n "$VIDEO_ID" ]; then
                    VRESP=$(curl -s "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${VIDEO_ID}&key=${YOUTUBE_API_KEY}" || true)
                    LIVE_CHAT_ID=$(echo "$VRESP" | grep -o '"activeLiveChatId": *"[^"]*"' | head -1 | sed -E 's/.*"activeLiveChatId": *"([^"]*)".*/\1/')
                fi
            fi

            if [ -n "$LIVE_CHAT_ID" ]; then
                CHAT_URL="https://www.googleapis.com/youtube/v3/liveChat/messages?liveChatId=${LIVE_CHAT_ID}&part=snippet&key=${YOUTUBE_API_KEY}"
                [ -n "$NEXT_PAGE_TOKEN" ] && CHAT_URL="${CHAT_URL}&pageToken=${NEXT_PAGE_TOKEN}"
                CRESP=$(curl -s "$CHAT_URL" || true)

                if [ -z "$CRESP" ] || ! echo "$CRESP" | grep -q '"pollingIntervalMillis"'; then
                    # Chat lookup failed (broadcast/chat ended, bad id,
                    # etc.) — clear and let the next loop re-resolve it.
                    LIVE_CHAT_ID=""
                    NEXT_PAGE_TOKEN=""
                else
                    NEXT_PAGE_TOKEN=$(echo "$CRESP" | grep -o '"nextPageToken": *"[^"]*"' | head -1 | sed -E 's/.*"nextPageToken": *"([^"]*)".*/\1/')
                    NEW_INTERVAL=$(echo "$CRESP" | grep -o '"pollingIntervalMillis": *[0-9]*' | head -1 | grep -oE '[0-9]+')
                    if [ -n "$NEW_INTERVAL" ] && [ "$NEW_INTERVAL" -ge 5000 ]; then
                        CHAT_POLL_INTERVAL=$(( NEW_INTERVAL / 1000 ))
                    fi
                    while IFS= read -r MSG; do
                        NORM=$(echo "$MSG" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
                        case "$NORM" in
                            '!vote1') VOTES1=$((VOTES1 + 1)) ;;
                            '!vote2') VOTES2=$((VOTES2 + 1)) ;;
                        esac
                    done < <(echo "$CRESP" | grep -o '"displayMessage": *"[^"]*"' | sed -E 's/.*"displayMessage": *"([^"]*)".*/\1/')

                    TOTAL=$((VOTES1 + VOTES2))
                    if [ "$TOTAL" -gt 0 ]; then
                        PCT1=$(( VOTES1 * 100 / TOTAL ))
                        PCT2=$((100 - PCT1))
                        render_bar "$PCT1" > "$ASSET_DIR/poll_bar1.txt.tmp" && mv -f "$ASSET_DIR/poll_bar1.txt.tmp" "$ASSET_DIR/poll_bar1.txt"
                        render_bar "$PCT2" > "$ASSET_DIR/poll_bar2.txt.tmp" && mv -f "$ASSET_DIR/poll_bar2.txt.tmp" "$ASSET_DIR/poll_bar2.txt"
                        printf '%s votes  •  %s%% / %s%%' "$TOTAL" "$PCT1" "$PCT2" > "$ASSET_DIR/poll_votes.txt.tmp" && mv -f "$ASSET_DIR/poll_votes.txt.tmp" "$ASSET_DIR/poll_votes.txt"
                    fi
                fi
            fi
        fi

        sleep "$CHAT_POLL_INTERVAL"
    done
) &
POLL_PID=$!

#############################################
# Static panel text (unchanged across videos)
#############################################
printf 'J A M E S   W E B B'              > "$ASSET_DIR/title1.txt"
printf 'S P A C E   T E L E S C O P E'    > "$ASSET_DIR/title2.txt"
printf "T O D A Y ' S   D I S C O V E R Y" > "$ASSET_DIR/header.txt"
printf 'DEEP SPACE REPORT'                > "$ASSET_DIR/eyebrow.txt"
printf 'SUBSCRIBE for daily space discoveries' > "$ASSET_DIR/cta.txt"
printf 'DID YOU KNOW' > "$ASSET_DIR/fact_label.txt"

#############################################
# Default headline / fact pools (used as a
# last resort if galaxy_info.txt / facts.txt
# are missing or empty)
#############################################
DEFAULT_HEADLINES=(
    "The James Webb Space Telescope continues revealing the Universe in extraordinary infrared detail."
    "Webb is looking deeper into cosmic history, studying some of the earliest galaxies ever observed."
    "Astronomers are using Webb to investigate the atmospheres and chemistry of distant exoplanets."
    "Infrared observations are revealing stellar nurseries hidden behind dense clouds of cosmic dust."
    "Webb is helping scientists investigate how the first galaxies formed and evolved after the Big Bang."
    "Distant galaxies observed by Webb are giving astronomers new clues about the evolution of the cosmos."
    "Webb observations are revealing complex chemistry in the regions where stars and planets are born."
    "Young planetary systems are helping scientists understand how worlds form around distant stars."
    "Webb continues studying protoplanetary disks where the building blocks of new planets are taking shape."
    "Astronomers are using Webb to explore the environments surrounding supermassive black holes."
    "The Euclid mission is mapping billions of galaxies to investigate the nature of dark matter and dark energy."
    "The Vera C. Rubin Observatory is beginning a new era of wide-field astronomical observations of the Southern Sky."
    "Gravitational-wave observatories are opening another window onto violent events across the Universe."
    "Scientists are combining observations from Webb and other observatories to build a more complete picture of cosmic evolution."
    "Every deep-space observation adds another piece to the story of how galaxies, stars, and planets came to exist."
)

DEFAULT_FACTS=(
    "The Universe is approximately 13.8 billion years old."
    "A light-year is the distance light travels in one year, about 9.46 trillion kilometers."
    "The James Webb Space Telescope observes the Universe primarily in infrared wavelengths."
    "Webb can observe extremely distant galaxies whose light has traveled for more than 13 billion years."
    "Webb studies the atmospheres of exoplanets by analyzing how their atmospheres interact with starlight."
    "Infrared astronomy allows Webb to see through some clouds of cosmic dust that block visible light."
    "Webb is studying how stars and planetary systems form inside clouds of gas and dust."
    "Some early galaxies observed by Webb existed within the first few hundred million years of cosmic history."
    "Astronomers use Webb to investigate how galaxies assembled and evolved over billions of years."
    "The Milky Way contains hundreds of billions of stars."
    "The observable Universe contains an enormous number of galaxies, each containing millions to trillions of stars."
    "The Sun contains about 99.8 percent of the mass of the Solar System."
    "Jupiter is the largest planet in our Solar System."
    "Mars is home to Olympus Mons, the largest known volcano in the Solar System."
    "Saturn's spectacular rings are made primarily of water-ice particles mixed with rock and dust."
    "Venus is the hottest planet in the Solar System because of its powerful greenhouse effect."
    "Mercury experiences extreme temperature differences between its day and night sides."
    "Neptune has the fastest planetary winds measured in the Solar System, exceeding 2,000 kilometers per hour."
    "Uranus rotates with an extreme axial tilt of about 98 degrees, making it appear to rotate on its side."
    "Earth is currently the only planet known to naturally support life."
    "The Moon is slowly moving away from Earth at an average rate of about 3.8 centimeters per year."
    "The International Space Station orbits Earth at roughly 28,000 kilometers per hour."
    "Neutron stars pack more mass than the Sun into a sphere only a few tens of kilometers across."
    "A black hole's event horizon marks the boundary beyond which light cannot escape."
    "At the center of the Milky Way lies a supermassive black hole called Sagittarius A*."
    "Gravitational waves are ripples in spacetime produced by accelerating massive objects, including merging black holes."
    "Dark matter does not emit or reflect light in a way we can directly detect, but its gravitational effects reveal its presence."
    "Dark energy is the name given to the unknown component associated with the accelerating expansion of the Universe."
    "The Milky Way and Andromeda galaxies are expected to interact and eventually merge over billions of years."
    "A supernova is a powerful stellar explosion associated with the death of certain massive stars and other stellar events."
    "The core of the Sun reaches temperatures of roughly 15 million degrees Celsius."
    "Proxima Centauri is the closest known star to the Sun, at about 4.24 light-years away."
    "Thousands of exoplanets have been confirmed beyond our Solar System."
    "Exoplanets range from enormous gas giants to rocky worlds and planets with unusual atmospheric compositions."
    "Galaxies are connected across the Universe by a vast cosmic web of filaments, walls, and enormous voids."
    "Einstein's theory of relativity predicts that clocks run more slowly in stronger gravitational fields."
    "Voyager 1 is the most distant human-made spacecraft from Earth."
    "Voyager 1 crossed the heliopause and entered interstellar space in 2012."
    "Earth's magnetic field helps shield the planet from charged particles carried by the solar wind."
    "Auroras occur when energetic charged particles interact with gases in Earth's upper atmosphere."
    "Webb has produced some of the deepest and most detailed infrared observations of the distant Universe."
    "Webb is helping astronomers investigate how the earliest galaxies formed and evolved."
    "Some early galaxies observed by Webb appear surprisingly bright and massive, providing important tests for galaxy-formation models."
    "Star-forming nebulae contain enormous clouds of gas and dust where new stars can form."
    "The asteroid belt between Mars and Jupiter contains millions of rocky bodies of different sizes."
    "Comets are icy bodies that can develop bright comas and tails when heated by the Sun."
    "Pulsars are rapidly rotating neutron stars that produce beams of electromagnetic radiation."
    "The Event Horizon Telescope produced the first image of a black hole's shadow in 2019."
    "In 2022, the Event Horizon Telescope revealed the first image of Sagittarius A*, the black hole at the center of our galaxy."
    "The search for potentially habitable exoplanets is one of the major goals of modern astronomy."
)

#############################################
# build_labels_chain: optional feature — draws
# pointer/callout labels onto specific
# coordinates in the video, similar to
# hand-annotated documentary footage. Fully
# optional per video: only activates if a file
# named <basename>.labels.txt exists.
#
# File format — one label per line, comma
# separated:
#   x,y,Label text here
# where x,y is the pixel position on the
# 1280x720 output frame that the label should
# point at. Box placement, connector line, and
# edge-avoidance (flips below/left near frame
# edges) are computed automatically.
#
# Visual style matches the rest of the panel:
# gold-ring/white marker dot (uses the
# pre-rendered dot_marker.png), gold-tinted
# connector line, and a label box with a gold
# accent bar + thin gold outline (same language
# as the CTA box).
#
# Notes/limits:
#  - Keep label text under ~28 characters — the
#    box is a fixed width and does not
#    reflow/resize to fit longer text.
#  - Best used for points with x > ~370 so
#    labels don't collide with the left info
#    panel.
#  - The connector is a right-angle line
#    (vertical then horizontal), not a true
#    diagonal — ffmpeg has no native diagonal
#    line primitive without much heavier
#    filters, so this is the practical choice.
#  - Requires dot_marker.png (generated once at
#    startup) to be wired in as ffmpeg input
#    index 2 — see run_video()'s -i list.
#
# Sets globals: LABELS_CHAIN (filter string to
# append), LABELS_OUT (bracketed output label
# to continue the chain from, e.g. "[base]" if
# no labels file exists, or the last label's
# output node otherwise).
#############################################
build_labels_chain() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"

    # FIX: without `local`, every bare loop variable assigned in this
    # function (i, idx, and the C-style `for ((i=...))` counters below)
    # is a GLOBAL bash variable. The main stream loop at the bottom of
    # this file also uses a bare `i` (`for ((i = 0; i < NUM_URLS; i++))`),
    # and this function runs (via prepare_video_content -> run_video)
    # once per video inside that loop. Any unscoped `i`/`idx` in here
    # silently overwrites the outer loop's counter, which is what caused
    # the stream to get stuck replaying the first video forever instead
    # of advancing through the whole playlist.
    local i idx

    LABELS_CHAIN=""
    LABELS_OUT="[base]"

    local labels_file="${base}.labels.txt"
    if [ ! -f "$labels_file" ]; then
        return 0
    fi

    # First pass: collect valid lines so we know the count up front
    # (needed to size the marker `split` filter correctly).
    local xs=() ys=() texts=()
    while IFS=',' read -r x y text; do
        x="$(echo "$x" | tr -d '[:space:]')"
        y="$(echo "$y" | tr -d '[:space:]')"
        text="$(echo "$text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ "$x" =~ ^[0-9]+$ ]] || continue
        [[ "$y" =~ ^[0-9]+$ ]] || continue
        [ -z "$text" ] && continue
        xs+=("$x"); ys+=("$y"); texts+=("$text")
    done < "$labels_file"

    local n=${#xs[@]}
    if [ "$n" -eq 0 ]; then
        echo "NOTICE: $labels_file had no valid lines — skipping labels for this video."
        return 0
    fi
    echo "Using coordinate labels: $labels_file ($n label(s))"

    local BOX_H=42
    local V_OFFSET=70
    local H_OFFSET=40
    local ACCENT_W=4
    local BOX_GAP=10          # minimum clear space required between two label boxes
    local LABEL_FONTSIZE=18
    local LABEL_PAD_L=14      # gap between accent bar and text start
    local LABEL_PAD_R=16      # gap between text end and box's right edge
    local AVG_CHAR_W=10       # rough proportional-font width estimate at fontsize 18
    local BOX_W_MIN=110       # never smaller than this, even for a 1-word label
    local BOX_W_MAX=260       # never bigger than this, even for a long label
    local placed_x=() placed_y=() placed_w=()  # boxes already placed this video
    local k collision tries

    # Split the pre-rendered marker image (input [2:v]) into one copy per
    # label so each can be overlaid independently at its own coordinate.
    local split_outs=""
    for ((i = 1; i <= n; i++)); do split_outs+="[dm${i}]"; done
    LABELS_CHAIN+="[2:v]split=${n}${split_outs};"

    local prev="base"
    for ((i = 0; i < n; i++)); do
        idx=$((i + 1))
        local x="${xs[$i]}" y="${ys[$i]}" text="${texts[$i]}"
        printf '%s' "$text" > "$ASSET_DIR/label${idx}.txt"

        # Auto-size the box to the label's text instead of using one
        # fixed width for every label — "Pulsar Wind" no longer gets the
        # same wide box as a much longer phrase.
        local box_w=$(( ${#text} * AVG_CHAR_W + ACCENT_W + LABEL_PAD_L + LABEL_PAD_R ))
        [ "$box_w" -lt "$BOX_W_MIN" ] && box_w=$BOX_W_MIN
        [ "$box_w" -gt "$BOX_W_MAX" ] && box_w=$BOX_W_MAX

        local box_y=$((y - V_OFFSET))
        if [ "$box_y" -lt 20 ]; then
            box_y=$((y + V_OFFSET - BOX_H))
        fi
        local box_x=$((x + H_OFFSET))
        if [ $((box_x + box_w)) -gt 1260 ]; then
            box_x=$((x - H_OFFSET - box_w))
        fi
        [ "$box_x" -lt 0 ] && box_x=10

        # Collision avoidance: if this box overlaps (within BOX_GAP of)
        # any box already placed for an earlier label on this video,
        # push it downward in BOX_H+BOX_GAP steps until it's clear, so
        # two nearby coordinate labels never end up crowding each other
        # like "Glowing gas knot" / "Dust cloud region" did before.
        tries=0
        while :; do
            collision=false
            for ((k = 0; k < ${#placed_x[@]}; k++)); do
                local px="${placed_x[$k]}" py="${placed_y[$k]}" pw="${placed_w[$k]}"
                if [ $((box_x)) -lt $((px + pw + BOX_GAP)) ] && \
                   [ $((box_x + box_w + BOX_GAP)) -gt $((px)) ] && \
                   [ $((box_y)) -lt $((py + BOX_H + BOX_GAP)) ] && \
                   [ $((box_y + BOX_H + BOX_GAP)) -gt $((py)) ]; then
                    collision=true
                    break
                fi
            done
            [ "$collision" = false ] && break
            box_y=$((box_y + BOX_H + BOX_GAP))
            # Ran off the bottom of the frame — wrap back to the top and
            # keep nudging; after a handful of tries just accept overlap
            # rather than loop forever (extremely dense label sets only).
            if [ $((box_y + BOX_H)) -gt 700 ]; then
                box_y=20
            fi
            tries=$((tries + 1))
            [ "$tries" -gt 12 ] && break
        done
        placed_x+=("$box_x")
        placed_y+=("$box_y")
        placed_w+=("$box_w")

        local seg_y_top seg_y_bot
        if [ "$box_y" -gt "$y" ]; then
            seg_y_top=$y; seg_y_bot=$box_y
        else
            seg_y_top=$box_y; seg_y_bot=$y
        fi
        local seg_h=$((seg_y_bot - seg_y_top))
        [ "$seg_h" -lt 2 ] && seg_h=2

        local h_left h_w
        if [ "$box_x" -gt "$x" ]; then
            h_left=$x; h_w=$((box_x - x))
        else
            h_left=$box_x; h_w=$((x - box_x))
        fi
        [ "$h_w" -lt 2 ] && h_w=2

        local n1="lbl${idx}_dot" n2="lbl${idx}_v" n3="lbl${idx}_h" n4="lbl${idx}_bg" n5="lbl${idx}_bar" n6="lbl${idx}_outline" n7="lbl${idx}_txt"

        # Gold-tinted connector line (right-angle: vertical then horizontal)
        LABELS_CHAIN+="[${prev}]drawbox=x=${x}:y=${seg_y_top}:w=2:h=${seg_h}:color=${GOLD}@0.85:t=fill[${n2}];"
        LABELS_CHAIN+="[${n2}]drawbox=x=${h_left}:y=${box_y}:w=${h_w}:h=2:color=${GOLD}@0.85:t=fill[${n3}];"
        # Label box: dark fill + gold accent bar (left edge) + thin gold outline
        LABELS_CHAIN+="[${n3}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=black@0.78:t=fill[${n4}];"
        LABELS_CHAIN+="[${n4}]drawbox=x=${box_x}:y=${box_y}:w=${ACCENT_W}:h=${BOX_H}:color=${GOLD}:t=fill[${n5}];"
        LABELS_CHAIN+="[${n5}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=${GOLD}@0.5:t=1[${n6}];"
        LABELS_CHAIN+="[${n6}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/label${idx}.txt:fontcolor=white:fontsize=${LABEL_FONTSIZE}:x=$((box_x + ACCENT_W + LABEL_PAD_L)):y=$((box_y + (BOX_H - LABEL_FONTSIZE) / 2)):${SHADOW}[${n7}];"
        # Circular gold-ring/white marker dot, overlaid on top of everything
        LABELS_CHAIN+="[${n7}][dm${idx}]overlay=x=$((x - 8)):y=$((y - 8))[${n1}];"

        prev="$n1"
    done

    LABELS_OUT="[${prev}]"
    echo "Drew $n label(s) from $labels_file"
}

#############################################
# prepare_video_content: (re)loads headlines +
# facts for the video about to stream, and
# rebuilds BASE_CHAIN / FACT_END to match.
#
# Per-video override: if files named
#   <basename>.headlines.txt
#   <basename>.facts.txt
#   <basename>.category.txt   (optional short chip label, e.g. "COMETS")
#   <basename>.nofacts        (optional empty flag file — hides facts)
# exist (basename = video filename without
# extension — same derivation used for the
# up-next bumper title), they're used verbatim,
# in the order given. Useful for curating panel
# content to match a specific video.
#
# Otherwise falls back to the shared pool
# (galaxy_info.txt / facts.txt / built-in
# defaults), shuffled into a fresh random order
# each video so the panel doesn't feel like a
# static banner repeating identically on every
# clip.
#############################################
prepare_video_content() {
    local url="$1"
    local base
    base="${url##*/}"
    base="${base%.*}"

    # Segment counter globals are set by the main stream loop before
    # calling run_video(); default them here too so this function stays
    # safe to call standalone (e.g. future tooling/tests).
    : "${CURRENT_INDEX:=1}"
    : "${TOTAL_VIDEOS:=1}"
    : "${VIDEO_START_OFFSET:=0}"

    # Poll panel is visible only for the final POLL_WINDOW seconds of
    # every POLL_CYCLE-second cycle — a brief "results reveal" — with
    # the info panel (headlines/facts) running the rest of the time.
    # VIDEO_START_OFFSET (set by run_video()) shifts ffmpeg's own
    # per-process `t` back onto real wall-clock time so this stays in
    # sync across video boundaries.
    local poll_start=$((POLL_CYCLE - POLL_WINDOW))
    POLL_ENABLE="gte(mod(t+${VIDEO_START_OFFSET}\,${POLL_CYCLE})\,${poll_start})"
    INFO_ENABLE="lt(mod(t+${VIDEO_START_OFFSET}\,${POLL_CYCLE})\,${poll_start})"

    # Optional category chip (e.g. "EXOPLANETS", "BLACK HOLES") shown
    # next to the section header when a <basename>.category.txt file
    # exists for this video. Purely additive — if the file is missing
    # or empty, no chip is drawn at all.
    SHOW_CATEGORY=false
    if [ -f "${base}.category.txt" ]; then
        CATEGORY_TEXT="$(head -n1 "${base}.category.txt" | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ -n "$CATEGORY_TEXT" ]; then
            printf '%s' "$CATEGORY_TEXT" > "$ASSET_DIR/category.txt"
            SHOW_CATEGORY=true
        fi
    fi

    # Optional per-video flag to hide the "DID YOU KNOW" fact panel —
    # useful for videos whose footage is already text-heavy (e.g. an
    # infographic clip) where a second block of text would compete for
    # attention rather than add to it. Create an empty file named
    # <basename>.nofacts next to the video to suppress it.
    SHOW_FACTS=true
    if [ -f "${base}.nofacts" ]; then
        SHOW_FACTS=false
        echo "NOTICE: ${base}.nofacts present — hiding the fact panel for this video."
    fi

    # FIX: same reasoning as build_labels_chain() above — this function
    # is also called once per video from inside the outer stream loop
    # (`for ((i = 0; i < NUM_URLS; i++))` at the bottom of this file),
    # and it reuses bare `i`/`idx` in several for-loops below. Without
    # `local`, those loops overwrite the outer loop's global `i`, which
    # made the stream get stuck re-playing the first video forever
    # instead of advancing through the playlist.
    local i idx

    RAW_LINES=()
    if [ -f "${base}.headlines.txt" ]; then
        echo "Using curated headlines: ${base}.headlines.txt"
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && RAW_LINES+=("$line")
        done < "${base}.headlines.txt"
    fi
    if [ "${#RAW_LINES[@]}" -eq 0 ]; then
        local pool=()
        if [ -f "$INFO_FILE" ]; then
            while IFS= read -r line; do
                [ -n "$(echo "$line" | tr -d '[:space:]')" ] && pool+=("$line")
            done < "$INFO_FILE"
        fi
        [ "${#pool[@]}" -eq 0 ] && pool=("${DEFAULT_HEADLINES[@]}")
        while IFS= read -r line; do
            RAW_LINES+=("$line")
        done < <(printf '%s\n' "${pool[@]}" | shuf)
    fi

    FACTS=()
    if [ -f "${base}.facts.txt" ]; then
        echo "Using curated facts: ${base}.facts.txt"
        while IFS= read -r line; do
            [ -n "$(echo "$line" | tr -d '[:space:]')" ] && FACTS+=("$line")
        done < "${base}.facts.txt"
    fi
    if [ "${#FACTS[@]}" -eq 0 ]; then
        local fpool=()
        if [ -f "facts.txt" ]; then
            while IFS= read -r line; do
                [ -n "$(echo "$line" | tr -d '[:space:]')" ] && fpool+=("$line")
            done < "facts.txt"
        fi
        [ "${#fpool[@]}" -eq 0 ] && fpool=("${DEFAULT_FACTS[@]}")
        while IFS= read -r line; do
            FACTS+=("$line")
        done < <(printf '%s\n' "${fpool[@]}" | shuf)
    fi

    N=${#RAW_LINES[@]}
    CYCLE=$((N * SLOT))
    echo "This video: $N headline(s), rotation cycle ${CYCLE}s"

    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        echo "${RAW_LINES[$i]}" | fold -s -w 25 > "$ASSET_DIR/headline${idx}.txt"
    done

    MAX_HEADLINE_LINES=1
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        lines=$(grep -c '' "$ASSET_DIR/headline${idx}.txt")
        [ "$lines" -gt "$MAX_HEADLINE_LINES" ] && MAX_HEADLINE_LINES=$lines
    done
    echo "Longest headline wraps to $MAX_HEADLINE_LINES line(s)."

    HEADLINE_Y=230
    PROGRESS_Y=$((HEADLINE_Y + MAX_HEADLINE_LINES * HEADLINE_LINE_H + 40))
    DOTS_Y=$((PROGRESS_Y + 20))
    FACT_DIVIDER_Y=$((DOTS_Y + 40))
    FACT_LABEL_Y=$((FACT_DIVIDER_Y + 14))
    FACT_TEXT_Y=$((FACT_LABEL_Y + 20))

    TICKER_STRING=""
    for i in "${!RAW_LINES[@]}"; do
        TICKER_STRING+="${RAW_LINES[$i]}     •     "
    done
    printf '%s' "$TICKER_STRING" > "$ASSET_DIR/ticker.txt"

    FACT_N=${#FACTS[@]}
    FACT_CYCLE=$((FACT_N * FACT_SLOT))
    for i in "${!FACTS[@]}"; do
        idx=$((i + 1))
        echo "${FACTS[$i]}" | fold -s -w 23 > "$ASSET_DIR/fact${idx}.txt"
    done

    #########################################
    # Rebuild BASE_CHAIN for this video's content
    #########################################
    # Gentle vignette on the raw footage gives the frame a cinematic,
    # "shot on a documentary camera" depth instead of a flat, clinical
    # rectangle — subtle enough not to darken the subject itself.
    CHAIN="[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black,vignette=PI/6[video];"
    CHAIN+="[1:v]scale=1280:720:flags=fast_bilinear[ovl];"
    CHAIN+="[ovl][video]overlay=0:0[base];"

    # Optional coordinate-based callout labels for this video, drawn onto
    # the raw video before the panel/UI so the panel stays on top.
    build_labels_chain "$url"
    CHAIN+="$LABELS_CHAIN"

    # Panel drawn directly onto the video+labels plate. (A crossfade
    # entrance animation was tried here — split into two copies and
    # blend them in over 0.5s — but benchmarking showed `blend`'s
    # per-pixel expression evaluation runs on every frame for the
    # entire video, not just the fade window, and alone accounted for
    # roughly 85-90% of total render time (measured: ~8x slower with it
    # than without, on identical filter graphs). On a CPU-constrained
    # 24/7 stream that's not a trade worth making for a cosmetic fade,
    # so the panel now just appears directly, the same reliable/cheap
    # way every other element in this script is drawn.
    CHAIN+="${LABELS_OUT}drawbox=x=0:y=0:w=333:h=720:color=${NAVY}@0.82:t=fill[p1];"
    CHAIN+="[p1]drawbox=x=333:y=0:w=4:h=720:color=${NAVY}@0.62:t=fill[p2];"
    CHAIN+="[p2]drawbox=x=337:y=0:w=4:h=720:color=${NAVY}@0.42:t=fill[p3];"
    CHAIN+="[p3]drawbox=x=341:y=0:w=4:h=720:color=${NAVY}@0.24:t=fill[p3b];"
    CHAIN+="[p3b]drawbox=x=345:y=0:w=3:h=720:color=${NAVY}@0.10:t=fill[p4];"
    CHAIN+="[p4]drawbox=x=0:y=0:w=348:h=3:color=${GOLD}@0.9:t=fill[p5];"
    CHAIN+="[p5]drawbox=x=348:y=0:w=1:h=720:color=${GOLD}@0.45:t=fill[p6];"

    # LIVE badge: a proper capsule plate (thin gold outline + dark fill)
    # behind the pulsing dot and label, instead of the dot/text floating
    # bare on the panel — reads like a real broadcast lower-third chip.
    CHAIN+="[p6]drawbox=x=22:y=16:w=100:h=30:color=black@0.5:t=fill[p6a];"
    CHAIN+="[p6a]drawbox=x=22:y=16:w=100:h=30:color=${GOLD}@0.55:t=1[p6b];"
    CHAIN+="[p6b]drawbox=x=34:y=27:w=10:h=10:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[p7];"
    CHAIN+="[p7]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=20:x=52:y=23[p8];"

    CHAIN+="[p8]drawtext=fontfile=${FONT}:text='Credits\: NASA':fontcolor=${SILVER}@0.85:fontsize=14:x=313-text_w:y=19:${SHADOW}[p9];"
    CHAIN+="[p9]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=14:x=313-text_w:y=39:${SHADOW}[p10];"
    CHAIN+="[p10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/subs.txt:reload=1:fontcolor=${SILVER}@0.85:fontsize=13:x=313-text_w:y=57:${SHADOW}[p10b];"
    CHAIN+="[p10b]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/viewers.txt:reload=1:fontcolor=${SILVER}@0.85:fontsize=13:x=313-text_w:y=75:${SHADOW}[p10c];"

    # Kicker tag first (small gold tag with a left tick, documentary
    # "series eyebrow" style), then the main title, then the section
    # header directly above the rotating headline it belongs to — a
    # clearer reading order than the old title->header->eyebrow stack.
    CHAIN+="[p10c]drawbox=x=33:y=104:w=3:h=11:color=${GOLD}:t=fill[p10d];"
    CHAIN+="[p10d]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${GOLD}:fontsize=12:x=45:y=104[p11a];"

    CHAIN+="[p11a]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=24:x=33:y=128:${SHADOW}[p11];"
    CHAIN+="[p11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title2.txt:fontcolor=${SILVER}:fontsize=16:x=33:y=158:${SHADOW}[p12];"
    CHAIN+="[p12]drawbox=x=33:y=186:w=280:h=1:color=${GOLD}@0.35:t=fill[p13];"

    #########################################
    # POLL PANEL (a brief results reveal — the
    # final POLL_WINDOW seconds of every
    # POLL_CYCLE-second cycle)
    #########################################
    CHAIN+="[p13]drawbox=x=33:y=202:w=8:h=8:color=${RED}:t=fill:enable='${POLL_ENABLE}'[pv1];"
    CHAIN+="[pv1]drawtext=fontfile=${FONT}:text='LIVE POLL':fontcolor=${GOLD}:fontsize=15:x=49:y=199:enable='${POLL_ENABLE}'[pv2];"
    CHAIN+="[pv2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/poll_question.txt:reload=1:expansion=none:fontcolor=white:fontsize=19:line_spacing=8:x=33:y=228:enable='${POLL_ENABLE}':${SHADOW}[pv3];"

    CHAIN+="[pv3]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/poll_opt1.txt:reload=1:expansion=none:fontcolor=${GOLD}:fontsize=14:x=33:y=328:enable='${POLL_ENABLE}'[pv4];"
    CHAIN+="[pv4]drawbox=x=33:y=350:w=280:h=16:color=black@0.35:t=fill:enable='${POLL_ENABLE}'[pv5];"
    CHAIN+="[pv5]drawbox=x=33:y=350:w=280:h=16:color=${GOLD}@0.4:t=1:enable='${POLL_ENABLE}'[pv6];"
    CHAIN+="[pv6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/poll_bar1.txt:reload=1:expansion=none:fontcolor=${GOLD}:fontsize=13:x=37:y=352:enable='${POLL_ENABLE}'[pv7];"

    CHAIN+="[pv7]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/poll_opt2.txt:reload=1:expansion=none:fontcolor=${GOLD}:fontsize=14:x=33:y=384:enable='${POLL_ENABLE}'[pv8];"
    CHAIN+="[pv8]drawbox=x=33:y=406:w=280:h=16:color=black@0.35:t=fill:enable='${POLL_ENABLE}'[pv9];"
    CHAIN+="[pv9]drawbox=x=33:y=406:w=280:h=16:color=${GOLD}@0.4:t=1:enable='${POLL_ENABLE}'[pv10];"
    CHAIN+="[pv10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/poll_bar2.txt:reload=1:expansion=none:fontcolor=${GOLD}:fontsize=13:x=37:y=408:enable='${POLL_ENABLE}'[pv11];"

    CHAIN+="[pv11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/poll_votes.txt:reload=1:expansion=none:fontcolor=${SILVER}@0.8:fontsize=11:x=33:y=440:enable='${POLL_ENABLE}':${SHADOW}[pv12];"

    #########################################
    # INFO PANEL (headlines/facts — the default,
    # running for all but the final POLL_WINDOW
    # seconds of each POLL_CYCLE)
    #########################################
    CHAIN+="[pv12]drawbox=x=33:y=202:w=8:h=8:color=${GOLD}:t=fill:enable='${INFO_ENABLE}'[p14];"
    CHAIN+="[p14]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/header.txt:fontcolor=${GOLD}:fontsize=15:x=49:y=199:enable='${INFO_ENABLE}'[p16];"

    local prev="p16"
    if [ "$SHOW_CATEGORY" = true ]; then
        local cat_w=$(( ${#CATEGORY_TEXT} * 8 + 24 ))
        [ "$cat_w" -lt 70 ] && cat_w=70
        [ "$cat_w" -gt 160 ] && cat_w=160
        local cat_x=$((313 - cat_w))
        # Aligned with the short kicker row (y=104), not the wide
        # letter-spaced "TODAY'S DISCOVERY" header row below it, which
        # runs edge-to-edge and would collide with a right-aligned chip.
        CHAIN+="[${prev}]drawbox=x=${cat_x}:y=100:w=${cat_w}:h=20:color=${NAVY}@0.9:t=fill[catbg];"
        CHAIN+="[catbg]drawbox=x=${cat_x}:y=100:w=${cat_w}:h=20:color=${GOLD}@0.6:t=1[catout];"
        CHAIN+="[catout]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/category.txt:fontcolor=${GOLD}:fontsize=11:x=$((cat_x + 10)):y=106[catxt];"
        prev="catxt"
    fi
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local start=$((i * SLOT))
        local end=$((start + SLOT))
        local nxt="h${idx}"
        local ALPHA="if(between(mod(t\,${CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${CYCLE})-${start}\,0.6)\,(mod(t\,${CYCLE})-${start})/0.6\,if(gt(mod(t\,${CYCLE})-${start}\,${SLOT}-0.6)\,(${end}-mod(t\,${CYCLE}))/0.6\,1))\,0)"
        CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/headline${idx}.txt:fontcolor=white:fontsize=${HEADLINE_FONTSIZE}:line_spacing=${HEADLINE_LINE_SPACING}:x=33:y=${HEADLINE_Y}:alpha='${ALPHA}':enable='${INFO_ENABLE}':${SHADOW}[${nxt}];"
        prev="$nxt"
    done

    CHAIN+="[${prev}]drawtext=fontfile=${FONT}:text='STORY ${CURRENT_INDEX} OF ${TOTAL_VIDEOS}':fontcolor=${SILVER}@0.8:fontsize=10:x=33:y=$((PROGRESS_Y - 16)):enable='${INFO_ENABLE}':${SHADOW}[pgcap];"
    CHAIN+="[pgcap]drawbox=x=33:y=${PROGRESS_Y}:w=280:h=2:color=${SILVER}@0.35:t=fill:enable='${INFO_ENABLE}'[pg1];"
    CHAIN+="[pg1]drawbox=x=33:y=${PROGRESS_Y}:w='280*(mod(t\,${SLOT}))/${SLOT}':h=2:color=${GOLD}:t=fill:enable='${INFO_ENABLE}'[pg2];"
    prev="pg2"

    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local x=$((33 + i * 17))
        local nxt="db${idx}"
        CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=white@0.3:t=fill:enable='${INFO_ENABLE}'[${nxt}];"
        prev="$nxt"
    done

    local last=$((N - 1))
    for i in "${!RAW_LINES[@]}"; do
        idx=$((i + 1))
        local x=$((33 + i * 17))
        local start=$((i * SLOT))
        local end=$((start + SLOT))
        local ENABLE="${INFO_ENABLE}*between(mod(t\,${CYCLE})\,${start}\,${end})"
        if [ "$i" -eq "$last" ]; then
            CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[pdotend];"
            prev="pdotend"
        else
            local nxt="da${idx}"
            CHAIN+="[${prev}]drawbox=x=${x}:y=${DOTS_Y}:w=7:h=7:color=${GOLD}:t=fill:enable='${ENABLE}'[${nxt}];"
            prev="$nxt"
        fi
    done

    if [ "$SHOW_FACTS" = true ]; then
        CHAIN+="[${prev}]drawbox=x=33:y=${FACT_DIVIDER_Y}:w=280:h=2:color=${GOLD}@0.4:t=fill:enable='${INFO_ENABLE}'[fp1];"
        CHAIN+="[fp1]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact_label.txt:fontcolor=${GOLD}@0.85:fontsize=12:x=33:y=${FACT_LABEL_Y}:enable='${INFO_ENABLE}'[fp2];"
        prev="fp2"
        for i in "${!FACTS[@]}"; do
            idx=$((i + 1))
            local start=$((i * FACT_SLOT))
            local end=$((start + FACT_SLOT))
            local nxt="f${idx}"
            local FALPHA="if(between(mod(t\,${FACT_CYCLE})\,${start}\,${end})\,if(lt(mod(t\,${FACT_CYCLE})-${start}\,0.6)\,(mod(t\,${FACT_CYCLE})-${start})/0.6\,if(gt(mod(t\,${FACT_CYCLE})-${start}\,${FACT_SLOT}-0.6)\,(${end}-mod(t\,${FACT_CYCLE}))/0.6\,1))\,0)"
            CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/fact${idx}.txt:fontcolor=white@0.9:fontsize=16:line_spacing=7:x=33:y=${FACT_TEXT_Y}:alpha='${FALPHA}':enable='${INFO_ENABLE}'[${nxt}];"
            prev="$nxt"
        done
    fi

    BASE_CHAIN="$CHAIN"
    FACT_END="$prev"
}

#############################################
# build_final_filter: appends the CTA / next-
# video countdown / ticker / watermark / border
# section onto BASE_CHAIN. Called fresh for each
# video since the countdown depends on that
# video's probed duration.
#############################################
build_final_filter() {
    local total_duration="$1"
    local tail="$BASE_CHAIN"

    local CTA_CYCLE=240
    local CTA_SHOW=8
    local CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})\,if(lt(mod(t\,${CTA_CYCLE})\,0.6)\,mod(t\,${CTA_CYCLE})/0.6\,if(gt(mod(t\,${CTA_CYCLE})\,${CTA_SHOW}-0.6)\,(${CTA_SHOW}-mod(t\,${CTA_CYCLE}))/0.6\,1))\,0)"
    local CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})"
    local COUNTDOWN_ENABLE="not(${CTA_ENABLE})"

    # CTA capsule: soft outer glow (a slightly larger, dimmer gold box
    # behind the plate) plus a navy fill and a thin outline, reading
    # like a premium broadcast lower-third instead of a flat rectangle.
    tail+="[${FACT_END}]drawbox=x=729:y=616:w=515:h=51:color=${GOLD}@0.12:t=fill[cta_glow];"
    tail+="[cta_glow]drawbox=x=733:y=620:w=507:h=43:color=${NAVY}@0.85:t=fill[cta_bg];"
    tail+="[cta_bg]drawbox=x=733:y=620:w=507:h=43:color=${GOLD}@0.4:t=1[cta_outline];"
    tail+="[cta_outline]drawbox=x=733:y=620:w=4:h=43:color=${GOLD}:t=fill[cta_bar];"
    tail+="[cta_bar]drawbox=x=755:y=636:w=11:h=11:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta_dot];"
    tail+="[cta_dot]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=19:x=773:y=633:alpha='${CTA_ALPHA}'[cta_sub];"

    if [[ "$total_duration" =~ ^[0-9]+$ ]] && [ "$total_duration" -gt 0 ]; then
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='Next video in %{eif\:max(${total_duration}-t\,0)\:d}s':fontcolor=white:fontsize=19:x=773:y=633:enable='${COUNTDOWN_ENABLE}'[cta_final];"
    else
        tail+="[cta_sub]drawtext=fontfile=${FONT}:text='Coming up next...':fontcolor=white@0.85:fontsize=19:x=773:y=633:enable='${COUNTDOWN_ENABLE}'[cta_final];"
    fi

    # Bottom ticker: layered navy plate (two steps for a soft top edge)
    # with a slim gold hairline, and a refined "ON AIR" tag replacing the
    # old flat gold BULLETIN block — same function, a cleaner broadcast
    # aesthetic.
    tail+="[cta_final]drawbox=x=0:y=678:w=1280:h=2:color=${GOLD}@0.35:t=fill[tk0];"
    tail+="[tk0]drawbox=x=0:y=680:w=1280:h=40:color=${NAVY}@0.80:t=fill[tk1];"
    tail+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${GOLD}@0.9:t=fill[tk2];"
    tail+="[tk2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
    tail+="[tk3]drawbox=x=0:y=680:w=124:h=40:color=${NAVY}@0.95:t=fill[tk4];"
    tail+="[tk4]drawbox=x=0:y=682:w=117:h=1:color=${GOLD}@0.7:t=fill[tk4b];"
    tail+="[tk4b]drawbox=x=113:y=682:w=2:h=36:color=${GOLD}@0.5:t=fill[tk5];"
    tail+="[tk5]drawbox=x=17:y=690:w=8:h=8:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[tk5b];"
    tail+="[tk5b]drawtext=fontfile=${FONT}:text='ON AIR':fontcolor=${GOLD}:fontsize=15:x=33:y=693[tk6];"

    tail+="[tk6]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=${SILVER}@0.5:fontsize=15:borderw=1.5:bordercolor=black@0.7:x=353:y=655[wm1];"

    # Pulsing ring around the subscribe icon (baked into overlay.png at
    # SUB_ICON_X/SUB_ICON_Y) — visible for 1s out of every 3s, so it
    # catches the eye without being a constant distraction.
    local SUB_PULSE_ENABLE="lt(mod(t\,3)\,1)"
    local sub_ring_x=$((SUB_ICON_X - SUB_ICON_R))
    local sub_ring_y=$((SUB_ICON_Y - SUB_ICON_R))
    local sub_ring_d=$((SUB_ICON_R * 2))
    tail+="[wm1]drawbox=x=${sub_ring_x}:y=${sub_ring_y}:w=${sub_ring_d}:h=${sub_ring_d}:color=${GOLD}@0.9:t=3:enable='${SUB_PULSE_ENABLE}'[wm2];"

    # Broadcast-style corner frame brackets (thin gold L-marks inset from
    # each edge) — a classic documentary/mission-control framing touch
    # that reads as intentional composition rather than a raw video feed.
    local CL=34   # bracket arm length
    local CI=16   # inset from the frame edge
    local CT=2    # bracket line thickness
    tail+="[wm2]drawbox=x=${CI}:y=${CI}:w=${CL}:h=${CT}:color=${GOLD}@0.5:t=fill[cf1];"
    tail+="[cf1]drawbox=x=${CI}:y=${CI}:w=${CT}:h=${CL}:color=${GOLD}@0.5:t=fill[cf2];"
    tail+="[cf2]drawbox=x=$((1280 - CI - CL)):y=${CI}:w=${CL}:h=${CT}:color=${GOLD}@0.5:t=fill[cf3];"
    tail+="[cf3]drawbox=x=$((1280 - CI - CT)):y=${CI}:w=${CT}:h=${CL}:color=${GOLD}@0.5:t=fill[cf4];"
    tail+="[cf4]drawbox=x=${CI}:y=$((720 - CI - CT)):w=${CL}:h=${CT}:color=${GOLD}@0.5:t=fill[cf5];"
    tail+="[cf5]drawbox=x=${CI}:y=$((720 - CI - CL)):w=${CT}:h=${CL}:color=${GOLD}@0.5:t=fill[cf6];"
    tail+="[cf6]drawbox=x=$((1280 - CI - CL)):y=$((720 - CI - CT)):w=${CL}:h=${CT}:color=${GOLD}@0.5:t=fill[cf7];"
    tail+="[cf7]drawbox=x=$((1280 - CI - CT)):y=$((720 - CI - CL)):w=${CT}:h=${CL}:color=${GOLD}@0.5:t=fill[cf8];"

    # Sealed-frame finish: a hairline gold border reinforces the
    # broadcast-package feel; the flat black vignette box is gone now
    # that the actual footage carries a real vignette filter.
    tail+="[cf8]drawbox=x=0:y=0:w=1280:h=720:color=${GOLD}@0.25:t=1[final]"

    echo "$tail"
}

#############################################
# Up-next bumper: short branded title card
# streamed between videos to reduce drop-off
# at the loop/transition point.
#############################################
run_bumper() {
    local next_url="$1"

    local raw title
    raw="${next_url##*/}"
    raw="${raw%.*}"
    raw="${raw//[-_]/ }"
    raw="$(echo "$raw" | tr -d '[:space:]')"
    if [ -z "$raw" ] || [ ${#raw} -lt 3 ]; then
        title="A New Discovery"
    else
        raw="${next_url##*/}"
        raw="${raw%.*}"
        raw="${raw//[-_]/ }"
        title=$(echo "$raw" | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')
    fi

    local sub_idx=$((RANDOM % ${#BUMPER_MESSAGES[@]}))
    printf '%s' "$title" | fold -s -w 34 > "$ASSET_DIR/bumper_title.txt"
    printf '%s' "${BUMPER_MESSAGES[$sub_idx]}" > "$ASSET_DIR/bumper_sub.txt"

    echo ">>> Up next: $title"

    local fade_out_start
    fade_out_start=$(awk -v d="$BUMPER_DURATION" 'BEGIN{print d - 0.6}')

    local BFILTER
    BFILTER="[0:v]scale=1280:720:force_original_aspect_ratio=increase,crop=1280:720,vignette=PI/6[bg];"
    BFILTER+="[bg]drawbox=x=0:y=0:w=1280:h=720:color=${NAVY}@0.72:t=fill[b1a];"
    BFILTER+="[b1a]drawbox=x=22:y=16:w=100:h=30:color=black@0.5:t=fill[b1b];"
    BFILTER+="[b1b]drawbox=x=22:y=16:w=100:h=30:color=${GOLD}@0.55:t=1[b1c];"
    BFILTER+="[b1c]drawbox=x=34:y=27:w=10:h=10:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[b2];"
    BFILTER+="[b2]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=20:x=52:y=23[b3];"
    BFILTER+="[b3]drawbox=x=340:y=313:w=600:h=1:color=${GOLD}@0.6:t=fill[b4];"
    BFILTER+="[b4]drawtext=fontfile=${FONT}:text='UP NEXT':fontcolor=${GOLD}:fontsize=22:x=(w-text_w)/2:y=260[b5];"
    BFILTER+="[b5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/bumper_title.txt:fontcolor=white:fontsize=36:line_spacing=8:x=(w-text_w)/2:y=347:${SHADOW}[b6];"
    BFILTER+="[b6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/bumper_sub.txt:fontcolor=${SILVER}@0.85:fontsize=18:x=(w-text_w)/2:y=427[b7];"
    BFILTER+="[b7]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=${SILVER}@0.5:fontsize=14:x=(w-text_w)/2:y=470[b8];"
    BFILTER+="[b8]drawbox=x=16:y=16:w=34:h=2:color=${GOLD}@0.5:t=fill[bc1];"
    BFILTER+="[bc1]drawbox=x=16:y=16:w=2:h=34:color=${GOLD}@0.5:t=fill[bc2];"
    BFILTER+="[bc2]drawbox=x=1230:y=16:w=34:h=2:color=${GOLD}@0.5:t=fill[bc3];"
    BFILTER+="[bc3]drawbox=x=1262:y=16:w=2:h=34:color=${GOLD}@0.5:t=fill[bc4];"
    BFILTER+="[bc4]drawbox=x=16:y=670:w=34:h=2:color=${GOLD}@0.5:t=fill[bc5];"
    BFILTER+="[bc5]drawbox=x=16:y=636:w=2:h=34:color=${GOLD}@0.5:t=fill[bc6];"
    BFILTER+="[bc6]drawbox=x=1230:y=670:w=34:h=2:color=${GOLD}@0.5:t=fill[bc7];"
    BFILTER+="[bc7]drawbox=x=1262:y=636:w=2:h=34:color=${GOLD}@0.5:t=fill[bc8];"
    BFILTER+="[bc8]fade=t=in:st=0:d=0.5,fade=t=out:st=${fade_out_start}:d=0.6[final]"

    ffmpeg \
    -hide_banner \
    -loglevel warning \
    -loop 1 -t "$BUMPER_DURATION" -i overlay.png \
    -f lavfi -t "$BUMPER_DURATION" -i anullsrc=r=48000:cl=stereo \
    -filter_complex "$BFILTER" \
    -map "[final]" \
    -map 1:a \
    -r 24 \
    -s 1280x720 \
    -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -threads 2 \
    -profile:v high \
    -level 4.1 \
    -pix_fmt yuv420p \
    -b:v 3000k \
    -maxrate 3000k \
    -bufsize 6000k \
    -g 60 \
    -keyint_min 60 \
    -sc_threshold 0 \
    -c:a aac \
    -b:a 128k \
    -ar 48000 \
    -ac 2 \
    -f flv \
    "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}" || echo "WARNING: bumper failed, continuing to next video"
}

#############################################
# Stream one video with automatic retry on
# failure/crash (e.g. Bus error, network drop),
# instead of letting set -e kill the script.
#############################################
run_video() {
    local url="$1"
    local attempt=1

    # How far into the overall broadcast (not this video) we are right
    # now, in seconds. prepare_video_content()'s poll/info enable
    # expressions add this to ffmpeg's own `t` (which restarts at 0 for
    # every video, since each one is a fresh ffmpeg process) so the
    # panel switch follows real time across video boundaries instead of
    # restarting its 10-minute cycle every time a new clip begins.
    VIDEO_START_OFFSET=$(( $(date +%s) - STREAM_START_EPOCH ))

    # Load headlines/facts tied to this specific video (curated file if
    # present, otherwise a freshly shuffled pool) and rebuild the panel
    # filter chain to match.
    prepare_video_content "$url"

    # Probe actual duration so the CTA box can show a real countdown to
    # the next video. Falls back gracefully if probing fails.
    local duration
    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$url" 2>/dev/null || echo "")
    duration=${duration%.*}
    [[ "$duration" =~ ^[0-9]+$ ]] || duration=""
    if [ -n "$duration" ]; then
        echo "Probed duration: ${duration}s"
    else
        echo "Could not probe duration — countdown will show generic filler text."
    fi

    local filter
    filter=$(build_final_filter "$duration")

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        echo "----------------------------------------"
        echo "Streaming (attempt ${attempt}/${MAX_RETRIES}):"
        echo "$url"
        echo "----------------------------------------"

        set +e
        ffmpeg \
        -hide_banner \
        -loglevel info \
        -reconnect 1 \
        -reconnect_streamed 1 \
        -reconnect_delay_max 5 \
        -re \
        -i "$url" \
        -loop 1 -i overlay.png \
        -loop 1 -i "$DOT_MARKER" \
        -filter_complex "$filter" \
        -map "[final]" \
        -map 0:a? \
        -r 30 \
        -s 1280x720 \
        -c:v libx264 \
        -preset ultrafast \
        -tune zerolatency \
        -threads 2 \
        -profile:v high \
        -level 4.1 \
        -pix_fmt yuv420p \
        -b:v 3000k \
        -maxrate 3000k \
        -bufsize 6000k \
        -g 60 \
        -keyint_min 60 \
        -sc_threshold 0 \
        -c:a aac \
        -b:a 128k \
        -ar 48000 \
        -ac 2 \
        -shortest \
        -f flv \
        "rtmp://a.rtmp.youtube.com/live2/${YOUTUBE_STREAM_KEY}"
        local exit_code=$?
        set -e

        if [ "$exit_code" -eq 0 ]; then
            echo "Video finished normally."
            return 0
        fi

        echo "WARNING: ffmpeg exited with code ${exit_code} (attempt ${attempt}/${MAX_RETRIES})."
        attempt=$((attempt + 1))
        if [ "$attempt" -le "$MAX_RETRIES" ]; then
            echo "Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        else
            echo "ERROR: Max retries reached for this video. Moving on."
        fi
    done
    return 1
}

#############################################
# Stream loop
#############################################
IFS=',' read -ra RAW_URLS <<< "$VIDEO_URL"
URLS=()
for u in "${RAW_URLS[@]}"; do
    u="${u#"${u%%[![:space:]]*}"}"
    u="${u%"${u##*[![:space:]]}"}"
    [ -n "$u" ] && URLS+=("$u")
done
NUM_URLS=${#URLS[@]}
if [ "$NUM_URLS" -eq 0 ]; then
    echo "ERROR: VIDEO_URL contained no valid entries after parsing"
    exit 1
fi

# Shuffle playback order fresh for every workflow run, so the sequence
# of videos isn't identical every time the 5-hour cron restarts the
# container. (Fisher-Yates via `shuf`, always available on Ubuntu.)
if [ "$NUM_URLS" -gt 1 ]; then
    mapfile -t URLS < <(printf '%s\n' "${URLS[@]}" | shuf)
    echo "Shuffled playback order for this run:"
    for u in "${URLS[@]}"; do
        echo "  - $u"
    done
fi

while true; do
    for ((i = 0; i < NUM_URLS; i++)); do
        url="${URLS[$i]}"
        next_idx=$(( (i + 1) % NUM_URLS ))
        next_url="${URLS[$next_idx]}"

        # Read by prepare_video_content() to render the "STORY X OF Y"
        # segment counter next to the progress bar.
        CURRENT_INDEX=$((i + 1))
        TOTAL_VIDEOS=$NUM_URLS

        run_video "$url"

        if [ "$ENABLE_BUMPER" = true ]; then
            run_bumper "$next_url"
        fi

        echo "Loading next video..."
        echo ""
    done
done
