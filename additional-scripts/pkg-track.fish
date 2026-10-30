#!/usr/bin/env fish
# pkg-track.fish - keep packages.conf in step with what you install and remove by hand.
#
# How it works: it remembers which packages were explicitly installed the last time it looked
# (a "baseline", stored outside the notes in ~/.local/state/os-migrate-notes/). Every time you
# use the package manager, the new explicit list is compared with the baseline:
#   - a package that is new in the list          -> added to packages.conf
#   - a package that was listed and is now gone  -> removed from packages.conf
# Packages that came in only as dependencies are never in the explicit list, so they are
# ignored, and so is everything that was already installed when the baseline was taken.
# System updates change nothing, because they do not change the explicit list.
#
# Usage:
#   ./pkg-track.fish install     (needs sudo) take the baseline and set up the automatic triggers:
#                                  - a pacman hook   -> runs after every pacman / paru transaction
#                                  - a flatpak watcher (user systemd path unit)
#                                  - a pipx watcher (user systemd path unit, when pipx is installed)
#                                  - a snap watcher (user systemd path unit, when snap is installed)
#                                  - a git watcher (new clones in ~/Documents)
#   ./pkg-track.fish uninstall   (needs sudo) remove the triggers (packages.conf is left as it is)
#   ./pkg-track.fish init        take a new baseline now, without touching packages.conf
#   ./pkg-track.fish update      compare now (the triggers run this); --force allows a large removal
#   ./pkg-track.fish status      show the baseline, the triggers and the last changes
#   ./pkg-track.fish log         show the last 40 log lines
#
# Names listed in additional-scripts/pkg-ignore.conf are never added automatically (one name or
# pattern per line, e.g. gtk4 or lib32-*). Created on the first init.
#
# Backup: after a change, packages.conf is committed and pushed on its own (see auto_backup).
# The hourly sync-notes.sh timer backs it up as well, so a failed push is only a delay.
#
# Layout: lives in <notes>/additional-scripts/ next to lib.fish and packages.conf.
#
# Covered: pacman (any front end: paru, yay, pamac... they all call pacman), apt, dnf, zypper,
# flatpak, snap (snap list, minus runtimes and base snaps), pipx and git. What counts as "installed by you":
#   pacman  pacman -Qqe                 apt    apt-mark showmanual
#   dnf     dnf repoquery --userinstalled      zypper  rpm -qa minus /var/lib/zypp/AutoInstalled
# pipx apps are tracked by what "pipx install" was given (pipx list --json, package_or_url), so an app
# that is not on PyPI (a git address, a path) is tracked too, as that address. With a terminal you are
# asked for a name for it; without one, name it later with: sync-notes.sh pkg rename
# git: a clone made directly in ~/Documents (folder named like the repo) is added to the [git] list.
# A clone that disappears is NEVER removed from the list; every other kind is removed when uninstalled.
# Triggers: pacman = a pacman hook, apt = an apt hook (DPkg::Post-Invoke), dnf and zypper = a user
# systemd path unit on the package manager's history file, flatpak = a path unit on its exports,
# pipx = path units on its venvs and bin folders, snap = on /var/lib/snapd/snaps, git = on ~/Documents.

set here (realpath (dirname (status filename)))
if test (basename $here) = additional-scripts
    set notes (dirname $here)
else
    set notes $here
end
set extras $notes/additional-scripts
set pkgfile $extras/packages.conf
set ignorefile $extras/pkg-ignore.conf
set self (realpath (status filename))

# ---- edit these ----
set auto_backup 1      # 1 = commit and push packages.conf after a change
set max_removed 15     # a single run never removes more entries than this (a broken pacman
                       # query would otherwise look like "everything was uninstalled")
# --------------------

# comm needs both lists sorted the same way
set -gx LC_ALL C

set state $HOME/.local/state/os-migrate-notes
set logfile $state/pkg-track.log
mkdir -p $state

function info;  set_color green;  echo "==> $argv"; set_color normal; end
function warn;  set_color yellow; echo "!!  $argv"; set_color normal; end

# say TEXT : always goes to the log, and to the screen when run by hand
function say
    echo (date '+%F %T')" $argv" >> $logfile
    isatty stdout; and echo "$argv"
    return 0
end

if not test -f $extras/lib.fish
    warn "missing $extras/lib.fish (it belongs next to this script)"
    exit 1
end
source $extras/lib.fish
set pm (detect_pm)
set -q PKG_TRACK_PM; and set pm $PKG_TRACK_PM     # testing only: pretend to be another package manager

# ================================================================ lists
# explicitly installed native packages, sorted. Fails when the query fails or is empty.
function now_native
    set -l raw
    switch $pm
        case pacman
            set raw (pacman -Qqe 2>/dev/null); or return 1
        case apt
            set raw (apt-mark showmanual 2>/dev/null); or return 1
        case dnf
            set raw (dnf -q repoquery --userinstalled --qf '%{name}\n' 2>/dev/null); or return 1
        case zypper
            # zypper has no "installed by the user" query: everything minus what it marked automatic
            test -f /var/lib/zypp/AutoInstalled; or return 1
            set -l all (rpm -qa --qf '%{NAME}\n' 2>/dev/null); or return 1
            set raw (printf '%s\n' $all | sort -u | comm -23 - (sort -u /var/lib/zypp/AutoInstalled | psub))
        case '*'
            return 1
    end
    set -l clean
    for n in $raw
        set n (string trim -- $n)
        test -n "$n"; or continue
        test "$n" = gpg-pubkey; and continue
        set -a clean $n
    end
    test (count $clean) -gt 0; or return 1
    printf '%s\n' $clean | sort -u
end

# is_installed NAME : is the native package installed right now?
function is_installed
    switch $pm
        case pacman
            pacman -Qq $argv[1] >/dev/null 2>&1
        case apt
            # "ii" = installed; a removed package whose config files are left ("rc") does not count
            set -l st (dpkg-query -W -f='${db:Status-Abbrev}' $argv[1] 2>/dev/null)
            string match -q -- 'ii*' "$st"
        case dnf zypper
            rpm -q $argv[1] >/dev/null 2>&1
        case '*'
            return 1
    end
end

# flatpak apps, sorted (nothing when flatpak is missing)
function now_flatpak
    type -q flatpak; or return 0
    set -l raw (flatpak list --app --columns=application 2>/dev/null)
    test (count $raw) -gt 0; and printf '%s\n' $raw | sort -u
    return 0
end

# pipx_wait_idle : a pipx install in progress has its folder in venvs/ before it is finished. Wait
# (up to 2 minutes) while a folder younger than 10 minutes still has no pipx_metadata.json.
function pipx_wait_idle
    set -l dirs (pipx_venvs_dirs)
    for i in (seq 60)
        set -l busy 0
        for d in $dirs
            for v in (find $d -mindepth 1 -maxdepth 1 -type d -mmin -10 2>/dev/null)
                test -f $v/pipx_metadata.json; or set busy 1
            end
        end
        test $busy -eq 0; and return 0
        sleep 2
    end
end

# pipx apps by their SPEC (what "pipx install" got: a PyPI name or a git address), sorted.
# Status 1 when pipx is there but its list cannot be read (nothing is then compared).
function now_pipx
    type -q pipx; or return 0
    pipx_wait_idle
    pipx_forget
    set -l s (pipx_specs); or return 1
    test (count $s) -gt 0; and printf '%s\n' $s | sort -u
    return 0
end

# git clones in ~/Documents (see git_repos in lib.fish), sorted. Only ever added to packages.conf.
function now_git
    type -q git; or return 0
    git_repos
    return 0
end

# pipx_venvs_dirs / pipx_bin_dirs : where pipx keeps its apps and puts their commands
function pipx_venvs_dirs
    set -l out
    type -q pipx; and set -a out (pipx environment --value PIPX_LOCAL_VENVS 2>/dev/null)
    set -q PIPX_HOME; and set -a out $PIPX_HOME/venvs
    set -a out $HOME/.local/share/pipx/venvs $HOME/.local/pipx/venvs
    printf '%s\n' $out | awk 'NF && !seen[$0]++'
end
function pipx_bin_dirs
    set -l out
    type -q pipx; and set -a out (pipx environment --value PIPX_BIN_DIR 2>/dev/null)
    set -q PIPX_BIN_DIR; and set -a out $PIPX_BIN_DIR
    set -a out $HOME/.local/bin
    printf '%s\n' $out | awk 'NF && !seen[$0]++'
end

# write_list FILE ITEMS... : one item per line, sorted, an empty file when there are none
function write_list
    set -l f $argv[1]
    set -e argv[1]
    if test (count $argv) -gt 0
        printf '%s\n' $argv | sort -u >$f
    else
        : >$f
    end
end

# conf_name_for SECTION NAME : the name packages.conf uses for this installed package, or nothing
function conf_name_for
    set -l sec $argv[1]
    set -l want $argv[2]
    for l in (pkg_lines $pkgfile)
        set -l w (string split ' ' -- $l)
        test "$w[1]" = "$sec"; or continue
        if test $sec = pipx
            # the line may carry a name of your own (NAME src=SPEC): compare the SPEC and the name
            set -l ptoks
            set -q w[3]; and set ptoks $w[3..-1]
            if test "$w[2]" = "$want" -o (pipx_entry_spec $w[2] $ptoks) = "$want"
                echo $w[2]
                return 0
            end
            continue
        end
        if contains -- $sec flatpak snap git
            if test "$w[2]" = "$want"
                echo $w[2]
                return 0
            end
            continue
        end
        set -l toks
        set -q w[3]; and set toks $w[3..-1]
        set -l r (pkg_resolve $pm $w[2] $toks)
        if test "$r" = "$want"
            echo $w[2]
            return 0
        end
    end
    return 1
end

# is_ignored NAME : listed in pkg-ignore.conf?
function is_ignored
    test -f $ignorefile; or return 1
    for l in (cat $ignorefile)
        set l (string replace -r '(^|\s)#.*$' '' -- $l)
        set l (string trim -- $l)
        test -n "$l"; or continue
        string match -q -- $l $argv[1]; and return 0
    end
    return 1
end

# ================================================================ baseline
function make_ignore_file
    test -f $ignorefile; and return 0
    printf '%s\n' \
        '# pkg-ignore.conf - packages that pkg-track.fish never adds to packages.conf by itself.' \
        '# One name or pattern per line, for example:  gtk4   or   lib32-*' >$ignorefile
end

function do_init
    make_ignore_file
    touch $state/format-2
    set -l ok 0
    if test $pm != none
        set -l n (now_native); or begin
            warn "could not read the installed packages, no baseline taken"
            return 1
        end
        write_list $state/native.txt $n
        set ok 1
    else
        warn "no supported package manager found for native packages"
    end
    if type -q flatpak
        write_list $state/flatpak.txt (now_flatpak)
        set ok 1
    end
    if type -q pipx
        set -l px (now_pipx); and write_list $state/pipx.txt $px; and set ok 1
    end
    if type -q git
        write_list $state/git.txt (now_git)
        set ok 1
    end
    if type -q snap
        write_list $state/snap.txt (now_snap)
        set ok 1
    end
    test $ok -eq 1; or return 1
    say "baseline recorded: "(count (cat $state/native.txt 2>/dev/null))" native, "(count (cat $state/flatpak.txt 2>/dev/null))" flatpak, "(count (cat $state/pipx.txt 2>/dev/null))" pipx, "(count (cat $state/snap.txt 2>/dev/null))" snap, "(count (cat $state/git.txt 2>/dev/null))" git repos (packages.conf not changed)"
end

# ================================================================ compare
# reconcile SECTION NOWFILE PREVFILE FORCE : apply the difference to packages.conf.
# Appends to the globals added_all / removed_all. Status 1 = refused (nothing written).
function reconcile
    set -l sec $argv[1]
    set -l nowf $argv[2]
    set -l prevf $argv[3]
    set -l force $argv[4]

    set -l added (comm -13 $prevf $nowf)
    set -l removed (comm -23 $prevf $nowf)

    set -l foreign
    test $sec = native; and test $pm = pacman; and set foreign (pacman -Qqm 2>/dev/null)

    # removed: only entries that are in packages.conf, and only if really gone from the system
    set -l drop
    for n in $removed
        switch $sec
            case native
                is_installed $n; and continue                # still installed, only its reason changed
            case pipx
                pm_installed pipx $n; and continue
            case snap
                pm_installed snap $n; and continue
            case '*'
                flatpak info $n >/dev/null 2>&1; and continue
        end
        set -l cn (conf_name_for $sec $n)
        test -n "$cn"; and set -a drop $cn
    end
    if test (count $drop) -gt $max_removed; and test $force -eq 0
        say "refused: $sec would lose "(count $drop)" entries (limit $max_removed). Check with 'pacman -Qqe', then run: pkg-track.fish update --force"
        return 1
    end

    for cn in $drop
        conf_remove $pkgfile $sec $cn
        set -ga removed_all "-$cn"
    end

    for n in $added
        is_ignored $n; and continue
        set -l cn (conf_name_for $sec $n)
        test -n "$cn"; and continue                          # already listed (the manager, or by hand)
        set -l line $n
        if test $sec = native; and contains -- $n $foreign
            set line "$n arch"                               # AUR package
        else if test $sec = native; and test $pm != pacman
            set line "$n only=$pm"                           # same rule as the manager in sync-notes.sh: other distros may name it differently
        end
        conf_add $pkgfile $sec $line
        set -ga added_all "+$n"
        if test $sec = pipx; and not pipx_is_pypi $n
            if isatty stdin
                pipx_ask_name $pkgfile $n
            else
                say "pipx: $n is not on PyPI, so the list has its address. Give it a name with: sync-notes.sh pkg rename"
            end
        end
    end

    cp -f $nowf $prevf
end

# backup_pkgfile MESSAGE : commit and push packages.conf on its own
function backup_pkgfile
    test $auto_backup -eq 1; or return 0
    type -q git; or return 0
    test -d $notes/.git; or return 0
    git -C $notes remote get-url origin >/dev/null 2>&1; or return 0

    set -l rel (string replace -- "$notes/" '' $pkgfile)
    git -C $notes add -- $rel 2>/dev/null
    if git -C $notes rev-parse --verify -q HEAD >/dev/null 2>&1
        git -C $notes diff --cached --quiet HEAD -- $rel; and return 0
    end
    if not git -C $notes commit -q -m "$argv[1]" -- $rel 2>/dev/null
        say "backup: git commit failed (are user.name and user.email set?)"
        return 1
    end

    set -l branch (git -C $notes rev-parse --abbrev-ref HEAD)
    set -lx GIT_SSH_COMMAND "ssh -o BatchMode=yes -o ConnectTimeout=15"
    set -lx GIT_TERMINAL_PROMPT 0
    if timeout 60 git -C $notes push -q -u origin $branch 2>/dev/null
        say "backup: packages.conf pushed to origin/$branch"
    else
        say "backup: committed, push failed (the hourly sync-notes run will retry)"
    end
end

# baselines from an older version of this script stored pipx apps by pipx's own name instead of what
# was installed. Comparing those with the new ones would be wrong, so they are taken again (nothing
# is added or removed that one time).
function check_baseline_format
    test -f $state/format-2; and return 0
    rm -f $state/pipx.txt $state/git.txt
    touch $state/format-2
end

function do_update
    check_baseline_format
    set -l force 0
    contains -- --force $argv; and set force 1

    test -f $pkgfile; or begin
        say "packages.conf not found: $pkgfile"
        return 1
    end

    set -g added_all
    set -g removed_all
    set -l failed 0

    if test $pm != none
        if not test -f $state/native.txt
            say "no baseline yet, taking one now (nothing is added this time)"
            do_init; return $status
        end
        set -l now (now_native); or begin
            say "could not read the installed packages, nothing changed"
            return 1
        end
        write_list $state/native.now $now
        reconcile native $state/native.now $state/native.txt $force; or set failed 1
    end

    if type -q flatpak
        if not test -f $state/flatpak.txt
            write_list $state/flatpak.txt (now_flatpak)
        else
            write_list $state/flatpak.now (now_flatpak)
            reconcile flatpak $state/flatpak.now $state/flatpak.txt $force; or set failed 1
        end
    end

    if type -q pipx
        if not test -f $state/pipx.txt
            set -l px (now_pipx); and write_list $state/pipx.txt $px
        else
            set -l px (now_pipx)
            set -l px_status $status
            if test $px_status -ne 0
                say "could not read the pipx apps, pipx not compared"
                set failed 1
            else
                write_list $state/pipx.now $px
                reconcile pipx $state/pipx.now $state/pipx.txt $force; or set failed 1
            end
        end
    end

    # git clones: only new ones are added. A clone you delete stays in packages.conf (you remove
    # those by hand, or with sync-notes.sh pkg remove).
    if type -q git
        if not test -f $state/git.txt
            write_list $state/git.txt (now_git)
        else
            for u in (comm -13 $state/git.txt (now_git | sort -u | psub))
                is_ignored $u; and continue
                set -l have (conf_name_for git $u)
                test -n "$have"; and continue
                conf_add $pkgfile git $u
                set -ga added_all "+git:"(basename (string trim -r -c / -- $u) .git)
                # it has an install.sh / setup.fish: with a terminal ask which one was run, else leave a tip
                if isatty stdin
                    git_ask_install $pkgfile $u
                else if test (count (git_install_candidates (git_dest $u))) -gt 0
                    say "tip: "(basename (git_dest $u))" has an install script; record it with: sync-notes.sh pkg script "(basename (git_dest $u))
                end
            end
            write_list $state/git.txt (now_git)
        end
    end

    if type -q snap
        if not test -f $state/snap.txt
            write_list $state/snap.txt (now_snap)
        else
            write_list $state/snap.now (now_snap)
            reconcile snap $state/snap.now $state/snap.txt $force; or set failed 1
        end
    end

    if test (count $added_all) -gt 0 -o (count $removed_all) -gt 0
        set -l summary (string join ' ' -- "packages:" $added_all $removed_all)
        say $summary
        backup_pkgfile (string trim -- $summary)
    end
    return $failed
end

# ================================================================ triggers
set hook_script /usr/local/bin/pkg-track-hook
set pacman_hook /etc/pacman.d/hooks/zz-pkg-track.hook
set apt_hook /etc/apt/apt.conf.d/99-pkg-track
set unit_dir $HOME/.config/systemd/user

# the history file each package manager appends to once per transaction (dnf, zypper)
function history_files
    switch $pm
        case dnf
            for f in /var/lib/dnf/history.sqlite /usr/lib/sysimage/libdnf5/transaction_history.sqlite /var/lib/dnf/history
                test -e $f; and echo $f
            end
        case zypper
            test -e /var/log/zypp/history; and echo /var/log/zypp/history
    end
end

# the root-owned wrapper only starts this script as you, so a package manager run never executes
# anything you could edit as root. setsid -f: the package manager does not wait for it.
function install_wrapper
    set -l user (id -un)
    sudo mkdir -p (dirname $hook_script)
    printf '%s\n' \
        '#!/bin/sh' \
        '# installed by pkg-track.fish: update packages.conf after a package manager run' \
        "setsid -f sh -c \"sleep 2; runuser -u $user -- env HOME='$HOME' fish '$self' update\" >/dev/null 2>&1 </dev/null" \
        'exit 0' | sudo tee $hook_script >/dev/null
    sudo chmod 755 $hook_script
end

# one user service, started by the path units
function write_service
    mkdir -p $unit_dir
    printf '%s\n' \
        '[Unit]' 'Description=Update packages.conf (pkg-track)' 'StartLimitIntervalSec=0' \
        '' \
        '[Service]' 'Type=oneshot' \
        "ExecStart=/bin/sh -c 'sleep 3; exec fish \"$self\" update'" >$unit_dir/pkg-track.service
end

function do_install
    test $pm != none; or begin
        warn "no supported package manager found"
        return 1
    end
    do_init; or return 1
    set -l units

    switch $pm
        case pacman
            install_wrapper
            sudo mkdir -p /etc/pacman.d/hooks
            printf '%s\n' \
                '[Trigger]' 'Operation = Install' 'Operation = Remove' 'Type = Package' 'Target = *' \
                '' \
                '[Action]' 'Description = Updating packages.conf (pkg-track)' 'When = PostTransaction' \
                "Exec = $hook_script" | sudo tee $pacman_hook >/dev/null
            info "pacman hook installed: $pacman_hook"
        case apt
            install_wrapper
            printf '%s\n' '// installed by pkg-track.fish' "DPkg::Post-Invoke { \"$hook_script\"; };" \
                | sudo tee $apt_hook >/dev/null
            info "apt hook installed: $apt_hook"
        case dnf zypper
            set -l hf (history_files)
            if test (count $hf) -eq 0
                warn "no $pm history file found to watch, so there is no automatic trigger. Run './pkg-track.fish update' by hand after installing."
            else
                write_service
                set -l body '[Unit]' "Description=Watch $pm for changes" '' '[Path]'
                for f in $hf
                    set -a body "PathChanged=$f"
                end
                set -a body 'Unit=pkg-track.service' '' '[Install]' 'WantedBy=default.target'
                printf '%s\n' $body >$unit_dir/pkg-track-native.path
                set -a units pkg-track-native.path
                info "$pm watcher written: watching $hf"
            end
    end

    if type -q flatpak
        write_service
        # the exports folder changes when an app finishes installing or is removed
        printf '%s\n' \
            '[Unit]' 'Description=Watch flatpak apps for changes' \
            '' \
            '[Path]' \
            'PathChanged=/var/lib/flatpak/exports/share/applications' \
            'PathChanged=%h/.local/share/flatpak/exports/share/applications' \
            'Unit=pkg-track.service' \
            '' \
            '[Install]' 'WantedBy=default.target' >$unit_dir/pkg-track-flatpak.path
        set -a units pkg-track-flatpak.path
    end

    if type -q pipx
        write_service
        # An app gets its folder in venvs/ when the install STARTS, but its command in the bin folder
        # only when it is DONE, so both are watched (update also waits for an install in progress).
        set -l body '[Unit]' 'Description=Watch pipx apps for changes' '' '[Path]'
        for d in (pipx_venvs_dirs) (pipx_bin_dirs)
            set -a body "PathChanged=$d"
        end
        set -a body 'Unit=pkg-track.service' '' '[Install]' 'WantedBy=default.target'
        printf '%s\n' $body >$unit_dir/pkg-track-pipx.path
        set -a units pkg-track-pipx.path
    end

    if type -q git
        write_service
        # a new clone shows up as a new folder in ~/Documents
        printf '%s\n' \
            '[Unit]' 'Description=Watch ~/Documents for new git clones' \
            '' \
            '[Path]' \
            "PathChanged=$HOME/Documents" \
            'Unit=pkg-track.service' \
            '' \
            '[Install]' 'WantedBy=default.target' >$unit_dir/pkg-track-git.path
        set -a units pkg-track-git.path
    end

    if type -q snap
        write_service
        # snapd keeps one .snap file per installed revision here; it changes on install and remove
        printf '%s\n' \
            '[Unit]' 'Description=Watch snap packages for changes' \
            '' \
            '[Path]' \
            'PathChanged=/var/lib/snapd/snaps' \
            'Unit=pkg-track.service' \
            '' \
            '[Install]' 'WantedBy=default.target' >$unit_dir/pkg-track-snap.path
        set -a units pkg-track-snap.path
    end

    if test (count $units) -gt 0
        systemctl --user daemon-reload
        systemctl --user enable --now $units
        info "enabled: $units"
    end
    info "done. Install or remove something with $pm, then check: ./pkg-track.fish log"
end

function do_uninstall
    sudo rm -f $pacman_hook $apt_hook $hook_script
    for u in pkg-track-native.path pkg-track-flatpak.path pkg-track-pipx.path pkg-track-snap.path pkg-track-git.path
        test -f $unit_dir/$u; and systemctl --user disable --now $u 2>/dev/null
        rm -f $unit_dir/$u
    end
    rm -f $unit_dir/pkg-track.service $unit_dir/pkg-track-flatpak.service
    systemctl --user daemon-reload 2>/dev/null
    info "triggers removed (packages.conf and the baseline were left as they are)"
end

function do_status
    echo "package manager:   $pm"
    echo "baseline folder:   $state"
    echo "native baseline:   "(count (cat $state/native.txt 2>/dev/null))" packages"
    echo "flatpak baseline:  "(count (cat $state/flatpak.txt 2>/dev/null))" apps"
    echo "pipx baseline:     "(count (cat $state/pipx.txt 2>/dev/null))" apps"
    echo "snap baseline:     "(count (cat $state/snap.txt 2>/dev/null))" packages"
    echo "git baseline:      "(count (cat $state/git.txt 2>/dev/null))" clones"
    switch $pm
        case pacman
            test -f $pacman_hook; and echo "pacman hook:       installed"; or echo "pacman hook:       NOT installed (run: install)"
        case apt
            test -f $apt_hook; and echo "apt hook:          installed"; or echo "apt hook:          NOT installed (run: install)"
        case dnf zypper
            if systemctl --user is-enabled --quiet pkg-track-native.path 2>/dev/null
                echo "$pm watcher:     enabled"
            else
                echo "$pm watcher:     not enabled (run: install)"
            end
    end
    if systemctl --user is-enabled --quiet pkg-track-flatpak.path 2>/dev/null
        echo "flatpak watcher:   enabled"
    else
        echo "flatpak watcher:   not enabled"
    end
    if systemctl --user is-enabled --quiet pkg-track-pipx.path 2>/dev/null
        echo "pipx watcher:      enabled"
    else
        echo "pipx watcher:      not enabled"
    end
    if systemctl --user is-enabled --quiet pkg-track-snap.path 2>/dev/null
        echo "snap watcher:      enabled"
    else
        echo "snap watcher:      not enabled"
    end
    if systemctl --user is-enabled --quiet pkg-track-git.path 2>/dev/null
        echo "git watcher:       enabled"
    else
        echo "git watcher:       not enabled"
    end
    echo "ignore list:       $ignorefile"
    echo
    echo "last changes:"
    test -f $logfile; and tail -n 8 $logfile; or echo "  (nothing logged yet)"
end

# ================================================================ main
# one run at a time: the pacman hook, the flatpak watcher and a run by hand share a lock
function with_lock
    if not set -q PKG_TRACK_LOCKED
        set -gx PKG_TRACK_LOCKED 1
        exec flock $state/lock fish $self $argv
    end
end

switch "$argv[1]"
    case install
        do_install
    case uninstall
        do_uninstall
    case init
        with_lock $argv
        do_init
    case update
        with_lock $argv
        do_update $argv[2..-1]
    case status
        do_status
    case log
        test -f $logfile; and tail -n 40 $logfile; or echo "nothing logged yet"
    case '*'
        sed -n '2,/^$/p' $self | string replace -r '^# ?' ''
        exit 1
end
