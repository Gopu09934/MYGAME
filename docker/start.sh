#!/bin/bash
set -euo pipefail

#############################################

#Validate Environment Variables

#############################################
if [ -z "${VIDEO_URL:-}" ]; then
echo "ERROR: VIDEO_URL is not set"
exit 1
fi
if [ -z "${YOUTUBE_STREAM_KEY:-}" ]; then
echo "ERROR: YOUTUBE_STREAM_KEY is not set"
exit 1
fi

Subscriber count + live viewer count are optional — if the API creds
aren't provided, those panel elements just stay blank instead of
failing the whole stream.

SHOW_STATS=true
if [ -z "${YOUTUBE_API_KEY:-}" ] || [ -z "${YOUTUBE_CHANNEL_ID:-}" ]; then
echo "NOTICE: YOUTUBE_API_KEY / YOUTUBE_CHANNEL_ID not set — subscriber/viewer stats will be hidden."
SHOW_STATS=false
fi

echo "========================================"
echo "Starting 24/7 YouTube Stream (Vice City Gaming Overlay)"
echo "Output Resolution : 1280x720 (720p — sized for a 2-core CI runner)"
echo "FPS : 30"
echo "========================================"

FONT="font.ttf"

Miami Vice / GTA Vice City palette.

GOLD="0xFF3FBF" # neon pink/magenta — primary accent
GOLD_DIM="0xB82C88" # dimmer pink for subtler accents
RED="0xFF3B3B" # LIVE dot / signal red
NAVY="0x140021" # deep purple-black panel background
SILVER="0x4DECEC" # neon cyan — secondary/technical text
ASSET_DIR="panel_assets"
INFO_FILE="vice_info.txt"
TICKER_SPEED=110
CHANNEL_NAME="Vice City Nights"
SHADOW="shadowcolor=black@0.6:shadowx=1:shadowy=1"

VIEWER_MIN_TO_SHOW=10
STREAM_START_EPOCH=$(date +%s)

POLL_CYCLE=300
POLL_WINDOW=45
BAR_CHARS=24
POLLS_FILE="polls.txt"

DEFAULT_POLLS=(
"Favorite Vice City radio station?|Flash FM|Wave 103"
"Which ride next?|Cheetah|Infernus"
"Next mission type?|Story missions|Rampages and side jobs"
"Best Vice City character?|Tommy Vercetti|Lance Vance"
)

MAX_RETRIES=5
RETRY_DELAY=5

mkdir -p "$ASSET_DIR"

#############################################

Coordinate-label marker dot (used only when
baking the static HUD — see render_static_hud).

#############################################
DOT_MARKER="dot_marker.png"
GOLD_R=255; GOLD_G=63; GOLD_B=191
DOT_VF="format=rgba,geq=r=(if(lte(hypot(X-10,Y-10),5),${GOLD_R},if(lte(hypot(X-10,Y-10),8),255,0))):g=(if(lte(hypot(X-10,Y-10),5),${GOLD_G},if(lte(hypot(X-10,Y-10),8),255,0))):b=(if(lte(hypot(X-10,Y-10),5),${GOLD_B},if(lte(hypot(X-10,Y-10),8),255,0))):a=(if(lte(hypot(X-10,Y-10),8),255,0))"
ffmpeg -y -f lavfi -i "color=c=black@0.0:s=20x20" -vf "$DOT_VF" -frames:v 1 "$DOT_MARKER" -loglevel error
if [ ! -s "$DOT_MARKER" ]; then
echo "WARNING: geq-based marker generation failed — using a blank 1x1 fallback."
echo "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=" | base64 -d > "$DOT_MARKER"
fi

#############################################

Background clock writer

#############################################
date -u +'%d %b %Y • %H:%M:%S UTC' > "$ASSET_DIR/clock.txt"
(
while true; do
date -u +'%d %b %Y • %H:%M:%S UTC' > "$ASSET_DIR/clock.txt.tmp"
mv -f "$ASSET_DIR/clock.txt.tmp" "$ASSET_DIR/clock.txt"
sleep 1
done
) &
CLOCK_PID=$!

#############################################

Background subscriber-count writer

#############################################
printf ' ' > "$ASSET_DIR/subs.txt"
SUBS_PID=""
if [ "$SHOW_STATS" = true ]; then
(
WARNED_ONCE=false
while true; do
RESP=$(curl -s "https://www.googleapis.com/youtube/v3/channels?part=statistics&id=${YOUTUBE_CHANNEL_ID}&key=${YOUTUBE_API_KEY}" || true)
COUNT=$(echo "$RESP" | grep -o '"subscriberCount"[^"]"[0-9]"' | grep -oE '[0-9]+')
if [ -n "$COUNT" ]; then
FORMATTED=$(echo "$COUNT" | rev | sed 's/(...)/\1,/g' | rev | sed 's/^,//')
printf '%s subscribers' "$FORMATTED" > "$ASSET_DIR/subs.txt.tmp"
mv -f "$ASSET_DIR/subs.txt.tmp" "$ASSET_DIR/subs.txt"
WARNED_ONCE=false
elif [ "$WARNED_ONCE" = false ]; then
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

Background live-viewer-count writer

#############################################
printf ' ' > "$ASSET_DIR/viewers.txt"
VIEWERS_PID=""
if [ "$SHOW_STATS" = true ]; then
(
LIVE_VIDEO_ID=""
while true; do
if [ -z "$LIVE_VIDEO_ID" ]; then
SEARCH_RESP=$(curl -s "https://www.googleapis.com/youtube/v3/search?part=id&channelId=${YOUTUBE_CHANNEL_ID}&eventType=live&type=video&key=${YOUTUBE_API_KEY}" || true)
LIVE_VIDEO_ID=$(echo "$SEARCH_RESP" | grep -o '"videoId": "[^"]"' | head -1 | sed -E 's/."videoId": "([^"])"./\1/')
if [ -n "$LIVE_VIDEO_ID" ]; then
printf '%s' "$LIVE_VIDEO_ID" > "$ASSET_DIR/live_video_id.txt.tmp"
mv -f "$ASSET_DIR/live_video_id.txt.tmp" "$ASSET_DIR/live_video_id.txt"
fi
fi
if [ -n "$LIVE_VIDEO_ID" ]; then
VRESP=$(curl -s "https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails&id=${LIVE_VIDEO_ID}&key=${YOUTUBE_API_KEY}" || true)
VIEWERS=$(echo "$VRESP" | grep -o '"concurrentViewers": "[0-9]"' | grep -o '[0-9]*')
if [ -n "$VIEWERS" ] && [ "$VIEWERS" -ge "$VIEWER_MIN_TO_SHOW" ]; then
printf '%s watching now' "$VIEWERS" > "$ASSET_DIR/viewers.txt.tmp"
mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
elif [ -n "$VIEWERS" ]; then
printf ' ' > "$ASSET_DIR/viewers.txt.tmp"
mv -f "$ASSET_DIR/viewers.txt.tmp" "$ASSET_DIR/viewers.txt"
else
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

Background poll writer

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

Static overlay text

#############################################
printf 'VICE CITY NIGHTS' > "$ASSET_DIR/title1.txt"
printf '24/7 GAMEPLAY' > "$ASSET_DIR/eyebrow.txt"
printf 'SUBSCRIBE for more Vice City chaos' > "$ASSET_DIR/cta.txt"

DEFAULT_HEADLINES=(
"Tommy Vercetti is carving out territory across sun-soaked Vice City tonight."
"The streets of Vice City are heating up with turf wars and heists."
"Cruising the strip in a stolen Cheetah, neon lights streaking past."
"Another deal gone sideways down at the docks of Vice City."
"Starfish Island's mansions hide more secrets than they let on."
"Flash FM and Wave 103 keep the radio waves alive across the city."
"Weapons, cash, and turf — another night of Vice City business."
"The Vercetti Estate is quiet for now, but not for long."
"Rampages, side jobs, and mayhem fill tonight's Vice City run."
"From Ocean Beach to Downtown, no corner of Vice City stays calm for long."
"A new stash house has opened up somewhere in Little Havana."
"The Malibu Club lights are on — another deal is going down inside."
"Police heat is rising fast on the streets tonight."
"A fresh convoy of cash is rolling through Vice Point."
"Every mission tonight adds another chapter to Tommy's rise to power."
)

BUMPER_MESSAGES=(
"Stay tuned — more Vice City chaos incoming."
"Grab a drink, the next run starts in a moment."
"Vice City never sleeps. Neither do we."
)
BUMPER_DURATION=6
ENABLE_BUMPER="${ENABLE_BUMPER:-false}"

#############################################

build_labels_chain: computes the optional
coordinate/callout labels for a video. Now
called from render_static_hud() (baked once
per video) instead of the live per-frame
chain — label positions and text never change
mid-video, so there is no reason to recompute
them 30 times a second.
File format: <basename>.labels.txt, one label
per line as "x,y,Label text".
Sets globals: LABELS_CHAIN (filter string to
append onto the canvas), LABELS_OUT (node to
continue from — "[base]" if no labels file).

#############################################
build_labels_chain() {
local url="$1"
local base
base="${url##/}"
base="${base%.}"

# `local` is required here: this function is called once per video
# from inside the outer stream loop, which also uses a bare `i` as
# its own counter. Any unscoped i/idx below would silently clobber
# that outer loop variable and get the stream stuck replaying the
# first video forever.
local i idx

LABELS_CHAIN=""
LABELS_OUT="[base]"

local labels_file="${base}.labels.txt"
if [ ! -f "$labels_file" ]; then
    return 0
fi

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
local BOX_GAP=10
local LABEL_FONTSIZE=18
local LABEL_PAD_L=14
local LABEL_PAD_R=16
local AVG_CHAR_W=10
local BOX_W_MIN=110
local BOX_W_MAX=260
local placed_x=() placed_y=() placed_w=()
local k collision tries

# dot_marker.png is input index 1 in the render_static_hud() call
# that invokes this function — see that function for the -i list.
local split_outs=""
for ((i = 1; i <= n; i++)); do split_outs+="[dm${i}]"; done
LABELS_CHAIN+="[1:v]split=${n}${split_outs};"

local prev="base"
for ((i = 0; i < n; i++)); do
    idx=$((i + 1))
    local x="${xs[$i]}" y="${ys[$i]}" text="${texts[$i]}"
    printf '%s' "$text" > "$ASSET_DIR/label${idx}.txt"

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

    LABELS_CHAIN+="[${prev}]drawbox=x=${x}:y=${seg_y_top}:w=2:h=${seg_h}:color=${GOLD}@0.85:t=fill[${n2}];"
    LABELS_CHAIN+="[${n2}]drawbox=x=${h_left}:y=${box_y}:w=${h_w}:h=2:color=${GOLD}@0.85:t=fill[${n3}];"
    LABELS_CHAIN+="[${n3}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=black@0.78:t=fill[${n4}];"
    LABELS_CHAIN+="[${n4}]drawbox=x=${box_x}:y=${box_y}:w=${ACCENT_W}:h=${BOX_H}:color=${GOLD}:t=fill[${n5}];"
    LABELS_CHAIN+="[${n5}]drawbox=x=${box_x}:y=${box_y}:w=${box_w}:h=${BOX_H}:color=${GOLD}@0.5:t=1[${n6}];"
    LABELS_CHAIN+="[${n6}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/label${idx}.txt:fontcolor=white:fontsize=${LABEL_FONTSIZE}:x=$((box_x + ACCENT_W + LABEL_PAD_L)):y=$((box_y + (BOX_H - LABEL_FONTSIZE) / 2)):${SHADOW}[${n7}];"
    LABELS_CHAIN+="[${n7}][dm${idx}]overlay=x=$((x - 8)):y=$((y - 8))[${n1}];"

    prev="$n1"
done

LABELS_OUT="[${prev}]"
echo "Drew $n label(s) from $labels_file"

}

#############################################

render_static_hud: bakes every frame-invariant
HUD element for the given video into one RGBA
PNG, rendered once per video instead of being
redrawn on every output frame.
This is the fix for the sub-realtime encode
speed (observed ~0.3x / ~10fps against a 30fps
target): the old per-frame filter_complex chain
ran ~55 drawbox/drawtext ops on the full
1280x720 frame every single frame, which a
2-core runner cannot sustain at 30fps. Nearly
all of those ops (labels, LIVE badge shell,
category chip, wordmark, credits text, corner
brackets, sealed border, ticker plate, ON AIR
label, channel name) never change mid-video, so
baking them once collapses the live per-frame
chain down to only the handful of things that
actually animate (blinking dots, live text
files, the poll reveal window, the ticker
scroll, and the CTA fade).
Sets: writes $ASSET_DIR/static_hud.png

#############################################
render_static_hud() {
local url="$1"

build_labels_chain "$url"

local CHAIN="[0:v]format=rgba[base];"
CHAIN+="$LABELS_CHAIN"

# LIVE badge shell (the blinking red dot itself is drawn live, on
# top of this, every frame — see the dynamic chain below).
CHAIN+="${LABELS_OUT}drawbox=x=22:y=16:w=100:h=30:color=black@0.5:t=fill[h1];"
CHAIN+="[h1]drawbox=x=22:y=16:w=100:h=30:color=${GOLD}@0.55:t=1[h2];"
CHAIN+="[h2]drawtext=fontfile=${FONT}:text='LIVE':fontcolor=white:fontsize=20:x=52:y=23[h4];"

local prev="h4"
if [ "$SHOW_CATEGORY" = true ]; then
    local cat_w=$(( ${#CATEGORY_TEXT} * 8 + 24 ))
    [ "$cat_w" -lt 70 ] && cat_w=70
    [ "$cat_w" -gt 160 ] && cat_w=160
    CHAIN+="[${prev}]drawbox=x=132:y=16:w=${cat_w}:h=30:color=${NAVY}@0.85:t=fill[catbg];"
    CHAIN+="[catbg]drawbox=x=132:y=16:w=${cat_w}:h=30:color=${GOLD}@0.5:t=1[catout];"
    CHAIN+="[catout]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/category.txt:fontcolor=${GOLD}:fontsize=13:x=$((132 + 12)):y=27[catxt];"
    prev="catxt"
fi

CHAIN+="[${prev}]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/title1.txt:fontcolor=white:fontsize=20:x=22:y=58:${SHADOW}[h5];"
CHAIN+="[h5]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/eyebrow.txt:fontcolor=${GOLD}:fontsize=12:x=22:y=82:${SHADOW}[h6];"
CHAIN+="[h6]drawtext=fontfile=${FONT}:text='Credits\: Rockstar Games':fontcolor=${SILVER}@0.85:fontsize=14:x=1260-text_w:y=19:${SHADOW}[h7];"

# CTA box shell — background/outline/bar only. Visibility toggles
# via enable=CTA_ENABLE, and the text fades via alpha=, both of
# which have to stay in the live chain since they depend on `t`.
# The shell itself is drawn here unconditionally, sitting invisible
# under nothing when the CTA is "off" is not an option — so the
# shell keeps its own enable gate too and lives in the dynamic
# chain instead. (See build_dynamic_chain.)

# Bottom ticker plate + left "ON AIR" tab shell (dot blink and
# channel-name/scroll text stay dynamic).
CHAIN+="[h7]drawbox=x=0:y=678:w=1280:h=2:color=${GOLD}@0.35:t=fill[tk0];"
CHAIN+="[tk0]drawbox=x=0:y=680:w=1280:h=40:color=${NAVY}@0.80:t=fill[tk1];"
CHAIN+="[tk1]drawbox=x=0:y=680:w=1280:h=2:color=${GOLD}@0.9:t=fill[tk2];"
CHAIN+="[tk2]drawbox=x=0:y=680:w=124:h=40:color=${NAVY}@0.95:t=fill[tk4];"
CHAIN+="[tk4]drawbox=x=0:y=682:w=117:h=1:color=${GOLD}@0.7:t=fill[tk4b];"
CHAIN+="[tk4b]drawbox=x=113:y=682:w=2:h=36:color=${GOLD}@0.5:t=fill[tk5];"
CHAIN+="[tk5]drawtext=fontfile=${FONT}:text='ON AIR':fontcolor=${GOLD}:fontsize=15:x=33:y=693[tk6];"
CHAIN+="[tk6]drawtext=fontfile=${FONT}:text='${CHANNEL_NAME}':fontcolor=${SILVER}@0.5:fontsize=15:borderw=1.5:bordercolor=black@0.7:x=353:y=655[cf0];"

local CL=34
local CI=16
local CT=2
CHAIN+="[cf0]drawbox=x=${CI}:y=${CI}:w=${CL}:h=${CT}:color=${GOLD}@0.5:t=fill[cf1];"
CHAIN+="[cf1]drawbox=x=${CI}:y=${CI}:w=${CT}:h=${CL}:color=${GOLD}@0.5:t=fill[cf2];"
CHAIN+="[cf2]drawbox=x=$((1280 - CI - CL)):y=${CI}:w=${CL}:h=${CT}:color=${GOLD}@0.5:t=fill[cf3];"
CHAIN+="[cf3]drawbox=x=$((1280 - CI - CT)):y=${CI}:w=${CT}:h=${CL}:color=${GOLD}@0.5:t=fill[cf4];"
CHAIN+="[cf4]drawbox=x=${CI}:y=$((720 - CI - CT)):w=${CL}:h=${CT}:color=${GOLD}@0.5:t=fill[cf5];"
CHAIN+="[cf5]drawbox=x=${CI}:y=$((720 - CI - CL)):w=${CT}:h=${CL}:color=${GOLD}@0.5:t=fill[cf6];"
CHAIN+="[cf6]drawbox=x=$((1280 - CI - CL)):y=$((720 - CI - CT)):w=${CL}:h=${CT}:color=${GOLD}@0.5:t=fill[cf7];"
CHAIN+="[cf7]drawbox=x=$((1280 - CI - CT)):y=$((720 - CI - CL)):w=${CT}:h=${CL}:color=${GOLD}@0.5:t=fill[cf8];"
CHAIN+="[cf8]drawbox=x=0:y=0:w=1280:h=720:color=${GOLD}@0.25:t=1[out]"

ffmpeg -y \
    -f lavfi -i "color=c=black@0.0:s=1280x720" \
    -loop 1 -i "$DOT_MARKER" \
    -frames:v 1 \
    -filter_complex "$CHAIN" \
    -map "[out]" \
    "$ASSET_DIR/static_hud.png" \
    -loglevel error

}

#############################################

build_dynamic_chain: everything that must be
recomputed every frame because it depends on
t, live-reloaded text files, or a visibility
window. This is composited on top of the
baked static_hud.png (input index 1 in
run_video's ffmpeg call).

#############################################
build_dynamic_chain() {
local poll_start=$((POLL_CYCLE - POLL_WINDOW))
POLL_ENABLE="gte(mod(t+${VIDEO_START_OFFSET},${POLL_CYCLE}),${poll_start})"

local CHAIN
CHAIN="[0:v]scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:black,vignette=PI/6[base];"
CHAIN+="[base][1:v]overlay=0:0[hud];"

# Blinking LIVE dot, sitting on top of the static badge shell.
CHAIN+="[hud]drawbox=x=34:y=27:w=10:h=10:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[d1];"

# Live-reloaded stats stack (clock / subs / viewers), same
# coordinates the static credits line used as its anchor.
CHAIN+="[d1]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/clock.txt:reload=1:fontcolor=${GOLD}:fontsize=14:x=1260-text_w:y=39:${SHADOW}[d2];"
CHAIN+="[d2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/subs.txt:reload=1:fontcolor=${SILVER}@0.85:fontsize=13:x=1260-text_w:y=57:${SHADOW}[d3];"
CHAIN+="[d3]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/viewers.txt:reload=1:fontcolor=${SILVER}@0.85:fontsize=13:x=1260-text_w:y=75:${SHADOW}[d4];"

# LIVE POLL reveal window — only visible for the final POLL_WINDOW
# seconds of each POLL_CYCLE; enable=false frames are cheap no-ops.
local PX=956 PW=284
CHAIN+="[d4]drawbox=x=${PX}:y=104:w=${PW}:h=8:color=${RED}:t=fill:enable='${POLL_ENABLE}'[pv1];"
CHAIN+="[pv1]drawtext=fontfile=${FONT}:text='LIVE POLL':fontcolor=${GOLD}:fontsize=14:x=$((PX + 16)):y=101:enable='${POLL_ENABLE}'[pv2];"
CHAIN+="[pv2]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/poll_question.txt:reload=1:expansion=none:fontcolor=white:fontsize=16:line_spacing=6:x=${PX}:y=128:enable='${POLL_ENABLE}':${SHADOW}[pv3];"
CHAIN+="[pv3]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/poll_opt1.txt:reload=1:expansion=none:fontcolor=${GOLD}:fontsize=13:x=${PX}:y=210:enable='${POLL_ENABLE}'[pv4];"
CHAIN+="[pv4]drawbox=x=${PX}:y=230:w=${PW}:h=14:color=black@0.35:t=fill:enable='${POLL_ENABLE}'[pv5];"
CHAIN+="[pv5]drawbox=x=${PX}:y=230:w=${PW}:h=14:color=${GOLD}@0.4:t=1:enable='${POLL_ENABLE}'[pv6];"
CHAIN+="[pv6]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/poll_bar1.txt:reload=1:expansion=none:fontcolor=${GOLD}:fontsize=12:x=$((PX + 4)):y=231:enable='${POLL_ENABLE}'[pv7];"
CHAIN+="[pv7]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/poll_opt2.txt:reload=1:expansion=none:fontcolor=${GOLD}:fontsize=13:x=${PX}:y=258:enable='${POLL_ENABLE}'[pv8];"
CHAIN+="[pv8]drawbox=x=${PX}:y=278:w=${PW}:h=14:color=black@0.35:t=fill:enable='${POLL_ENABLE}'[pv9];"
CHAIN+="[pv9]drawbox=x=${PX}:y=278:w=${PW}:h=14:color=${GOLD}@0.4:t=1:enable='${POLL_ENABLE}'[pv10];"
CHAIN+="[pv10]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/poll_bar2.txt:reload=1:expansion=none:fontcolor=${GOLD}:fontsize=12:x=$((PX + 4)):y=279:enable='${POLL_ENABLE}'[pv11];"
CHAIN+="[pv11]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/poll_votes.txt:reload=1:expansion=none:fontcolor=${SILVER}@0.8:fontsize=10:x=${PX}:y=306:enable='${POLL_ENABLE}':${SHADOW}[pv12];"

# Periodic subscribe CTA — shell + text, both gated to CTA_SHOW
# seconds out of every CTA_CYCLE; enable=false frames are cheap.
local CTA_CYCLE=240
local CTA_SHOW=8
local CTA_ALPHA="if(between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})\,if(lt(mod(t\,${CTA_CYCLE})\,0.6)\,mod(t\,${CTA_CYCLE})/0.6\,if(gt(mod(t\,${CTA_CYCLE})\,${CTA_SHOW}-0.6)\,(${CTA_SHOW}-mod(t\,${CTA_CYCLE}))/0.6\,1))\,0)"
local CTA_ENABLE="between(mod(t\,${CTA_CYCLE})\,0\,${CTA_SHOW})"

CHAIN+="[pv12]drawbox=x=729:y=616:w=515:h=51:color=${GOLD}@0.12:t=fill:enable='${CTA_ENABLE}'[cta_glow];"
CHAIN+="[cta_glow]drawbox=x=733:y=620:w=507:h=43:color=${NAVY}@0.85:t=fill:enable='${CTA_ENABLE}'[cta_bg];"
CHAIN+="[cta_bg]drawbox=x=733:y=620:w=507:h=43:color=${GOLD}@0.4:t=1:enable='${CTA_ENABLE}'[cta_outline];"
CHAIN+="[cta_outline]drawbox=x=733:y=620:w=4:h=43:color=${GOLD}:t=fill:enable='${CTA_ENABLE}'[cta_bar];"
CHAIN+="[cta_bar]drawbox=x=755:y=636:w=11:h=11:color=${RED}:t=fill:enable='${CTA_ENABLE}'[cta_dot];"
CHAIN+="[cta_dot]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/cta.txt:fontcolor=white:fontsize=19:x=773:y=633:alpha='${CTA_ALPHA}'[cta_final];"

# Scrolling ticker text + blinking ON AIR dot, both over the static
# ticker plate baked into static_hud.png.
CHAIN+="[cta_final]drawtext=fontfile=${FONT}:textfile=${ASSET_DIR}/ticker.txt:fontcolor=white:fontsize=17:borderw=2:bordercolor=black@0.6:y=695:x='w-mod(t*${TICKER_SPEED}\,text_w+w)'[tk3];"
CHAIN+="[tk3]drawbox=x=17:y=690:w=8:h=8:color=${RED}:t=fill:enable='lt(mod(t\,1)\,0.6)'[final]"

DYNAMIC_CHAIN="$CHAIN"

}

#############################################

prepare_video_content: rebuilds the ticker
pool for this video, resolves the optional
category chip, bakes the static HUD PNG, and
builds the per-frame dynamic chain to match.

#############################################
prepare_video_content() {
local url="$1"
local base
base="${url##/}"
base="${base%.}"

: "${CURRENT_INDEX:=1}"
: "${TOTAL_VIDEOS:=1}"
: "${VIDEO_START_OFFSET:=0}"

SHOW_CATEGORY=false
if [ -f "${base}.category.txt" ]; then
    CATEGORY_TEXT="$(head -n1 "${base}.category.txt" | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ -n "$CATEGORY_TEXT" ]; then
        printf '%s' "$CATEGORY_TEXT" > "$ASSET_DIR/category.txt"
        SHOW_CATEGORY=true
    fi
fi

local i
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

N=${#RAW_LINES[@]}
echo "This video: $N headline(s) feeding the bottom ticker"

TICKER_STRING=""
for i in "${!RAW_LINES[@]}"; do
    TICKER_STRING+="${RAW_LINES[$i]}     •     "
done
printf '%s' "$TICKER_STRING" > "$ASSET_DIR/ticker.txt"

echo "Baking static HUD for this video..."
render_static_hud "$url"

build_dynamic_chain

}

#############################################

Up-next bumper — unchanged.

#############################################
run_bumper() {
local next_url="$1"

local raw title
raw="${next_url##*/}"
raw="${raw%.*}"
raw="${raw//[-_]/ }"
raw="$(echo "$raw" | tr -d '[:space:]')"
if [ -z "$raw" ] || [ ${#raw} -lt 3 ]; then
    title="Vice City Business"
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
-loop 1 -framerate 24 -t "$BUMPER_DURATION" -i overlay.png \
-f lavfi -t "$BUMPER_DURATION" -i anullsrc=r=48000:cl=stereo \
-filter_complex "$BFILTER" \
-filter_complex_threads 2 \
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

run_video: streams one video with retry.
Main ffmpeg call now only needs two inputs —
the source video and the pre-baked
static_hud.png — instead of three. overlay.png
is dropped entirely here: it was being decoded
every frame for no reason (nothing in the live
filter graph referenced it — the panel draws
directly onto the scaled/padded gameplay frame,
see prepare_video_content's comment history),
and its presence at input index 1 also meant
build_labels_chain's "[1:v]" reference was
quietly pulling in the wrong image instead of
the actual dot marker. Baking the dot marker
and labels into static_hud.png ahead of time
fixes both problems at once.

#############################################
run_video() {
local url="$1"
local attempt=1

VIDEO_START_OFFSET=$(( $(date +%s) - STREAM_START_EPOCH ))

prepare_video_content "$url"

local filter="$DYNAMIC_CHAIN"

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
    -loop 1 -framerate 30 -i "$ASSET_DIR/static_hud.png" \
    -filter_complex "$filter" \
    -filter_complex_threads 2 \
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

Stream loop

#############################################
IFS=',' read -ra RAW_URLS <<< "$VIDEO_URL"
URLS=()
for u in "${RAW_URLS[@]}"; do
u="${u#"${u%%[![:space:]]}"}"
u="${u%"${u##[![:space:]]}"}"
[ -n "$u" ] && URLS+=("$u")
done
NUM_URLS=${#URLS[@]}
if [ "$NUM_URLS" -eq 0 ]; then
echo "ERROR: VIDEO_URL contained no valid entries after parsing"
exit 1
fi

if [ "$NUM_URLS" -gt 1 ]; then
mapfile -t URLS < <(printf '%s\n' "${URLS[@]}" | shuf)
echo "Shuffled playback order for this run:"
for u in "${URLS[@]}"; do
echo " - $u"
done
fi

while true; do
for ((i = 0; i < NUM_URLS; i++)); do
url="${URLS[$i]}"
next_idx=$(( (i + 1) % NUM_URLS ))
next_url="${URLS[$next_idx]}"

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
