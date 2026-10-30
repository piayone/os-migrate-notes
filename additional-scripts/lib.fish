#!/usr/bin/fish
# lib.fish - shared helpers for initual-setup.sh, sync-notes.sh and pkg-track.fish.
# Sourced by them, not run directly. The caller defines info and warn.

# ================================================================ package managers
# prints pacman, apt, dnf, zypper or none
function detect_pm
    if type -q pacman
        echo pacman
    else if type -q apt-get
        echo apt
    else if type -q dnf
        echo dnf
    else if type -q zypper
        echo zypper
    else
        echo none
    end
end

# pm_has PM NAME : is the package available in the repos (pacman also checks the AUR)?
function pm_has
    set -l pm $argv[1]
    set -l n $argv[2]
    switch $pm
        case pacman
            pacman -Si $n >/dev/null 2>&1; and return 0
            pacman -Sg $n >/dev/null 2>&1; and return 0
            type -q paru; and paru -Si $n >/dev/null 2>&1; and return 0
            return 1
        case apt
            apt-cache show $n >/dev/null 2>&1
        case dnf
            dnf -q info $n >/dev/null 2>&1
        case zypper
            zypper -q info $n >/dev/null 2>&1
        case '*'
            return 1
    end
end

# pm_installed PM NAME : is it installed right now? (PM may also be flatpak, snap or pipx)
function pm_installed
    switch $argv[1]
        case pacman
            pacman -Qq $argv[2] >/dev/null 2>&1
        case apt
            dpkg -s $argv[2] >/dev/null 2>&1
        case dnf zypper
            rpm -q $argv[2] >/dev/null 2>&1
        case flatpak
            type -q flatpak; or return 1
            flatpak info $argv[2] >/dev/null 2>&1
        case pipx
            pipx_installed $argv[2]
        case snap
            snap list $argv[2] >/dev/null 2>&1
        case '*'
            return 1
    end
end

# pm_install PM PKG... : install (pacman uses paru when it exists, so AUR packages work)
function pm_install
    set -l pm $argv[1]
    set -e argv[1]
    test (count $argv) -gt 0; or return 0
    switch $pm
        case pacman
            if type -q paru
                paru -S --needed --noconfirm $argv
            else
                sudo pacman -S --needed --noconfirm $argv
            end
        case apt
            sudo apt-get install -y $argv
        case dnf
            sudo dnf install -y $argv
        case zypper
            sudo zypper --non-interactive install $argv
        case '*'
            return 1
    end
end

# pm_remove PM PKG... : uninstall (PM may also be flatpak)
function pm_remove
    set -l pm $argv[1]
    set -e argv[1]
    test (count $argv) -gt 0; or return 0
    switch $pm
        case pacman
            sudo pacman -Rns $argv
        case apt
            sudo apt-get remove -y $argv
        case dnf
            sudo dnf remove -y $argv
        case zypper
            sudo zypper --non-interactive remove $argv
        case flatpak
            flatpak uninstall -y $argv
        case pipx
            # each word may be the alias, the address / PyPI name, or the name pipx gave the app
            for w in $argv
                set -l v (pipx_venv_for $w)
                if test -z "$v"
                    warn "pipx: '$w' is not installed"
                    continue
                end
                pipx uninstall $v
            end
            pipx_forget
        case snap
            for n in $argv
                sudo snap remove $n
            end
        case '*'
            return 1
    end
end

# pm_update PM : refresh the package lists and update the system
function pm_update
    switch $argv[1]
        case pacman
            if type -q paru
                paru -Syu --noconfirm
            else
                sudo pacman -Syu --noconfirm
            end
        case apt
            sudo apt-get update; and sudo apt-get upgrade -y
        case dnf
            sudo dnf upgrade -y --refresh
        case zypper
            sudo zypper --non-interactive refresh; and sudo zypper --non-interactive update
    end
end

# now_snap : the snap apps installed here, sorted, one per line. Runtimes that come in as
# dependencies are left out: snapd itself, core*/bare, snaps with the "base" note, and the
# gnome-*/gtk-*/kf5-*/kf6-*/mesa-*/qt* platform snaps.
function now_snap
    type -q snap; or return 0
    set -l out
    for l in (snap list 2>/dev/null | tail -n +2)
        set -l f (string split -n ' ' -- $l)
        test (count $f) -ge 1; or continue
        set -l name $f[1]
        set -l notes $f[-1]
        contains -- $notes base snapd; and continue
        string match -qr '^(core[0-9]*|bare|snapd|gnome-.*|gtk-.*|kf5-.*|kf6-.*|mesa-.*|qt.*-core.*)$' -- $name; and continue
        set -a out $name
    end
    test (count $out) -gt 0; and printf '%s\n' $out | sort -u
    return 0
end

# ================================================================ pipx
# A [pipx] line in packages.conf is   SPEC [name=ALIAS]
#   SPEC  is what "pipx install" gets: a PyPI name (spotdl), a git address (git+https://github.com/u/repo),
#         a web address or a local path/file. pipx remembers the same text as "package_or_url".
#   name= is optional and works on every kind of line (see "names you give to entries" below). Uninstall,
#         remove and list accept the name, the SPEC, or the name pipx gave the app.
#   (older files may have  NAME src=SPEC  instead: that still works.)

# pipx_forget : drop the cached `pipx list` (call it after installing or removing something)
function pipx_forget
    set -e __pipx_pairs
    set -e __pipx_have
end

# pipx_pairs : one line per installed pipx app, "venv-name<TAB>package_or_url".
# Nothing when pipx is missing; status 1 when pipx is there but its list cannot be read.
# The answer is cached for the run (pipx list is slow); pipx_forget clears it.
function pipx_pairs
    type -q pipx; or return 0
    if not set -q __pipx_have
        set -l js (pipx list --json 2>/dev/null | string collect)
        test -n "$js"; or return 1
        set -l out
        if type -q python3
            set out (printf '%s' "$js" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for name, venv in sorted(data.get("venvs", {}).items()):
    main = (venv.get("metadata") or {}).get("main_package") or {}
    print("%s\t%s" % (name, main.get("package_or_url") or name))
'); or return 1
        else
            # no python: the plain names (an app installed from git is then known by its own name)
            for n in (pipx list --short 2>/dev/null | string split -f1 ' ')
                set -a out (printf '%s\t%s' $n $n)
            end
        end
        set -g __pipx_pairs $out
        set -g __pipx_have 1
    end
    # printf with no arguments would still print one empty line
    test (count $__pipx_pairs) -gt 0; and printf '%s\n' $__pipx_pairs
    return 0
end

# pipx_specs : the package_or_url of every installed app, sorted, one per line. Status 1 = could not read.
function pipx_specs
    set -l pairs (pipx_pairs); or return 1
    for l in $pairs
        string split -f2 \t -- $l
    end | sort -u
    return 0
end

# pipx_is_pypi SPEC : a plain PyPI name (extras and a version are fine: name[extra]==1.2)
function pipx_is_pypi
    string match -q -- '*/*' $argv[1]; and return 1
    string match -qr '^[A-Za-z0-9][A-Za-z0-9._-]*(\[[A-Za-z0-9,._-]+\])?([=<>!~]=?[A-Za-z0-9.*+!_-]+)?$' -- $argv[1]
end

# pipx_basename SPEC : git+https://github.com/u/some-tool.git@v1 -> some-tool ; a PyPI name stays as it is
function pipx_basename
    set -l x $argv[1]
    if pipx_is_pypi $x
        string replace -r '[\[=<>!~].*$' '' -- $x
        return 0
    end
    set x (string replace -r '[#?].*$' '' -- $x)
    set x (string replace -r '@[^/@]*$' '' -- $x)
    set x (string trim -r -c / -- $x)
    set x (string replace -r '.*/' '' -- $x)
    set x (string replace -r '\.git$' '' -- $x)
    set x (string replace -r '(\.whl|\.tar\.gz|\.zip)$' '' -- $x)
    echo $x
end

# pipx_short SPEC : for display. A plain name stays; an address becomes "some-tool (git)"
function pipx_short
    if pipx_is_pypi $argv[1]
        echo $argv[1]
    else
        echo (pipx_basename $argv[1])" (not PyPI)"
    end
end

# pipx_entry_spec KEY [TOKEN...] : the SPEC of a [pipx] line
function pipx_entry_spec
    set -l key $argv[1]
    set -e argv[1]
    for t in $argv
        if string match -q -- 'src=*' $t
            string replace -- 'src=' '' $t
            return 0
        end
    end
    echo $key
end

# pipx_conf_spec FILE KEY : the SPEC of the [pipx] line with that key (status 1 when there is none)
function pipx_conf_spec
    for l in (pkg_lines $argv[1])
        set -l w (string split ' ' -- $l)
        test "$w[1]" = pipx -a "$w[2]" = "$argv[2]"; or continue
        set -l toks
        set -q w[3]; and set toks $w[3..-1]
        pipx_entry_spec $w[2] $toks
        return 0
    end
    return 1
end

# pipx_conf_key FILE WORD : the key of the [pipx] line that WORD means: its key (the name you gave it),
# its SPEC, or the plain name of the project (some-tool for git+https://.../some-tool). Status 1 when none.
function pipx_conf_key
    set -l want (string lower -- $argv[2])
    for l in (pkg_lines $argv[1])
        set -l w (string split ' ' -- $l)
        test "$w[1]" = pipx; or continue
        set -l toks
        set -q w[3]; and set toks $w[3..-1]
        set -l spec (pipx_entry_spec $w[2] $toks)
        for c in $w[2] $spec (pipx_basename $spec) (entry_alias $toks)
            if test (string lower -- $c) = "$want"
                echo $w[2]
                return 0
            end
        end
    end
    return 1
end

# pipx_resolve WORD : the SPECs WORD can stand for (itself, and the SPEC of the list entry it names)
function pipx_resolve
    echo $argv[1]
    if set -q pkgfile; and test -f "$pkgfile"
        set -l k (pipx_conf_key $pkgfile $argv[1]); or return 0
        set -l sp (pipx_conf_spec $pkgfile $k); and echo $sp
    end
end

# pipx_venv_for WORD : the name pipx uses for the app WORD stands for (nothing, status 1, when not installed)
function pipx_venv_for
    set -l specs (pipx_resolve $argv[1])
    for l in (pipx_pairs)
        set -l f (string split \t -- $l)
        test (count $f) -ge 2; or continue
        if contains -- "$f[1]" $specs; or contains -- "$f[2]" $specs
            echo $f[1]
            return 0
        end
    end
    return 1
end

# pipx_installed WORD : is THIS app installed? WORD is the name you gave it or its SPEC. It compares the
# source, not pipx's own name: a fork of spotdl installed from git is also called "spotdl" by pipx, but
# it is not the PyPI "spotdl" entry.
function pipx_installed
    type -q pipx; or return 1
    set -l specs (pipx_resolve $argv[1])
    for l in (pipx_pairs)
        set -l f (string split \t -- $l)
        test (count $f) -ge 2; or continue
        contains -- "$f[2]" $specs; and return 0
    end
    return 1
end

# ---- names you give to entries (any section)
# Any line of packages.conf can carry   name=ALIAS   (any text; spaces etc. are stored as %20 ...). The first word of the line stays what
# it was (the package name, flatpak id, git address or pipx spec), so installing and tracking do not
# change; the alias is what the manager shows, and remove / uninstall / list accept it or the original.

# entry_alias TOKEN... : the value of the name= token (status 1 when there is none)
function entry_alias
    for t in $argv
        if string match -q -- 'name=*' $t
            alias_decode (string replace -- 'name=' '' $t)
            return 0
        end
    end
    return 1
end

# entry_token NAME TOKEN... : the value of a NAME=value token (status 1 when there is none)
function entry_token
    set -l want $argv[1]
    set -e argv[1]
    for t in $argv
        if string match -q -- "$want=*" $t
            string replace -- "$want=" '' $t
            return 0
        end
    end
    return 1
end

# conf_alias FILE SECTION KEY : the name given to that entry (nothing when there is none)
function conf_alias
    for l in (pkg_lines $argv[1])
        set -l w (string split ' ' -- $l)
        test "$w[1]" = "$argv[2]" -a "$w[2]" = "$argv[3]"; or continue
        set -l toks
        set -q w[3]; and set toks $w[3..-1]
        entry_alias $toks
        return 0
    end
    return 1
end

# alias_valid NAME : a name you may give: any text, but not empty, not just "-" (that clears the name)
# and without control characters
function alias_valid
    set -l n (string trim -- $argv[1])
    test -n "$n"; or return 1
    test "$n" != -; or return 1
    not string match -qr '[[:cntrl:]]' -- $n
end

# alias_alt NAME : NAME for the space separated items_alt lists (its spaces become no-break spaces)
function alias_alt
    string replace -a ' ' \u00a0 -- $argv[1]
end

# conf_set_token FILE SECTION KEY TOKENNAME VALUE : set (or, with an empty VALUE, remove) the TOKENNAME=VALUE
# token on that entry's line. Everything else on the line stays. Status 1 when the entry is not in the file.
function conf_set_token
    set -l file $argv[1]
    set -l sec $argv[2]
    set -l key $argv[3]
    set -l tname $argv[4]
    set -l new $argv[5]
    conf_has $file $sec $key; or return 1
    set -l cur native
    set -l out
    for l in (cat $file)
        set -l h (string match -r '^\s*\[(\w+)\]\s*$' -- $l)
        if set -q h[2]
            set cur $h[2]
            set -a out $l
            continue
        end
        if test "$cur" = "$sec"
            set -l c (string replace -r '(^|\s)#.*$' '' -- $l)
            set -l w (string split -n ' ' -- (string trim -- $c))
            if set -q w[1]; and test "$w[1]" = "$key"
                set -l row $w[1]
                for t in $w[2..-1]
                    string match -q -- "$tname=*" $t; or set -a row $t
                end
                test -n "$new"; and set -a row "$tname=$new"
                set -a out (string join ' ' -- $row)
                continue
            end
        end
        set -a out $l
    end
    printf '%s\n' $out >$file
end

# conf_set_alias FILE SECTION KEY ALIAS : give the entry the name ALIAS (empty ALIAS takes the name away)
function conf_set_alias
    conf_set_token $argv[1] $argv[2] $argv[3] name (alias_encode "$argv[4]")
end

# pipx_ask_name FILE KEY : only with a terminal. For an app that does not come from PyPI, offer to give
# its entry a name (it is otherwise listed by its whole address). Enter keeps it as it is.
function pipx_ask_name
    set -l file $argv[1]
    set -l key $argv[2]
    isatty stdin; or return 0
    set -l spec (pipx_conf_spec $file $key); or return 0
    pipx_is_pypi $spec; and return 0
    # already has a name? then there is nothing to ask
    test -z "$(conf_alias $file pipx $key)"; or return 0
    set -l guess (pipx_basename $spec)
    echo
    echo "  '$guess' is not on PyPI, so it is listed by its address:"
    echo "    $spec"
    while true
        read -P "  Name for it? (e.g. $guess; Enter = no name): " -l name; or return 0
        set name (string trim -- $name)
        test -n "$name"; or return 0
        if not alias_valid $name
            warn "not a usable name"
            continue
        end
        if conf_name_taken $file $name
            warn "'$name' is taken"
            continue
        end
        conf_set_alias $file pipx $key $name; and info "named: $name"
        return 0
    end
end

# conf_name_taken FILE NAME : is NAME already the key or the name of some entry?
function conf_name_taken
    for l in (pkg_lines $argv[1])
        set -l w (string split ' ' -- $l)
        set -l toks
        set -q w[3]; and set toks $w[3..-1]
        test "$w[2]" = "$argv[2]"; and return 0
        test "$(entry_alias $toks)" = "$argv[2]"; and return 0
    end
    return 1
end

# pipx_listed FILE SPEC : is an app with this SPEC already in a [pipx] line (under any name)?
function pipx_listed
    for l in (pkg_lines $argv[1])
        set -l w (string split ' ' -- $l)
        test "$w[1]" = pipx; or continue
        set -l toks
        set -q w[3]; and set toks $w[3..-1]
        test (pipx_entry_spec $w[2] $toks) = "$argv[2]"; and return 0
    end
    return 1
end

# ---- install scripts of git repos
# A [git] line can carry  install=PATH  (PATH inside the clone): the script you ran to install that repo
# (install.sh...). The setup offers to run it after cloning the repo on a new machine.

# git_install_candidates DIR : the install scripts found in a clone (two folders deep), one per line,
# paths relative to DIR, the shallowest first
function git_install_candidates
    set -l d $argv[1]
    test -d $d; or return 0
    for f in (find $d -maxdepth 2 -type f -not -path '*/.git/*' \( -iname 'install.sh' -o -iname 'install' -o -iname 'install.fish' \
            -o -iname 'installer.sh' -o -iname 'setup.sh' -o -iname 'setup.fish' -o -iname 'install-*.sh' \) -printf '%P\n' 2>/dev/null)
        string match -q -- '* *' $f; and continue      # a path with a space cannot be stored on the line
        echo $f
    end | awk -F/ '{print NF, $0}' | sort -n | cut -d' ' -f2-
end

# git_entry_tokens FILE URL : the options after the address on that [git] line, one per line
function git_entry_tokens
    for l in (pkg_lines $argv[1])
        set -l w (string split ' ' -- $l)
        test "$w[1]" = git -a "$w[2]" = "$argv[2]"; or continue
        set -q w[3]; and printf '%s\n' $w[3..-1]
        return 0
    end
end

# git_run_install DIR REL : run the install script of a clone, from the repo's own folder
function git_run_install
    set -l dir $argv[1]
    set -l rel $argv[2]
    set -l f $dir/$rel
    test -f $f; or begin
        warn "$f is not there"
        return 1
    end
    set -l first (head -n1 $f)
    pushd $dir
    if string match -q '*fish*' -- $first; or string match -q '*.fish' -- $rel
        fish $rel
    else if string match -q '*.sh' -- $rel; or string match -q '*sh*' -- $first
        bash $rel
    else
        chmod +x $rel 2>/dev/null
        ./$rel
    end
    set -l st $status
    popd
    return $st
end

# git_ask_install FILE URL [DIR] : only with a terminal. When the clone has an install script, ask whether you
# installed the repo with it; if yes the line gets install=PATH so the setup offers it on a new machine.
function git_ask_install
    set -l file $argv[1]
    set -l url $argv[2]
    set -l dir (git_dest $url)
    set -q argv[3]; and set dir $argv[3]
    isatty stdin; or return 0
    test -d $dir; or return 0
    entry_token install (git_entry_tokens $file $url) >/dev/null; and return 0
    set -l cands (git_install_candidates $dir)
    test (count $cands) -gt 0; or return 0
    set -l repo (basename $dir)
    echo
    echo "  $repo has an install script:"
    for i in (seq (count $cands))
        echo "    $i) $cands[$i]"
    end
    set -l pick 1
    if test (count $cands) -gt 1
        read -P "  Which one did you run to install it? (number; Enter = none, it is not installed this way): " -l a; or return 0
        set a (string trim -- $a)
        test -n "$a"; or return 0
        string match -qr '^[0-9]+$' -- $a; and test $a -ge 1 -a $a -le (count $cands); or begin
            warn "not a number from the list, nothing recorded"
            return 0
        end
        set pick $a
    else
        read -P "  Did you install $repo with it? Record it, and the setup will offer to run it on a new machine [y/N]: " -l a; or return 0
        string match -qri '^y' -- (string trim -- $a); or return 0
    end
    conf_set_token $file git $url install $cands[$pick]; and info "recorded: $repo is installed with $cands[$pick]"
end

# ---- git repos
# git_repos : the origin address of each clone that sits directly in ~/Documents in a folder named
# like the repo (that is where a [git] entry is cloned). The notes folder itself is left out.
function git_repos
    type -q git; or return 0
    for d in $HOME/Documents/*/
        set d (string trim -r -c / -- $d)
        test -d $d/.git; or continue
        if set -q notes; and test (realpath $d) = "$notes"
            continue
        end
        set -l url (git -C $d remote get-url origin 2>/dev/null); or continue
        test -n "$url"; or continue
        test (basename $d) = (basename (string trim -r -c / -- $url) .git); or continue
        echo $url
    end | sort -u
    return 0
end

# ================================================================ layout of the notes
# Everything that is backed up lives in one of two places inside the notes folder, and both
# mirror your home folder (the live path without ~/):
#   Backup/<path>                     always restored   ~/Downloads/clean.py -> Backup/Downloads/clean.py
#   Desktop Environment/<DE>/<path>   restored only when that desktop is chosen in initual-setup.sh
#                                     ~/.config/mango -> Desktop Environment/mango/.config/mango
# Nothing about a specific desktop is written in the scripts: <DE> is just a folder name, and the
# desktops offered by initual-setup.sh are the folders that exist in "Desktop Environment/".
# A desktop can also have pre.fish (runs before any config is restored, e.g. to install the
# desktop's own packages) and post.fish (runs after, e.g. to enable a service) in its folder.
# Entries in packages.conf can still carry de=NAME to install a package only for a chosen desktop.
# The choice made in the setup is saved OUTSIDE the notes (one name per line, "none" = no desktop).

set -g layout_backup Backup
set -g layout_de "Desktop Environment"
set -g layout_system System

function de_cfg_file
    echo $HOME/.config/os-migrate-notes/desktop
end

# selected_des : the saved desktop names, lower case, one per line
function selected_des
    set -l f (de_cfg_file)
    test -f $f; or return 0
    for l in (cat $f)
        set l (string lower -- (string trim -- $l))
        test -n "$l"; and echo $l
    end
end

# de_selected NAME... : true when no name is given (not tied to a desktop) or one of them was chosen
function de_selected
    test (count $argv) -gt 0; or return 0
    set -l sel (selected_des)
    for n in $argv
        contains -- (string lower -- $n) $sel; and return 0
    end
    return 1
end

# de_tags TOKEN... : the desktop names inside de=a,b tokens (nothing when there is no de= token)
function de_tags
    for t in $argv
        string match -q -- 'de=*' $t; or continue
        string split -n , -- (string lower -- (string replace -- 'de=' '' $t))
    end
end

# de_dirs NOTES : the desktops that have a folder in "Desktop Environment/" of the notes, one per line
function de_dirs
    set -l root $argv[1]/$layout_de
    test -d $root; or return 0
    for d in $root/*/
        basename $d
    end | sort -f
end

# de_dir_name NOTES NAME : the folder that matches NAME in any letter case (status 1 when there is none)
function de_dir_name
    set -l want (string lower -- $argv[2])
    for d in (de_dirs $argv[1])
        if test (string lower -- $d) = "$want"
            echo $d
            return 0
        end
    end
    return 1
end

# de_of_name NAME : the desktop a notes name belongs to ("mango" for "Desktop Environment/mango/...");
# nothing, and status 1, for a name in Backup/
function de_of_name
    set -l parts (string split -m2 / -- $argv[1])
    test "$parts[1]" = "$layout_de"; or return 1
    test -n "$parts[2]"; or return 1
    echo $parts[2]
end

# ---- which desktops use a shared thing
# Rofi, the SDDM files and the like are shared by several desktops, so they are not moved into one
# desktop's folder. Instead the desktops that use them are listed on the tracked.conf entry:
#   de=NAME[,NAME]  : it is restored (and synced) only on a machine where one of those desktops was
#   chosen. No de= = every machine. This works for Backup/ entries and for System/ entries alike.

# entry_active NAME OPTION... : should this tracked.conf entry be restored on this machine?
# A file inside "Desktop Environment/<DE>/" needs that desktop; a de=a,b option needs one of those.
function entry_active
    set -l name $argv[1]
    set -e argv[1]
    set -l d (de_of_name $name)
    if test -n "$d"; and not de_selected $d
        return 1
    end
    set -l tags (de_tags $argv)
    if test (count $tags) -gt 0; and not de_selected $tags
        return 1
    end
    return 0
end

# uses_elsewhere OPTION... : true when the options have a de= list and none of those desktops is
# chosen on this machine (so a sync leaves the shared copy alone). With no saved desktop choice
# nothing is held back.
function uses_elsewhere
    set -l tags (de_tags $argv)
    test (count $tags) -gt 0; or return 1
    test (count (selected_des)) -gt 0; or return 1
    de_selected $tags; and return 1
    return 0
end

# tracked_name_for LIVE [DE] : where the copy of LIVE goes in the notes. The notes mirror the live path:
# under Backup/ or Desktop Environment/DE/ for a path in your home folder, under System/ for any other.
function tracked_name_for
    # outside the home folder: a system file, saved as System/<its absolute path without the first />
    if not string match -q -- "$HOME/*" $argv[1]
        echo "$layout_system/"(string replace -r -- '^/' '' $argv[1])
        return 0
    end
    set -l rel (string replace -- "$HOME/" "" $argv[1])
    if test -n "$argv[2]"
        echo "$layout_de/$argv[2]/$rel"
    else
        echo "$layout_backup/$rel"
    end
end

# ================================================================ packages.conf
# Sections:
#   [native]   packages from the distro's own repos (pacman, apt, dnf, zypper)
#   [flatpak]  flatpak apps by application id (the same on every distro)
#   [snap]     snap packages by name (the same on every distro that has snapd)
#   [pipx]     Python apps installed with pipx: a PyPI name, or a git/web address or path (the same on every
#              distro)
#   Any line can end in  name=ALIAS  to give the entry a name of your own (sync-notes.sh pkg rename).
#   [git]      git repos, one URL per line, cloned to ~/Documents/<repo name>
# A [native] line is:  name [apt=x] [dnf=x] [zypper=x] [pacman=x] [only=apt,dnf] [arch]
#   name           the package name, used on every distro that has a package with that name
#   apt=x ...      the name to use on that package manager instead
#   only=a,b       install only with those package managers
#   arch           short for only=pacman (the package exists on Arch/CachyOS only)
#   de=a,b         only when one of those desktop environments was chosen in initual-setup.sh
#   replaces=x,y   uninstall these packages first (e.g. a package that conflicts with this one)

# pkg_lines FILE : cleaned lines as "section name tokens..." (comments and blanks removed)
function pkg_lines
    test -f $argv[1]; or return 0
    set -l cur native
    for l in (cat $argv[1])
        set l (string replace -r '(^|\s)#.*$' '' -- $l)
        set l (string replace -ra '\s+' ' ' -- $l)
        set l (string trim -- $l)
        test -n "$l"; or continue
        set -l h (string match -r '^\[(\w+)\]$' -- $l)
        if set -q h[2]
            set cur $h[2]
            continue
        end
        echo "$cur $l"
    end
end

# pkg_resolve PM NAME [TOKEN...] : the package name to use on PM, or nothing (status 1)
function pkg_resolve
    set -l pm $argv[1]
    set -l name $argv[2]
    set -l toks
    set -q argv[3]; and set toks $argv[3..-1]
    test "$pm" != none; or return 1

    set -l restrict 0
    set -l ok 0
    for t in $toks
        if test "$t" = arch
            set restrict 1
            test "$pm" = pacman; and set ok 1
        else if string match -q -- 'only=*' $t
            set restrict 1
            contains -- $pm (string split , -- (string replace -- 'only=' '' $t)); and set ok 1
        end
    end
    if test $restrict -eq 1; and test $ok -eq 0
        return 1
    end

    for t in $toks
        if string match -q -- "$pm=*" $t
            string replace -- "$pm=" '' $t
            return 0
        end
    end
    echo $name
end

# conf_has FILE SECTION NAME
function conf_has
    for l in (pkg_lines $argv[1])
        set -l w (string split ' ' -- $l)
        if test "$w[1]" = "$argv[2]"; and test "$w[2]" = "$argv[3]"
            return 0
        end
    end
    return 1
end

# conf_add FILE SECTION LINE : put LINE at the end of that section (the section is created if missing)
function conf_add
    set -l file $argv[1]
    set -l sec $argv[2]
    set -l new $argv[3]
    set -l lines
    test -f $file; and set lines (cat $file)
    set -l cur native
    set -l last 0
    set -l i 0
    for l in $lines
        set i (math $i + 1)
        set -l h (string match -r '^\s*\[(\w+)\]\s*$' -- $l)
        if set -q h[2]
            set cur $h[2]
            test "$cur" = "$sec"; and set last $i
            continue
        end
        if test "$cur" = "$sec"
            string match -qr '^\s*$' -- $l; or set last $i
        end
    end
    set -l out
    if test $last -eq 0
        set out $lines "" "[$sec]" $new
    else
        set out $lines[1..$last] $new
        if test $last -lt (count $lines)
            set -a out $lines[(math $last + 1)..-1]
        end
    end
    printf '%s\n' $out >$file
end

# conf_remove FILE SECTION NAME : delete that entry, keep everything else (comments, blanks)
function conf_remove
    set -l file $argv[1]
    set -l sec $argv[2]
    set -l name $argv[3]
    set -l cur native
    set -l out
    for l in (cat $file)
        set -l h (string match -r '^\s*\[(\w+)\]\s*$' -- $l)
        if set -q h[2]
            set cur $h[2]
            set -a out $l
            continue
        end
        if test "$cur" = "$sec"
            set -l c (string replace -r '(^|\s)#.*$' '' -- $l)
            set -l w (string split -n ' ' -- (string trim -- $c))
            if set -q w[1]; and test "$w[1]" = "$name"
                continue
            end
        end
        set -a out $l
    end
    printf '%s\n' $out >$file
end

# git_repos_conf FILE : the address of every [git] entry of packages.conf
function git_repos_conf
    for l in (pkg_lines $argv[1])
        set -l w (string split ' ' -- $l)
        test "$w[1]" = git; and echo $w[2]
    end
end

# git_dest URL : the folder a [git] entry is cloned to (~/Documents/<repo name>)
function git_dest
    echo $HOME/Documents/(basename (string trim -r -c / -- $argv[1]) .git)
end

# install_packages FILE : install everything in the file that exists for this system
function install_packages
    set -l file $argv[1]
    set -l pm (detect_pm)
    set -l native
    set -l fp
    set -l px
    set -l sn
    set -l gits
    set -l git_inst
    set -l to_install
    set -l skipped
    set -l failed
    set -l replaced

    for l in (pkg_lines $file)
        set -l w (string split ' ' -- $l)
        set -l toks
        set -q w[3]; and set toks $w[3..-1]
        # tied to a desktop environment that was not chosen: not meant for this machine
        set -l tags (de_tags $toks)
        if test (count $tags) -gt 0; and not de_selected $tags
            continue
        end
        if test "$w[1]" = flatpak
            set -a fp $w[2]
            continue
        end
        # snap, pipx and git are not native packages: collected here, installed below
        if test "$w[1]" = snap
            set -a sn $w[2]
            continue
        end
        if test "$w[1]" = pipx
            set -a px (pipx_entry_spec $w[2] $toks)
            continue
        end
        if test "$w[1]" = git
            set -a gits $w[2]
            set -a git_inst (entry_token install $toks; or echo -)
            continue
        end
        set -l r (pkg_resolve $pm $w[2] $toks)
        if test -z "$r"
            set -a skipped $w[2]
        else
            set -a native $r
            for t in $toks
                string match -q -- 'replaces=*' $t
                and set -a replaced (string split -n , -- (string replace -- 'replaces=' '' $t))
            end
        end
    end

    if test (count $native) -gt 0
        if test "$pm" = none
            warn "no supported package manager (pacman, apt, dnf, zypper): native packages skipped"
        else
            # packages that must go first (replaces=), e.g. ones that conflict with a new one
            for r in $replaced
                if pm_installed $pm $r
                    info "removing $r (replaced by a package in the list)"
                    pm_remove $pm $r; or warn "could not remove $r"
                end
            end
            # pacman with paru: try everything in one go (AUR names are resolved by paru).
            # Everything else (apt, dnf, zypper, or pacman without paru): drop the names that do not
            # exist first, one bad name fails the whole install. Without paru only the official
            # repos count, so AUR packages are skipped and listed at the end.
            set -l todo $native
            if test "$pm" != pacman; or not type -q paru
                set todo
                for p in $native
                    if pm_has $pm $p
                        set -a todo $p
                    else if test "$pm" = pacman
                        set -a skipped "$p (AUR only, needs paru)"
                    else
                        set -a skipped "$p (not in $pm repos)"
                    end
                end
            end
            if test (count $todo) -gt 0
                info "installing "(count $todo)" packages with $pm"
                if not pm_install $pm $todo
                    warn "the batch failed, retrying package by package"
                    for p in $todo
                        pm_installed $pm $p; and continue
                        if pm_has $pm $p
                            pm_install $pm $p; or set -a failed $p
                        else
                            set -a skipped "$p (not found)"
                        end
                    end
                end
            end
        end
    end

    if test (count $fp) -gt 0
        if not type -q flatpak; and test "$pm" != none
            info "flatpak is not installed, installing it first"
            pm_install $pm flatpak
        end
        if type -q flatpak
            flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
            info "installing "(count $fp)" flatpak apps"
            if not flatpak install -y flathub $fp
                for a in $fp
                    flatpak install -y flathub $a; or set -a failed "$a (flatpak)"
                end
            end
        else
            set -a skipped $fp
        end
    end

    if test (count $sn) -gt 0
        if type -q snap
            info "installing "(count $sn)" snap packages"
            for a in $sn
                pm_installed snap $a; or sudo snap install $a; or set -a failed "$a (snap)"
            end
        else
            warn "snap is not installed (add snapd to [native], then enable snapd.socket), snap packages skipped: $sn"
        end
    end

    if test (count $px) -gt 0
        if type -q pipx
            info "installing "(count $px)" pipx apps"
            for a in $px
                pipx_installed $a; and continue
                # an app of the same name from another source (PyPI spotdl vs your fork) is replaced
                pipx install $a; or pipx install --force $a; or set -a failed "$a (pipx)"
            end
            pipx_forget
        else
            warn "pipx is not installed (add python-pipx to [native]), pipx apps skipped: $px"
        end
    end

    if test (count $gits) -gt 0
        if type -q git
            mkdir -p $HOME/Documents
            for i in (seq (count $gits))
                set -l u $gits[$i]
                set -l d (git_dest $u)
                if test -d $d/.git
                    continue
                end
                info "cloning $u"
                if git clone $u $d
                    # a repo you installed with its own script on the old machine: offer to run it again
                    test "$git_inst[$i]" != -; and set -a to_install "$d|$git_inst[$i]"
                else
                    set -a failed "$u (git)"
                end
            end
        else
            warn "git is not installed (add git to [native]), repos skipped: $gits"
        end
    end

    # install scripts of the repos that were just cloned (recorded with install=PATH)
    for item in $to_install
        set -l parts (string split '|' -- $item)
        set -l repo (basename $parts[1])
        if not test -f $parts[1]/$parts[2]
            warn "$repo: the recorded install script $parts[2] is not in the clone any more"
            continue
        end
        if isatty stdin
            echo
            read -P "$repo was installed with its $parts[2] on your old machine. Run it now? [y/N]: " -l ans
            if string match -qri '^y' -- (string trim -- "$ans")
                git_run_install $parts[1] $parts[2]; or set -a failed "$repo ($parts[2])"
            else
                info "skipped. To install it later: cd $parts[1]; and run $parts[2]"
            end
        else
            warn "$repo: run its install script yourself: cd $parts[1]; and run $parts[2]"
        end
    end

    test (count $skipped) -gt 0; and warn "no package for this system, skipped: $skipped"
    test (count $failed) -gt 0; and warn "failed to install: $failed"
    return 0
end

# parse_selection INPUT COUNT : "all", "3", "1-4" or "1,4,6-8" -> sorted unique numbers, one per line
function parse_selection
    set -l input (string lower (string replace -a ' ' '' -- $argv[1]))
    set -l count $argv[2]
    set -l out

    if test "$input" = all -o "$input" = a
        seq $count
        return 0
    end

    for tok in (string split , -- $input)
        test -z "$tok"; and continue
        set -l lo
        set -l hi
        if string match -qr '^\d+$' -- $tok
            set lo $tok
            set hi $tok
        else if string match -qr '^\d+-\d+$' -- $tok
            set lo (string split - -- $tok)[1]
            set hi (string split - -- $tok)[2]
        else
            echo "  not understood: '$tok'" >&2
            return 1
        end
        if test $lo -lt 1 -o $lo -gt $hi -o $hi -gt $count
            echo "  out of range: '$tok' (valid: 1-$count)" >&2
            return 1
        end
        set out $out (seq $lo $hi)
    end

    test (count $out) -gt 0; or return 1
    printf '%s\n' $out | sort -nu
end

# ================================================================ tracked.conf
# One entry per line:   live path | place in the notes | options
# Options (space separated): exclude=PATTERN (repeatable)  private  optional  exec  de=NAME[,NAME]  name=ALIAS
# The place is Backup/<path> or Desktop Environment/<DE>/<path> (see "layout of the notes" above).

# tracked_list CONF : prints  live<TAB>name<TAB>options  per entry (~ is expanded)
function tracked_list
    set -l conf $argv[1]
    test -f $conf; or return 0
    for l in (cat $conf)
        set l (string replace -r '(^|\s)#.*$' '' -- $l)
        set l (string trim -- $l)
        test -n "$l"; or continue
        set -l f (string split '|' -- $l)
        test (count $f) -ge 2; or continue
        set -l live (string trim -- $f[1])
        set -l name (string trim -- $f[2])
        set -l opts
        set -q f[3]; and set opts (string trim -- $f[3..-1])
        set live (string replace -r -- '^~' "$HOME" $live)
        printf '%s\t%s\t%s\n' $live $name "$opts"
    end
end

# tracked_name_ok NAME : is it a valid place in the notes? Only Backup/<path>, System/<path> and
# Desktop Environment/<DE>/<path> are, and never with .. in them. A desktop's pre.fish and
# post.fish are its setup hooks, so they cannot be the copy of a tracked file.
function tracked_name_ok
    set -l n $argv[1]
    test -n "$n"; or return 1
    string match -q -- '/*' $n; and return 1
    string match -qr -- '(^|/)\.\.?(/|$)' $n; and return 1
    set -l parts (string split / -- $n)
    if test "$parts[1]" = "$layout_backup"
        test (count $parts) -ge 2; or return 1
        test -n "$parts[2]"; or return 1
        return 0
    else if test "$parts[1]" = "$layout_system"
        # System/<absolute path without the leading />, e.g. System/usr/local/bin/rotate-sddm-bg.sh
        test (count $parts) -ge 2; or return 1
        test -n "$parts[2]"; or return 1
        return 0
    else if test "$parts[1]" = "$layout_de"
        test (count $parts) -ge 3; or return 1
        test -n "$parts[2]" -a -n "$parts[3]"; or return 1
        if test (count $parts) -eq 3; and contains -- $parts[3] pre.fish post.fish
            return 1
        end
        return 0
    end
    return 1
end

# tracked_header : the comment block at the top of tracked.conf
function tracked_header
    printf '%s\n' \
        '# tracked.conf - the folders and files that sync-notes.sh copies into these notes and' \
        '# initual-setup.sh puts back on a new machine.' \
        '#' \
        '# One entry per line:   live path | place in the notes | options' \
        '#   live path   where it lives on the machine (~ = your home folder). Outside the home folder' \
        '#               (/etc, /usr/local/bin...) is allowed too: read and restored with sudo' \
        '#   place       Backup/<path>                     always restored' \
        '#               Desktop Environment/<DE>/<path>   restored only when that desktop is chosen' \
        '#                                                 in initual-setup.sh' \
        '#               System/<path>                     a path outside the home folder, restored with sudo' \
        '#                                                 (System/usr/local/bin/x.sh is /usr/local/bin/x.sh)' \
        '#               <path> is the live path without ~/, so the notes mirror your home folder' \
        '#               (~/Downloads/clean.py is Backup/Downloads/clean.py)' \
        '#   options     exclude=PATTERN  leave matching files out (repeat it for more patterns)' \
        '#               private          restrict permissions (chmod go-rwx) after copying' \
        '#               optional         no warning when the live path does not exist' \
        '#               exec             make the .sh and .py files executable after restoring' \
        '#               enable           System/ only: systemctl enable the restored .service/.timer' \
        '#               rehome           System/ only: rewrite /home/OLDUSER to this machine\'s home folder' \
        '#               de=NAME[,NAME]   for a Backup/ entry that only some desktops use (rofi, ...): it stays' \
        '#                                in Backup/, but is restored only when one of those desktops is' \
        '#                                chosen (set it with sync-notes.sh dir uses)' \
        '#               name=ALIAS       a name of your own, shown in the NAME column of the lists' \
        '#                                (any text: spaces are written as %20; set it with sync-notes.sh dir rename)' \
        '#' \
        '# Desktop environments: the desktops offered by initual-setup.sh are the folders inside' \
        '# "Desktop Environment/" in the notes. Put pre.fish (runs before the configs are restored)' \
        '# and post.fish (runs after) in a desktop folder for its own setup steps.' \
        '#' \
        '# Add or remove entries with additional-scripts/sync-notes.sh (menu option 4), or edit this' \
        '# file by hand.'
end

# tracked_unsafe PATH NOTES : prints the reason and returns 0 when PATH must not be tracked
function tracked_unsafe
    set -l p $argv[1]
    set -l n $argv[2]
    if test "$p" = "$HOME" -o "$p" = /
        echo "that is your whole home folder"
        return 0
    end
    if not string match -q -- "$HOME/*" $p
        # not in the home folder: a system file (needs sudo to restore), allowed with a few exceptions
        sys_blocked $p $n
        return $status
    end
    for d in Documents Downloads Pictures Music Videos Desktop Public Templates .config .local .local/share .cache .ssh .gnupg
        if test "$p" = "$HOME/$d"
            echo "$p is a whole system folder, pick something inside it"
            return 0
        end
    end
    if test "$p" = "$n"; or string match -q -- "$p/*" "$n/"; or string match -q -- "$n/*" $p
        echo "that contains or sits inside the notes folder itself"
        return 0
    end
    return 1
end


# sys_blocked PATH NOTES : prints the reason and returns 0 when PATH must never be tracked as a system file
# (a system folder as a whole, someone else's home, a file that would break the machine if restored).
function sys_blocked
    set -l p (string trim -r -c / -- $argv[1])
    set -l n $argv[2]
    test -n "$p"; or set p /
    set -l roots / /bin /boot /dev /etc /home /lib /lib32 /lib64 /mnt /opt /proc /root /run /sbin /srv /sys /tmp \
        /usr /var /usr/bin /usr/sbin /usr/lib /usr/lib64 /usr/local /usr/local/bin /usr/local/lib /usr/share \
        /var/lib /var/log /var/cache /etc/systemd /etc/systemd/system /etc/default /etc/ssh /etc/pacman.d
    if contains -- $p $roots
        echo "$p is a whole system folder, pick something inside it"
        return 0
    end
    for d in /proc /sys /dev /run /tmp /.snapshots /boot
        if test "$p" = $d; or string match -q -- "$d/*" $p
            echo "$p is not something to back up (system runtime / snapshot / boot files)"
            return 0
        end
    end
    if string match -q -- '/home/*' $p; or string match -q -- '/root/*' $p
        echo "that is inside a home folder: only your own home folder ($HOME) is handled as a normal entry"
        return 0
    end
    if contains -- $p /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/sudoers /etc/fstab /etc/crypttab /etc/machine-id /etc/hostname
        echo "$p would break a different machine if it were restored there"
        return 0
    end
    if test -n "$n"
        if test "$p" = "$n"; or string match -q -- "$p/*" "$n/"; or string match -q -- "$n/*" $p
            echo "that contains or sits inside the notes folder itself"
            return 0
        end
    end
    return 1
end

# sys_live_for_name NAME : the absolute path a System/... place stands for (System/etc/x -> /etc/x)
function sys_live_for_name
    echo "/"(string replace -- "$layout_system/" "" $argv[1])
end

# tracked_remove CONF NAME : delete the entry with that notes name, keep comments
function tracked_remove
    set -l conf $argv[1]
    set -l name $argv[2]
    set -l out
    for l in (cat $conf)
        set -l c (string replace -r '(^|\s)#.*$' '' -- $l)
        set -l f (string split '|' -- $c)
        if set -q f[2]; and test (string trim -- $f[2]) = "$name"
            continue
        end
        set -a out $l
    end
    printf '%s\n' $out >$conf
end

# tracked_update CONF NAME NEWNAME [DESKTOP...] : give the entry whose place is NAME the place NEWNAME and
# set its de= option to the desktops (none = no de= option). Its other options stay.
function tracked_update
    set -l conf $argv[1]
    set -l name $argv[2]
    set -l newname $argv[3]
    set -l des
    set -q argv[4]; and set des $argv[4..-1]
    set -l out
    for l in (cat $conf)
        set -l c (string replace -r '(^|\s)#.*$' '' -- $l)
        set -l f (string split '|' -- $c)
        if set -q f[2]; and test (string trim -- $f[2]) = "$name"
            set -l live (string trim -- $f[1])
            set -l opts
            if set -q f[3]
                for o in (string split -n ' ' -- (string trim -- $f[3]))
                    string match -q -- 'de=*' $o; or set -a opts $o
                end
            end
            test (count $des) -gt 0; and set -a opts "de="(string join ',' -- $des)
            set -l row "$live | $newname"
            test (count $opts) -gt 0; and set row "$row | "(string join ' ' -- $opts)
            set -a out $row
            continue
        end
        set -a out $l
    end
    printf '%s\n' $out >$conf
end

# alias_encode TEXT / alias_decode TEXT : a name of your own may hold any text, but tracked.conf
# separates options by spaces and lines by | and #, so those (and %) are written as %20 %7C %23 %25
# in the file and turned back when shown.
function alias_encode
    string replace -a '%' '%25' -- $argv[1] | string replace -a ' ' '%20' | string replace -a '|' '%7C' | string replace -a '#' '%23'
end

function alias_decode
    string replace -a '%20' ' ' -- $argv[1] | string replace -a '%7C' '|' | string replace -a '%23' '#' | string replace -a '%25' '%'
end

# tracked_set_alias CONF PLACE ALIAS : give the entry saved at PLACE the name ALIAS (name=ALIAS option,
# shown in the NAME column of the lists). An empty ALIAS takes the name away. Its other options stay.
# Status 1 when there is no entry at that place.
function tracked_set_alias
    set -l conf $argv[1]
    set -l place $argv[2]
    set -l nick $argv[3]
    set -l out
    set -l found 1
    for l in (cat $conf)
        set -l c (string replace -r '(^|\s)#.*$' '' -- $l)
        set -l f (string split '|' -- $c)
        if set -q f[2]; and test (string trim -- $f[2]) = "$place"
            set -l live (string trim -- $f[1])
            set -l opts
            if set -q f[3]
                for o in (string split -n ' ' -- (string trim -- $f[3]))
                    string match -q -- 'name=*' $o; or set -a opts $o
                end
            end
            if test -n "$nick"
                set -l enc (alias_encode "$nick")
                set -a opts "name=$enc"
            end
            set -l row "$live | $place"
            test (count $opts) -gt 0; and set row "$row | "(string join ' ' -- $opts)
            set -a out $row
            set found 0
            continue
        end
        set -a out $l
    end
    test $found -eq 0; or return 1
    printf '%s\n' $out >$conf
end
