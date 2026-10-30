#!/usr/bin/env bash
# Plays every installed workshop item for a few seconds and records the ones where
# linux-wallpaperengine prints an "Unsupported ..." error (e.g. puppet model MDLV0013).
# Results go to wpe-unsupported.txt in the folder you run it from.
#
# Usage: bash wpe-scan.sh [MONITOR]      e.g. bash wpe-scan.sh HDMI-A-1

# ---- edit these ----
WORKSHOP="$HOME/Games/steamapps/workshop/content/431960"
ASSETS="$HOME/Games/steamapps/common/wallpaper_engine/assets"
MONITOR="${1:-HDMI-A-1}"
SECONDS_PER_ITEM=6
OUT="$PWD/wpe-unsupported.txt"
# --------------------

: > "$OUT"
mapfile -t ids < <(for d in "$WORKSHOP"/*/; do b=$(basename "$d"); [[ "$b" =~ ^[0-9]+$ ]] && echo "$b"; done | sort -n)
total=${#ids[@]}
n=0

trap 'pkill -KILL -f "linux-wallpaperengine --assets-dir" 2>/dev/null; echo; echo "Interrupted. Partial results in $OUT"; exit 130' INT TERM

for id in "${ids[@]}"; do
    n=$((n + 1))
    printf '\r[%d/%d] %s   ' "$n" "$total" "$id" >&2

    out=$(SDL_AUDIODRIVER=dummy timeout -s KILL "$SECONDS_PER_ITEM" linux-wallpaperengine \
            --assets-dir "$ASSETS" --fps 30 --silent --layer background \
            --screen-root "$MONITOR" --scaling fit --bg "$WORKSHOP/$id" 2>&1)

    line=$(grep -m1 "Unsupported" <<< "$out")
    if [ -n "$line" ]; then
        title=$(grep -oE '"title"[[:space:]]*:[[:space:]]*"[^"]*"' "$WORKSHOP/$id/project.json" 2>/dev/null \
                | head -1 | sed -E 's/^[^:]*:[[:space:]]*"(.*)"$/\1/')
        printf '%s\t%s\t%s\n' "$id" "${title:-(no title)}" "$line" | tee -a "$OUT" >&2
    fi
done

pkill -KILL -f "linux-wallpaperengine --assets-dir" 2>/dev/null
echo >&2
echo "Done. $(wc -l < "$OUT") unsupported item(s) listed in $OUT" >&2
