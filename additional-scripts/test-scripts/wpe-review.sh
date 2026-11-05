#!/usr/bin/env bash
# Wallpaper Engine workshop browser + unsupported-item scanner (linux-wallpaperengine)
#
# Full-screen terminal UI to:
#   * browse every installed workshop item back and forth (arrow keys)
#   * search by workshop ID, partial ID, name, or a pasted Steam URL
#   * preview any item live on your monitor
#   * test a single item, or scan everything, for "Unsupported ..." errors
#     (results go to wpe-unsupported.txt, same format as the old script)
#
# Usage:
#   bash wpe-scan.sh [MONITOR]            e.g. bash wpe-scan.sh HDMI-A-1
#   bash wpe-scan.sh [MONITOR] --scan     old behaviour: headless full scan, no UI
#
# Optional: install `fzf` to get live fuzzy search on the "f" key.

# ---- edit these ----
WORKSHOP="$HOME/Games/steamapps/workshop/content/431960"
ASSETS="$HOME/Games/steamapps/common/wallpaper_engine/assets"
MONITOR="${1:-HDMI-A-1}"
SECONDS_PER_ITEM=6
FPS=30
SCALING=fit          # fit | fill | stretch | default
SILENT=1             # 1 = mute previews
AUTO_PREVIEW=0       # 1 = start previewing as you move through the list
OUT="$PWD/wpe-unsupported.txt"
# --------------------

MODE="${2:-}"
LOG="${TMPDIR:-/tmp}/wpe-preview.$$.log"

# ------------------------------------------------------------------ checks
if ((BASH_VERSINFO[0] < 4)); then echo "bash 4+ required" >&2; exit 1; fi
command -v linux-wallpaperengine >/dev/null || { echo "linux-wallpaperengine not found in PATH" >&2; exit 1; }
[[ -d $WORKSHOP ]] || { echo "Workshop folder not found: $WORKSHOP" >&2; exit 1; }

# ------------------------------------------------------------------ state
declare -A TITLE TYPE BAD IDSET
ALL=() VIEW=()
CUR=0 FILTER="" MSG="" KEY=""
PLAY_PID="" PLAY_ID=""
SCAN_FOUND=() SCAN_N=0 SCAN_TOTAL=0 SCAN_ID=""
CHECK_LINE="" REPLY_TXT=""
buf=""

C_B=$'\e[1m' C_D=$'\e[2m' C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m'
C_C=$'\e[36m' C_I=$'\e[7m' C_0=$'\e[0m'

# ------------------------------------------------------------------ data
load_index() {
    local d b line id v re='"[^"]*"[[:space:]]*$'
    ALL=(); TITLE=(); TYPE=(); IDSET=()
    for d in "$WORKSHOP"/*/; do
        b=${d%/}; b=${b##*/}
        [[ $b =~ ^[0-9]+$ ]] && { ALL+=("$b"); IDSET[$b]=1; }
    done
    ((${#ALL[@]})) || { echo "No workshop items found in $WORKSHOP" >&2; exit 1; }
    mapfile -t ALL < <(printf '%s\n' "${ALL[@]}" | sort -n)

    re=':[[:space:]]*"(.*)"[[:space:]]*$'
    while IFS= read -r line; do
        id=${line%/project.json:*}; id=${id##*/}
        v=${line#*/project.json:}
        [[ $v =~ $re && -z ${TITLE[$id]+x} ]] && TITLE[$id]=${BASH_REMATCH[1]}
    done < <(grep -H -m1 -oE '"title"[[:space:]]*:[[:space:]]*"[^"]*"' "$WORKSHOP"/*/project.json 2>/dev/null)
    while IFS= read -r line; do
        id=${line%/project.json:*}; id=${id##*/}
        v=${line#*/project.json:}
        [[ $v =~ $re && -z ${TYPE[$id]+x} ]] && TYPE[$id]=${BASH_REMATCH[1],,}
    done < <(grep -H -m1 -oE '"type"[[:space:]]*:[[:space:]]*"[^"]*"' "$WORKSHOP"/*/project.json 2>/dev/null)
}

load_bad() {
    BAD=()
    [[ -s $OUT ]] || return 0
    local id rest
    while IFS=$'\t' read -r id _ rest; do
        [[ $id =~ ^[0-9]+$ ]] && BAD[$id]=$rest
    done < "$OUT"
}

record_bad() {   # id line
    [[ -n ${BAD[$1]+x} ]] && return
    BAD[$1]=$2
    printf '%s\t%s\t%s\n' "$1" "${TITLE[$1]:-(no title)}" "$2" >> "$OUT"
}

# plays an item for N seconds and looks for "Unsupported" (original scan logic)
check_item() {   # id -> CHECK_LINE
    local out
    out=$(SDL_AUDIODRIVER=dummy timeout -s KILL "$SECONDS_PER_ITEM" linux-wallpaperengine \
            --assets-dir "$ASSETS" --fps "$FPS" --silent --layer background \
            --screen-root "$MONITOR" --scaling "$SCALING" --bg "$WORKSHOP/$1" 2>&1 </dev/null)
    CHECK_LINE=$(grep -m1 "Unsupported" <<< "$out")
}

# ------------------------------------------------------------------ preview
preview_alive() { [[ -n $PLAY_PID ]] && kill -0 "$PLAY_PID" 2>/dev/null; }

stop_preview() {
    [[ -n $PLAY_PID ]] && kill -KILL "$PLAY_PID" 2>/dev/null
    PLAY_PID=""; PLAY_ID=""
}

start_preview() {   # id
    stop_preview
    local envs=()
    ((SILENT)) && envs=(SDL_AUDIODRIVER=dummy)
    local args=(--assets-dir "$ASSETS" --fps "$FPS" --layer background
                --screen-root "$MONITOR" --scaling "$SCALING" --bg "$WORKSHOP/$1")
    ((SILENT)) && args=(--silent "${args[@]}")
    : > "$LOG"
    env "${envs[@]}" linux-wallpaperengine "${args[@]}" >"$LOG" 2>&1 </dev/null &
    PLAY_PID=$!; PLAY_ID=$1
    disown "$PLAY_PID" 2>/dev/null
    MSG="Previewing $1 on $MONITOR"
}

# auto-flags an item if the running preview prints "Unsupported ..."
poll_preview() {
    [[ -n $PLAY_ID && -z ${BAD[$PLAY_ID]+x} && -s $LOG ]] || return 0
    local l
    l=$(grep -m1 "Unsupported" "$LOG" 2>/dev/null)
    if [[ -n $l ]]; then
        record_bad "$PLAY_ID" "$l"
        MSG="⚠ Unsupported detected in $PLAY_ID — saved to $(basename "$OUT")"
    fi
}

# ------------------------------------------------------------------ terminal helpers
readkey() {   # [timeout] -> KEY
    local k r='' rc
    KEY=
    IFS= read -rsn1 -t "${1:-1}" k; rc=$?
    if ((rc > 128)); then KEY=tick; return; fi
    if ((rc)); then KEY=quit; return; fi
    case $k in
        $'\e')
            IFS= read -rsn2 -t 0.05 r
            case $r in
                '[A'|'OA') KEY=up;;
                '[B'|'OB') KEY=down;;
                '[C'|'OC') KEY=right;;
                '[D'|'OD') KEY=left;;
                '[5') IFS= read -rsn1 -t 0.05 _; KEY=pgup;;
                '[6') IFS= read -rsn1 -t 0.05 _; KEY=pgdn;;
                '[H'|'OH') KEY=home;;
                '[F'|'OF') KEY=end;;
                '[1') IFS= read -rsn1 -t 0.05 _; KEY=home;;
                '[4') IFS= read -rsn1 -t 0.05 _; KEY=end;;
                '') KEY=esc;;
                *) KEY=other;;
            esac;;
        '') KEY=enter;;
        ' ') KEY=space;;
        *) KEY=$k;;
    esac
}

ask() {   # prompt -> REPLY_TXT (normal line editing at the bottom row)
    tput cnorm
    printf '\e[%d;1H\e[K%s' "$(tput lines)" "$C_C"
    IFS= read -erp "$1" REPLY_TXT
    printf '%s' "$C_0"
    tput civis
}

L()     { buf+="$1${C_0}"$'\e[K\n'; }
paint() { printf '\e[H%s\e[J' "$buf"; }
trunc() { local s=$1 w=$2; ((w < 1)) && w=1; ((${#s} > w)) && s="${s:0:w-1}…"; printf '%s' "$s"; }

titlebar() {   # text cols
    local t
    printf -v t '%-*s' "$2" " $1"
    buf+="${C_I}${C_B}${t:0:$2}${C_0}"$'\e[K\n'
}

rule() { printf -v RULE '%*s' "$1" ''; RULE=${RULE// /─}; }

# ------------------------------------------------------------------ view / search
set_view_all() { VIEW=("${ALL[@]}"); FILTER=""; }

find_in_view() {   # id -> sets CUR
    local i
    for i in "${!VIEW[@]}"; do
        [[ ${VIEW[i]} == "$1" ]] && { CUR=$i; return 0; }
    done
    return 1
}

do_search() {
    ask " Search (ID, part of ID, name, or Steam URL): "
    local q=${REPLY_TXT,,} id hay t ok
    [[ -z ${q//[[:space:]]/} ]] && return 1
    [[ $q =~ id=([0-9]+) ]] && q=${BASH_REMATCH[1]}
    local terms exact=() rest=()
    read -ra terms <<< "$q"
    for id in "${ALL[@]}"; do
        hay="$id ${TITLE[$id],,}"; ok=1
        for t in "${terms[@]}"; do
            [[ $hay == *"$t"* ]] || { ok=0; break; }
        done
        ((ok)) || continue
        if [[ $id == "$q" ]]; then exact+=("$id"); else rest+=("$id"); fi
    done
    local n=$(( ${#exact[@]} + ${#rest[@]} ))
    if ((n == 0)); then MSG="No matches for '$REPLY_TXT'"; return 1; fi
    VIEW=("${exact[@]}" "${rest[@]}")
    FILTER="search: $REPLY_TXT"
    CUR=0
    MSG="$n match(es) for '$REPLY_TXT' — ←/→ to step through them, c to clear"
    return 0
}

do_jump() {
    ask " Go to workshop ID (or list position): "
    local q=${REPLY_TXT//[[:space:]]/}
    [[ $q =~ id=([0-9]+) ]] && q=${BASH_REMATCH[1]}
    [[ $q =~ ^[0-9]+$ ]] || { MSG="Please enter a number"; return 1; }
    if [[ -n ${IDSET[$q]+x} ]]; then
        find_in_view "$q" || { set_view_all; find_in_view "$q"; }
        MSG="Jumped to $q"; return 0
    fi
    if ((q >= 1 && q <= ${#VIEW[@]})); then CUR=$((q - 1)); return 0; fi
    MSG="ID $q not found in your installed items"; return 1
}

do_fzf() {
    command -v fzf >/dev/null || { MSG="fzf is not installed — use / to search"; return; }
    local sel id
    sel=$(for id in "${VIEW[@]}"; do printf '%s\t%s\n' "$id" "${TITLE[$id]:-(no title)}"; done \
          | fzf --delimiter=$'\t' --prompt='find> ' --header='Enter = select   Esc = cancel') || return
    find_in_view "${sel%%$'\t'*}"
}

# ------------------------------------------------------------------ browser
draw_browser() {
    local cols rows total=${#VIEW[@]} lh top i id line m pc bc cur=${VIEW[CUR]} W st notes
    cols=$(tput cols); rows=$(tput lines)
    lh=$((rows - 15)); ((lh < 3)) && lh=3
    W=$((cols - 12)); ((W < 10)) && W=10
    rule "$cols"
    buf=

    titlebar "Wallpaper Engine  ▸  Browser" "$cols"
    line=" ${total} shown of ${#ALL[@]}${FILTER:+ · $FILTER} · flagged ${#BAD[@]} · monitor $MONITOR · auto-preview $( ((AUTO_PREVIEW)) && echo on || echo off )"
    L "${C_C}${line:0:cols}"
    L "$RULE"

    top=$((CUR - lh / 2))
    ((top > total - lh)) && top=$((total - lh))
    ((top < 0)) && top=0
    for ((i = top; i < top + lh; i++)); do
        if ((i >= total)); then L ""; continue; fi
        id=${VIEW[i]}
        m=' '; pc=' '; bc=' '
        ((i == CUR)) && m='▸'
        [[ $id == "$PLAY_ID" ]] && preview_alive && pc='●'
        [[ -n ${BAD[$id]+x} ]] && bc='⚠'
        printf -v line ' %s %5d  %-11s%s%s %-6.6s %s' "$m" "$((i + 1))" "$id" "$pc" "$bc" "${TYPE[$id]:-?}" "${TITLE[$id]:-(no title)}"
        line=${line:0:cols-1}
        if ((i == CUR)); then
            printf -v line '%-*s' "$cols" "$line"
            L "${C_I}${line:0:cols}"
        elif [[ $bc != ' ' ]]; then
            L "${C_R}${line}"
        elif [[ $pc != ' ' ]]; then
            L "${C_G}${line}"
        else
            L "$line"
        fi
    done
    L "$RULE"

    # ---- details panel (6 lines)
    if [[ $cur == "$PLAY_ID" ]]; then
        if preview_alive; then st="${C_G}● Playing on $MONITOR"; else st="${C_Y}■ Preview process exited"; fi
    elif [[ -n $PLAY_ID ]] && preview_alive; then
        st="${C_D}● Another item is playing ($PLAY_ID)"
    else
        st="${C_D}○ Not playing — press Enter to preview"
    fi
    if [[ -n ${BAD[$cur]+x} ]]; then
        notes="${C_R}⚠ ${BAD[$cur]:0:W}"
    elif [[ $cur == "$PLAY_ID" && -s $LOG ]]; then
        notes="${C_D}log: $(tail -n1 "$LOG" | tr -d '\r\033' | cut -c1-"$W")"
    else
        notes="${C_D}not flagged"
    fi
    L " ${C_D}ID      ${C_0}${C_B}$cur"
    L " ${C_D}Title   ${C_0}$(trunc "${TITLE[$cur]:-(no title)}" "$W")"
    L " ${C_D}Type    ${C_0}${TYPE[$cur]:-unknown}"
    L " ${C_D}Folder  ${C_0}$(trunc "$WORKSHOP/$cur" "$W")"
    L " ${C_D}Status  ${C_0}$st"
    L " ${C_D}Notes   ${C_0}$notes"
    L "$RULE"

    L " ${C_Y}${MSG:0:cols-2}"
    L "${C_D} ←/→ prev/next   ↑/↓ same   PgUp/PgDn ±10   Home/End   / search   f fuzzy   g jump to ID"
    L "${C_D} Enter preview   x stop   a auto-preview   t test item   c clear filter   Esc/q back"
    paint
}

move() {
    local n=${#VIEW[@]} d=$1
    CUR=$((CUR + d))
    if ((d == 1 || d == -1)); then
        ((CUR < 0)) && CUR=$((n - 1))
        ((CUR >= n)) && CUR=0
    else
        ((CUR < 0)) && CUR=0
        ((CUR >= n)) && CUR=$((n - 1))
    fi
    MSG=
    ((AUTO_PREVIEW)) && start_preview "${VIEW[CUR]}"
}

browser() {
    ((${#VIEW[@]})) || { MSG="Nothing to show"; return; }
    ((CUR >= ${#VIEW[@]})) && CUR=0
    local id
    while :; do
        poll_preview
        draw_browser
        readkey 1
        id=${VIEW[CUR]}
        case $KEY in
            tick) ;;
            left|up|h|k) move -1;;
            right|down|l|j) move 1;;
            pgup) move -10;;
            pgdn) move 10;;
            home) CUR=0;;
            end) CUR=$((${#VIEW[@]} - 1));;
            enter|space|p) start_preview "$id";;
            x) stop_preview; MSG="Preview stopped";;
            a) AUTO_PREVIEW=$((1 - AUTO_PREVIEW)); MSG="Auto-preview $( ((AUTO_PREVIEW)) && echo ON || echo OFF )";;
            /) do_search;;
            f) do_fzf;;
            g) do_jump;;
            c) set_view_all; find_in_view "$id"; MSG="Filter cleared";;
            t)
                stop_preview
                MSG="Testing $id for ${SECONDS_PER_ITEM}s…"; draw_browser
                check_item "$id"
                if [[ -n $CHECK_LINE ]]; then record_bad "$id" "$CHECK_LINE"; MSG="⚠ $id: $CHECK_LINE"
                else MSG="✓ $id: no 'Unsupported' errors in ${SECONDS_PER_ITEM}s"; fi;;
            esc)
                if [[ -n $FILTER ]]; then set_view_all; find_in_view "$id"; MSG="Filter cleared"
                else return; fi;;
            q|quit) return;;
        esac
    done
}

# ------------------------------------------------------------------ scan everything
draw_scan() {
    local cols w filled pct bar rest i start
    cols=$(tput cols); w=$((cols - 14)); ((w < 10)) && w=10
    filled=$((w * SCAN_N / SCAN_TOTAL)); pct=$((100 * SCAN_N / SCAN_TOTAL))
    printf -v bar '%*s' "$filled" ''; bar=${bar// /█}
    printf -v rest '%*s' "$((w - filled))" ''; rest=${rest// /░}
    buf=
    titlebar "Wallpaper Engine  ▸  Scanning for unsupported items" "$cols"
    L ""
    L " Item $SCAN_N / $SCAN_TOTAL  (${pct}%)"
    L " ${C_G}${bar}${C_D}${rest}"
    L ""
    L " ${C_D}Testing  ${C_0}$SCAN_ID  $(trunc "${TITLE[$SCAN_ID]:-(no title)}" $((cols - 24)))"
    L " ${C_D}Flagged  ${C_0}${C_R}${#SCAN_FOUND[@]}"
    L ""
    L " ${C_D}Latest flagged:"
    start=$((${#SCAN_FOUND[@]} - 8)); ((start < 0)) && start=0
    for ((i = start; i < ${#SCAN_FOUND[@]}; i++)); do
        L "   ${C_R}⚠${C_0} ${SCAN_FOUND[i]}  $(trunc "${TITLE[${SCAN_FOUND[i]}]:-(no title)}" $((cols - 20)))"
    done
    L ""
    L "${C_D} Press q to cancel after the current item"
    paint
}

scan_all() {
    stop_preview
    local total=${#ALL[@]} eta k id cancelled=0
    eta=$((total * SECONDS_PER_ITEM / 60))
    ask " Scan all $total items (~${eta} min)? This overwrites $(basename "$OUT") [y/N] "
    [[ ${REPLY_TXT,,} == y* ]] || { MSG="Scan cancelled"; return; }
    : > "$OUT"; BAD=(); SCAN_FOUND=(); SCAN_TOTAL=$total; SCAN_N=0
    for id in "${ALL[@]}"; do
        SCAN_N=$((SCAN_N + 1)); SCAN_ID=$id
        draw_scan
        check_item "$id"
        if [[ -n $CHECK_LINE ]]; then record_bad "$id" "$CHECK_LINE"; SCAN_FOUND+=("$id"); fi
        if IFS= read -rsn1 -t 0.01 k && [[ ${k,,} == q ]]; then cancelled=1; break; fi
    done
    pkill -KILL -f "linux-wallpaperengine --assets-dir" 2>/dev/null
    if ((cancelled)); then MSG="Scan cancelled at $SCAN_N/$total — ${#BAD[@]} flagged so far"
    else MSG="Scan finished — ${#BAD[@]} unsupported of $total. Open 'Review flagged items' to browse them."; fi
}

review_flagged() {
    if ((${#BAD[@]} == 0)); then MSG="Nothing flagged yet — run a scan or test items first"; return 1; fi
    mapfile -t VIEW < <(printf '%s\n' "${!BAD[@]}" | sort -n)
    FILTER="flagged unsupported"; CUR=0
    return 0
}

# ------------------------------------------------------------------ settings
settings() {
    local s=0 k cols labels vals scales=(fit fill stretch default) i
    while :; do
        cols=$(tput cols)
        vals=("$MONITOR" "$SCALING" "$( ((SILENT)) && echo muted || echo sound )"
              "$( ((AUTO_PREVIEW)) && echo on || echo off )" "${SECONDS_PER_ITEM}s" "$FPS" "$OUT")
        labels=("Monitor" "Scaling" "Preview audio" "Auto-preview while browsing" "Seconds per test/scan item" "FPS" "Results file")
        buf=
        titlebar "Wallpaper Engine  ▸  Settings" "$cols"
        L ""
        for i in "${!labels[@]}"; do
            if ((i == s)); then
                printf -v k '  ▸ %-30s %s' "${labels[i]}" "${vals[i]}"
                L "${C_I}$(printf '%-*s' "$cols" "$k")"
            else
                L "    ${labels[i]}$(printf '%*s' $((30 - ${#labels[i]})) '') ${C_C}${vals[i]}"
            fi
        done
        L ""
        L "${C_Y} ${MSG:0:cols-2}"
        L "${C_D} ↑/↓ select   Enter/→ change   Esc/q back     (applies to the next preview/test)"
        paint
        readkey 30
        case $KEY in
            up|k) s=$(((s + ${#labels[@]} - 1) % ${#labels[@]}));;
            down|j) s=$(((s + 1) % ${#labels[@]}));;
            enter|space|right|l|left|h)
                case $s in
                    0) ask " Monitor name (e.g. HDMI-A-1): "; [[ -n $REPLY_TXT ]] && MONITOR=$REPLY_TXT;;
                    1) for i in "${!scales[@]}"; do [[ ${scales[i]} == "$SCALING" ]] && break; done
                       SCALING=${scales[$(((i + 1) % ${#scales[@]}))]};;
                    2) SILENT=$((1 - SILENT));;
                    3) AUTO_PREVIEW=$((1 - AUTO_PREVIEW));;
                    4) ask " Seconds per item: "; [[ $REPLY_TXT =~ ^[1-9][0-9]*$ ]] && SECONDS_PER_ITEM=$REPLY_TXT;;
                    5) ask " FPS: "; [[ $REPLY_TXT =~ ^[1-9][0-9]*$ ]] && FPS=$REPLY_TXT;;
                    6) ask " Results file path: "; [[ -n $REPLY_TXT ]] && { OUT=$REPLY_TXT; load_bad; };;
                esac;;
            q|esc|quit) MSG=; return;;
        esac
    done
}

# ------------------------------------------------------------------ main menu
MENU_ITEMS=(
    "Browse all wallpapers"
    "Search by ID or name"
    "Jump to a workshop ID"
    "Review flagged (unsupported) items"
    "Scan everything for unsupported items"
    "Settings"
    "Stop current preview"
    "Quit"
)

draw_menu() {
    local sel=$1 cols i line st
    cols=$(tput cols)
    if preview_alive; then st="${C_G}● playing $PLAY_ID"; else st="${C_D}○ idle"; fi
    buf=
    titlebar "Wallpaper Engine  ▸  Workshop Browser" "$cols"
    L ""
    L "  ${C_C}┌──────────────────────────────────────────┐"
    L "  ${C_C}│${C_0}${C_B}   Wallpaper Engine · Workshop Browser    ${C_0}${C_C}│"
    L "  ${C_C}└──────────────────────────────────────────┘"
    L ""
    L "  ${C_D}Items${C_0} ${#ALL[@]}    ${C_D}Flagged${C_0} ${C_R}${#BAD[@]}${C_0}    ${C_D}Monitor${C_0} $MONITOR    ${C_D}Preview${C_0} $st"
    L ""
    for i in "${!MENU_ITEMS[@]}"; do
        printf -v line '  %s %d  %s' "$([[ $i == "$sel" ]] && echo '▸' || echo ' ')" "$((i + 1))" "${MENU_ITEMS[i]}"
        if ((i == sel)); then L "${C_I}$(printf '%-*s' 46 "$line")"; else L "$line"; fi
    done
    L ""
    L "  ${C_Y}${MSG:0:cols-4}"
    L ""
    L "${C_D}  ↑/↓ select   Enter open   1-8 shortcut   / quick search   q quit"
    paint
}

main_menu() {
    local sel=0 n=${#MENU_ITEMS[@]}
    while :; do
        poll_preview
        draw_menu "$sel"
        readkey 1
        local act=-1
        case $KEY in
            tick) ;;
            up|k) sel=$(((sel + n - 1) % n));;
            down|j) sel=$(((sel + 1) % n));;
            enter|space|right) act=$sel;;
            [1-8]) act=$((KEY - 1)); sel=$act;;
            /) act=1;;
            q|esc|quit) act=7;;
        esac
        case $act in
            0) MSG=; set_view_all; CUR=0; browser;;
            1) set_view_all; do_search && browser;;
            2) MSG=; set_view_all; CUR=0; do_jump && browser;;
            3) review_flagged && browser;;
            4) scan_all;;
            5) MSG=; settings;;
            6) stop_preview; MSG="Preview stopped";;
            7) return;;
        esac
    done
}

# ------------------------------------------------------------------ headless scan (old behaviour)
scan_headless() {
    : > "$OUT"; BAD=()
    local n=0 total=${#ALL[@]} id
    trap 'pkill -KILL -f "linux-wallpaperengine --assets-dir" 2>/dev/null; echo; echo "Interrupted. Partial results in $OUT"; exit 130' INT TERM
    for id in "${ALL[@]}"; do
        n=$((n + 1))
        printf '\r[%d/%d] %s   ' "$n" "$total" "$id" >&2
        check_item "$id"
        if [[ -n $CHECK_LINE ]]; then
            record_bad "$id" "$CHECK_LINE"
            printf '\n%s\t%s\t%s\n' "$id" "${TITLE[$id]:-(no title)}" "$CHECK_LINE" >&2
        fi
    done
    pkill -KILL -f "linux-wallpaperengine --assets-dir" 2>/dev/null
    echo >&2
    echo "Done. ${#BAD[@]} unsupported item(s) listed in $OUT" >&2
}

# ------------------------------------------------------------------ start
echo "Indexing workshop items…" >&2
load_index

if [[ $MODE == --scan ]]; then
    scan_headless
    exit 0
fi

load_bad
set_view_all

cleanup() {
    stop_preview
    pkill -KILL -f "linux-wallpaperengine --assets-dir" 2>/dev/null
    rm -f "$LOG"
    tput cnorm; tput rmcup
}
trap cleanup EXIT
trap 'exit 130' INT TERM

tput smcup; tput civis; clear
MSG="Loaded ${#ALL[@]} workshop items."
main_menu