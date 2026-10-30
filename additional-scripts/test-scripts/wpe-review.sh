#!/usr/bin/env bash
# Go through every installed Wallpaper Engine workshop item, one at a time.
# Shows the ID and name, then asks whether to keep it.
#   Enter / y -> keep it: log "ID<TAB>Name" to the kept file, go to the next one
#   n         -> log "ID<TAB>Name" to the rejected file, go to the next one
#   o         -> open the item's Steam workshop page in your browser, then ask again
#   q         -> quit (progress is saved, next run continues where you stopped)
#
# Items you already answered are remembered in the reviewed file and are never shown again.
# Delete that file (or run with --reset) to start over.
#
# Usage: ./wpe-review.sh
#        ./wpe-review.sh --reset

# ---- edit these ----
WORKSHOP="$HOME/Games/steamapps/workshop/content/431960"
REJECTED="$PWD/wpe-rejected.txt"     # ID and name of every item you answered "no" to
KEPT="$PWD/wpe-kept.txt"             # ID and name of every item you answered "yes" to
REVIEWED="$PWD/wpe-reviewed.txt"     # IDs already shown, so nothing is repeated
ASSETS="$HOME/Games/steamapps/common/wallpaper_engine/assets"
FPS=60
MONITOR=""                           # output to preview on, e.g. HDMI-A-1. Empty = first enabled output
PREVIEW=1                            # 1 = play each wallpaper while asking, 0 = text only
# --------------------

if [ "${1:-}" = "--reset" ]; then
    rm -f "$REVIEWED"
    echo "Progress reset. The rejected list ($REJECTED) and kept list ($KEPT) were left as they are."
    exit 0
fi

[ -d "$WORKSHOP" ] || { echo "Workshop folder not found: $WORKSHOP" >&2; exit 1; }
touch "$REJECTED" "$KEPT" "$REVIEWED"

# optional first argument: the monitor to preview on  (./wpe-review.sh HDMI-A-1)
[ -n "${1:-}" ] && MONITOR="$1"
if [ "$PREVIEW" -eq 1 ]; then
    command -v linux-wallpaperengine >/dev/null || { echo "linux-wallpaperengine not found, previews off" >&2; PREVIEW=0; }
fi
if [ "$PREVIEW" -eq 1 ] && [ -z "$MONITOR" ]; then
    MONITOR=$(wlr-randr 2>/dev/null | awk '/^[^ ]/{name=$1} /Enabled:/{if ($2=="yes") {print name; exit}}')
    [ -z "$MONITOR" ] && { echo "No monitor found, previews off" >&2; PREVIEW=0; }
fi

PREVIEW_PID=""
stop_preview() {
    [ -n "$PREVIEW_PID" ] || return 0
    kill -CONT "$PREVIEW_PID" 2>/dev/null
    kill "$PREVIEW_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$PREVIEW_PID" 2>/dev/null || break
        sleep 0.2
    done
    kill -9 "$PREVIEW_PID" 2>/dev/null
    PREVIEW_PID=""
}
start_preview() {
    [ "$PREVIEW" -eq 1 ] || return 0
    SDL_AUDIODRIVER=dummy linux-wallpaperengine --assets-dir "$ASSETS" --fps "$FPS" --silent \
        --layer background --screen-root "$MONITOR" --bg "$WORKSHOP/$1" \
        >/tmp/wpe-review-engine.log 2>&1 &
    PREVIEW_PID=$!
}
trap stop_preview EXIT

# read one string field ($2) from a workshop item's project.json ($1 = id)
field() {
    grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$WORKSHOP/$1/project.json" 2>/dev/null \
        | head -1 | sed -E 's/^[^:]*:[[:space:]]*"(.*)"$/\1/'
}

# collect IDs (numeric folders only), sorted, skipping ones already reviewed
mapfile -t all < <(
    for d in "$WORKSHOP"/*/; do
        id=$(basename "$d")
        [[ "$id" =~ ^[0-9]+$ ]] && echo "$id"
    done | sort -n
)

todo=()
for id in "${all[@]}"; do
    grep -qxF "$id" "$REVIEWED" || todo+=("$id")
done

total=${#todo[@]}
if [ "$total" -eq 0 ]; then
    echo "Nothing left to review (${#all[@]} installed, all already reviewed)."
    echo "Run with --reset to go through them again."
    exit 0
fi

echo "$total item(s) to review (${#all[@]} installed)."
echo

n=0
for id in "${todo[@]}"; do
    n=$((n + 1))
    name=$(field "$id" title)
    name=${name:-"(no title)"}

    echo "[$n/$total]"
    echo "Workshop ID:   $id"
    echo "Workshop Name: $name"

    start_preview "$id"

    while true; do
        read -r -p "Keep it? [Y/n/o/q] " ans
        case "${ans,,}" in
            o|open)
                url="https://steamcommunity.com/sharedfiles/filedetails/?id=$id"
                echo "Opening $url"
                xdg-open "$url" >/dev/null 2>&1 &
                ;;
            ""|y|yes)
                printf '%s\t%s\n' "$id" "$name" >> "$KEPT"
                break ;;
            n|no)
                printf '%s\t%s\n' "$id" "$name" >> "$REJECTED"
                echo "-> logged to $REJECTED"
                break ;;
            q|quit)
                echo "Stopped. Run again to continue."
                exit 0 ;;
            *)
                echo "Press Enter or y to keep, n to reject, o to open the workshop page, q to quit." ;;
        esac
    done

    stop_preview
    echo "$id" >> "$REVIEWED"
    echo
done

echo "Done. Kept items: $KEPT"
echo "      Rejected items: $REJECTED"