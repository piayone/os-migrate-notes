#!/usr/bin/env fish
# initual-setup.sh - initial setup from the os-migrate-notes repo
#
# Usage:
#   ./initual-setup.sh                 asks which desktop environment to set up (auto-detect, or
#                                      one of the backed-up desktops) and how deleted files
#                                      should be handled in the backup
#   ./initual-setup.sh NAME [NAME...]  use these desktop environments without asking (or: none)
#   ./initual-setup.sh --no-system     do not restore the System/ files (they need sudo)
#   ./initual-setup.sh --no-pkg-track  do not install the package tracker (pkg-track.fish)
#
# Desktop environments: nothing about a specific one is written in this script. The desktops
# you can pick are the folders inside "Desktop Environment/" in the notes (the folder name is
# the name of the desktop). Only the files of the desktops you pick are restored, the files in
# "Backup/" always are. Optional hooks live in the desktop's own folder:
#   Desktop Environment/NAME/pre.fish   runs before any config is copied (installing the desktop's
#                                       own packages, for recipes that depend on the distro, so they
#                                       can never overwrite your config)
#   Desktop Environment/NAME/post.fish  runs after the configs are restored (enabling a service,
#                                       manual steps)
#
# Works on Arch/CachyOS (pacman + paru), Debian/Ubuntu (apt), Fedora (dnf) and openSUSE
# (zypper); the package manager is detected. Arch-only parts (paru, asked first, packages marked "arch" in
# packages.conf) are skipped elsewhere, and packages a distro does not have are listed at the end.
#
# Order: questions -> packages + GRUB -> update -> copy config files (last, so
# the packages cannot overwrite your configs with their defaults) -> venvs for any
# requirements.txt (asked) -> enable the hourly sync-notes.sh
# timer (needs additional-scripts/sync-notes.sh in the notes).
#
# What gets installed:  additional-scripts/packages.conf  (edit with sync-notes.sh, menu option 4)
# What gets restored:   additional-scripts/tracked.conf   (edit with sync-notes.sh, menu option 4)
#                       notes made by an older version are moved to this layout first (sync-notes.sh --migrate)
#
# Shared things: rofi and the like stay in Backup/ and are not moved into one desktop. Which desktops
# use them is a de=NAME option on the tracked.conf entry; they are restored only when one of those
# desktops is chosen. Set it with: sync-notes.sh dir uses
#
# System files (outside your home folder: /usr/local/bin/x.sh, /etc/systemd/system/x.service, an SDDM
# theme...) are saved under System/ in the notes. They are put back with sudo, as root, after one
# question that lists them (without a terminal they are skipped unless sudo needs no password).
# Options on their tracked.conf line: enable (systemctl enable the unit), rehome (rewrite /home/OLDUSER
# and USERNAME="OLDUSER" to this machine's user), exec, private, de=
#
# Layout: this script sits in the notes root; mangohud-env.sh, usbguard.sh, sync-notes.sh,
# pkg-track.fish, lib.fish and the .conf files live in <notes>/additional-scripts/. Your own files
# are in <notes>/Backup/ (the same paths as in your home folder, e.g. Backup/.config/fish/config.fish)
# and <notes>/Desktop Environment/<DE>/.

set here (realpath (dirname (status filename)))
if test (basename $here) = additional-scripts
    set notes (dirname $here)
else
    set notes $here
end
set extras $notes/additional-scripts
set cfg $HOME/.config

function info;  set_color green;  echo "==> $argv"; set_color normal; end
function warn;  set_color yellow; echo "!!  $argv"; set_color normal; end

# shared helpers: package manager detection, packages.conf, tracked.conf
if not test -f $extras/lib.fish
    warn "missing $extras/lib.fish (it belongs next to the other scripts in additional-scripts/)"
    exit 1
end
source $extras/lib.fish
set pm (detect_pm)
info "package manager: $pm"

# notes made by an older version (folders at the top level, de=NAME tags): move them to the
# Backup / Desktop Environment layout first, the rest of this script expects it
set old_n 0
for line in (tracked_list $extras/tracked.conf)
    set p (string split \t -- $line)
    tracked_name_ok $p[2]; or set old_n (math $old_n + 1)
end

# place SRC DST : replace DST with a copy of SRC (preserving symlinks). No backups.
function place
    set src $argv[1]
    set dst $argv[2]
    if not test -e $src -o -L $src
        warn "missing, skipped: $src"
        return 1
    end
    if contains -- "$dst" "" / $HOME
        warn "refusing to replace $dst"
        return 1
    end
    # never wipe a folder that holds the notes themselves
    if test "$dst" = "$notes"; or string match -q -- "$dst/*" "$notes/"
        warn "refusing to replace $dst: it contains the notes folder"
        return 1
    end
    if test -e $dst -o -L $dst
        rm -rf $dst
    end
    mkdir -p (dirname $dst)
    cp -a $src $dst
    info "$src -> $dst"
end

# make every *.sh under the given dirs executable
function make_exec
    for d in $argv
        test -e $d; and find $d -type f -name '*.sh' -exec chmod +x {} +
    end
end

# make the .sh and .py files under PATH executable (PATH may be one file)
function make_exec_all
    if test -d $argv[1]
        find $argv[1] -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +
    else if test -f $argv[1]
        chmod +x $argv[1]
    end
end

# ---------------------------------------------------------------- args
set no_system 0
set no_pkg_track 0
set de_args
for a in $argv
    switch $a
        case --no-system
            set no_system 1
        case --no-pkg-track
            set no_pkg_track 1
        case '--*'
            warn "unknown option: $a"
        case '*'
            set -a de_args (string lower -- $a)
    end
end

# place_sys NAME OPTION... : put the System/ copy back at its absolute path, with sudo.
# NAME is the place in the notes (System/usr/local/bin/x.sh), the live path is "/" + the rest.
function place_sys
    set -l name $argv[1]
    set -e argv[1]
    set -l opts $argv
    set -l live (sys_live_for_name $name)
    set -l src $notes/$name
    if not test -e $src -o -L $src
        warn "missing, skipped: $src"
        return 1
    end
    set -l why (sys_blocked $live $notes)
    if test -n "$why"
        warn "refused, $why"
        return 1
    end
    # a staged copy: rehome rewrites that one, the notes stay as they are
    set -l stage (mktemp -d)
    cp -a $src $stage/item; or begin
        rm -rf $stage
        return 1
    end
    if contains -- rehome $opts
        set -l files $stage/item
        test -d $stage/item -a ! -L $stage/item; and set files (find $stage/item -type f)
        for f in $files
            test -f $f -a ! -L $f; or continue
            grep -qI . $f 2>/dev/null; or continue
            # every other home folder named in the file -> this one, and USERNAME="old" -> this user
            set -l olds (grep -oE '/home/[A-Za-z0-9._-]+' $f | string replace '/home/' '' | sort -u)
            set -l olds2 (grep -oE '^[[:space:]]*(export[[:space:]]+)?(USERNAME|USER_NAME|TARGET_USER|LOGIN_USER)=.*' $f | string replace -r '^.*=' '' | string trim -c "\"' " | sort -u)
            for o in $olds $olds2
                test -n "$o" -a "$o" != "$USER"; or continue
                string match -qr '^[A-Za-z0-9._-]+$' -- $o; or continue
                set -l q "[\"']?"
                set -l hp "s#/home/$o(/|\$|\"|'| )#$HOME\1#g"
                set -l up "s#^([[:space:]]*(export[[:space:]]+)?(USERNAME|USER_NAME|TARGET_USER|LOGIN_USER)=)$q$o$q#\1\"$USER\"#"
                sed -i -E "$hp; $up" $f
            end
        end
    end
    contains -- exec $opts; and make_exec_all $stage/item
    contains -- private $opts; and chmod -R go-rwx $stage/item
    if test -e $live -o -L $live
        sudo rm -rf $live
    end
    sudo mkdir -p (dirname $live); and sudo cp -a $stage/item $live; and sudo chown -R root:root $live
    or begin
        warn "could not restore $live"
        rm -rf $stage
        return 1
    end
    rm -rf $stage
    info "$src -> $live (sudo)"
    if contains -- enable $opts
        sudo systemctl daemon-reload
        set -l unit (basename $live)
        if sudo systemctl enable $unit
            info "enabled $unit"
        else
            warn "could not enable $unit"
        end
    end
end

# ================================================================
# 0. QUESTIONS (everything else runs without asking)
# ================================================================
set cfg_dir $HOME/.config/os-migrate-notes    # outside the notes: never synced or committed
set de_cfg (de_cfg_file)
set delete_cfg $cfg_dir/delete-mode

function save_choice   # save_choice FILE VALUE...
    set -l f $argv[1]
    set -e argv[1]
    mkdir -p (dirname $f); and chmod 700 (dirname $f)
    printf '%s\n' $argv >$f; and chmod 600 $f
end

# parse_des_reply REPLY KNOWN... : numbers and names -> desktop names (lower case), one per line.
# Only the desktops in KNOWN can be chosen; "n" or "none" means no desktop.
function parse_des_reply
    set -l reply $argv[1]
    set -e argv[1]
    set -l known $argv
    set -l known_lc (string lower -- $known)
    for t in (string split -n ' ' -- (string replace -a , ' ' -- (string lower -- $reply)))
        if string match -qr '^[0-9]+$' -- $t
            if test $t -ge 1 -a $t -le (count $known)
                string lower -- $known[$t]
            else
                warn "no number $t in the list, ignored" >&2
            end
        else if contains -- $t n none
            echo none
        else if contains -- $t $known_lc
            echo $t
        else
            warn "no backed-up desktop called '$t', ignored" >&2
        end
    end
end

# ---------------------------------------------------------------- desktop environment
# The desktops that can be set up are the folders in "Desktop Environment/" in the notes.
set known_des (de_dirs $notes)
set de_raw (string lower "$XDG_CURRENT_DESKTOP $DESKTOP_SESSION")
set detected
for d in $known_des
    set dl (string lower -- $d)
    string match -q -- "*$dl*" $de_raw; and set -a detected $d
end

# choose_des : numbered list of the backed-up desktops; sets the global $picked_des
function choose_des
    set -g picked_des
    echo
    for i in (seq (count $known_des))
        echo "  $i) $known_des[$i]"
    end
    echo "  n) none"
    read -P "Choose (numbers or names, e.g. '1 2'; Enter = none): " pick_reply
    set -g picked_des (parse_des_reply "$pick_reply" $known_des)
end

set chosen_des
if test (count $de_args) -gt 0
    set chosen_des $de_args
    for d in $de_args
        contains -- $d none; and continue
        de_dir_name $notes $d >/dev/null; or warn "no folder '$d' in $notes/$layout_de: only packages.conf entries can use it"
    end
else if test (count $known_des) -eq 0
    info "no desktop environment folders in $notes/$layout_de: nothing to choose"
    set chosen_des none
else if isatty stdin
    echo
    set_color --bold; echo "Which desktop environment do you want to set up?"; set_color normal
    echo "  Backed up desktops: "(string join ', ' $known_des)
    if test (count $detected) -gt 0
        echo "  1) Auto-detect   (this session looks like: "(string join ', ' $detected)")"
    else
        echo "  1) Auto-detect   (could not tell from this session: '"(string trim -- "$XDG_CURRENT_DESKTOP $DESKTOP_SESSION")"')"
    end
    echo "  2) Choose from the backed-up desktops"
    echo "  3) None          (only the files that are not tied to a desktop)"
    read -P "Choose [1-3, Enter = 1]: " how
    switch (string lower -- (string trim -- "$how"))
        case 3 n none
            set chosen_des none
        case 2
            choose_des
            set chosen_des $picked_des
        case '' 1
            if test (count $detected) -gt 0
                set chosen_des $detected
            else
                warn "no desktop detected, choose one from the list"
                choose_des
                set chosen_des $picked_des
            end
        case '*'
            warn "not a valid choice, choose from the list"
            choose_des
            set chosen_des $picked_des
    end
else
    # no terminal: detected desktop, else the saved choice
    set chosen_des $detected
    test (count $chosen_des) -eq 0; and set chosen_des (selected_des)
end
set uniq_des
for d in $chosen_des
    contains -- $d $uniq_des; or set -a uniq_des $d
end
test (count $uniq_des) -eq 0; and set uniq_des none
set chosen_des $uniq_des
save_choice $de_cfg $chosen_des
info "desktop environment(s): $chosen_des (saved in $de_cfg)"

# ---------------------------------------------------------------- backup / delete mode
# How a file you delete later is handled in the notes and the backup copy. sync-notes.sh
# reads the same saved choice (it can be changed later with: sync-notes.sh --set-deletes).
#   mirror   copies match live exactly; deleted files are gone (with a mass-delete guard)
#   archive  like mirror, but deleted files go to a trash folder first (default)
#   keep     never delete anything, only add and update
set saved_dm archive
if test -f $delete_cfg
    set saved_dm_raw (string trim -- (head -n1 $delete_cfg))
    contains -- "$saved_dm_raw" mirror archive keep; and set saved_dm $saved_dm_raw
end
if isatty stdin
    echo
    set_color --bold; echo "How should files you delete later be handled in the backup?"; set_color normal
    echo "  1) mirror   - copies match live exactly; deleted files are gone"
    echo "  2) archive  - like mirror, but deleted files go to a trash folder first (default)"
    echo "  3) keep     - never delete anything, only add and update"
    read -P "Choose [1-3, Enter = $saved_dm]: " reply
    switch (string lower -- (string trim -- "$reply"))
        case 1 mirror
            set saved_dm mirror
        case 2 archive
            set saved_dm archive
        case 3 keep
            set saved_dm keep
        case ''
            # keep the current one
        case '*'
            warn "not a valid choice, using $saved_dm"
    end
    save_choice $delete_cfg $saved_dm
    info "backup delete mode: $saved_dm (saved in $delete_cfg)"
else if test -f $delete_cfg
    info "backup delete mode: $saved_dm (already saved)"
else
    info "no terminal: backup delete mode left unset, sync-notes.sh will use archive"
end

# ================================================================
# 1. PACKAGES + GRUB (run first, before everything else)
# ================================================================
info "caching sudo credentials"
sudo -v

# ---------------------------------------------------------------- paru (Arch only)
# paru is an AUR helper: it installs packages from the AUR (community-made build recipes, not checked
# by the distro). Without it only the official repos are used.
if test $pm = pacman
    if type -q paru
        info "paru is already installed"
    else if isatty stdin
        echo
        set_color --bold; echo "Install paru (AUR helper)?"; set_color normal
        echo "  What it is: a tool that builds and installs packages from the AUR (Arch User Repository),"
        echo "              so packages that are not in the official repos can be in packages.conf."
        echo "  Risk:       AUR packages are written by anyone and are not reviewed by Arch. Their build"
        echo "              scripts run on your machine with your user (and root for the install step), so a"
        echo "              bad or hijacked package can run harmful code. Packages are also built from source,"
        echo "              which takes time. Official repo packages are not affected."
        echo "  If you say no: only packages in the official repos are installed; the AUR-only ones in"
        echo "              packages.conf are skipped and listed at the end."
        read -P "Install paru? [y/N]: " paru_ans
        if string match -qri '^y' -- (string trim -- "$paru_ans")
            info "installing paru"
            # CachyOS ships paru in its own repo
            sudo pacman -S --needed --noconfirm paru
            if not type -q paru
                # plain Arch: build paru-bin from the AUR
                info "building paru-bin from the AUR"
                sudo pacman -S --needed --noconfirm base-devel git
                set paru_tmp (mktemp -d)
                if git clone https://aur.archlinux.org/paru-bin.git $paru_tmp/paru-bin
                    pushd $paru_tmp/paru-bin
                    makepkg -si --noconfirm
                    popd
                end
                rm -rf $paru_tmp
            end
            type -q paru; or warn "paru could not be installed: AUR packages will be skipped"
        else
            info "paru skipped: only the official repos are used, AUR-only packages are skipped"
        end
    else
        info "paru is not installed and there is no terminal to ask: AUR-only packages will be skipped"
    end
else if test $pm = apt
    info "refreshing the apt package lists"
    sudo apt-get update
end

# ---------------------------------------------------------------- packages
# everything in packages.conf: native packages with the detected package manager, flatpak apps
# with flatpak. Names this distro does not have are skipped and listed at the end.
info "installing the packages from packages.conf"
install_packages $extras/packages.conf

# ---------------------------------------------------------------- ufw (KDE Connect, LocalSend, AudioRelay)
if type -q ufw
    info "opening ports (KDE Connect, LocalSend, AudioRelay)"
    sudo ufw allow 1716/udp      # KDE Connect
    sudo ufw allow 5000/tcp      # LocalSend
    sudo ufw allow 53317/tcp     # LocalSend
    sudo ufw allow 1234/tcp      # AudioRelay
    sudo ufw allow 59100/tcp     # AudioRelay
    sudo ufw allow 59100/udp     # AudioRelay
    sudo ufw --force enable
    sudo systemctl enable --now ufw.service
    sudo ufw reload
    sudo ufw status
end

# ---------------------------------------------------------------- grub
# Only asked when GRUB is the boot loader of this machine and there is a terminal.
if test -f /etc/default/grub
    if isatty stdin
        echo
        set_color --bold; echo "GRUB: hide the boot menu and boot straight away?"; set_color normal
        echo "  What it does: sets GRUB_TIMEOUT=0 and GRUB_TIMEOUT_STYLE=hidden in /etc/default/grub (the old"
        echo "                values are replaced), then regenerates the GRUB config. The boot menu no longer"
        echo "                shows, the default entry starts at once."
        echo "  Risk:         with a dual boot or after a bad update you can no longer pick another system or an"
        echo "                older kernel from the menu (holding Shift or Esc at boot usually shows it again)."
        read -P "Do it? [y/N]: " grub_ans
        if string match -qri '^y' -- (string trim -- "$grub_ans")
            info "setting GRUB_TIMEOUT=0 and hidden menu"
            sudo sed -i -E '/^#?[[:space:]]*GRUB_TIMEOUT(_STYLE)?=/d' /etc/default/grub
            printf "GRUB_TIMEOUT='0'\nGRUB_TIMEOUT_STYLE=hidden\n" | sudo tee -a /etc/default/grub >/dev/null
            if type -q update-grub
                sudo update-grub                                  # Debian, Ubuntu
            else if type -q grub-mkconfig
                sudo grub-mkconfig -o /boot/grub/grub.cfg         # Arch
            else if type -q grub2-mkconfig
                sudo grub2-mkconfig -o /boot/grub2/grub.cfg       # Fedora, openSUSE
            else
                warn "no grub config tool found - regenerate the grub config manually"
            end
        else
            info "GRUB left as it is"
        end
    else
        info "GRUB found, no terminal to ask: left as it is"
    end
end

# ================================================================
# 2. UPDATE PACKAGES + DESKTOP PRE-HOOKS
#    (done before any config is copied, so no package can overwrite your config)
# ================================================================
if test $pm != none
    info "updating packages"
    pm_update $pm
end

# desktop pre-hooks (Desktop Environment/NAME/pre.fish): sourced, so they can use info, warn,
# pm_install, $pm, $notes. They run before the configs are restored on purpose.
for d in $chosen_des
    set dn (de_dir_name $notes $d)
    test -n "$dn"; or continue
    set hook $notes/$layout_de/$dn/pre.fish
    if test -f $hook
        info "desktop pre-hook: $hook"
        source $hook
    end
end

# ================================================================
# 3. COPY CONFIG FILES (very last, so nothing above can overwrite them)
# ================================================================

# ---------------------------------------------------------------- tracked folders
# Everything listed in additional-scripts/tracked.conf: config.fish, ghostty, Keypass,
# .passwords, the Music scripts, clean.py ... (saved in Backup/) and the files of your desktop
# environment (saved in Desktop Environment/NAME/), plus whatever you added with sync-notes.sh
# (menu option 4). Both places hold the same paths as your home folder.
set sys_names
set sys_opts
for line in (tracked_list $extras/tracked.conf)
    set p (string split \t -- $line)
    set live $p[1]
    set name $p[2]
    set optstr ""
    set -q p[3]; and set optstr $p[3]
    set opts (string split -n ' ' -- $optstr)
    if not tracked_name_ok $name
        warn "tracked.conf: '$name' is not in the Backup / Desktop Environment layout, skipped"
        continue
    end
    # not meant for this machine: a file of a desktop that was not chosen (Desktop Environment/NAME/...),
    # or a Backup/ entry with a de= list (rofi...) where none of those desktops was chosen
    entry_active $name $opts; or continue
    if contains -- optional $opts; and not test -e $notes/$name -o -L $notes/$name
        continue
    end
    # System/ files need sudo: collected here, restored after one question below
    if string match -q -- "$layout_system/*" $name
        set -a sys_names $name
        set -a sys_opts (string join ',' -- $opts)
        continue
    end
    if place $notes/$name $live
        contains -- private $opts; and chmod -R go-rwx $live
        contains -- exec $opts; and make_exec_all $live
    end
end

# ---------------------------------------------------------------- system files (sudo)
if test (count $sys_names) -gt 0
    if test $no_system -eq 1
        info "system files skipped (--no-system): "(count $sys_names)
    else
        echo
        set_color --bold; echo "System files to put back (needs sudo, replaces what is there):"; set_color normal
        for i in (seq (count $sys_names))
            set o (string split -n ',' -- $sys_opts[$i])
            printf '  /%s   %s\n' (string replace -- "$layout_system/" '' $sys_names[$i]) (string join ' ' -- $o)
        end
        set go 0
        if isatty stdin
            read -P "Restore these now? [Y/n]: " ans
            string match -qri '^n' -- (string trim -- "$ans"); or set go 1
            test $go -eq 1; and not sudo -v; and set go 0
        else if sudo -n true 2>/dev/null
            set go 1
        else
            warn "no terminal and sudo needs a password: system files skipped (run this script again by hand)"
        end
        if test $go -eq 1
            for i in (seq (count $sys_names))
                place_sys $sys_names[$i] (string split -n ',' -- $sys_opts[$i])
            end
        else
            info "system files not restored; run ./initual-setup.sh again to do it"
        end
    end
end

# ---------------------------------------------------------------- python venvs
# Any requirements.txt in what was just restored (the tracked folders) or in a cloned repo of
# packages.conf: ask, one by one, whether to build a venv (.venv next to it) for it.
set req_files
for line in (tracked_list $extras/tracked.conf)
    set p (string split \t -- $line)
    set -q p[2]; tracked_name_ok $p[2]; or continue
    set -q p[3]; and set o (string split -n ' ' -- $p[3]); or set o
    entry_active $p[2] $o; or continue
    string match -q -- "$layout_system/*" $p[2]; and continue
    test -d $p[1]; or continue
    for f in (find $p[1] -maxdepth 3 -name requirements.txt -not -path '*/.venv/*' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)
        contains -- $f $req_files; or set -a req_files $f
    end
end
for u in (git_repos_conf $extras/packages.conf)
    set d (git_dest $u)
    test -d $d; or continue
    for f in (find $d -maxdepth 2 -name requirements.txt -not -path '*/.venv/*' -not -path '*/.git/*' 2>/dev/null)
        contains -- $f $req_files; or set -a req_files $f
    end
end
if test (count $req_files) -gt 0
    set py (command -v python3 python 2>/dev/null)
    if test (count $py) -eq 0
        warn "requirements.txt found but python is not installed, venvs skipped: $req_files"
    else if not isatty stdin
        info "requirements.txt found, no terminal to ask: no venv built ("(count $req_files)")"
    else
        for f in $req_files
            set rd (dirname $f)
            echo
            echo "  $f"
            echo "  A venv is a private Python environment in $rd/.venv; the packages from this file are"
            echo "  installed into it with pip (downloaded from PyPI), nothing is installed system-wide."
            read -P "  Build it? [y/N]: " venv_ans
            string match -qri '^y' -- (string trim -- "$venv_ans"); or continue
            test $pm = apt; and pm_install apt python3-venv
            info "creating venv at $rd/.venv"
            $py[1] -m venv $rd/.venv; or begin
                warn "could not create the venv"
                continue
            end
            # tkinter is not pip-installable: it comes from the system package (the "tk" entry of packages.conf)
            set tmp_req (mktemp)
            grep -viE '^\s*tkinter\s*$' $f >$tmp_req
            $rd/.venv/bin/pip install --upgrade pip
            $rd/.venv/bin/pip install -r $tmp_req; or warn "pip could not install everything from $f"
            rm -f $tmp_req
            info "activate with: source $rd/.venv/bin/activate.fish"
        end
    end
end

# ---------------------------------------------------------------- desktop hooks
# The files of a desktop come from its folder in "Desktop Environment/" (restored above), its
# packages from the de= entries of packages.conf. If Desktop Environment/NAME/post.fish exists
# for a chosen desktop it runs now, after the configs are in place (manual steps, enabling a
# service...). It is sourced, so it can use info, warn, place, $pm, $notes, $cfg.
for d in $chosen_des
    set dn (de_dir_name $notes $d)
    test -n "$dn"; or continue
    set hook $notes/$layout_de/$dn/post.fish
    if test -f $hook
        info "desktop hook: $hook"
        source $hook
    end
end

# ---------------------------------------------------------------- notes
# ~/Documents/os-migrate-notes is where the notes live from now on (sync-notes.sh and its
# timer work in there). If it does not exist yet (or is empty), e.g. on a fresh install where
# this script runs from a backup folder (os-migrate-notes-backup) copied from a USB drive, the
# WHOLE folder this script runs from is copied into it, so nothing from the backup is lost.
# If it already exists and has content, it is never overwritten: only the setup-*.txt
# reference notes are copied into it.
set notes_dst $HOME/Documents/os-migrate-notes
set notes_fresh 0
if not test -e $notes_dst
    set notes_fresh 1
else if test -d $notes_dst; and test (count (command ls -A $notes_dst)) -eq 0
    set notes_fresh 1
end

if test $notes_fresh -eq 1; and test (realpath -m $notes_dst) != $notes
    info "$notes_dst is missing or empty: copying everything from $notes into it"
    mkdir -p $notes_dst; or begin
        warn "cannot create $notes_dst"
        exit 1
    end
    tar -C $notes -cf - . | tar -C $notes_dst -xf -
    set st $pipestatus
    # tar exit 1 only means "a file changed while reading", which is fine here
    if test "$st[1]" -gt 1 -o "$st[2]" != 0
        warn "copy into $notes_dst failed; removing the partial copy so the next run starts clean"
        rm -rf $notes_dst
        exit 1
    end
    chmod --reference=$notes $notes_dst
    info "$notes -> $notes_dst (everything copied)"
else
    mkdir -p $notes_dst
    if test (realpath $notes_dst) = $notes
        info "already running from $notes_dst, notes are in place"
    else
        for f in $notes/setup-*.txt
            cp -a $f $notes_dst/
            info "$f -> $notes_dst/"
        end
    end
end

# ---------------------------------------------------------------- auto-sync timer
# sync-notes.sh copies the live configs back into ~/Documents/os-migrate-notes. It runs from a systemd
# user timer (3 min after login, then hourly). This is enabled LAST, after every config has
# been restored above, so the sync can never overwrite your notes with fresh-install defaults.
set sync_dst $notes_dst/additional-scripts
if test -f $extras/sync-notes.sh
    if test (realpath $notes_dst) != $notes
        mkdir -p $sync_dst
        for f in sync-notes.sh lib.fish
            test -f $extras/$f; and cp -a $extras/$f $sync_dst/$f
        end
        # the two lists are only copied when missing, so an existing one is never overwritten
        for f in tracked.conf packages.conf pkg-ignore.conf
            test -f $extras/$f; and cp -an $extras/$f $sync_dst/$f
        end
        info "$extras/ tools -> $sync_dst/"
    end
    chmod +x $sync_dst/sync-notes.sh 2>/dev/null

    set unit_dir $HOME/.config/systemd/user
    mkdir -p $unit_dir
    printf '[Unit]\nDescription=Sync live configs into %s\n\n[Service]\nType=oneshot\nExecStart=%s/sync-notes.sh\nNice=19\nIOSchedulingClass=idle\n' \
        $notes_dst $sync_dst >$unit_dir/sync-notes.service
    printf '[Unit]\nDescription=Hourly sync of configs into notes\n\n[Timer]\nOnBootSec=3min\nOnCalendar=hourly\n\n[Install]\nWantedBy=timers.target\n' \
        >$unit_dir/sync-notes.timer

    if type -q systemctl
        systemctl --user daemon-reload
        systemctl --user enable --now sync-notes.timer
        info "sync-notes timer enabled (hourly): systemctl --user list-timers sync-notes.timer"
    else
        warn "systemctl not found - sync timer files written but not enabled"
    end
else
    warn "sync-notes.sh not found in $extras, auto-sync timer skipped"
end

# ---------------------------------------------------------------- package tracker
# pkg-track.fish keeps packages.conf in step with what you install and remove by hand later
# (pacman/paru, apt, dnf, zypper, flatpak). It is installed LAST, after every package above is
# in place, so everything this script installed becomes the baseline and is not "new". Boot-time
# and setup installs are never recorded; only package manager runs after this point are.
# It runs from the copy in ~/Documents/os-migrate-notes/additional-scripts/, so the hook keeps
# working if this folder is moved or deleted.
if test $no_pkg_track -eq 1
    info "package tracker skipped (--no-pkg-track)"
else if not test -f $extras/pkg-track.fish
    warn "pkg-track.fish not found in $extras, package tracker skipped"
else
    set pt_dir $extras
    if test (realpath $notes_dst) != $notes
        mkdir -p $sync_dst
        for f in pkg-track.fish lib.fish
            test -f $extras/$f; and cp -a $extras/$f $sync_dst/$f
        end
        # the lists are only copied when missing, so an existing one is never overwritten
        for f in packages.conf pkg-ignore.conf
            test -f $extras/$f; and cp -an $extras/$f $sync_dst/$f
        end
        set pt_dir $sync_dst
    end
    info "installing the package tracker (needs sudo for the pacman/apt hook)"
    fish $pt_dir/pkg-track.fish install; or warn "package tracker setup failed, run later: fish $pt_dir/pkg-track.fish install"
end

info "done."