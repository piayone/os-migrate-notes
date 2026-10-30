#!/usr/bin/env bash
# mangohud-env.sh - turn MangoHud on for ONE program by putting MANGOHUD=1 in its launcher.
#
# Usage:
#   mangohud-env.sh                 menu: 1 add, 2 list, 3 remove
#   mangohud-env.sh <name>          add MangoHud to <name> right away
#   mangohud-env.sh --list          list the programs that have MangoHud enabled
#   mangohud-env.sh --remove [name] take MangoHud out of a program again
#
# Remove (option 3 / --remove):
#   Shows a numbered list of programs that currently have MangoHud enabled.
#   You can select by numbers, ranges (1-4), names, or a mix, separated by
#   spaces or commas. Example:  1-4 5 10 melonds staem
#   Mistyped names are fuzzy-matched; if several candidates match you are
#   asked to pick the right one.
#
# Where it looks for <name> (matches the launcher's file name or its Name= line):
#   1. ~/.local/share/applications   -> edited in place (a .bak copy is kept)
#   2. system launchers (/usr/share/applications, flatpak exports, ...)
#                                    -> copied into 1. first, then edited, so package
#                                       updates never touch your edit
#   3. nothing found                 -> asks for the path of a .desktop file or of the
#                                       program itself. A program gets a new launcher in 1.
#
# From a terminal it asks in the terminal; started from a keybind it uses rofi.
# Flatpak launchers get --env=MANGOHUD=1 (the variable has to reach the sandbox).
#
# Note on Steam / Steam games: enabling MangoHud on the Steam .desktop only
# affects the Steam client itself. For individual games set a Steam launch
# option such as:  mangohud %command%   (or MANGOHUD=1 %command%).

LOCAL="$HOME/.local/share/applications"
SYSTEM_DIRS=(
    /usr/local/share/applications
    /usr/share/applications
    /var/lib/flatpak/exports/share/applications
    "$HOME/.local/share/flatpak/exports/share/applications"
)

# ---------------------------------------------------------------- output
if [ -t 1 ]; then
    C_OK=$'\e[32m'; C_ERR=$'\e[31m'; C_DIM=$'\e[2m'; C_BOLD=$'\e[1m'; C_OFF=$'\e[0m'
else
    C_OK=""; C_ERR=""; C_DIM=""; C_BOLD=""; C_OFF=""
fi

use_rofi() { [ ! -t 0 ] && command -v rofi >/dev/null 2>&1; }

# desktop notification, only when started without a terminal
notify() { use_rofi && notify-send -a "MangoHud" "$1" 2>/dev/null; return 0; }

tilde() { printf '%s' "${1/#$HOME/\~}"; }

# show ok|err "headline" "label|value" ...   -> a small aligned block
show() {
    local status="$1" head="$2" kv color="$C_OK" mark="✔"
    shift 2
    [ "$status" = err ] && { color="$C_ERR"; mark="✖"; }
    printf '\n%s%s %s%s\n' "$color" "$mark" "$head" "$C_OFF"
    for kv in "$@"; do
        printf '  %s%-11s%s %s\n' "$C_DIM" "${kv%%|*}" "$C_OFF" "${kv#*|}"
    done
    printf '\n'
}

# fail "message" ["label|value" ...]
fail() {
    local msg="$1"
    shift
    show err "$msg" "$@"
    notify "$msg"
    return 1
}

# ---------------------------------------------------------------- input
trim() {
    local s="$1"
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

# ask "prompt" ["hint"] -> prints the answer, returns 1 if empty or cancelled
ask() {
    local a
    if use_rofi; then
        a=$(rofi -dmenu -p "$1" -mesg "${2:-}" -theme-str 'listview {lines: 0;}' </dev/null) || return 1
    else
        [ -n "${2:-}" ] && echo "${C_DIM}$2${C_OFF}" >&2
        read -r -p "$1: " a || return 1
    fi
    a=$(trim "$a")
    [ -n "$a" ] || return 1
    printf '%s' "$a"
}

# pick "prompt" item... -> prints the chosen item (no question when there is only one)
pick() {
    local prompt="$1" a=""
    shift
    if [ "$#" -eq 1 ]; then printf '%s' "$1"; return 0; fi
    if use_rofi; then
        a=$(printf '%s\n' "$@" | rofi -dmenu -i -p "$prompt") || return 1
    else
        local PS3="$prompt (number): "
        select a in "$@"; do [ -n "$a" ] && break; done
    fi
    [ -n "$a" ] || return 1
    printf '%s' "$a"
}

# choose "prompt" query file... -> an exact "<query>.desktop" wins, otherwise ask
choose() {
    local prompt="$1" q="${2,,}" f b
    shift 2
    for f in "$@"; do
        b=${f##*/}
        [ "${b,,}" = "$q.desktop" ] && { printf '%s' "$f"; return 0; }
    done
    pick "$prompt" "$@"
}

# start menu -> prints 1, 2 or 3
menu() {
    local a
    local items=("Add MangoHud to a program" "List programs with MangoHud" "Remove MangoHud from a program")
    if use_rofi; then
        a=$(printf '%s\n' "1. ${items[0]}" "2. ${items[1]}" "3. ${items[2]}" \
            | rofi -dmenu -i -format i -p "MangoHud" -theme-str 'listview {lines: 3;}') || return 1
        printf '%s' "$((a + 1))"
    else
        printf '\n%sMangoHud launcher tool%s\n  1) %s\n  2) %s\n  3) %s\n\n' \
            "$C_BOLD" "$C_OFF" "${items[0]}" "${items[1]}" "${items[2]}" >&2
        read -r -p "Choose [1-3]: " a || return 1
        printf '%s' "$(trim "$a")"
    fi
}

# ---------------------------------------------------------------- launchers
# first plain Name= line of a launcher
display_name() { awk -F= '$1=="Name" {print substr($0, 6); exit}' "$1"; }

# launchers in directory $1 whose file name or Name= line contains $2 (case-insensitive)
matches_in() {
    local dir="$1" q="${2,,}" f b
    [ -d "$dir" ] || return 0
    for f in "$dir"/*.desktop; do
        [ -f "$f" ] || continue
        b=${f##*/}
        if [[ "${b,,}" == *"$q"* ]] \
           || awk -F= -v q="$q" 'tolower($1)=="name" && index(tolower($2), q) {ok=1} END {exit !ok}' "$f"; then
            printf '%s\n' "$f"
        fi
    done
}

# new launcher in $LOCAL for the program $1 (full path)
new_launcher() {
    local exe="$1" base q
    base=${exe##*/}
    base=${base%.*}                       # myapp.AppImage -> myapp
    [ -n "$base" ] || base=${exe##*/}
    TARGET="$LOCAL/$base.desktop"
    CREATED=1
    if [ -e "$TARGET" ]; then
        CREATED=0
        SOURCE="launcher from an earlier run (the one for $exe)"
        return 0
    fi
    # quote the path the way the .desktop spec wants it
    q=${exe//\\/\\\\}; q=${q//\"/\\\"}; q=${q//\$/\\\$}; q=${q//\`/\\\`}; q=${q//%/%%}
    cat > "$TARGET" <<EOF
[Desktop Entry]
Type=Application
Name=${base^}
Exec="$q"
Terminal=false
Categories=Game;
EOF
    SOURCE="new launcher created for $exe"
}

# find or build the launcher for query $1. Sets TARGET (a file in $LOCAL), SOURCE (how it got
# there) and CREATED=1 when it was not in $LOCAL before. Returns 1 when nothing was chosen.
locate() {
    local q="$1" f d p exe found=()
    local -A seen=()
    CREATED=0
    SOURCE=""

    # 1. already in the local folder
    mapfile -t found < <(matches_in "$LOCAL" "$q")
    if [ "${#found[@]}" -gt 0 ]; then
        TARGET=$(choose "Launcher" "$q" "${found[@]}") || return 1
        SOURCE="already in $(tilde "$LOCAL")"
        return 0
    fi
    if [ "$mode" = remove ]; then
        fail "Nothing to remove for '$q'" "Searched|$(tilde "$LOCAL")"
        return 1
    fi

    # 2. system launchers: copy the chosen one into the local folder
    for d in "${SYSTEM_DIRS[@]}"; do
        while IFS= read -r f; do
            [ -n "${seen[${f##*/}]:-}" ] && continue
            seen[${f##*/}]=1
            found+=("$f")
        done < <(matches_in "$d" "$q")
    done
    if [ "${#found[@]}" -gt 0 ]; then
        f=$(choose "Launcher" "$q" "${found[@]}") || return 1
        TARGET="$LOCAL/${f##*/}"
        cp -a "$f" "$TARGET" || return 1
        CREATED=1
        SOURCE="copied from $(tilde "$f")"
        return 0
    fi

    # 3. not found: ask for a path
    p=$(ask "'$q' not found: paste the path" \
        "Path of its .desktop file, or of the program itself") || return 1
    p=${p%\"}; p=${p#\"}; p=${p%\'}; p=${p#\'}; p=${p/#\~/$HOME}

    if [ -f "$p" ] && [[ "$p" == *.desktop ]]; then
        TARGET="$LOCAL/${p##*/}"
        if [ "$p" -ef "$TARGET" ]; then
            SOURCE="already in $(tilde "$LOCAL")"
        else
            cp -a "$p" "$TARGET" || return 1
            CREATED=1
            SOURCE="copied from $(tilde "$p")"
        fi
        return 0
    fi
    if [ -f "$p" ] && [ -x "$p" ]; then
        exe=$p
    else
        exe=$(command -v -- "$p" 2>/dev/null)
    fi
    if [ -z "$exe" ] || [ ! -f "$exe" ]; then
        fail "'$p' is not a .desktop file or a program" \
            "Hint|paste the full path of the launcher or of the executable"
        return 1
    fi
    new_launcher "$exe"
}

# ---------------------------------------------------------------- collect enabled
# fills global arrays: EN_NAMES EN_FILES EN_PATHS EN_COUNTS EN_WHERES
# returns 0 if any found, 1 if none
collect_enabled() {
    local d f b have total w where
    local -A seen=()
    EN_NAMES=(); EN_FILES=(); EN_PATHS=(); EN_COUNTS=(); EN_WHERES=()

    for d in "$LOCAL" "${SYSTEM_DIRS[@]}"; do
        [ -d "$d" ] || continue
        for f in "$d"/*.desktop; do
            [ -f "$f" ] || continue
            b=${f##*/}
            [ -n "${seen[$b]:-}" ] && continue
            seen[$b]=1
            have=$(grep -c '^Exec=.*MANGOHUD=1' "$f")
            [ "$have" -gt 0 ] || continue
            total=$(grep -c '^Exec=' "$f")
            w=$(display_name "$f"); : "${w:=$b}"
            EN_NAMES+=("$w")
            EN_FILES+=("$b")
            EN_PATHS+=("$f")
            if [ "$have" -eq "$total" ]; then EN_COUNTS+=("$have of $total"); else EN_COUNTS+=("$have of $total (partial)"); fi
            if [ "$d" = "$LOCAL" ]; then where="yours"; else where="system"; fi
            EN_WHERES+=("$where")
        done
    done
    [ "${#EN_NAMES[@]}" -gt 0 ]
}

# print the numbered table of enabled programs (uses EN_* arrays)
print_enabled_table() {
    local i wn=7 wf=8 wc=10
    for i in "${!EN_NAMES[@]}"; do
        [ "${#EN_NAMES[$i]}" -gt "$wn" ] && wn=${#EN_NAMES[$i]}
        [ "${#EN_FILES[$i]}" -gt "$wf" ] && wf=${#EN_FILES[$i]}
        [ "${#EN_COUNTS[$i]}" -gt "$wc" ] && wc=${#EN_COUNTS[$i]}
    done
    printf '\n%s✔ %d program(s) with MangoHud enabled%s\n\n' "$C_OK" "${#EN_NAMES[@]}" "$C_OFF"
    printf '  %s%3s  %-*s  %-*s  %-*s  %s%s\n' "$C_DIM" "#" "$wn" "Program" "$wf" "Launcher" "$wc" "Exec lines" "Where" "$C_OFF"
    for i in "${!EN_NAMES[@]}"; do
        printf '  %3d  %-*s  %-*s  %-*s  %s\n' "$((i + 1))" "$wn" "${EN_NAMES[$i]}" "$wf" "${EN_FILES[$i]}" "$wc" "${EN_COUNTS[$i]}" "${EN_WHERES[$i]}"
    done
    printf '\n'
}

# ---------------------------------------------------------------- actions
do_add() {
    local q="${1:-}" execs have name rows=()
    [ -n "$q" ] || q=$(ask "Program name") || return 0
    mode=add
    mkdir -p "$LOCAL"
    TARGET=""
    locate "$q" || return 1

    execs=$(grep -c '^Exec=' "$TARGET")
    [ "$execs" -gt 0 ] || { fail "No Exec= line in $(tilde "$TARGET")"; return 1; }

    # one-time backup of a launcher that was already in the local folder
    if [ "$CREATED" -eq 0 ] && [ ! -e "$TARGET.bak" ]; then
        cp -a "$TARGET" "$TARGET.bak" && rows+=("Backup|${TARGET##*/}.bak")
    fi

    # per Exec= line: skip if already set; flatpak gets --env=, everything else gets env
    sed -i -E '/^Exec=/{/MANGOHUD=1/b;/flatpak run/{s/flatpak run/flatpak run --env=MANGOHUD=1/;b};s/^Exec=/Exec=env MANGOHUD=1 /}' "$TARGET"
    have=$(grep -c '^Exec=.*MANGOHUD=1' "$TARGET")
    name=$(display_name "$TARGET")
    : "${name:=${TARGET##*/}}"

    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$LOCAL" 2>/dev/null
    show ok "MangoHud enabled for $name" \
        "Program|$q" \
        "Launcher|${TARGET##*/}" \
        "Location|$(tilde "${TARGET%/*}")" \
        "Source|$SOURCE" \
        "Exec lines|$have of $execs now set MANGOHUD=1" \
        "${rows[@]}" \
        "Next|quit $name completely, then start it from its launcher"
    notify "MangoHud enabled for $name"
}

# remove MangoHud from one concrete launcher path $1 (file under LOCAL or system)
_remove_one() {
    local path="$1" name d note="" rows=()
    name=$(display_name "$path")
    : "${name:=${path##*/}}"

    # work on a local copy if the path is a system launcher
    if [[ "$path" != "$LOCAL"/* ]]; then
        TARGET="$LOCAL/${path##*/}"
        if [ ! -e "$TARGET" ]; then
            cp -a "$path" "$TARGET" || return 1
        fi
        path="$TARGET"
    else
        TARGET="$path"
    fi

    sed -i -E '/^Exec=/{s/ --env=MANGOHUD=1//;s/env MANGOHUD=1 //}' "$path"

    # a local copy identical to the system launcher is just clutter: drop it
    for d in "${SYSTEM_DIRS[@]}"; do
        if [ -f "$d/${path##*/}" ] && cmp -s "$d/${path##*/}" "$path"; then
            rm -f "$path" "$path.bak"
            note="local copy deleted (identical to the system launcher in $(tilde "$d"))"
            break
        fi
    done
    [ -n "$note" ] && rows+=("Cleanup|$note")

    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$LOCAL" 2>/dev/null
    show ok "MangoHud removed from $name" \
        "Launcher|${path##*/}" \
        "${rows[@]}" \
        "Next|quit $name completely, then start it again"
    notify "MangoHud removed from $name"
}

# resolve a single token (number, range, or name) against EN_* arrays
# prints selected 0-based indices (one per line); may ask for clarification on fuzzy names
_resolve_token() {
    local tok="$1" i n low high ql matches=()
    n=${#EN_NAMES[@]}

    # pure number
    if [[ "$tok" =~ ^[0-9]+$ ]]; then
        if [ "$tok" -ge 1 ] && [ "$tok" -le "$n" ]; then
            printf '%s\n' "$((tok - 1))"
            return 0
        fi
        printf '%sNo entry #%s (valid: 1-%s)%s\n' "$C_ERR" "$tok" "$n" "$C_OFF" >&2
        return 1
    fi

    # range N-M
    if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        low=${BASH_REMATCH[1]}; high=${BASH_REMATCH[2]}
        if [ "$low" -gt "$high" ]; then
            local t=$low; low=$high; high=$t
        fi
        if [ "$low" -lt 1 ] || [ "$high" -gt "$n" ]; then
            printf '%sRange %s out of bounds (valid: 1-%s)%s\n' "$C_ERR" "$tok" "$n" "$C_OFF" >&2
            return 1
        fi
        for ((i = low; i <= high; i++)); do
            printf '%s\n' "$((i - 1))"
        done
        return 0
    fi

    # name: exact (case-insensitive) on Name or launcher file (without .desktop)
    ql=${tok,,}
    matches=()
    for i in "${!EN_NAMES[@]}"; do
        if [ "${EN_NAMES[$i],,}" = "$ql" ] || [ "${EN_FILES[$i]%.desktop}" = "$ql" ]; then
            matches+=("$i")
        fi
    done
    if [ "${#matches[@]}" -eq 1 ]; then
        printf '%s\n' "${matches[0]}"
        return 0
    fi
    if [ "${#matches[@]}" -gt 1 ]; then
        printf '%s"%s" matches multiple entries:%s\n' "$C_DIM" "$tok" "$C_OFF" >&2
        for i in "${matches[@]}"; do
            printf '  %d) %s  (%s)\n' "$((i + 1))" "${EN_NAMES[$i]}" "${EN_FILES[$i]}" >&2
        done
        local pick
        pick=$(ask "Which number for '$tok'?" "enter one of the numbers above") || return 1
        if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$n" ]; then
            # only accept if it was one of the matches
            for i in "${matches[@]}"; do
                if [ "$((i + 1))" -eq "$pick" ]; then
                    printf '%s\n' "$i"
                    return 0
                fi
            done
        fi
        printf '%sInvalid choice for "%s"%s\n' "$C_ERR" "$tok" "$C_OFF" >&2
        return 1
    fi

    # fuzzy / substring / simple typo tolerance
    matches=()
    for i in "${!EN_NAMES[@]}"; do
        local nn="${EN_NAMES[$i],,}" ff="${EN_FILES[$i]%.desktop}"
        if [[ "$nn" == *"$ql"* ]] || [[ "$ff" == *"$ql"* ]] \
           || [[ "$ql" == *"$nn"* ]] || [[ "$ql" == *"$ff"* ]]; then
            matches+=("$i")
            continue
        fi
        # very light Levenshtein-ish: same length ±1 and share most characters
        # (good enough for "staem" -> "steam")
        if [ ${#ql} -ge 3 ]; then
            local a="$ql" b="$nn"
            [ ${#b} -lt 3 ] && b="$ff"
            if [ ${#a} -ge $(( ${#b} - 1 )) ] && [ ${#a} -le $(( ${#b} + 1 )) ]; then
                # count shared prefix length + common chars roughly
                local shared=0 j
                for ((j = 0; j < ${#a} && j < ${#b}; j++)); do
                    [ "${a:j:1}" = "${b:j:1}" ] && ((shared++))
                done
                if [ "$shared" -ge $(( (${#b} * 2) / 3 )) ]; then
                    matches+=("$i")
                fi
            fi
        fi
    done

    if [ "${#matches[@]}" -eq 0 ]; then
        printf '%sNo match for "%s". Available:%s\n' "$C_ERR" "$tok" "$C_OFF" >&2
        for i in "${!EN_NAMES[@]}"; do
            printf '  %d) %s  (%s)\n' "$((i + 1))" "${EN_NAMES[$i]}" "${EN_FILES[$i]}" >&2
        done
        return 1
    fi
    if [ "${#matches[@]}" -eq 1 ]; then
        printf '%s"%s" → %s (%s)%s\n' "$C_DIM" "$tok" "${EN_NAMES[${matches[0]}]}" "${EN_FILES[${matches[0]}]}" "$C_OFF" >&2
        printf '%s\n' "${matches[0]}"
        return 0
    fi

    # multiple fuzzy hits → let user pick
    printf '%s"%s" could be:%s\n' "$C_DIM" "$tok" "$C_OFF" >&2
    for i in "${matches[@]}"; do
        printf '  %d) %s  (%s)\n' "$((i + 1))" "${EN_NAMES[$i]}" "${EN_FILES[$i]}" >&2
    done
    local pick
    pick=$(ask "Which number for '$tok'?" "enter one of the numbers above, or cancel") || return 1
    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$n" ]; then
        for i in "${matches[@]}"; do
            if [ "$((i + 1))" -eq "$pick" ]; then
                printf '%s\n' "$i"
                return 0
            fi
        done
    fi
    printf '%sInvalid choice for "%s"%s\n' "$C_ERR" "$tok" "$C_OFF" >&2
    return 1
}

do_remove() {
    local q="${1:-}" sel tokens=() idxs=() i idx seen_idx=()
    local -A picked=()

    if ! collect_enabled; then
        show ok "No program has MangoHud enabled yet" \
            "Add one|run this script again and choose 1"
        notify "No program has MangoHud enabled yet"
        return 0
    fi

    # if a name was given on the command line, try to resolve it directly
    if [ -n "$q" ]; then
        mapfile -t idxs < <(_resolve_token "$q")
        if [ "${#idxs[@]}" -eq 0 ]; then
            return 1
        fi
    else
        # interactive: show list then ask for selection
        if use_rofi; then
            local lines=() choice
            for i in "${!EN_NAMES[@]}"; do
                lines+=("$((i + 1)). ${EN_NAMES[$i]}  —  ${EN_FILES[$i]}  (${EN_COUNTS[$i]})")
            done
            choice=$(printf '%s\n' "${lines[@]}" | rofi -dmenu -i -multi-select -p "Remove MangoHud" \
                -mesg "Select one or more (Shift+Enter multi). Esc cancel.") || return 0
            [ -z "$choice" ] && return 0
            while IFS= read -r line; do
                [[ "$line" =~ ^([0-9]+)\. ]] && idxs+=("$(( ${BASH_REMATCH[1]} - 1 ))")
            done <<< "$choice"
        else
            print_enabled_table
            printf '%sEnter numbers, ranges (1-3), and/or names (space or comma separated).%s\n' "$C_DIM" "$C_OFF" >&2
            printf '%sExamples:  1 3 5   |   1-4 7   |   steam melonds   |   1-2 staem%s\n\n' "$C_DIM" "$C_OFF" >&2
            sel=$(ask "Remove which?" "numbers / ranges / names") || return 0
            # split on spaces and commas
            IFS=$' ,\t\n' read -r -a tokens <<< "$sel"
            for tok in "${tokens[@]}"; do
                [ -z "$tok" ] && continue
                mapfile -t -O "${#idxs[@]}" idxs < <(_resolve_token "$tok")
            done
        fi
    fi

    if [ "${#idxs[@]}" -eq 0 ]; then
        fail "Nothing selected"
        return 1
    fi

    # unique, in ascending order
    for idx in "${idxs[@]}"; do
        [ -n "${picked[$idx]:-}" ] && continue
        picked[$idx]=1
        seen_idx+=("$idx")
    done
    IFS=$'\n' seen_idx=($(printf '%s\n' "${seen_idx[@]}" | sort -n))
    unset IFS

    mode=remove
    for idx in "${seen_idx[@]}"; do
        _remove_one "${EN_PATHS[$idx]}"
    done
}

# every launcher whose Exec line(s) set MANGOHUD=1; a local copy hides the system one
do_list() {
    if ! collect_enabled; then
        show ok "No program has MangoHud enabled yet" \
            "Add one|run this script again and choose 1"
        notify "No program has MangoHud enabled yet"
        return 0
    fi

    if use_rofi; then
        local i
        for i in "${!EN_NAMES[@]}"; do
            printf '%s   —   %s   (%s)\n' "${EN_NAMES[$i]}" "${EN_FILES[$i]}" "${EN_COUNTS[$i]}"
        done | rofi -dmenu -i -p "MangoHud on" \
            -mesg "${#EN_NAMES[@]} program(s) have MangoHud enabled. Esc to close."
        return 0
    fi

    print_enabled_table
}

usage() {
    cat <<EOF
Usage: ${0##*/} [name | --list | --remove [name]]
  (no argument)     menu: 1 add, 2 list, 3 remove
  <name>            add MangoHud to a program
  --list, -l        list the programs that have MangoHud enabled
  --remove, -r      take MangoHud out of program(s)
                    (lists enabled programs; accepts numbers, ranges 1-4,
                     names, or mix, space/comma separated; fuzzy match on names)
EOF
}

# ---------------------------------------------------------------- main
mode=add
TARGET=""
CREATED=0
SOURCE=""

case "${1:-}" in
    -h|--help)   usage ;;
    -l|--list)   do_list ;;
    -r|--remove) shift; do_remove "${1:-}" ;;
    "")
        choice=$(menu) || exit 0
        case "$choice" in
            1) do_add "" ;;
            2) do_list ;;
            3) do_remove "" ;;
            *) exit 0 ;;
        esac
        ;;
    *) do_add "$1" ;;
esac
