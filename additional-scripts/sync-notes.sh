#!/usr/bin/env fish
# sync-notes.sh - the reverse of initual-setup.sh.
# Copies your LIVE config files back into the notes folder (the parent of the
# additional-scripts folder this script is in), replacing the old copies there, so the
# notes always match what you actually use. What is copied is listed in
# additional-scripts/tracked.conf (add or remove entries with the manager below),
# Inside the notes everything mirrors your home folder: Backup/<path> holds what is restored
# on every machine, Desktop Environment/<DE>/<path> the files of one desktop (restored only
# when that desktop is chosen in initual-setup.sh; the desktops are just those folders).
#
# Usage:
#   ./sync-notes.sh             sync everything, then commit and push to git (origin)
#   ./sync-notes.sh --dry-run   only show what would be replaced (alias: -n)
#   ./sync-notes.sh --no-git    sync the files but skip the git commit and push
#   ./sync-notes.sh --quiet     do not list every copied file
#   ./sync-notes.sh --sync      skip the menu and sync (same as the default)
#   ./sync-notes.sh --backup    skip the menu and make a copy for a USB drive / phone
#   ./sync-notes.sh --set-repo  set or change the git repo URL (also menu option 3)
#   ./sync-notes.sh --manage    open the manager: packages and folders (also menu option 4)
#   ./sync-notes.sh --set-deletes   choose how deleted files are handled and remember it (also menu option 5)
#   ./sync-notes.sh --deletes=MODE  use MODE (mirror, archive or keep) for this run only
#   ./sync-notes.sh --force     let a sync go ahead that the mass-delete guard would refuse
#   ./sync-notes.sh --migrate   move a notes folder made by an older version to the Backup /
#                               Desktop Environment layout (--yes: do not ask, --dry-run: only show)
#
# The manager edits the two lists (packages.conf and tracked.conf, next to this script):
#   ./sync-notes.sh pkg list [text]     list the packages (optionally only names containing text)
#   ./sync-notes.sh pkg search [text]   search the repos and flathub, then add what you pick
#   ./sync-notes.sh pkg add [names]     add packages by name (a flatpak id like org.gimp.GIMP works too;
#                                       pipx:NAME adds a pipx app, pipx:git+https://github.com/u/repo one that is
#                                       not on PyPI; a plain git URL adds a repo cloned to ~/Documents)
#   ./sync-notes.sh pkg remove [name]   remove packages: pick by number, type names, or filter by text
#   ./sync-notes.sh pkg export          add what is installed on this machine but not listed yet
#   ./sync-notes.sh pkg script [repo [path|-]]  a cloned git repo that you installed with its install.sh /
#                                       setup.fish...: record which script (install=PATH in packages.conf); the setup
#                                       then offers to run it after cloning the repo on a new machine. It also asks
#                                       right after a repo is cloned or added.
#   ./sync-notes.sh pkg rename [item [name]]  give any entry (native, flatpak, snap, pipx, git) a name of your
#                                       own; it is saved as name=NAME on its line in packages.conf and shown by the
#                                       manager. remove / uninstall / list accept the name or the original one.
#                                       A pipx app that is not on PyPI asks for a name right after it is installed.
#   ./sync-notes.sh pkg install         install everything in packages.conf now
#   ./sync-notes.sh dir list [text]     list the tracked folders (optionally only lines containing text,
#                                       e.g. mango, sddm, private; several words must all match)
#   ./sync-notes.sh dir add [path]      start backing up a folder or file. It is saved under Backup/ with
#                                       the same path it has in your home folder (~/Downloads/clean.py ->
#                                       Backup/Downloads/clean.py), or, when you say it belongs to one
#                                       desktop, under Desktop Environment/<that desktop>/
#                                       For a folder it first shows what is inside (a tree like eza --tree,
#                                       hidden files included). "Keep it out of git" can then ignore only
#                                       part of it: *.log (every folder that has some), logs/*.log, one
#                                       file or one folder; the paths written to .gitignore are listed
#   ./sync-notes.sh dir remove          stop backing one up
#   ./sync-notes.sh dir rename [item [name]]  give a folder or file a name of your own, any text (saved as name=NAME on its
#                                       line in tracked.conf). The lists show it in the NAME column instead of the
#                                       file or folder name; the PATH column shows a folder's own path, or the folder
#                                       a file sits in. "-" as the name goes back to the file or folder name.
#   ./sync-notes.sh dir de              add a desktop environment: scans ~/.config for known desktops (hypr,
#                                       sway, niri, mango, KDE...), or asks for a path; backs up its config
#                                       under Desktop Environment/<name>/ and makes pre.fish / post.fish
#   ./sync-notes.sh dir uses            choose which desktops use something shared (rofi...). It stays in
#                                       Backup/ and is not moved; the restore is limited to those desktops.
#                                       Offers the desktops whose files mention it. A thing that sits in one
#                                       desktop's folder can be made shared here (its copy moves to Backup/).
#   ./sync-notes.sh help                show this text
# Packages are installed with pacman/paru, apt, dnf or zypper (whichever this machine has)
# and flatpak apps with flatpak. initual-setup.sh installs the packages and restores the folders.
#
# Git repo URL: if the notes folder has no git remote, a terminal run asks for the URL and
# remembers it in ~/.config/os-migrate-notes/git-url. That file is OUTSIDE the notes folder,
# so it is never synced, committed or copied into the backup. Without a terminal (timer)
# and without a saved URL, the git step is simply skipped.
#
# When run by hand in a terminal, a small menu asks what to do (Enter = normal sync).
# When run without a terminal (systemd timer, cron) the menu is skipped and it just syncs.
#
# Backup copy: (re)creates the folder $HOME/Documents/os-migrate-notes-backup, replacing everything in
# it each time (the old copy is deleted only after the new one is complete). It holds
# EVERYTHING in the notes folder (Keypass, .passwords, images, media, logs...) except the
# git files themselves (.git, .gitignore, .gitattributes, .gitmodules, .gitkeep).
# .gitignore is not used for the backup. README.md is kept. Copy that folder to your drive.
#
# Deleted files: what happens to a file you deleted live but that is still in the notes and in
# the backup copy depends on the delete mode (choose it with menu option 5 or --set-deletes;
# it is remembered in ~/.config/os-migrate-notes/delete-mode, outside the notes):
#   mirror    the copies match your live files exactly; deleted files are gone
#   archive   like mirror, but removed files and folders are first moved to a trash folder
#             (~/.local/share/os-migrate-notes/deleted/DATE, outside the notes, so never synced,
#             committed or backed up) and purged after 60 days. The backup copy keeps its 3
#             previous versions in ~/Documents/os-migrate-notes-backup.previous. (default)
#   keep      only add and update, nothing is ever deleted from the notes or the backup copy
# In mirror mode a sync that would delete 30% or more of a folder (or all of it, e.g. the
# source is empty or its drive is not mounted) is refused unless you pass --force.
#
# Safety: if a live source is missing, the old copy in the notes is KEPT, never deleted.
# Directories are copied to a temp folder first and swapped in only if the copy succeeded.
# Git: the commit is refused if a secret or media file (.kdbx, .passwords, recovery codes,
# audio/video) is about to be committed, so a broken .gitignore cannot leak it.

# Layout: this script lives in <notes>/additional-scripts/, next to config.fish,
# mangohud-env.sh, usbguard.sh ... The notes root (git repo) is its parent folder.
# If the script is run from the root instead, the root is simply its own folder.
set here (realpath (dirname (status filename)))
if test (basename $here) = additional-scripts
    set notes (dirname $here)
else
    set notes $here
end
set extras $notes/additional-scripts
set cfg $HOME/.config
set pkgfile $extras/packages.conf
set dirfile $extras/tracked.conf
set self (realpath (status filename))

function info;  set_color green;  echo "==> $argv"; set_color normal; end
function warn;  set_color yellow; echo "!!  $argv"; set_color normal; end

set dry 0
if contains -- --dry-run $argv; or contains -- -n $argv
    set dry 1
    info "dry run: nothing will be changed"
end

set quiet 0
contains -- --quiet $argv; and set quiet 1

set no_git 0
if contains -- --no-git $argv
    set no_git 1
end

set assume_yes 0
if contains -- --yes $argv
    set assume_yes 1
end

# shared helpers (package manager, packages.conf, tracked.conf)
if test -f $extras/lib.fish
    source $extras/lib.fish
    set have_lib 1
    set pm (detect_pm)
else
    set have_lib 0
    set pm none
    warn "missing $extras/lib.fish: tracked folders skipped, manager unavailable"
    function tracked_list; end
    function tracked_name_ok; return 1; end
    set -g layout_backup Backup
    set -g layout_de "Desktop Environment"
end

# backup_copy : copy the whole notes folder into ~/Documents/os-migrate-notes-backup, leaving out only
# the git files themselves. Does not touch the live configs.
function backup_copy
    set dest $HOME/Documents/os-migrate-notes-backup
    set gitfiles --exclude=.git --exclude=.gitignore --exclude=.gitattributes --exclude=.gitmodules --exclude=.gitkeep

    if test $dry -eq 1
        info "[dry-run] would copy $notes -> $dest (everything except git files)"
        return 0
    end

    mkdir -p $HOME/Documents; or begin
        warn "cannot create $HOME/Documents"
        return 1
    end
    # build in a temp folder first; the old backup is replaced only if the copy succeeded
    set tmp (mktemp -d $HOME/Documents/.os-migrate-notes-backup.XXXXXX); or return 1

    # copy EVERYTHING (secrets, media, images, logs too); only git's own files are skipped.
    # .gitignore rules are NOT used here, they only matter for the git push.
    tar -C $notes $gitfiles -cf - . | tar -C $tmp -xf -
    set st $pipestatus
    # tar exit 1 only means "a file changed while reading", which is fine here
    if test "$st[1]" -gt 1 -o "$st[2]" != 0
        warn "backup copy failed, kept the old backup (if any)"
        rm -rf $tmp
        return 1
    end

    chmod 755 $tmp
    switch $delmode
        case keep
            # add and update only: merge into the existing backup, delete nothing
            if test -d $dest
                if not cp -a $tmp/. $dest/
                    warn "backup merge failed, kept the old backup"
                    rm -rf $tmp
                    return 1
                end
                rm -rf $tmp
            else
                mv $tmp $dest
            end
        case archive
            # the old backup becomes a dated "previous" copy; only the newest $backup_keep are kept
            if test -d $dest
                set -l prev $HOME/Documents/os-migrate-notes-backup.previous
                mkdir -p $prev; and chmod 700 $prev
                if not mv $dest $prev/$arch_run
                    warn "could not keep the old backup, left it in place"
                    rm -rf $tmp
                    return 1
                end
                for o in (ls -1 $prev | sort -r | tail -n +(math $backup_keep + 1))
                    rm -rf $prev/$o
                end
            end
            mv $tmp $dest
        case '*'
            rm -rf $dest
            mv $tmp $dest
    end

    info "backup ready: $dest ("(du -sh $dest | cut -f1)", delete mode: $delmode)"
    info "now copy that folder to your USB drive or phone"
end

# ---------------------------------------------------------------- git repo URL
# The URL is kept OUTSIDE the notes folder, so it is never synced, committed or put in the
# backup copy. It can contain a token, so the file is private (mode 600) and the URL is
# always shown with the credentials masked.
set repo_cfg $HOME/.config/os-migrate-notes
set repo_url_file $repo_cfg/git-url

function is_tty
    isatty stdin; and isatty stdout
end

function mask_url
    string replace -r '://[^/@]+@' '://***@' -- $argv[1]
end

# prints the saved URL, or nothing
function saved_repo_url
    test -f $repo_url_file; and string trim -- (head -n1 $repo_url_file)
end

# point origin at URL $argv[1] (add it, or change it if it exists)
function apply_remote
    if git -C $notes remote get-url origin >/dev/null 2>&1
        git -C $notes remote set-url origin $argv[1]
    else
        git -C $notes remote add origin $argv[1]
    end
end

# set_repo_url : ask for the URL, save it outside the notes, point origin at it
function set_repo_url
    if not is_tty
        warn "run this by hand in a terminal to set the repo URL"
        return 1
    end
    set -l cur (saved_repo_url)
    if test -z "$cur"; and test -d $notes/.git
        set cur (git -C $notes remote get-url origin 2>/dev/null)
    end
    test -n "$cur"; and echo "current repo: "(mask_url $cur)
    read -P "Git repo URL (Enter = cancel): " url
    set url (string trim -- $url)
    if test -z "$url"
        warn "no URL entered, nothing changed"
        return 1
    end
    if not string match -qr '^((https?|ssh|git|file)://.+|[A-Za-z0-9._-]+@\S+:.+|/.+)$' -- $url
        warn "not a git URL (https://..., git@host:user/repo.git)"
        return 1
    end
    if test $dry -eq 1
        info "[dry-run] would save the URL and set origin to "(mask_url $url)
        return 0
    end
    mkdir -p $repo_cfg; and chmod 700 $repo_cfg
    printf '%s\n' $url >$repo_url_file; and chmod 600 $repo_url_file
    info "repo URL saved (outside the notes, never synced)"
    if test -d $notes/.git
        apply_remote $url; and info "git: origin -> "(mask_url $url)
    else
        info "not a git repo yet; the next sync offers to set it up"
    end
end

# ensure_repo : make sure the notes folder is a git repo with an origin.
# Returns 1 when the git step has to be skipped.
function ensure_repo
    if not type -q git
        warn "git skipped: git is not installed"
        return 1
    end

    if not test -d $notes/.git
        if test $dry -eq 1; or not is_tty
            warn "git skipped: not a repo (menu option 3 sets one up)"
            return 1
        end
        read -P "$notes is not a git repository. Set one up here? [y/N]: " yn
        if not string match -qri '^y' -- $yn
            warn "git skipped"
            return 1
        end
        git -C $notes init -q -b main; or return 1
        info "git: new repository created (branch main)"
    end

    if not git -C $notes remote get-url origin >/dev/null 2>&1
        set -l saved (saved_repo_url)
        if test -n "$saved"
            if test $dry -eq 1
                info "[dry-run] would set origin from the saved URL"
            else
                apply_remote $saved
                info "git: origin set from the saved URL ("(mask_url $saved)")"
            end
        else if test $dry -eq 0; and is_tty
            set_repo_url; or return 1
        else
            warn "git skipped: no origin and no saved URL (menu option 3)"
            return 1
        end
    end

    # the backup copy leaves .gitignore out, so a restored folder may lack one: without it
    # "git add -A" would commit images and logs that are meant to stay private
    if not test -f $notes/.gitignore
        warn "git skipped: no .gitignore (add one first)"
        return 1
    end
    return 0
end

# ================================================================ manager (packages and folders)
# ================================================================ small helpers
# ask PROMPT : read a line into the global $reply (trimmed). Status 1 at end of input.
function ask
    read -g -P "$argv[1]" reply; or return 1
    set -g reply (string trim -- $reply)
    return 0    # string trim returns 1 when there was nothing to trim
end

# yes_no PROMPT DEFAULT(y|n) : status 0 for yes
function yes_no
    set -l hint "[y/N]"
    test "$argv[2]" = y; and set hint "[Y/n]"
    ask "$argv[1] $hint: "; or return 1
    switch (string lower -- "$reply")
        case y yes
            return 0
        case n no
            return 1
        case ''
            test "$argv[2]" = y
        case '*'
            return 1
    end
end

function ensure_pkgfile
    test -f $pkgfile; or printf '[native]\n\n[flatpak]\n' >$pkgfile
end

# pick_items PROMPT : choose from the global lists items_key (names) and items_label (lines).
# Optional globals set by the builders: items_sec (source per item), items_header (column
# titles), items_noun and items_foot (footer text), items_inst (per item: 1 installed,
# 0 missing, - not applicable; it enables the word "missing").
# Type numbers (1,3-5 or all), names, "missing", or words to filter the list. Sets the global
# `picked` to indices into items_*. Status 1 when cancelled or there is nothing to pick.
# A filter that matches nothing shows an empty table and asks again (the list is not repeated).
function pick_items
    set -g picked
    test (count $items_key) -gt 0; or return 1
    set -l filt
    set -l any 0
    set -l only_missing 0
    set -l noun $items_noun
    test -n "$noun"; or set noun items
    set -l hint "1,3-5 / all"
    test (count $items_inst) -gt 0; and set hint "$hint, missing"
    while true
        set -g view
        set -l n 0
        echo
        test -n "$items_header"; and printf '       %s\n' "$items_header"
        for i in (seq (count $items_key))
            if test $only_missing -eq 1
                test "$items_inst[$i]" = 0; or continue
            end
            if test (count $filt) -gt 0
                set -l hits 0
                set -l alt ""
                test (count $items_alt) -eq (count $items_key); and set alt $items_alt[$i]
                for f in $filt
                    string match -qi -- "*$f*" "$items_sec[$i] $items_key[$i] $alt"; and set hits (math $hits + 1)
                end
                if test $any -eq 1
                    test $hits -gt 0; or continue
                else
                    test $hits -eq (count $filt); or continue
                end
            end
            set n (math $n + 1)
            set -a view $i
            printf '  %3d) %s\n' $n $items_label[$i]
        end
        echo
        echo "  $n of "(count $items_key)" $noun$items_foot"
        ask "$argv[1] ($hint, or text to filter): "; or return 1
        test -n "$reply"; or return 1

        if test "$reply" = missing; and test (count $items_inst) -gt 0
            set only_missing 1
            set filt
            set any 0
            continue
        end

        if string match -qr '^(all|a|[0-9][0-9,\s-]*)$' -- $reply
            set -l idx (parse_selection (string replace -ra '\s+' ',' -- $reply) $n); or continue
            for k in $idx
                set -a picked $view[$k]
            end
            return 0
        end

        # one or more names, separated by commas and/or spaces: every word must match exactly
        set -l words (string split -n ' ' -- (string replace -a , ' ' -- $reply))
        set -l hit
        set -l unknown
        for w in $words
            set -l found 0
            for i in (seq (count $items_key))
                set -l alts
                test (count $items_alt) -eq (count $items_key); and set alts (string split -n ' ' -- (string lower -- $items_alt[$i]))
                if test (string lower -- $items_key[$i]) = (string lower -- $w); or contains -- (string lower -- $w) $alts
                    contains -- $i $hit; or set -a hit $i
                    set found 1
                end
            end
            test $found -eq 1; or set -a unknown $w
        end
        if test (count $hit) -gt 0; and test (count $unknown) -eq 0
            set picked $hit
            return 0
        end
        set any 0
        if test (count $hit) -gt 0
            echo "  not in the list: $unknown (showing matches)"
            set any 1
        end
        # otherwise filter: every word must be in the name (or any word, after a partial name match)
        set filt $words
        set only_missing 0
    end
end

# ================================================================ packages
# fills items_key / items_label / items_sec from packages.conf
function build_pkg_items
    set -g items_key
    set -g items_alt
    set -g items_label
    set -g items_sec
    set -g items_toks
    set -g items_name
    set -g items_inst
    set -g items_header (printf '%-8s %-32s %-34s %s' SOURCE NAME "USED ON THIS SYSTEM" INSTALLED)
    set -g items_noun packages
    set -g items_foot " ($pm system; '-' = no package for it here)"
    for l in (pkg_lines $pkgfile)
        set -l w (string split ' ' -- $l)
        set -l sec $w[1]
        set -l name $w[2]
        set -l toks
        set -q w[3]; and set toks $w[3..-1]
        set -l here $name
        set -l shown $name
        set -l alt ""
        set -l mark "[ ]"
        if test $sec = native
            set here (pkg_resolve $pm $name $toks)
            if test -z "$here"
                set here "-"
            else if pm_installed $pm $here
                set mark "[x]"
            end
        else if test $sec = snap
            snap list $name >/dev/null 2>&1; and set mark "[x]"
        else if test $sec = pipx
            # NAME [src=SPEC]: the name you gave it, or the address itself
            set -l spec (pipx_entry_spec $name $toks)
            set here (string sub -l 34 -- (pipx_short $spec))
            set shown $name
            string match -q -- '*://*' $name; and set shown (pipx_short $name)
            set alt "$spec "(pipx_basename $spec)
            pipx_installed $spec; and set mark "[x]"
        else if test $sec = git
            set alt (basename (string trim -r -c / -- $name) .git)
            set here (string replace -- $HOME '~' (git_dest $name))
            test -d (git_dest $name)/.git; and set mark "[x]"
            set -l ins (entry_token install $toks)
            test -n "$ins"; and set here "$here  [runs $ins]"
        else if pm_installed flatpak $name
            set mark "[x]"
        end
        # a name you gave it (name=ALIAS) is shown in place of the package name and also matches
        set -l alias (entry_alias $toks)
        if test -n "$alias"
            set shown $alias
            set alt "$alt "(alias_alt $alias)
        end
        set -l inst 0
        test "$mark" = "[x]"; and set inst 1
        test "$here" = "-"; and set inst "-"
        set -a items_inst $inst
        set -a items_key $name
        set -a items_sec $sec
        set -a items_toks "$toks"
        set -a items_alt "$alt"
        set -a items_name "$alias"
        set -a items_label (printf '%-8s %-32s %-34s %s' $sec (string sub -l 32 -- $shown) $here $mark)
    end
end

function pkg_list
    ensure_pkgfile
    build_pkg_items
    if test (count $items_key) -eq 0
        echo "No packages in packages.conf yet. Add some with: sync-notes.sh pkg search"
        return 0
    end
    # every word must match the name or the source (so "kde dolphin" or "flatpak vlc" work)
    set -l words (string split -n ' ' -- (string replace -a , ' ' -- "$argv[1]"))
    echo
    printf '  %-8s %-32s %-34s %s\n' SOURCE NAME "USED ON THIS SYSTEM" INSTALLED
    set -l shown 0
    for i in (seq (count $items_key))
        set -l ok 1
        for w in $words
            string match -qi -- "*$w*" "$items_sec[$i] $items_key[$i] $items_alt[$i]"; or set ok 0
        end
        test $ok -eq 1; or continue
        echo "  $items_label[$i]"
        set shown (math $shown + 1)
    end
    echo
    echo "  $shown of "(count $items_key)" packages ("$pm" system; '-' = no package for it here)"
end

# add_native NAME SOURCE(repo|aur)
function add_native
    set -l name $argv[1]
    set -l src $argv[2]
    if conf_has $pkgfile native $name
        info "$name is already in packages.conf"
        return 0
    end
    set -l line $name
    if test $pm = pacman
        test "$src" = aur; and set line "$name arch"
    else if test $pm != none
        set line "$name only=$pm"
    end
    conf_add $pkgfile native $line
    set -a new_native $name
    info "added to [native]: $line"
end

function add_flatpak
    if conf_has $pkgfile flatpak $argv[1]
        info "$argv[1] is already in packages.conf"
        return 0
    end
    conf_add $pkgfile flatpak $argv[1]
    set -a new_flatpak $argv[1]
    info "added to [flatpak]: $argv[1]"
end

function add_snap
    if conf_has $pkgfile snap $argv[1]
        info "$argv[1] is already in packages.conf"
        return 0
    end
    # packages.conf only has [native] and [flatpak] by default: add the [snap] header once
    grep -qx '\[snap\]' $pkgfile; or printf '\n[snap]\n' >>$pkgfile
    conf_add $pkgfile snap $argv[1]
    set -a new_snap $argv[1]
    info "added to [snap]: $argv[1]"
end

# add_pipx SPEC : a Python app installed with pipx (conf_add creates the [pipx] section). SPEC is a
# PyPI name, or a git/web address or path for an app that is not on PyPI.
function add_pipx
    if pipx_listed $pkgfile $argv[1]
        info "$argv[1] is already in packages.conf"
        return 0
    end
    conf_add $pkgfile pipx $argv[1]
    set -a new_pipx $argv[1]
    info "added to [pipx]: $argv[1]"
end

# add_git URL : a repo that is cloned to ~/Documents/<repo name>
function add_git
    if conf_has $pkgfile git $argv[1]
        info "$argv[1] is already in packages.conf"
        return 0
    end
    conf_add $pkgfile git $argv[1]
    set -a new_git $argv[1]
    info "added to [git]: $argv[1] (clones to "(string replace -- $HOME '~' (git_dest $argv[1]))")"
end

# offer to install what was just added (new_native / new_flatpak / new_snap / new_pipx / new_git).
# Packages that are already installed here are left out; when nothing is left, nothing is asked.
function offer_install
    set -l added (math (count $new_native) + (count $new_flatpak) + (count $new_snap) + (count $new_pipx) + (count $new_git))
    test $added -gt 0; or return 0
    set -l todo_native
    set -l todo_flatpak
    set -l todo_snap
    set -l todo_pipx
    set -l todo_git
    if test $pm != none
        for n in $new_native
            pm_installed $pm $n; or set -a todo_native $n
        end
    end
    for n in $new_flatpak
        pm_installed flatpak $n; or set -a todo_flatpak $n
    end
    for n in $new_snap
        snap list $n >/dev/null 2>&1; or set -a todo_snap $n
    end
    for n in $new_pipx
        pipx_installed (pipx_conf_spec $pkgfile $n); or set -a todo_pipx $n
    end
    for u in $new_git
        test -d (git_dest $u)/.git; or set -a todo_git $u
    end
    set -l total (math (count $todo_native) + (count $todo_flatpak) + (count $todo_snap) + (count $todo_pipx) + (count $todo_git))
    if test $total -eq 0
        info "already installed on this system, nothing to install"
        return 0
    end
    set -l skipped (math $added - $total)
    test $skipped -gt 0; and info "$skipped already installed here, skipped"
    yes_no "Install the $total new package(s) on this system now?" y; or return 0
    if test (count $todo_native) -gt 0
        pm_install $pm $todo_native
    end
    if test (count $todo_flatpak) -gt 0
        if type -q flatpak
            flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
            flatpak install -y flathub $todo_flatpak
        else
            warn "flatpak is not installed (add it to the list, then run: pkg install)"
        end
    end
    if test (count $todo_snap) -gt 0
        if type -q snap
            for n in $todo_snap
                sudo snap install $n
            end
        else
            warn "snap is not installed, only added to the list"
        end
    end
    if test (count $todo_pipx) -gt 0
        if type -q pipx
            for n in $todo_pipx
                set -l spec (pipx_conf_spec $pkgfile $n)
                pipx_forget
                # installed fine and not from PyPI: offer a name for its entry
                if pipx install $spec; or pipx install --force $spec
                    pipx_forget
                    pipx_ask_name $pkgfile $n
                end
            end
        else
            warn "pipx is not installed, only added to the list"
        end
    end
    if test (count $todo_git) -gt 0
        if type -q git
            mkdir -p $HOME/Documents
            for u in $todo_git
                git clone $u (git_dest $u); and git_ask_install $pkgfile $u
            end
        else
            warn "git is not installed, only added to the list"
        end
    end
end

# add_one_name NAME : add one package by name (no install offer), checking that it exists.
# A git URL becomes a [git] entry, pipx:NAME a [pipx] entry, an application id like org.gimp.GIMP a flatpak.
function add_one_name
    set -l name $argv[1]
    if string match -qr '^(https?://|git@|ssh://).+' -- $name
        add_git $name
        return 0
    else if string match -q -- 'pipx:*' $name
        set -l px (string replace -- 'pipx:' '' $name)
        if test -z "$px"
            warn "no package name after pipx:"
            return 1
        end
        # only a plain name can be looked up on PyPI; a git address, web address or path is used as it is
        if pipx_is_pypi $px
            if not curl -sf -o /dev/null https://pypi.org/pypi/(string replace -r '[\[=<>!~].*$' '' -- $px)/json
                warn "'$px' was not found on PyPI (or PyPI is not reachable)"
                echo "     for git or a path use pipx:git+https://github.com/user/repo"
                yes_no "Add it anyway?" n; or return 1
            end
        end
        add_pipx $px
        return 0
    end
    if string match -qr '^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}$' -- $name
        add_flatpak $name
    else
        set -l src repo
        if pm_has $pm $name
            if test $pm = pacman; and not pacman -Si $name >/dev/null 2>&1
                set src aur
            end
        else
            warn "'$name' was not found in the $pm repos"
            yes_no "Add it anyway?" n; or return 1
        end
        add_native $name $src
    end
end

# pkg_add_name [NAMES] : add one or more packages by name (separated by spaces or commas)
function pkg_add_name
    ensure_pkgfile
    set -g new_native
    set -g new_flatpak
    set -g new_snap
    set -g new_pipx
    set -g new_git
    set -l input "$argv"
    if test -z "$input"
        ask "Package name(s) (flatpak id, pipx:name or git URL): "; or return 1
        set input $reply
    end
    set -l words (string split -n ' ' -- (string replace -a , ' ' -- "$input"))
    test (count $words) -gt 0; or return 0
    for w in $words
        add_one_name $w
    end
    offer_install
end

# search_native TERM : appends to res_src / res_name / res_desc
function search_native
    set -l term $argv[1]
    switch $pm
        case pacman
            set -l tool pacman
            type -q paru; and set tool paru
            set -l cname ""
            set -l crepo ""
            for l in (command $tool -Ss $term 2>/dev/null | head -n 400)
                if string match -qr '^\S' -- $l
                    set -l f (string split ' ' -- $l)
                    set -l rn (string split -m1 / -- $f[1])
                    set crepo $rn[1]
                    set cname $rn[2]
                else if test -n "$cname"
                    if contains -- $cname $res_name
                        set cname ""
                        continue
                    end
                    set -l s repo
                    test "$crepo" = aur; and set s aur
                    set -a res_src $s
                    set -a res_name $cname
                    set -a res_desc (string trim -- $l)
                    set cname ""
                end
            end
        case apt
            for l in (apt-cache search --names-only $term 2>/dev/null | head -n 80)
                set -l p (string split -m1 ' - ' -- $l)
                set -a res_src repo
                set -a res_name $p[1]
                set -a res_desc "$p[2]"
            end
        case dnf
            for l in (dnf -q search $term 2>/dev/null | head -n 200)
                set -l m (string match -r '^(\S+?)\.(noarch|x86_64|i686|aarch64|ppc64le|s390x)\s*:?\s*(.*)$' -- $l)
                set -q m[2]; or continue
                contains -- $m[2] $res_name; and continue
                set -a res_src repo
                set -a res_name $m[2]
                set -a res_desc "$m[4]"
            end
        case zypper
            for l in (zypper -q search -t package $term 2>/dev/null | head -n 200)
                set -l f (string split '|' -- $l)
                test (count $f) -ge 4; or continue
                test (string trim -- $f[4]) = package; or continue
                set -a res_src repo
                set -a res_name (string trim -- $f[2])
                set -a res_desc (string trim -- $f[3])
            end
    end
end

function search_flatpak
    type -q flatpak; or begin
        echo "  (flatpak is not installed, so flathub is not searched)"
        return 0
    end
    for l in (flatpak search --columns=application,name,description $argv[1] 2>/dev/null | head -n 60)
        set -l f (string split \t -- $l)
        test (count $f) -ge 2; or continue
        string match -qr '^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$' -- $f[1]; or continue
        set -a res_src flatpak
        set -a res_name $f[1]
        set -a res_desc "$f[2]  $f[3]"
    end
end

function search_snap
    type -q snap; or begin
        echo "  (snap is not installed, so the snap store is not searched)"
        return 0
    end
    for l in (snap find $argv[1] 2>/dev/null | tail -n +2 | head -n 60)
        set -l f (string split -n ' ' -- $l)
        test (count $f) -ge 1; or continue
        contains -- $f[1] $res_name; and continue
        set -a res_src snap
        set -a res_name $f[1]
        set -l d ""
        test (count $f) -ge 5; and set d (string join ' ' -- $f[5..-1])
        set -a res_desc "$d"
    end
end

# pkg_search SOURCE [TERM] : SOURCE is native, flatpak, snap or all
function pkg_search
    ensure_pkgfile
    set -l source $argv[1]
    set -l term $argv[2]
    if test -z "$term"
        ask "Search for: "; or return 1
        set term $reply
    end
    test -n "$term"; or return 0
    set -g res_src
    set -g res_name
    set -g res_desc
    set -g new_native
    set -g new_flatpak
    set -g new_snap
    set -g new_pipx
    set -g new_git
    info "searching for '$term'"
    switch $source
        case native
            test $pm != none; and search_native $term
        case flatpak
            search_flatpak $term
        case snap
            search_snap $term
        case '*'
            test $pm != none; and search_native $term
            search_flatpak $term
    end
    if test (count $res_name) -eq 0
        warn "nothing found for '$term' (try Add by name)"
        return 1
    end

    # same numbered picker as the other menus
    set -g items_key $res_name
    set -g items_alt
    set -g items_sec
    set -g items_inst
    set -g items_label
    set -g items_header (printf '%-8s %-36s %s' SOURCE NAME DESCRIPTION)
    set -g items_noun results
    set -g items_foot ""
    for i in (seq (count $res_name))
        set -l tag $res_src[$i]
        test $tag = repo; and set tag native
        set -a items_sec $tag
        set -l sec native
        test $res_src[$i] = flatpak; and set sec flatpak
        test $res_src[$i] = snap; and set sec snap
        set -l mark ""
        conf_has $pkgfile $sec $res_name[$i]; and set mark " (in list)"
        set -l d (string sub -l 60 -- "$res_desc[$i]")
        set -a items_label (printf '%-8s %-36s %s%s' $tag $res_name[$i] "$d" "$mark")
    end
    pick_items "Add which?"; or return 0
    for k in $picked
        switch $res_src[$k]
            case flatpak
                add_flatpak $res_name[$k]
            case snap
                add_snap $res_name[$k]
            case '*'
                add_native $res_name[$k] $res_src[$k]
        end
    end
    offer_install
end

function pkg_remove
    ensure_pkgfile
    build_pkg_items
    if test (count $items_key) -eq 0
        warn "packages.conf has no packages"
        return 1
    end
    set -g picked
    if test -n "$argv[1]"
        for i in (seq (count $items_key))
            set -l alts (string split -n ' ' -- $items_alt[$i])
            if test $items_key[$i] = $argv[1]; or contains -- (alias_alt $argv[1]) $alts
                set -a picked $i
            end
        end
        if test (count $picked) -eq 0
            warn "not in packages.conf: $argv[1]"
            return 1
        end
    else
        pick_items "Remove which?"; or begin
            echo "cancelled"
            return 0
        end
    end

    echo
    echo "Remove from packages.conf:"
    for i in $picked
        set -l what $items_key[$i]
        test $items_sec[$i] = pipx; and string match -q -- '*://*' $what; and set what (pipx_short $what)
        test -n "$items_name[$i]"; and set what "$items_name[$i] ($what)"
        printf '   - %s (%s)\n' $what $items_sec[$i]
    end
    yes_no "Remove them from the list?" y; or begin
        echo "cancelled"
        return 0
    end

    # note what is installed here before the lines disappear
    set -l inst_src
    set -l inst_name
    for i in $picked
        set -l src flatpak
        set -l n $items_key[$i]
        # a git entry is only removed from the list: the clone in ~/Documents is never deleted
        test $items_sec[$i] = git; and continue
        if test $items_sec[$i] = native
            set src $pm
            set n (pkg_resolve $pm $items_key[$i] (string split -n ' ' -- $items_toks[$i]))
        else if test $items_sec[$i] = snap
            set src snap
        else if test $items_sec[$i] = pipx
            set src pipx
            set n (pipx_conf_spec $pkgfile $items_key[$i])
        end
        test -n "$n"; or continue
        if test $src = snap
            if snap list $n >/dev/null 2>&1
                set -a inst_src snap
                set -a inst_name $n
            end
            continue
        end
        pm_installed $src $n; and begin
            set -a inst_src $src
            set -a inst_name $n
        end
    end

    for i in $picked
        conf_remove $pkgfile $items_sec[$i] $items_key[$i]
    end
    pipx_forget
    info "removed "(count $picked)" from packages.conf"
    for i in $picked
        test $items_sec[$i] = git; and info "the clone of $items_key[$i] was left in "(string replace -- $HOME '~' (git_dest $items_key[$i]))
    end

    if test (count $inst_name) -gt 0
        echo "Still installed on this system: $inst_name"
        if yes_no "Uninstall them too?" n
            for src in (printf '%s\n' $inst_src | sort -u)
                set -l names
                for k in (seq (count $inst_name))
                    test $inst_src[$k] = $src; and set -a names $inst_name[$k]
                end
                if test $src = snap
                    for n in $names
                        sudo snap remove $n
                    end
                else
                    pm_remove $src $names
                end
            end
        end
    end
end

# pkg_rename [ITEM [NEWNAME]] : give any entry of packages.conf (native, flatpak, snap, pipx, git) a name of
# your own, or change it. The entry keeps installing the same package; the name is what the manager
# shows. Remove, uninstall and list accept the name or the original (package name, id, address).
# "-" as the new name takes the name away again.
function pkg_rename
    ensure_pkgfile
    build_pkg_items
    if test (count $items_key) -eq 0
        warn "no packages"
        return 1
    end
    set -g picked
    set -l want $argv[1]
    if test -n "$want"
        for i in (seq (count $items_key))
            set -l al (string split -n ' ' -- $items_alt[$i])
            if test $items_key[$i] = "$want"; or contains -- (alias_alt $want) $al
                set -a picked $i
            end
        end
        if test (count $picked) -eq 0
            warn "not found: $want"
            return 1
        end
    else
        pick_items "Rename which?"; or begin
            echo "cancelled"
            return 0
        end
    end

    for i in $picked
        set -l key $items_key[$i]
        set -l sec $items_sec[$i]
        set -l shown $key
        test $sec = pipx; and string match -q -- '*://*' $key; and set shown (pipx_short $key)
        echo
        echo "  $sec: $shown"
        test -n "$items_name[$i]"; and echo "  now: $items_name[$i]"
        set -l new $argv[2]
        if test -z "$new"
            ask "  new name ('-' = none, Enter = keep): "; or return 1
            set new $reply
        end
        test -n "$new"; or continue
        test "$new" = -; and set new ""
        if test -n "$new"
            if not alias_valid $new
                warn "not a usable name"
                continue
            end
            if test "$new" = "$items_name[$i]"
                info "unchanged"
                continue
            end
            # the name has to point at one entry only
            set -l clash 0
            for j in (seq (count $items_key))
                test $j -eq $i; and continue
                if test "$items_key[$j]" = "$new" -o "$items_name[$j]" = "$new"
                    set clash 1
                end
            end
            if test $clash -eq 1
                warn "'$new' is taken"
                continue
            end
        end
        if conf_set_alias $pkgfile $sec $key "$new"
            if test -n "$new"
                info "$shown: $new"
            else
                info "$shown: name removed"
            end
        else
            warn "failed: $shown"
        end
    end
end

# add what is installed here but not listed
# pkg_script [REPO [PATH|-]] : which install script of a cloned repo was run to install it (install.sh,
# setup.fish...). It is saved as install=PATH on the repo's line in packages.conf; the setup then offers
# to run it after cloning the repo on a new machine. "-" as the path forgets it.
function pkg_script
    ensure_pkgfile
    build_pkg_items
    set -g picked
    set -l want $argv[1]
    for i in (seq (count $items_key))
        test $items_sec[$i] = git; or continue
        if test -z "$want"
            set -a picked $i
        else if test $items_key[$i] = "$want"; or contains -- (alias_alt $want) (string split -n ' ' -- $items_alt[$i])
            set -a picked $i
        end
    end
    if test (count $picked) -eq 0
        warn (test -n "$want"; and echo "no git repo called '$want' in packages.conf"; or echo "no git repos in packages.conf")
        return 1
    end
    if test -z "$want"
        echo
        for i in $picked
            printf '  %d) %s\n' $i (string split -n ' ' -- $items_alt[$i])[1]
        end
        ask "Which repo? (number, Enter = cancel): "; or return 0
        contains -- $reply $picked; or begin
            test -z "$reply"; or warn "not on the list"
            return 0
        end
        set picked $reply
    end
    for i in $picked
        set -l url $items_key[$i]
        set -l repo (string split -n ' ' -- $items_alt[$i])[1]
        set -l dir (git_dest $url)
        set -l new $argv[2]
        set -l cur (entry_token install (string split -n ' ' -- $items_toks[$i]))
        test -n "$cur"; and echo "  $repo: install script now: $cur"
        if test -z "$new"
            if not test -d $dir
                warn "$repo is not cloned here; give the path: pkg script $repo PATH"
                continue
            end
            set -l cands (git_install_candidates $dir)
            if test (count $cands) -eq 0
                warn "no install script found in $repo"
            else
                for k in (seq (count $cands))
                    echo "    $k) $cands[$k]"
                end
            end
            ask "  number or path inside the repo ('-' = none, Enter = leave it): "; or return 1
            set new $reply
            test -n "$new"; or continue
            if string match -qr '^[0-9]+$' -- $new
                test $new -ge 1 -a $new -le (count $cands); or begin
                    warn "not a number from the list"
                    continue
                end
                set new $cands[$new]
            end
        end
        test "$new" = -; and set new ""
        if test -n "$new"; and string match -qr -- '(^/|(^|/)\.\.(/|$)|\s)' $new
            warn "the path has to be inside the repo, without spaces or .."
            continue
        end
        if conf_set_token $pkgfile git $url install "$new"
            test -n "$new"; and info "$repo: the setup will offer to run $new after cloning"
            test -z "$new"; and info "$repo: no install script recorded any more"
        else
            warn "could not save it for $repo"
        end
    end
end

function pkg_export
    ensure_pkgfile
    set -g items_key
    set -g items_alt
    set -g items_label
    set -g items_sec
    set -g items_src
    set -g items_inst
    set -g items_header (printf '%-8s %s' SOURCE NAME)
    set -g items_noun "packages not in the list yet"
    set -g items_foot ""
    set -g hidden 0

    function _cand
        # _cand SECTION SOURCE NAME
        if conf_has $pkgfile $argv[1] $argv[3]
            set hidden (math $hidden + 1)
            return 0
        end
        set -a items_key $argv[3]
        set -a items_sec $argv[1]
        set -a items_src $argv[2]
        set -l tag $argv[1]
        test $argv[2] = aur; and set tag aur
        set -a items_label (printf '%-8s %s' $tag $argv[3])
    end

    switch $pm
        case pacman
            for n in (pacman -Qqen)
                _cand native repo $n
            end
            for n in (pacman -Qqem)
                _cand native aur $n
            end
        case apt
            for n in (apt-mark showmanual)
                _cand native repo $n
            end
        case dnf
            for n in (dnf -q repoquery --userinstalled --qf '%{name}' 2>/dev/null | sort -u)
                _cand native repo $n
            end
        case zypper
            warn "zypper cannot list what you installed yourself; use: sync-notes.sh pkg add <name>"
        case none
            warn "no supported package manager found"
    end
    if type -q flatpak
        for n in (flatpak list --app --columns=application 2>/dev/null)
            _cand flatpak flatpak $n
        end
    end
    if type -q pipx
        pipx_forget
        for n in (pipx_specs)
            if pipx_listed $pkgfile $n
                set hidden (math $hidden + 1)
                continue
            end
            _cand pipx pipx $n
        end
    end
    for u in (git_repos)
        _cand git git $u
    end
    if type -q snap
        for n in (now_snap)
            _cand snap snap $n
        end
    end
    functions -e _cand

    test $hidden -gt 0; and echo "($hidden already in packages.conf are hidden)"
    if test (count $items_key) -eq 0
        echo "Nothing new: all installed packages are already listed."
        return 0
    end
    echo "Explicitly installed here, not in packages.conf yet:"
    pick_items "Add which?"; or begin
        echo "cancelled"
        return 0
    end
    set -g new_native
    set -g new_flatpak
    set -g new_snap
    set -g new_pipx
    for i in $picked
        if test $items_sec[$i] = flatpak
            add_flatpak $items_key[$i]
        else if test $items_sec[$i] = snap
            add_snap $items_key[$i]
        else if test $items_sec[$i] = pipx
            add_pipx $items_key[$i]
            # an app that is not on PyPI: offer a name for it
            pipx_ask_name $pkgfile $items_key[$i]
        else if test $items_sec[$i] = git
            add_git $items_key[$i]
            # the repo has an install script? remember that it was installed with it
            git_ask_install $pkgfile $items_key[$i]
        else
            add_native $items_key[$i] $items_src[$i]
        end
    end
    info "already installed here, nothing to install"
end

function pkg_install
    ensure_pkgfile
    # install_packages handles every section: native, flatpak, snap, pipx and git
    install_packages $pkgfile
end

# term_cols : width of the terminal (80 when unknown)
function term_cols
    set -l c $COLUMNS
    string match -qr '^[0-9]+$' -- "$c"; or set c (stty size </dev/tty 2>/dev/null | string split ' ')[2]
    string match -qr '^[0-9]+$' -- "$c"; or set c 80
    test $c -lt 40; and set c 40
    echo $c
end

# ================================================================ folders
# Everything tracked is saved in the notes under the same path it has in your home folder:
#   Backup/<path>                     restored on every machine   (~/Downloads/clean.py -> Backup/Downloads/clean.py)
#   Desktop Environment/<DE>/<path>   restored only when that desktop is chosen in initual-setup.sh
function build_dir_items
    set -g items_key
    set -g items_alt
    set -g items_label
    set -g items_sec
    set -g items_inst
    set -g items_live      # the live path of each item
    set -g items_base      # the file or folder name of each item
    set -g items_cur       # the name of your own (name=ALIAS), empty when there is none
    set -g items_shown     # what the NAME column shows: the name of your own, else the file or folder name
    set -g items_pshow     # what the PATH column shows
    set -g items_noun "folders and files"
    set -g items_foot ""
    set -l wheres
    set -l ostrs
    # a name with spaces must not split into words when the lists are searched for a name
    set -l nbsp \u00a0
    set -l wn (string length -- NAME)
    set -l wp (string length -- PATH)
    set -l ww 26
    for line in (tracked_list $dirfile)
        set -l p (string split \t -- $line)
        set -l o ""
        set -q p[3]; and set o $p[3]
        # the name of your own is an option on the line; it is not repeated in the OPTIONS column
        set -l nick ""
        set -l kept
        for t in (string split -n ' ' -- $o)
            if string match -q -- 'name=*' $t
                set nick (alias_decode (string replace -- 'name=' '' $t))
            else
                set -a kept $t
            end
        end
        # file or folder? The live path says; when it is missing here, the copy in the notes does
        set -l is_dir 1
        if test -e $p[1] -o -L $p[1]
            test -d $p[1]; or set is_dir 0
        else if test -e $notes/$p[2] -o -L $notes/$p[2]
            test -d $notes/$p[2]; or set is_dir 0
        end
        # a folder shows its own path, a file the folder it sits in
        set -l base (basename -- $p[1])
        set -l pshow $p[1]
        test $is_dir -eq 0; and set pshow (dirname -- $p[1])
        if test "$pshow" = "$HOME"
            set pshow '~'
        else
            set pshow (string replace -- "$HOME/" '~/' $pshow)
        end
        set -l shown $base
        test -n "$nick"; and set shown $nick

        set -l where $layout_backup
        set -l d (de_of_name $p[2])
        test -n "$d"; and set where "DE: $d"
        set -l tg
        set -q p[3]; and set tg (de_tags (string split -n ' ' -- $p[3]))
        test (count $tg) -gt 0; and set where "$layout_backup: "(string join ',' $tg)
        string match -q -- "$layout_system/*" $p[2]; and set where "System (sudo)"
        string match -q -- "$layout_system/*" $p[2]; and test (count $tg) -gt 0; and set where "System (sudo): "(string join ',' $tg)
        tracked_name_ok $p[2]; or set where "(old layout)"
        set -l mark ""
        test -e $p[1] -o -L $p[1]; or set mark "  (missing on this machine)"
        set -l ostr (string join ' ' -- $kept)

        set -a items_key $p[2]
        set -a items_alt "$(string replace -a ' ' $nbsp -- "$nick")"
        set -a items_live $p[1]
        set -a items_base $base
        set -a items_cur "$nick"
        set -a items_shown $shown
        set -a items_pshow $pshow
        set -a wheres $where
        set -a ostrs "$ostr$mark"

         # column widths follow the longest entry (a very long one does not stretch the table)
        set -l l (string length -- $shown)
        test $l -gt $wn -a $l -le 32; and set wn $l
        set l (string length -- $pshow)
        test $l -gt $wp -a $l -le 48; and set wp $l
        set l (string length -- $where)
        test $l -gt $ww; and set ww $l
    end

    # fit the terminal: 7 characters go to the "  12) " prefix, 6 to the gaps between columns.
    # Shrink OPTIONS first, then PATH, NAME and WHERE, never below a minimum.
    set -l avail (math (term_cols) - 13)
    set -l wo 7
    for o in $ostrs
        set -l len (string length -- $o)
        test $len -gt $wo; and set wo $len
    end
    set -l over (math $wn + $wp + $ww + $wo - $avail)
    set -l cut (math "min($over, $wo - 10)")
    if test $cut -gt 0
        set wo (math $wo - $cut)
        set over (math $over - $cut)
    end
    set cut (math "min($over, $wp - 12)")
    if test $cut -gt 0
        set wp (math $wp - $cut)
        set over (math $over - $cut)
    end
    set cut (math "min($over, $wn - 10)")
    if test $cut -gt 0
        set wn (math $wn - $cut)
        set over (math $over - $cut)
    end
    set cut (math "min($over, $ww - 12)")
    if test $cut -gt 0
        set ww (math $ww - $cut)
    end

    set -l fmt "%-"$wn"s  %-"$wp"s  %-"$ww"s  %s"
    set -g items_header (printf $fmt NAME PATH WHERE OPTIONS)
    for i in (seq (count $items_key))
        set -a items_label (printf $fmt \
            "$(string shorten -m $wn -- $items_shown[$i])" \
            "$(string shorten -l -m $wp -- $items_pshow[$i])" \
            "$(string shorten -m $ww -- $wheres[$i])" \
            "$(string shorten -m $wo -- $ostrs[$i])")
    end
end

# gitignore_add PATTERN : append PATTERN to $notes/.gitignore on its own line.
# Creates the file if missing, never glues onto the last line, skips duplicates.
function gitignore_add
    set -l gi $notes/.gitignore
    test -f $gi; or touch $gi
    grep -qxF -- $argv[1] $gi; and return 0
    # last character is not a newline: add one first
    if test -s $gi; and test (tail -c1 $gi | wc -l) -eq 0
        echo >>$gi
    end
    echo $argv[1] >>$gi
end

# ---------------------------------------------------------------- folder listing
# tree_show DIR : print what is inside DIR as a tree, like `eza --tree -a` (names only, hidden files
# and folders included), so it is clear what is about to be backed up. It does not need eza.
# A .git folder is shown but not opened, symlinked folders are not followed, and a very long
# listing stops after $tree_max lines (the list of ignored paths uses the same limit).
set -g tree_max 400
set -g tree_lines 0
set -g tree_cut 0

function tree_walk
    set -l dir $argv[1]
    set -l prefix $argv[2]
    set -l items
    for x in (command ls -A -- $dir 2>/dev/null)
        set -l skip 0
        for e in $gi_excl
            string match -q -- "*/$e" "$dir/$x"; and set skip 1
        end
        test $skip -eq 0; and set -a items $x
    end
    set -l n (count $items)
    for i in (seq $n)
        if test $tree_lines -ge $tree_max
            set -g tree_cut 1
            return 0
        end
        set -l it $items[$i]
        set -l full $dir/$it
        set -l branch "├── "
        set -l pad "│   "
        if test $i -eq $n
            set branch "└── "
            set pad "    "
        end
        set -g tree_lines (math $tree_lines + 1)
        printf '%s' "$prefix$branch"
        if test -L $full
            set_color cyan
            printf '%s' "$it"
            set_color normal
            echo " -> "(readlink -- $full)
        else if test -d $full
            set_color --bold blue
            printf '%s' "$it"
            set_color normal
            if test "$it" = .git
                echo "  (not opened)"
            else
                echo
                tree_walk $full "$prefix$pad"
            end
        else
            printf '%s\n' "$it"
        end
    end
end

function tree_show
    set -l dir $argv[1]
    test -d $dir -a ! -L $dir; or return 0 
    set -g tree_lines 0
    set -g tree_cut 0
    echo
    set_color --bold
    echo (string replace -- "$HOME/" '~/' $dir)
    set_color normal
    tree_walk $dir ""
    if test $tree_cut -eq 1
        echo "  ... stopped after $tree_max lines ("(find $dir -mindepth 1 $gi_xf | count)" items in all)"
    end
    test $tree_lines -eq 0; and echo "  (empty)"
    return 0
end

# ---------------------------------------------------------------- partial .gitignore for a folder
# gi_esc TEXT : put a backslash before the characters .gitignore treats as wildcards, so a real
# file or folder name is matched literally (the wildcards the user typed are NOT escaped)
function gi_esc
    set -l s "$argv[1]"
    for ch in '\\' '*' '?' '['
        set s (string replace -a -- $ch "\\$ch" "$s")
    end
    printf '%s\n' "$s"
end

# gi_whole P NAME : keep the whole folder out of git
function gi_whole
    set -l p $argv[1]
    set -l name $argv[2]
    set -l ig "/"(gi_esc $name)"/"
    gitignore_drop_folder $name
    gitignore_add $ig
    info "git will ignore $ig (the whole folder)"
    echo "  "(find $p -mindepth 1 $gi_xf | count)" items inside, all of them ignored by git"
    # already committed earlier? stop tracking it (files stay on disk)
    if test -d $notes/.git; and git -C $notes ls-files --error-unmatch -- $name >/dev/null 2>&1
        git -C $notes rm -r -q --cached -- $name
        info "git: stopped tracking $name (the next sync commits that)"
    end
    return 0
end

# gi_find P NAME MODE : the paths (from the folder P) of the files and folders called NAME, one per
# line. exact = the name matches exactly, anywhere under P. partial = NAME appears inside another
# name (any letter case). Anything inside a .git folder is left out.
function gi_find
    set -l p $argv[1]
    set -l pat $argv[2]
    set -l how -name
    if test "$argv[3]" = partial
        set pat "*$argv[2]*"
        set how -iname
    end
    find $p -mindepth 1 -not -path '*/.git/*' $gi_xf $how $pat -printf '%P\n' | sort
end

# gi_split REPLY P : the words of an answer, one per line. With a comma the commas split; without one the
# spaces do, unless the whole answer is the name of something inside the folder P (a file called
# "Pokemon - HeartGold Version (USA).nds" stays one word).
function gi_split
    set -l r (string trim -- $argv[1])
    test -n "$r"; or return 0
    if test -n "$argv[2]"; and string match -q '* *' -- $r; and begin; test -e "$argv[2]/$r"; or test (gi_find $argv[2] $r exact | count) -gt 0; end
        echo $r
    else if string match -qr '(^|[\s,])[\x27\x22]' -- $r
        string match -ar -- '\x27[^\x27]*\x27|\x22[^\x22]*\x22|[^\s,]+' $r
    else if string match -q '*,*' -- $r
        string split -n , -- $r
    else
        string split -n ' ' -- $r
    end
end

# gi_rel P T : what T (typed by the user) means as a path from the folder P. Nothing, status 1, when it is
# not inside P.
function gi_rel
    set -l p $argv[1]
    set -l t (string trim -- $argv[2])
    set t (string trim -c "'\"" -- $t)
    test -n "$t"; or return 1
    set -l rel (string replace -r -- '^~' "$HOME" $t)
    if string match -q -- "$p/*" $rel
        set rel (string sub -s (math (string length -- "$p/") + 1) -- $rel)
    end
    set rel (string replace -r -- '^(\./)+' '' $rel)
    set rel (string trim -r -c / -- $rel)
    test -n "$rel"; or return 1
    string match -q -- '/*' $rel; and return 1
    string match -qr '(^|/)\.\.(/|$)' -- $rel; and return 1
    echo $rel
end

# gi_under REL DIR... : REL sits inside one of the DIRs ("." = the whole tracked folder). Prints the deepest one.
function gi_under
    set -l rel $argv[1]
    set -e argv[1]
    set -l best ""
    set -l bl -1
    for d in $argv
        set -l cl (string length -- $d)
        test "$d" = .; and set cl 0
        if test "$d" = .; or string match -q -- "$d/*" $rel
            if test $cl -gt $bl
                set best $d
                set bl $cl
            end
        end
    end
    test $bl -ge 0; or return 1
    echo $best
end

# gi_keep_lines P BASE DIR KEEP... : the .gitignore lines that leave DIR out of git except the KEEP paths
# (paths from the tracked folder P, all inside DIR; DIR "." = the whole folder). A folder that is ignored
# as a whole cannot have anything inside it brought back, so it is ignored by its contents (DIR/*) and
# every folder on the way to a kept path is let through first (!DIR/a/ then DIR/a/*).
function gi_keep_lines
    set -l p $argv[1]
    set -l base $argv[2]
    set -l dir $argv[3]
    set -e argv[1 2 3]
    if test "$dir" = .
        echo "$base/*"
    else
        echo "$base/"(gi_esc $dir)"/*"
    end
    for k in $argv
        set -l rest $k
        test "$dir" != .; and set rest (string sub -s (math (string length -- "$dir/") + 1) -- $k)
        set -l parts (string split / -- $rest)
        set -l acc ""
        test "$dir" != .; and set acc $dir
        for i in (seq (math (count $parts) - 1))
            if test -n "$acc"
                set acc "$acc/$parts[$i]"
            else
                set acc $parts[$i]
            end
            echo "!$base/"(gi_esc $acc)"/"
            echo "$base/"(gi_esc $acc)"/*"
        end
        if test -d $p/$k -a ! -L $p/$k
            echo "!$base/"(gi_esc $k)"/"
        else
            echo "!$base/"(gi_esc $k)
        end
    end
end

# gitignore_drop_folder NAME : remove the .gitignore lines of the tracked folder NAME (e.g. Backup/Games): the
# line /NAME, /NAME/..., and the ! lines under it. Lines of another tracked entry nested inside it
# (Backup/Games/Roms) and comments are left alone.
function gitignore_drop_folder
    set -l gi $notes/.gitignore
    test -f $gi; or return 0
    set -l base "/"(gi_esc $argv[1])
    set -l nested
    for line in (tracked_list $dirfile)
        set -l t (string split \t -- $line)
        string match -q -- "$argv[1]/*" $t[2]; and set -a nested "/"(gi_esc $t[2])
    end
    set -l out
    set -l dropped 0
    for l in (cat $gi)
        set -l body (string trim -- "$l")
        string match -q -- '!*' "$body"; and set body (string sub -s 2 -- "$body")
        set -l mine 0
        if test "$body" = "$base"; or string match -q -- "$base/*" "$body"
            set mine 1
            for nb in $nested
                if test "$body" = "$nb"; or string match -q -- "$nb/*" "$body"
                    set mine 0
                end
            end
        end
        if test $mine -eq 1
            set dropped (math $dropped + 1)
        else
            set -a out "$l"
        end
    end
    test $dropped -gt 0; or return 0
    if test (count $out) -gt 0
        printf '%s\n' $out >$gi.tmp
    else
        true >$gi.tmp
    end
    mv $gi.tmp $gi
    info ".gitignore: removed $dropped old rule(s) for $argv[1] (replaced by your new answer)"
end

# gitignore_remove LINE : take that exact line out of $notes/.gitignore
function gitignore_remove
    set -l gi $notes/.gitignore
    test -f $gi; or return 0
    grep -vxF -- $argv[1] $gi >$gi.tmp
    mv $gi.tmp $gi
    return 0
end

# gi_ext_hits P EXT : the files (paths from P) of that type, any depth, one per line. .git is left out.
function gi_ext_hits
    find $argv[1] -not -path '*/.git/*' $gi_xf \( -type f -o -type l \) -iname "*.$argv[2]" -printf '%P\n' | sort
end

# gi_resolve P T REL [VERB] : find out which path(s) inside the folder P the user means by REL (T is what
# they typed, REL the same relative to the folder). Sets the global $gi_picked (paths from P) and
# $gi_unpicked (matches that were listed but not picked).
#   - a path that exists (data/cache.db) is taken as it is
#   - a name is searched for anywhere under P: one hit is used, several are listed to pick from
#   - when nothing has that exact name, files and folders with a similar name are offered
# No tree: just the paths. Status 1 = nothing picked.
function gi_resolve
    set -l p $argv[1]
    set -l t $argv[2]
    set -l rel $argv[3]
    set -l act "NOT track"
    set -q argv[4]; and set act "KEEP tracking"
    set -l shown (string replace -- "$HOME/" '~/' $p)
    set -g gi_picked
    set -g gi_unpicked

    if string match -q '*/*' -- $rel; and test -e $p/$rel -o -L $p/$rel
        set -g gi_picked $rel
        return 0
    end

    set -l name (string replace -r -- '^.*/' '' $rel)
    set -l hits (gi_find $p $name exact)
    set -l n_exact (count $hits)

    # other names that only CONTAIN the word (test -> test_subject.sav) are offered too
    set -l similar
    if not string match -q '*/*' -- $rel; and not string match -qr '[*?\[]' -- $name
        for s in (gi_find $p $name partial)
            contains -- $s $hits; or set -a similar $s
        end
    end

    set -l head ""
    if string match -q '*/*' -- $rel
        test $n_exact -gt 0; and set head "'$t' is not there, but '$name' exists elsewhere in $shown:"
    else if test $n_exact -eq 1 -a (count $similar) -eq 0
        set -g gi_picked $hits
        info "found: $hits[1]"
        return 0
    else if test $n_exact -ge 1
        set head "'$name': $n_exact exact match(es), and "(count $similar)" more that contain it:"
    end

    if test $n_exact -eq 0
        set hits (gi_find $p $name partial)
        if test (count $hits) -eq 0
            warn "'$t' was not found inside $shown, skipped"
            return 1
        end
        set head "Nothing is called '$name' in $shown. Possible matches:"
        set similar
    end

    set -l all $hits $similar
    set -l cap 30
    set -l total (count $all)
    test $total -gt $cap; and set all $all[1..$cap]
    echo
    echo $head
    for i in (seq (count $all))
        set -l kind file
        test -L $p/$all[$i]; and set kind link
        test -d $p/$all[$i] -a ! -L $p/$all[$i]; and set kind folder
        set -l tag ""
        set -l star " "
        if test $i -le $n_exact
            set tag ", exact name"
            set star "*"
        end
        printf ' %s%3d) %s   (%s%s)\n' $star $i $all[$i] $kind $tag
    end
    test $total -gt $cap; and echo "  ... $total matches, only the first $cap are shown (type a longer name to narrow it down)"
    echo "  Pick the ones git should $act:"
    set -l enter skip
    test $n_exact -gt 0; and set enter "the * one(s)"
    ask "Choose (number(s) or all; Enter = $enter): "; or return 1

    set -l idx
    if test -z "$reply"
        if test $n_exact -eq 0
            echo "  skipped '$t'"
            return 1
        end
        set idx (seq $n_exact)
    else
        set idx (parse_selection (string replace -ra '\s+' ',' -- $reply) (count $all)); or return 1
    end
    for k in $idx
        set -a gi_picked $all[$k]
    end
    # the matches that were not picked: they stay tracked, unless a folder that is left out holds them
    for k in (seq (count $all))
        contains -- $k $idx; or set -a gi_unpicked $all[$k]
    end
    return 0
end

# gi_report P NAME : list the files git will NOT track and the ones it keeps tracking. Reads the globals
# $gi_r_dirs (folders left out whole, "." = the whole folder), $gi_r_files (single files and file types)
# and $gi_r_kept. Sets $gi_r_n to the number of files left out.
function gi_report
    set -l p $argv[1]
    set -l name $argv[2]
    set -l cap 60
    set -l out
    for d in $gi_r_dirs
        set -l root $p
        test "$d" != .; and set root $p/$d
        set -l found (find $root -mindepth 1 -not -path '*/.git/*' $gi_xf \( -type f -o -type l \) -print | sort)
        test (count $found) -gt 0; and set -a out (string replace -- "$p/" "" $found)
    end
    for f in $gi_r_files
        set -a out $f
    end
    if test (count $out) -gt 0
        set out (printf '%s\n' $out | sort -u)
        for k in $gi_r_kept
            test (count $out) -gt 0; or break
            set out (printf '%s\n' $out | grep -vxF -- $k)
        end
    end

    set -l n (count $out)
    set -g gi_r_n $n
    echo
    set_color --bold
    echo "Git will NOT track $n file(s):"
    set_color normal
    test $n -eq 0; and echo "  (nothing matches yet; files that appear later will be skipped)"
    set -l i 0
    for f in $out
        set i (math $i + 1)
        test $i -gt $cap; and break
        echo "  $name/$f"
    end
    test $n -gt $cap; and echo "  ... and "(math $n - $cap)" more"
    if test (count $gi_r_kept) -gt 0
        echo
        set_color --bold
        echo "Git KEEPS tracking:"
        set_color normal
        for k in $gi_r_kept
            echo "  $name/$k"
        end
    end
    echo
    echo "Everything else in the folder stays tracked."
end

# git_ignore_dir P NAME : P is the live folder, NAME its place in the notes. Asks what to keep out
# of git. Nothing typed = the whole folder. Otherwise each answer becomes lines in .gitignore:
#   *.log        every folder (also P itself) that holds .log files gets its own line, with that
#                folder's path:  /NAME/sub/dir/*.log   (so folders without such files are not touched)
#   logs/*.log   /NAME/logs/*.log
#   cache.db     searched for by name; every path you pick is written:  /NAME/data/cache.db
#   data/.venv   /NAME/data/.venv/      (a path from the folder that exists is taken as it is)
# Afterwards every folder and file that is ignored is listed.
function git_ignore_dir
    set -l p $argv[1]
    set -l name $argv[2]
    set -l shown (string replace -- "$HOME/" '~/' $p)
    set -l base "/"(gi_esc $name)

    # patterns the backup skips (exclude=...): hidden from the tree and from every search below
    set -g gi_excl
    set -q argv[3]; and set gi_excl $argv[3..-1]
    set -g gi_xf
    for e in $gi_excl
        set -a gi_xf -not -path "*/$e" -not -path "*/$e/*"
    end

    # the folder is listed here (only a folder, never a single file), so the answer can refer to it
    tree_show $p

    set -l lines        # the lines for .gitignore
    set -l ign_dirs     # folders (from the tracked folder) that are ignored whole
    set -l ign_files    # files (from the tracked folder) that are ignored
    set -l plan         # what each word was understood as, shown before anything is written
    set -l old_lines    # lines of an earlier run that the new ones replace
    set -l kept_all     # what is kept tracked inside the left-out folders and types
    while true
        set old_lines
        set kept_all
        set lines
        set ign_dirs
        set ign_files
        set plan
        set -l skipped_hits   # matches of a name that were not picked
        set -l type_pats      # the file types left out: "folder|pattern"
        set -l whole 0
        set -l keep_words
        echo
        echo "Choose files/directories to get EXCLUDED from git (they are still copied into the notes directory)"
        echo "  Separate with spaces or commas. Use 'quotes' for names with spaces."
        echo "    png jpg      every file of that type"
        echo "    cache.db     a file or folder with that name (searched in the folder)"
        echo "    logs/*.log   a path inside the folder"
        ask "EXCLUDE (names, *.ext or paths; Enter = the whole folder, q = cancel): "; or return 1
        test "$reply" = q; and return 1

        set -l words (string split -n ' ' -- (string replace -a , ' ' -- $reply))
        set -l toks
        if test -z "$reply"; or contains -- . $words
            # the whole folder; but something inside it may still be wanted in git
            ask "Whole folder not tracked. Exceptions git should still track? (names or paths; Enter = none): "; or return 1
            if test -z "$reply"
                gi_whole $p $name
                return 0
            end
            set whole 1
            set keep_words (gi_split $reply $p)
        else
            set toks (gi_split $reply $p)
        end

        # 1) what does each word mean? a path from the folder; a bare word that is a file type
        #    (png, .png) becomes *.png when no file or folder has exactly that name
        set -l w_t
        set -l w_rel
        for t in $toks
            set t (string trim -- $t)
            set t (string trim -c "'\"" -- $t)
            test -n "$t"; or continue
            set -l rel (string replace -r -- '^~' "$HOME" $t)
            if string match -q -- "$p/*" $rel
                set rel (string sub -s (math (string length -- "$p/") + 1) -- $rel)
            end
            set rel (string replace -r -- '^(\./)+' '' $rel)
            set rel (string trim -r -c / -- $rel)
            if test -z "$rel"; or string match -q -- '/*' $rel; or string match -qr '(^|/)\.\.(/|$)' -- $rel
                warn "'$t' is not inside $shown, skipped"
                continue
            end
            set -l as_name 1
            set -l ext ""
            if string match -qr -- '^\.[A-Za-z0-9]+$' $rel; and test (gi_find $p $rel exact | count) -eq 0
                set ext (string replace -- . '' $rel)        # .png
                set as_name 0
            else if string match -qr -- '^[A-Za-z0-9]+$' $rel
                set -l nm (gi_find $p $rel exact | count)
                set -l ec (gi_ext_hits $p $rel | count)
                if test $nm -eq 0 -a $ec -gt 0
                    set ext $rel                              # png
                    set as_name 0
                else if test $nm -gt 0 -a $ec -gt 0
                    echo
                    echo "'$rel' is the name of $nm file/folder(s) and also the type of $ec file(s) (*.$rel)."
                    ask "  n = the name(s), t = the *.$rel files, b = both (Enter = n): "; or return 1
                    switch (string lower -- $reply)
                        case t
                            set ext $rel
                            set as_name 0
                        case b
                            set ext $rel
                    end
                end
            end
            if test $as_name -eq 1
                set -a w_t $t
                set -a w_rel $rel
            end
            if test -n "$ext"
                set -a w_t $t
                set -a w_rel "*.$ext"
            end
        end

        # 2) folders and names first, then the types: files that sit inside a folder that is
        #    ignored whole need no line of their own
        set -l order
        for i in (seq (count $w_rel))
            string match -qr '[*?\[]' -- $w_rel[$i]; or set -a order $i
        end
        for i in (seq (count $w_rel))
            string match -qr '[*?\[]' -- $w_rel[$i]; and set -a order $i
        end

        for i in $order
            set -l t $w_t[$i]
            set -l rel $w_rel[$i]
            set -l dpart ""
            set -l bpart $rel
            if string match -q '*/*' -- $rel
                set dpart (string replace -r -- '/[^/]*$' '' $rel)
                set bpart (string replace -r -- '^.*/' '' $rel)
            end
            if string match -qr '[*?\[]' -- $dpart
                warn "'$t': wildcards work only in the file part (like logs/*.log), skipped"
                continue
            end

            if string match -qr '[*?\[]' -- $bpart
                # a type of file
                if test -n "$dpart"
                    # logs/*.log : only that folder
                    if not test -d $p/$dpart -a ! -L $p/$dpart
                        warn "'$t': there is no folder '$dpart' inside $shown, skipped"
                        continue
                    end
                    set -l found (find $p/$dpart -maxdepth 1 \( -type f -o -type l \) -name $bpart -printf '%f\n' | sort)
                    test (count $found) -eq 0; and warn "'$t': no file matches yet, the rule is added anyway"
                    for f in $found
                        set -a ign_files "$dpart/$f"
                    end
                    set -l ln "$base/"(gi_esc $dpart)"/$bpart"
                    contains -- $ln $lines; or set -a lines $ln
                    set -a type_pats "$dpart|$bpart"
                    set -a plan (printf '  %-14s every %s in %s/  (%s file(s))' $t $bpart $dpart (count $found))
                else
                    # *.png : every folder that holds such files, each recorded with its own path
                    set -l files
                    for f in (find $p \( -type f -o -type l \) -not -path '*/.git/*' $gi_xf -name $bpart -printf '%P\n' | sort)
                        set -l covered 0
                        for d in $ign_dirs
                            string match -q -- "$d/*" $f; and set covered 1
                        end
                        test $covered -eq 0; and set -a files $f
                    end
                    if test (count $files) -eq 0
                        warn "'$t': nothing to add (no such file, or already inside a folder you left out)"
                        continue
                    end
                    set -l rdirs
                    for f in $files
                        set -a ign_files $f
                        set -l rd ""
                        string match -q '*/*' -- $f; and set rd (string replace -r -- '/[^/]*$' '' $f)
                        contains -- "$rd" $rdirs; or set -a rdirs "$rd"
                    end
                    for rd in $rdirs
                        set -l ln "$base/$bpart"
                        test -n "$rd"; and set ln "$base/"(gi_esc $rd)"/$bpart"
                        contains -- $ln $lines; or set -a lines $ln
                    end
                    set -a type_pats "|$bpart"
                    set -a plan (printf '  %-14s every %s  (%s file(s) in %s folder(s))' $t $bpart (count $files) (count $rdirs))
                end
            else
                # one file or one folder: search for the name, and pick when it is in several places
                gi_resolve $p $t $rel; or continue
                set -a skipped_hits $gi_unpicked
                for r in $gi_picked
                    set -l ln "$base/"(gi_esc $r)
                    if test -d $p/$r -a ! -L $p/$r
                        set ln "$ln/"
                        set -a ign_dirs $r
                        set -a plan (printf '  %-14s folder %s/  (%s items)' $t $r (find $p/$r -mindepth 1 | count))
                    else
                        set -a ign_files $r
                        set -a plan (printf '  %-14s file   %s' $t $r)
                    end
                    contains -- $ln $lines; or set -a lines $ln
                end
            end
        end

        # a folder inside another folder that is ignored whole needs no line of its own
        set -l inner
        for d in $ign_dirs
            set -l nested 0
            for e in $ign_dirs
                test "$e" != "$d"; and string match -q -- "$e/*" $d; and set nested 1
            end
            test $nested -eq 1; or continue
            set -a inner $d
            set -l ln "$base/"(gi_esc $d)"/"
            set -l keep
            for l in $lines
                test "$l" != "$ln"; and set -a keep $l
            end
            set lines $keep
            set -a plan "                 ($d/ is inside a folder that is ignored whole, no line of its own)"
        end
        if test (count $inner) -gt 0
            set -l outer
            for d in $ign_dirs
                contains -- $d $inner; or set -a outer $d
            end
            set ign_dirs $outer
        end

        test $whole -eq 1; and set ign_dirs .

        # 3) what should still be tracked inside what is left out? A folder that is left out whole holds
        #    its files too, so something kept in it needs the folder to be ignored by its contents instead.
        set -l keeps
        set -l auto
        for u in (printf '%s\n' $skipped_hits | sort -u)
            test -n "$u"; or continue
            gi_under $u $ign_dirs >/dev/null; and set -a auto $u
        end
        if test (count $auto) -gt 0
            echo
            echo "You did not pick these, but they are inside a folder git will not track, so they would be skipped too:"
            printf '    %s\n' $auto
            yes_no "Make git track them anyway?" y; and set -a keeps $auto
        end
        set -l kw $keep_words
        if test $whole -eq 0
            echo
            ask "Any exceptions git should still track? (names or paths; Enter = none): "; or return 1
            set kw (gi_split $reply $p)
        end
        for t in $kw
            set -l krel (gi_rel $p $t); or begin
                warn "'$t' is not inside $shown, skipped"
                continue
            end
            gi_resolve $p $t $krel "KEEP tracked"; or continue
            for r in $gi_picked
                contains -- $r $keeps; or set -a keeps $r
            end
        end

        set -l tail          # ! lines for files of a left-out type
        set kept_all $keeps
        if test (count $keeps) -gt 0
            set -l by_dir    # "dir|path" pairs
            set -l real      # exceptions that really change something
            set -l already   # exceptions that git tracks anyway
            for k in $keeps
                # left out by name AND an exception: the exception wins, its own ignore line goes
                set -l own "$base/"(gi_esc $k)
                if contains -- $own $lines
                    set -l nl
                    for l in $lines
                        test "$l" != "$own"; and set -a nl $l
                    end
                    set lines $nl
                    set -l nf
                    for f in $ign_files
                        test "$f" != "$k"; and set -a nf $f
                    end
                    set ign_files $nf
                    set -a real $k
                    set -a plan (printf '  %-14s KEEP   %s  (also left out by name: tracked)' keep $k)
                    continue
                end
                set -l d (gi_under $k $ign_dirs)
                if test $status -eq 0
                    set -a by_dir "$d|$k"
                    set -a plan (printf '  %-14s KEEP   %s' keep $k)
                    set -a real $k
                    continue
                end
                # not in a left-out folder: is it a file of a left-out type?
                set -l hit 0
                for tp in $type_pats
                    set -l tpd (string split -m1 '|' -- $tp)[1]
                    set -l tpb (string split -m1 '|' -- $tp)[2]
                    set -l kd ""
                    string match -q '*/*' -- $k; and set kd (string replace -r -- '/[^/]*$' '' $k)
                    if string match -q -- $tpb (string replace -r -- '^.*/' '' $k); and begin; test -z "$tpd"; or test "$tpd" = "$kd"; end
                        set hit 1
                    end
                end
                if test $hit -eq 1
                    set -l ln "!$base/"(gi_esc $k)
                    contains -- $ln $tail; or set -a tail $ln
                    set -a plan (printf '  %-14s KEEP   %s' keep $k)
                    set -a real $k
                else
                    set -a already $k
                end
            end
            set kept_all $real
            test (count $already) -gt 0; and info (count $already)" exception(s) are not left out by anything above, git tracks them anyway"
            for d in $ign_dirs
                set -l ks
                for bp in $by_dir
                    set -l bd (string split -m1 '|' -- $bp)[1]
                    test "$bd" = "$d"; and set -a ks (string split -m1 '|' -- $bp)[2]
                end
                test (count $ks) -gt 0; or continue
                # the plain "folder/" line (from this run or an earlier one) is replaced by folder/* and the ! lines
                if test "$d" != .
                    set -l old "$base/"(gi_esc $d)"/"
                    set -l nl
                    for l in $lines
                        test "$l" != "$old"; and set -a nl $l
                    end
                    set lines $nl
                    set -a old_lines $old
                end
                for l in (gi_keep_lines $p $base $d $ks)
                    contains -- $l $lines; or set -a lines $l
                end
            end
            for l in $tail
                contains -- $l $lines; or set -a lines $l
            end
        end

        if test (count $lines) -eq 0
            warn "nothing to add to .gitignore"
            return 1
        end
        set -g gi_r_dirs $ign_dirs
        set -g gi_r_files $ign_files
        set -g gi_r_kept $kept_all
        echo
        echo "What you typed was understood as:"
        printf '%s\n' $plan
        gi_report $p $name
        yes_no "Write these rules to .gitignore?" y; and break
        echo "  ok, type it again"
    end

    gitignore_drop_folder $name
    for ln in $lines
        gitignore_add $ln
    end
    echo
    info "written to $notes/.gitignore:"
    printf '    %s\n' $lines

    # files of this folder that were committed earlier and now match: stop tracking them (they stay on disk)
    if test -d $notes/.git
        set -l nt (git -C $notes ls-files -ci --exclude-standard -- ":(literal)$name" 2>/dev/null | count)
        if test $nt -gt 0
            git -C $notes ls-files -z -ci --exclude-standard -- ":(literal)$name" | xargs -0 -r git -C $notes rm -q --cached --
            info "git: stopped tracking $nt file(s) that now match (the next sync commits that)"
        end
    end

    info "git will not track $gi_r_n file(s) of $name"
    test (count $kept_all) -gt 0; and info "git keeps tracking "(count $kept_all)" file(s) inside it"
    return 0
end

function dir_list
    build_dir_items
    if test (count $items_key) -eq 0
        echo "No tracked folders yet. Add one with: sync-notes.sh dir add"
        return 0
    end
    # every word must match the path, the WHERE column or the options (so "mango", "sddm" or
    # "private exec" work); no words = show everything
    set -l words (string split -n ' ' -- (string replace -a , ' ' -- "$argv[1]"))
    echo
    printf '       %s\n' $items_header
    set -l shown 0
    for i in (seq (count $items_key))
        set -l ok 1
        for w in $words
            string match -qi -- "*$w*" "$items_label[$i]"; or set ok 0
        end
        test $ok -eq 1; or continue
        set shown (math $shown + 1)
        printf '  %3d) %s\n' $shown $items_label[$i]
    end
    echo
    echo "  $shown of "(count $items_key)" folders and files"
    echo
    echo "  (Backup = every machine; Backup: x = only desktop x; DE: x = only desktop x's folder)"
end

# de_mentions TEXT : the desktops whose files in the notes mention TEXT (a name like rofi), one per
# line. That is how the setup guesses which desktops use something shared.
function de_mentions
    for d in (de_dirs $notes)
        grep -rIqiF --exclude-dir=.git -- $argv[1] $notes/$layout_de/$d 2>/dev/null; and echo $d
    end
end

# choose_uses WORD [CURRENT...] : ask which desktops use something shared. Sets the global
# $picked_uses to their (lower case) names, or to nothing for "every machine". The desktops whose
# files mention WORD are marked and offered as the default. Status 1 when cancelled.
function choose_uses
    set -g picked_uses
    set -l word $argv[1]
    set -l cur
    set -q argv[2]; and set cur (string lower -- $argv[2..-1])
    set -l des (de_dirs $notes)
    set -l des_lc
    test (count $des) -gt 0; and set des_lc (string lower -- $des)
    set -l found
    set -l fl (de_mentions $word)
    test (count $fl) -gt 0; and set found (string lower -- $fl)
    set -l dflt $cur
    test (count $dflt) -eq 0; and set dflt $found

    echo
    echo "Which desktops use it?"
    for i in (seq (count $des))
        set -l mark ""
        contains -- $des_lc[$i] $found; and set mark "   <- their files mention '$word'"
        echo "  $i) $des[$i]$mark"
    end
    echo "  a) all of them (restored on every machine)"
    set -l dl all
    test (count $dflt) -gt 0; and set dl (string join ' ' -- $dflt)
    set -l hint "numbers or names"
    ask "Desktops ($hint; Enter = $dl): "; or return 1
    if test -z "$reply"
        set -g picked_uses $dflt
        return 0
    end
    for t in (string split -n ' ' -- (string replace -a , ' ' -- (string lower -- $reply)))
        if contains -- $t a all
            set -g picked_uses
            return 0
        else if string match -qr '^[0-9]+$' -- $t
            if test $t -ge 1 -a $t -le (count $des)
                contains -- $des_lc[$t] $picked_uses; or set -a picked_uses $des_lc[$t]
            else
                warn "no number $t in the list, ignored"
            end
        else if string match -qr '^[a-z][a-z0-9._-]*$' -- $t
            contains -- $t $des_lc; or warn "'$t' has no folder in $layout_de yet, used as typed"
            contains -- $t $picked_uses; or set -a picked_uses $t
        else
            warn "'$t' is not a desktop name, ignored"
        end
    end
    if test (count $picked_uses) -eq 0
        warn "no desktop picked"
        return 1
    end
end

# exclude_check P PAT : PAT is something the user does NOT want copied into the notes. tar matches the WHOLE
# name, so "not_sync" would only skip something called exactly not_sync. Checks PAT against the folder P and,
# when nothing has that exact name, lists similar files/folders to choose from.
# Sets the global list $ex_result (the patterns to use). Status 1 = skip this pattern.
function exclude_check
    set -l p $argv[1]
    set -l pat $argv[2]
    set -g ex_result $pat
    if string match -q '*/*' -- $pat
        string match -qr '[*?\[]' -- $pat; or test -e $p/$pat -o -L $p/$pat; or warn "'$pat' is not in the folder (kept, it applies if it appears)"
        return 0
    end
    set -l hits (find $p -mindepth 1 -not -path '*/.git/*' -name "$pat" -printf '%P\n' | sort)
    if test (count $hits) -gt 0
        echo "  '$pat' will NOT be copied ("(count $hits)" item(s)):"
        printf '    %s\n' $hits | head -n 5
        test (count $hits) -gt 5; and echo "    ... and "(math (count $hits) - 5)" more"
        return 0
    end
    if string match -qr '[*?\[]' -- $pat
        warn "'$pat' matches nothing yet (kept, it applies if such a file appears)"
        return 0
    end
    set -l near (find $p -mindepth 1 -not -path '*/.git/*' -iname "*$pat*" -printf '%P\n' | sort)
    if test (count $near) -eq 0
        warn "'$pat' matches nothing (kept, it applies if such a file appears)"
        return 0
    end
    set -l cap 30
    set -l total (count $near)
    test $total -gt $cap; and set near $near[1..$cap]
    echo "  Nothing is named exactly '$pat'. Similar:"
    for i in (seq (count $near))
        set -l kind file
        test -d $p/$near[$i] -a ! -L $p/$near[$i]; and set kind folder
        printf '  %3d) %s   (%s)\n' $i $near[$i] $kind
    end
    test $total -gt $cap; and echo "  ... $total matches, only the first $cap are shown"
    echo "  Which should NOT be copied?  number(s) or all"
    echo "    w = everything containing '$pat'    k = '$pat' exactly as typed    Enter = skip"
    ask "Choose: "; or return 1
    # a path typed in full is accepted as it is
    if contains -- $reply $near
        set -g ex_result $reply
        return 0
    end
    switch (string lower -- $reply)
        case ''
            return 1
        case w
            set -g ex_result "*$pat*"
        case k
            set -g ex_result $pat
        case '*'
            set -l idx (parse_selection (string replace -ra '\s+' ',' -- $reply) (count $near)); or return 1
            set -g ex_result
            for k in $idx
                set -ga ex_result $near[$k]
            end
    end
    return 0
end

function dir_add
    set -g gi_xf
    set -g gi_excl
    set -l p $argv[1]
    if test -z "$p"
        ask "Folder or file to back up (type the path, or drag it here): "; or return 1
        set p $reply
    end
    set p (string trim -c "'\"" -- $p)
    set p (string replace -r -- '^~' "$HOME" $p)
    test -n "$p"; or return 0
    if not test -e $p -o -L $p
        warn "does not exist: $p"
        return 1
    end
    set p (realpath -s $p)
    set -l why (tracked_unsafe $p $notes)
    if test -n "$why"
        warn "refused: $why"
        return 1
    end
    if string match -q '*|*' -- $p
        warn "refused: the path contains a | character"
        return 1
    end
    for line in (tracked_list $dirfile)
        set -l t (string split \t -- $line)
        if test "$t[1]" = "$p"
            warn "already tracked as '$t[2]'"
            return 1
        end
    end

    # outside the home folder (/etc, /usr/local/bin...): allowed, but it is a system file. Reading it
    # may need sudo, and restoring it on a new machine needs sudo and replaces what is there.
    set -l is_sys 0
    string match -q -- "$HOME/*" $p; or set is_sys 1
    if test $is_sys -eq 1
        echo
        warn "system file: copied to $layout_system/, restored with sudo (replaces what is there)"
        yes_no "Are you sure you want to back it up?" n; or begin
            echo "cancelled"
            return 1
        end
    end

    # where it goes: the notes mirror the live path, under Backup/ or under one desktop's folder.
    # A path named like an existing desktop (~/.config/mango, "mango") suggests that desktop.
    set -l def (basename $p)
    set -l guess (de_dir_name $notes $def)
    set -g picked_de ""
    # one question: is it only for some desktops? One desktop -> saved in that desktop's own folder
    # (restored only for it); several -> stays in Backup/ with a de= limit; none -> every machine.
    # A system file always stays under System/ (limited with de= when desktops are picked).
    set -l uses
    set -l hit
    test $is_sys -eq 0; and set hit (de_mentions $def)
    set -l ud n
    test -n "$guess" -o (count $hit) -gt 0; and set ud y
    if yes_no "Only for some desktops?" $ud
        choose_uses $def $guess; or begin
            echo "cancelled"
            return 1
        end
        if test $is_sys -eq 0 -a (count $picked_uses) -eq 1
            set -l ex (de_dir_name $notes $picked_uses[1])
            if test -n "$ex"
                set -g picked_de $ex
            else
                set -g picked_de $picked_uses[1]
            end
        else
            set uses $picked_uses
        end
    end
    set -l name (tracked_name_for $p $picked_de)
    if not tracked_name_ok $name
        warn "refused: '$name' is not allowed as a place in the notes"
        return 1
    end
    for line in (tracked_list $dirfile)
        set -l t (string split \t -- $line)
        if test "$t[2]" = "$name"
            warn "the place '$name' is already used by $t[1]"
            return 1
        end
    end
    info "it will be saved in the notes as: $name"
    if test -e $notes/$name
        warn "$notes/$name already exists; the sync will replace it with a copy of $p"
        yes_no "Continue?" n; or return 1
    end

    set -l opts
    yes_no "Can other users read it?" y; or set -a opts private
    yes_no "Make the file(s) executable?" n; and set -a opts exec
    if test $is_sys -eq 1
        # systemd unit: switch it on after restoring
        if string match -qr -- '/systemd/(system|user)/[^/]+\.(service|timer|socket|path|target)$' $p
            yes_no "Enable it (systemctl enable) after it is restored?" y; and set -a opts enable
        end
        # files that mention your home folder or user name: point them at the new machine's user
        set -l homes 0
        if test -d $p -a ! -L $p
            grep -rIlF -- "/home/" $p >/dev/null 2>&1; and set homes 1
        else
            grep -IlF -- "/home/" $p >/dev/null 2>&1; and set homes 1
        end
        if test $homes -eq 1
            yes_no "Rewrite /home/... to the new home and user when restored?" y; and set -a opts rehome
        end
    end
    echo "Choose files/directories to get EXCLUDED from the notes directory (git is asked about separately)"
    ask "EXCLUDE (names, *.ext or paths; Enter = copy everything): "; or return 1
    for pat in (gi_split "$reply" $p)
        set pat (string trim -c "'\"" -- (string trim -- $pat))
        test -n "$pat"; or continue
        set -l pats $pat
        if test -d $p -a ! -L $p
            exclude_check $p $pat; or continue
            set pats $ex_result
        end
        for x in $pats
            # the options are space separated, so a space in a name becomes ? (matches any one character)
            set -a opts "exclude="(string replace -a ' ' '?' -- $x)
        end
    end
    test (count $uses) -gt 0; and set -a opts "de="(string join ',' $uses)

    set -l shown (string replace -- "$HOME/" '~/' $p)
    set -l line "$shown | $name"
    test (count $opts) -gt 0; and set line "$line | "(string join ' ' $opts)
    set -l cur
    test -f $dirfile; and set cur (cat $dirfile)
    printf '%s\n' $cur "$line" >$dirfile
    info "now tracked: $line"
    # a new desktop gets its folder right away, so the setup already lists it
    if test -n "$picked_de"; and not test -d $notes/$layout_de/$picked_de
        mkdir -p $notes/$layout_de/$picked_de
        de_starter $notes/$layout_de/$picked_de/pre.fish pre $picked_de
        de_starter $notes/$layout_de/$picked_de/post.fish post $picked_de
        info "new desktop '$picked_de' created"
        echo "  Open pre.fish / post.fish if you want the setup to do anything extra for $picked_de:"
        echo "    pre.fish    runs BEFORE the configs are restored (install the desktop's packages...)"
        echo "    post.fish   runs AFTER they are restored (enable a service, manual steps...)"
        echo "  They are in: "(string replace -- "$HOME/" '~/' $notes)"/$layout_de/$picked_de/"
    end

    # keep it out of git? (separate from "secrets": the files are still copied into the
    # notes folder and the USB backup copy, git just never sees them)
    set -l gi_default n
    contains -- private $opts; and set gi_default y
    if yes_no "Keep (part of) it out of git? (it is still copied into the notes)" $gi_default
        if test -d $p -a ! -L $p
            # a folder: ask whether only some types / files / folders should be left out
            set -l exs
            for o in $opts
                string match -q -- 'exclude=*' $o; and set -a exs (string replace -- 'exclude=' '' $o)
            end
            git_ignore_dir $p $name $exs
        else
            set -l ig "/$name"
            test -d $p; and set ig "/$name/"
            gitignore_add $ig
            info "git will ignore $ig"
            # already committed earlier? stop tracking it (files stay on disk)
            if test -d $notes/.git; and git -C $notes ls-files --error-unmatch -- $name >/dev/null 2>&1
                git -C $notes rm -r -q --cached -- $name
                info "git: stopped tracking $name (the next sync commits that)"
            end
        end
    else
        # git may track everything: drop rules left by an earlier run for this path
        gitignore_drop_folder $name
    end
    if yes_no "Sync it now?" y
        fish $self --sync --no-git --quiet
    end
end

# prune_empty DIR : remove DIR and its parents while they are empty, never the notes folder itself
function prune_empty
    set -l d $argv[1]
    while test "$d" != "$notes" -a "$d" != / -a -d "$d"
        # a desktop's own folder is what defines the desktop: it stays even when it is empty
        test (dirname $d) = "$notes/$layout_de"; and break
        rmdir $d 2>/dev/null; or break
        set d (dirname $d)
    end
end

function dir_remove
    build_dir_items
    if test (count $items_key) -eq 0
        warn "no tracked folders"
        return 1
    end
    pick_items "Stop tracking which?"; or begin
        echo "cancelled"
        return 0
    end
    set -l names $items_key[$picked]
    echo
    echo "Stop tracking: $names"
    echo "(your live files are not touched)"
    yes_no "Continue?" y; or return 0
    for n in $names
        tracked_remove $dirfile $n
        info "no longer tracked: $n"
        set -l copy_gone 1
        if tracked_name_ok $n; and test -e $notes/$n -o -L $notes/$n
            set copy_gone 0
            if yes_no "Also delete the copy in the notes ($n)?" n
                rm -rf $notes/$n
                info "deleted $notes/$n"
                prune_empty (dirname $notes/$n)
                set copy_gone 1
            end
        end
        if test $copy_gone -eq 1
            tracked_name_ok $n; and gitignore_drop_folder $n
        else
            info "the copy stays in the notes, so its .gitignore rules stay too (they keep private files out of git)"
        end
    end
end

# dir_rename [ITEM [NEWNAME]] : give a tracked folder or file a name of your own (name=NAME on its line in
# tracked.conf). The NAME column of the lists shows it in place of the file or folder name. ITEM is
# that name, the old file or folder name, the live path or the place in the notes. "-" as the new
# name goes back to the file or folder name.
function dir_rename
    build_dir_items
    if test (count $items_key) -eq 0
        warn "nothing tracked"
        return 1
    end
    set -g picked
    set -l want $argv[1]
    if test -n "$want"
        set -l wl (string replace -r -- '^~' "$HOME" $want)
        for i in (seq (count $items_key))
            if test "$items_cur[$i]" = "$want" -o "$items_key[$i]" = "$want" -o "$items_live[$i]" = "$wl" -o "$items_base[$i]" = "$want"
                set -a picked $i
            end
        end
        if test (count $picked) -eq 0
            warn "not found: $want"
            return 1
        end
        if test (count $picked) -gt 1; and test -n "$argv[2]"
            warn "'$want' matches several: use the live path"
            for i in $picked
                echo "  $items_live[$i]"
            end
            return 1
        end
    else
        pick_items "Rename which?"; or begin
            echo "cancelled"
            return 0
        end
    end

    for i in $picked
        set -l place $items_key[$i]
        echo
        echo "  $items_base[$i]   ($items_pshow[$i])"
        test -n "$items_cur[$i]"; and echo "  now: $items_cur[$i]"
        set -l new (string trim -- "$argv[2]")
        if test -z "$new"
            ask "  new name ('-' = none, Enter = keep): "; or return 1
            set new $reply
        end
        test -n "$new"; or continue
        test "$new" = -; and set new ""
        # the file or folder name itself is what it shows without a name of your own
        test "$new" = "$items_base[$i]"; and set new ""
        if test -n "$new"
            if not alias_valid "$new"
                warn "not a usable name"
                continue
            end
            if test "$new" = "$items_cur[$i]"
                info "unchanged"
                continue
            end
            # the name has to point at one entry only
            set -l clash 0
            for j in (seq (count $items_key))
                test $j -eq $i; and continue
                test "$items_shown[$j]" = "$new"; and set clash 1
            end
            if test $clash -eq 1
                warn "'$new' is taken"
                continue
            end
        end
        if tracked_set_alias $dirfile $place "$new"
            set -g items_cur[$i] "$new"
            if test -n "$new"
                set -g items_shown[$i] $new
                info "$items_base[$i]: $new"
            else
                set -g items_shown[$i] $items_base[$i]
                info "$items_base[$i]: name removed"
            end
        else
            warn "failed: $items_base[$i]"
        end
    end
end

# tracked_entry PLACE : the tracked.conf entry saved at that place, as  live<TAB>place<TAB>options
function tracked_entry
    for line in (tracked_list $dirfile)
        set -l t (string split \t -- $line)
        if test "$t[2]" = "$argv[1]"
            echo $line
            return 0
        end
    end
    return 1
end

# dir_uses : choose which desktops use something shared. Pick one or several (1,3-5): the answer is
# applied to all of them. A Backup/ or System/ entry (rofi, sddm...) only gets a de= option and stays
# where it is; a thing that sits in one desktop's folder is moved to Backup/ first, so that more than one desktop can use it.
function dir_uses
    build_dir_items
    if test (count $items_key) -eq 0
        warn "nothing is tracked yet"
        return 1
    end
    set -g items_noun "things"
    pick_items "Which ones?"; or begin
        echo "cancelled"
        return 0
    end
    set -l keys $items_key[$picked]
    test (count $keys) -gt 0; or return 0

    # ---- tracked entries: one answer for all of them
    set -l first (string split \t -- (tracked_entry $keys[1]))
    set -l word (basename $first[1])
    test (count $keys) -gt 1; and set word (basename (dirname $first[1]))
    set -l cur
    set -q first[3]; and set cur (de_tags (string split -n ' ' -- $first[3]))
    set -l de1 (de_of_name $keys[1])
    test -n "$de1"; and set cur (string lower -- $de1)
    set -l in_de 0
    for k in $keys
        set -l dk (de_of_name $k)
        test -n "$dk"; and set in_de 1
    end
    echo
    if test (count $keys) -gt 1
        echo "These "(count $keys)" entries:"
        for k in $keys
            echo "  $k"
        end
    end
    if test $in_de -eq 1
        echo "Some are in a desktop's folder (restored only for it)."
        echo "To share them, their copies move to $layout_backup/."
    end
    choose_uses $word $cur; or return 0
    set -l uses $picked_uses
    set -l shown_uses all
    test (count $uses) -gt 0; and set shown_uses (string join ', ' $uses)

    for key in $keys
        set -l t (string split \t -- (tracked_entry $key))
        set -l live $t[1]
        set -l newname $key
        set -l dkey (de_of_name $key)
        if test -n "$dkey"
            set newname (tracked_name_for $live)
            if test -e $notes/$newname -o -L $notes/$newname
                warn "$notes/$newname already exists, $key left as it is"
                continue
            end
        end
        if test $dry -eq 1
            info "[dry-run] $key -> $newname, desktops: $shown_uses"
            continue
        end
        if test "$newname" != "$key"
            if test -e $notes/$key -o -L $notes/$key
                mkdir -p (dirname $notes/$newname); and mv $notes/$key $notes/$newname
                or begin
                    warn "could not move $key, left as it is"
                    continue
                end
                info "moved $key -> $newname"
                prune_empty (dirname $notes/$key)
            end
            # a .gitignore line for the old place follows it
            set -l gi $notes/.gitignore
            if test -f $gi
                set -l gl (cat $gi)
                set -l ch 0
                for k in (seq (count $gl))
                    switch (string trim -- $gl[$k])
                        case "/$key"
                            set gl[$k] "/$newname"
                            set ch 1
                        case "/$key/"
                            set gl[$k] "/$newname/"
                            set ch 1
                    end
                end
                test $ch -eq 1; and printf '%s\n' $gl >$gi; and info ".gitignore: the line for $key now points at $newname"
            end
        end
        tracked_update $dirfile $key $newname $uses
        info "$newname: restored for $shown_uses"
    end
end

# ---------------------------------------------------------------- add a desktop environment
# Desktops that are recognised from ~/.config: "name|config path(s) inside ~/.config".
set -g known_de_cfg \
    'hyprland|hypr' 'sway|sway' 'niri|niri' 'mango|mango' 'river|river' 'labwc|labwc' \
    'wayfire|wayfire.ini wayfire' 'i3|i3' 'bspwm|bspwm' 'awesome|awesome' 'qtile|qtile' \
    'openbox|openbox' 'xfce|xfce4' 'cinnamon|cinnamon' 'budgie|budgie-desktop' \
    'kde|kdeglobals kwinrc plasmarc kglobalshortcutsrc plasma-org.kde.plasma.desktop-appletsrc'
# configs that usually go with a desktop (bars, launchers, lock screens...), offered after it
set -g known_de_extra waybar rofi wofi fuzzel dunst mako swaync swaylock swayidle hyprlock hypridle \
    hyprpaper wlogout eww kanshi polybar picom sxhkd gtk-3.0 gtk-4.0 qt5ct qt6ct

# de_scan : "name<TAB>paths" for every known desktop that has config in ~/.config
function de_scan
    for e in $known_de_cfg
        set -l f (string split -m1 '|' -- $e)
        set -l have
        for r in (string split ' ' -- $f[2])
            test -e $cfg/$r -o -L $cfg/$r; and set -a have $r
        end
        test (count $have) -gt 0; and printf '%s\t%s\n' $f[1] (string join ' ' -- $have)
    end
end

# is_tracked LIVE : is this live path already in tracked.conf?
function is_tracked
    for line in (tracked_list $dirfile)
        set -l t (string split \t -- $line)
        test "$t[1]" = "$argv[1]"; and return 0
    end
    return 1
end

# track_add LIVE PLACE [OPTION...] : append an entry to tracked.conf, with the same checks as dir_add.
# Status 1 when it was refused or is already tracked.
function track_add
    set -l p $argv[1]
    set -l name $argv[2]
    set -l opts
    set -q argv[3]; and set opts $argv[3..-1]
    set p (realpath -s $p)
    set -l why (tracked_unsafe $p $notes)
    if test -n "$why"
        warn "refused: $why"
        return 1
    end
    if string match -q '*|*' -- $p
        warn "refused: the path contains a | character"
        return 1
    end
    if not tracked_name_ok $name
        warn "refused: '$name' is not allowed as a place in the notes"
        return 1
    end
    for line in (tracked_list $dirfile)
        set -l t (string split \t -- $line)
        if test "$t[1]" = "$p"
            info "already tracked: "(string replace -- "$HOME/" '~/' $p)" ($t[2])"
            return 1
        end
        if test "$t[2]" = "$name"
            warn "the place '$name' is already used by $t[1]"
            return 1
        end
    end
    set -l shown (string replace -- "$HOME/" '~/' $p)
    set -l line "$shown | $name"
    test (count $opts) -gt 0; and set line "$line | "(string join ' ' -- $opts)
    set -l cur
    test -f $dirfile; and set cur (cat $dirfile)
    printf '%s\n' $cur "$line" >$dirfile
    info "now tracked: $line"
end

# de_starter FILE KIND DE : a commented starter pre.fish / post.fish (it also keeps the folder in git)
function de_starter
    set -l f $argv[1]
    set -l kind $argv[2]
    set -l de $argv[3]
    test -e $f; and return 0
    if test "$kind" = pre
        printf '%s\n' \
            "# pre.fish for \"$de\" - sourced by initual-setup.sh BEFORE any config is restored (right after the" \
            "# package update), so the packages can never overwrite your config. Use it to install the desktop's own" \
            "# packages when the recipe depends on the distro. You can use: info, warn, pm_has, pm_install, \$pm, \$notes" \
            "# Example:" \
            "#   if test \$pm = pacman" \
            "#       pm_install pacman some-package" \
            "#   end" >$f
    else
        printf '%s\n' \
            "# post.fish for \"$de\" - sourced by initual-setup.sh AFTER the configs are restored. Use it for" \
            "# manual steps or enabling a service. You can use: info, warn, place, \$pm, \$notes, \$cfg" \
            "# Example:" \
            "#   type -q some-tool; and some-tool enable --now" >$f
    end
end

# de_add : add a desktop environment: its config under Desktop Environment/<name>/ and its hooks
function de_add
    set -l names
    set -l paths
    for l in (de_scan)
        set -l f (string split \t -- $l)
        set -a names $f[1]
        set -a paths $f[2]
    end
    echo
    set_color --bold; echo "Add a desktop environment"; set_color normal

    set -l choice p
    if test (count $names) -gt 0
        echo "Found in ~/.config:"
        for i in (seq (count $names))
            set -l mark ""
            if de_dir_name $notes $names[$i] >/dev/null
                set -l n_used 0
                for tl in (tracked_list $dirfile)
                    set -l t (string split \t -- $tl)
                    if test (string lower -- "$(de_of_name $t[2])") = $names[$i]
                        set n_used (math $n_used + 1)
                    else if set -q t[3]; and contains -- $names[$i] (de_tags (string split -n ' ' -- $t[3]))
                        set n_used (math $n_used + 1)
                    end
                end
                if test $n_used -gt 0
                    set mark "   (set up: $n_used tracked)"
                else
                    set mark "   (folder exists, nothing tracked yet)"
                end
            end
            printf '  %d) %-10s %s%s\n' $i $names[$i] $paths[$i] $mark
        end
        echo "  p) none: type a path"
        ask "Choose [1-"(count $names)", p; Enter = cancel]: "; or return 1
        if test -z "$reply"
            echo "cancelled"
            return 0
        end
        set choice (string lower -- $reply)
    else
        echo "No known desktop found in ~/.config."
    end

    set -l de ""
    set -l lives
    if string match -qr '^[0-9]+$' -- $choice
        if test $choice -lt 1 -o $choice -gt (count $names)
            warn "no number $choice in the list"
            return 1
        end
        set de $names[$choice]
        for r in (string split ' ' -- $paths[$choice])
            set -a lives $cfg/$r
        end
    else if contains -- $choice p path
        ask "Path of its config (drag it here; Enter = cancel): "; or return 1
        set -l p (string trim -c "'\"" -- $reply)
        set p (string replace -r -- '^~' "$HOME" $p)
        if test -z "$p"
            echo "cancelled"
            return 0
        end
        if not test -e $p -o -L $p
            warn "does not exist: $p"
            return 1
        end
        set -a lives (realpath -s $p)
        set -l dflt (string lower -- (string replace -r -- '^\.' '' (basename $p)))
        ask "Name of the desktop [$dflt]: "; or return 1
        set de $reply
        test -n "$de"; or set de $dflt
    else
        warn "not a valid choice"
        return 1
    end

    # an existing folder (any letter case) is the same desktop
    set -l ex (de_dir_name $notes $de)
    if test -n "$ex"
        set de $ex
        info "'$de' is already in the notes: adding to it"
    else if not string match -qr '^[A-Za-z][A-Za-z0-9._-]*$' -- $de
        warn "'$de' is not a good desktop name (letters, digits, . _ - only)"
        return 1
    end
    set -l delc (string lower -- $de)

    # also offer the usual companions (bar, launcher, lock screen...) that are not backed up yet
    set -l extra
    for x in $known_de_extra
        set -l lp $cfg/$x
        test -e $lp -o -L $lp; or continue
        contains -- $lp $lives; and continue
        is_tracked $lp; and continue
        set -a extra $x
    end

    echo
    echo "Config to back up for $de (saved under $layout_de/$de/):"
    for lp in $lives
        if is_tracked $lp
            echo "  ~/"(string replace -- "$HOME/" '' $lp)"   (already tracked)"
        else
            echo "  ~/"(string replace -- "$HOME/" '' $lp)
        end
    end
    set -l picked_extra
    if test (count $extra) -gt 0
        echo
        echo "These usually go with a desktop and are not backed up yet:"
        for i in (seq (count $extra))
            printf '  %d) ~/.config/%s\n' $i $extra[$i]
        end
        echo "(shared things can be limited to desktops later: dir uses)"
        ask "Add which to $de? (1,3-4 / all; Enter = none): "; or return 1
        if test -n "$reply"
            set -l idx (parse_selection (string replace -ra '\s+' ',' -- $reply) (count $extra))
            for k in $idx
                set -a picked_extra $extra[$k]
            end
        end
    end
    # companions that are already in Backup/ for other desktops only (rofi, ...): this desktop can join them
    set -l share_name
    set -l share_tags
    for x in $known_de_extra
        set -l lp $cfg/$x
        for line in (tracked_list $dirfile)
            set -l t (string split \t -- $line)
            test "$t[1]" = "$lp"; or continue
            test (string split -m1 / -- $t[2])[1] = "$layout_backup"; or continue
            set -l tg
            set -q t[3]; and set tg (de_tags (string split -n ' ' -- $t[3]))
            test (count $tg) -gt 0; or continue
            contains -- $delc $tg; and continue
            set -a share_name $t[2]
            set -a share_tags (string join ',' -- $tg)
        end
    end
    set -l do_share 0
    if test (count $share_name) -gt 0
        echo
        echo "In $layout_backup/, restored only for other desktops:"
        for i in (seq (count $share_name))
            echo "  $share_name[$i]   (now: $share_tags[$i])"
        end
        yes_no "Does $de use them too?" y; and set do_share 1
    end
    set -l want_exec 0
    yes_no "Make .sh and .py files executable when restored?" y; and set want_exec 1
    ask "Packages for $de (space separated; Enter = none): "; or return 1
    set -l pkgs (string split -n ' ' -- (string replace -a , ' ' -- $reply))

    if test $dry -eq 1
        info "[dry-run] would create $layout_de/$de and track the config above"
        return 0
    end

    mkdir -p $notes/$layout_de/$de
    de_starter $notes/$layout_de/$de/pre.fish pre $de
    de_starter $notes/$layout_de/$de/post.fish post $de
    info "$layout_de/$de is ready"
    echo "  Open these two files if you want the setup to do anything extra for $de:"
    echo "    pre.fish    runs BEFORE the configs are restored (install the desktop's packages...)"
    echo "    post.fish   runs AFTER they are restored (enable a service, manual steps...)"
    echo "  They are in: "(string replace -- "$HOME/" '~/' $notes)"/$layout_de/$de/"

    set -l hdr "# ---- $layout_de/$de (restored only when $de is chosen in initual-setup.sh)"
    if test -f $dirfile; and not grep -qxF -- $hdr $dirfile
        printf '\n%s\n' $hdr >>$dirfile
    end
    set -l all_live $lives
    for x in $picked_extra
        set -a all_live $cfg/$x
    end
    for lp in $all_live
        set -l opts
        test $want_exec -eq 1 -a -d $lp -a ! -L $lp; and set opts exec
        set -l nm (tracked_name_for $lp $de)
        set -l exs
        set -l want_gi 0
        # a folder that is not tracked yet: ask what is not copied and what git must not track
        if test -d $lp -a ! -L $lp; and not is_tracked $lp
            set -l shown_lp (string replace -- "$HOME/" '~/' $lp)
            echo
            set_color --bold; echo $shown_lp; set_color normal
            echo "  Choose files/directories to get EXCLUDED from the notes directory (git is asked next)"
            ask "  EXCLUDE (names, *.ext or paths; Enter = copy everything): "; or return 1
            for pat in (gi_split "$reply" $lp)
                set pat (string trim -c "'\"" -- (string trim -- $pat))
                test -n "$pat"; or continue
                exclude_check $lp $pat; or continue
                for r in $ex_result
                    set -a exs "exclude="(string replace -a ' ' '?' -- $r)
                end
            end
            yes_no "  Keep (part of) it out of git? (it is still copied into the notes)" n; and set want_gi 1
        end
        set -a opts $exs
        if track_add $lp $nm $opts; and test $want_gi -eq 1
            set -l exp
            for o in $exs
                set -a exp (string replace -- 'exclude=' '' $o)
            end
            git_ignore_dir $lp $nm $exp
        end
    end

    if test $do_share -eq 1
        for i in (seq (count $share_name))
            tracked_update $dirfile $share_name[$i] $share_name[$i] (string split , -- $share_tags[$i]) $delc
            info "$share_name[$i]: now restored for "(string replace -a , ', ' -- $share_tags[$i])", $delc"
        end
    end

    if test (count $pkgs) -gt 0
        ensure_pkgfile
        for n in $pkgs
            if conf_has $pkgfile native $n
                info "$n is already in packages.conf"
                continue
            end
            test $pm != none; and not pm_has $pm $n; and warn "'$n' was not found in the $pm repos (added anyway)"
            conf_add $pkgfile native "$n de=$delc"
            info "packages.conf: $n (only when $de is chosen)"
        end
    end

    echo
    info "'$de' will be listed in the setup"
    if yes_no "Copy the config into the notes now? (a sync without the git step)" y
        fish $self --sync --no-git --quiet
    end
end

# ================================================================ migrate
# conf_row SHOWN PLACE OPTIONS W1 W2 : one aligned line of tracked.conf
function conf_row
    set -l line (string pad -r -w $argv[4] -- $argv[1])" | "
    if test -n "$argv[3]"
        echo "$line"(string pad -r -w $argv[5] -- $argv[2])" | $argv[3]"
    else
        echo "$line$argv[2]"
    end
end

# mig_de_for TAG OLDNAME : the folder name to use for desktop TAG while migrating. Sets $mig_de_result.
# An existing folder (any letter case) wins, then the spelling of the old top-level folder
# ("Kde" for de=kde), then TAG itself.
function mig_de_for
    set -g mig_de_result
    set -l t (string lower -- $argv[1])
    for d in $mig_des (de_dirs $notes)
        if test (string lower -- $d) = "$t"
            set -g mig_de_result $d
            return 0
        end
    end
    set -l first (string split -m1 / -- $argv[2])[1]
    set -l pick $argv[1]
    test (string lower -- $first) = "$t"; and set pick $first
    set -ga mig_des $pick
    set -g mig_de_result $pick
end

# do_migrate : bring a notes folder made by an older version to the Backup / Desktop Environment
# layout. tracked.conf gets the new places, the copies are MOVED (nothing is deleted or copied
# again), the .gitignore lines follow the moved folders so private files stay ignored, and the old
# additional-scripts/de/ hooks go into the folder of their desktop.
function do_migrate
    need_lib; or return 1
    set -g mig_des
    set -l live_l
    set -l old_l
    set -l new_l
    set -l opt_l
    for line in (tracked_list $dirfile)
        set -l p (string split \t -- $line)
        set -l live $p[1]
        set -l old $p[2]
        set -l optstr ""
        set -q p[3]; and set optstr $p[3]
        set -l keep
        set -l tag ""
        # an old entry's de= tag becomes a desktop folder; on an entry already in the new layout it
        # means "only these desktops use it" and stays
        set -l was_old 1
        tracked_name_ok $old; and set was_old 0
        for o in (string split -n ' ' -- $optstr)
            if test $was_old -eq 1; and string match -q -- 'de=*' $o
                set -l tags (string split -n , -- (string replace -- 'de=' '' $o))
                test -z "$tag" -a (count $tags) -gt 0; and set tag $tags[1]
            else
                set -a keep $o
            end
        end
        set -l new $old
        if not tracked_name_ok $old
            if string match -q -- "$HOME/*" $live
                set -l de ""
                if test -n "$tag"
                    mig_de_for $tag $old
                    set de $mig_de_result
                end
                set new (tracked_name_for $live $de)
            else
                warn "left as it is (not inside your home folder, so it cannot be mirrored): $live"
            end
        else
            set -l d (de_of_name $old)
            test -n "$d"; and set -a mig_des $d
        end
        set -l ostr (string join ' ' -- $keep)
        set -a live_l $live
        set -a old_l $old
        set -a new_l $new
        set -a opt_l "$ostr"
    end

    set -l hooks (find $extras/de -maxdepth 1 -name '*.fish' 2>/dev/null | sort)
    set -l n_moves 0
    for i in (seq (count $old_l))
        test "$old_l[$i]" = "$new_l[$i]"; or set n_moves (math $n_moves + 1)
    end
    if test $n_moves -eq 0 -a (count $hooks) -eq 0
        info "tracked.conf is already in the new layout, nothing to migrate"
        return 0
    end

    echo
    echo "Moving to the new layout in $notes:"
    for i in (seq (count $old_l))
        test "$old_l[$i]" = "$new_l[$i]"; and continue
        printf '  %-38s -> %s\n' $old_l[$i] $new_l[$i]
    end
    for h in $hooks
        set -l b (string replace -r '\.fish$' '' (basename $h))
        set -l kind post
        if string match -q '*.pre' $b
            set kind pre
            set b (string replace -r '\.pre$' '' $b)
        end
        mig_de_for $b ""
        printf '  %-38s -> %s\n' additional-scripts/de/(basename $h) "$layout_de/$mig_de_result/$kind.fish"
    end
    echo "  tracked.conf is rewritten (the old one is kept in $repo_cfg/tracked.conf.before-migrate)"
    echo "  .gitignore lines follow the moved folders, so private files stay out of git"
    echo
    if test $dry -eq 1
        info "[dry-run] nothing was changed"
        return 0
    end
    if test $assume_yes -eq 0
        if not is_tty
            warn "run this by hand in a terminal, or add --yes"
            return 1
        end
        yes_no "Go ahead?" y; or return 1
    end

    # move the copies, the ones nested inside another entry first
    set -l order (for i in (seq (count $old_l)); printf '%s %s\n' (count (string split / -- $old_l[$i])) $i; end | sort -rn | string replace -r '^\S+ ' '')
    for i in $order
        set -l o $old_l[$i]
        set -l n $new_l[$i]
        test "$o" = "$n"; and continue
        set -l src $notes/$o
        set -l dst $notes/$n
        # nothing there yet: the next sync copies it from the live path
        test -e $src -o -L $src; or continue
        if test -e $dst -o -L $dst
            warn "not moved, $n already exists (the old copy stays at $o)"
            continue
        end
        mkdir -p (dirname $dst); and mv $src $dst
        or begin
            warn "could not move $o"
            continue
        end
        info "moved $o -> $n"
        prune_empty (dirname $src)
    end

    # the desktops' hooks: additional-scripts/de/NAME.pre.fish -> pre.fish, NAME.fish -> post.fish
    for h in $hooks
        set -l b (string replace -r '\.fish$' '' (basename $h))
        set -l kind post
        if string match -q '*.pre' $b
            set kind pre
            set b (string replace -r '\.pre$' '' $b)
        end
        mig_de_for $b ""
        set -l dst $notes/$layout_de/$mig_de_result/$kind.fish
        mkdir -p (dirname $dst)
        if test -e $dst
            rm -f $h
            info "$layout_de/$mig_de_result/$kind.fish exists, removed additional-scripts/de/"(basename $h)
        else
            mv $h $dst
            info "moved hook additional-scripts/de/"(basename $h)" -> $layout_de/$mig_de_result/$kind.fish"
        end
    end
    rmdir $extras/de 2>/dev/null

    # tracked.conf: a fresh header, the always-restored entries, then one block per desktop
    mkdir -p $repo_cfg; and chmod 700 $repo_cfg
    cp -f $dirfile $repo_cfg/tracked.conf.before-migrate
    set -l shown_l
    set -l w1 0
    set -l w2 0
    for i in (seq (count $live_l))
        set -l s (string replace -- "$HOME/" '~/' $live_l[$i])
        set -a shown_l $s
        test (string length -- $s) -gt $w1; and set w1 (string length -- $s)
        test (string length -- $new_l[$i]) -gt $w2; and set w2 (string length -- $new_l[$i])
    end
    set -l conf (tracked_header)
    set -a conf ""
    set -l des_seen
    for i in (seq (count $new_l))
        set -l d (de_of_name $new_l[$i])
        if test -n "$d"
            contains -- $d $des_seen; or set -a des_seen $d
        else
            set -a conf (conf_row $shown_l[$i] $new_l[$i] "$opt_l[$i]" $w1 $w2)
        end
    end
    for d in $des_seen
        set -a conf "" "# ---- Desktop Environment/$d (restored only when $d is chosen in initual-setup.sh)"
        for i in (seq (count $new_l))
            set -l di (de_of_name $new_l[$i])
            test "$di" = "$d"; or continue
            set -a conf (conf_row $shown_l[$i] $new_l[$i] "$opt_l[$i]" $w1 $w2)
        end
    end
    printf '%s\n' $conf >$dirfile
    info "tracked.conf rewritten"

    # .gitignore: a line for a moved entry (or inside it) points at the new place; a line for a
    # folder that held moved entries (like /Music/) is kept and the new places are added too
    set -l gi $notes/.gitignore
    if test -f $gi
        set -l gl (cat $gi)
        set -l done_l
        set -l extra
        set -l n_changed 0
        for i in $order
            set -l o $old_l[$i]
            set -l n $new_l[$i]
            test "$o" = "$n"; and continue
            for k in (seq (count $gl))
                contains -- $k $done_l; and continue
                set -l raw (string trim -- $gl[$k])
                string match -q -- '#*' $raw; and continue
                string match -q -- '!*' $raw; and continue
                string match -qr '[*?\[]' -- $raw; and continue
                set -l s (string replace -r -- '^/' '' $raw)
                test -n "$s"; or continue
                if test "$s" = "$o"; or string match -q -- "$o/*" $s
                    set -l rest (string sub -s (math (string length -- $o) + 1) -- $s)
                    set gl[$k] "/$n$rest"
                    set -a done_l $k
                    set n_changed (math $n_changed + 1)
                else if string match -q -- (string trim -r -c / -- $s)"/*" $o
                    contains -- "/$n" $extra; or set -a extra "/$n"
                end
            end
        end
        for e in $extra
            contains -- $e $gl; or set -a gl $e
        end
        if test $n_changed -gt 0 -o (count $extra) -gt 0
            printf '%s\n' $gl >$gi
            info ".gitignore: $n_changed line(s) moved, "(count $extra)" added"
        end
    end

    echo
    info "migrated. Run sync-notes.sh to refresh the copies."
end

# ================================================================ menus
# numbered list with filter; pick numbers to install the ones that are missing
function pkg_list_menu
    ensure_pkgfile
    build_pkg_items
    if test (count $items_key) -eq 0
        echo "No packages in packages.conf yet. Use \"Add a package\" first."
        return 0
    end
    pick_items "Install which?"; or return 0
    set -g new_native
    set -g new_flatpak
    set -g new_snap
    set -g new_pipx
    set -g new_git
    for i in $picked
        if test "$items_inst[$i]" = "-"
            warn "$items_key[$i] has no package for this system, skipped"
            continue
        end
        switch $items_sec[$i]
            case native
                set -a new_native $items_key[$i]
            case snap
                set -a new_snap $items_key[$i]
            case pipx
                set -a new_pipx $items_key[$i]
            case git
                set -a new_git $items_key[$i]
            case '*'
                set -a new_flatpak $items_key[$i]
        end
    end
    offer_install
end

# choose where to search: the detected package manager, flatpak or snap; or add pipx / git by name
function add_menu
    echo
    echo "Add from"
    echo "  1) $pm (detected)"
    echo "  2) flatpak"
    echo "  3) snap"
    echo "  4) Add by name (a package that search does not find)"
    echo "  5) pipx"
    echo "  6) git repo (URL, cloned to ~/Documents)"
    echo "  0) Back"
    ask "Choose: "; or return 0
    switch $reply
        case 1
            if test $pm = none
                warn "no supported package manager found"
            else
                pkg_search native
            end
        case 2
            pkg_search flatpak
        case 3
            pkg_search snap
        case 4
            pkg_add_name
        case 5
            ask "pipx app(s): PyPI name or git address (Enter = cancel): "; or return 0
            set -l w (string split -n ' ' -- (string replace -a , ' ' -- $reply))
            test (count $w) -gt 0; and pkg_add_name pipx:$w
        case 6
            ask "Git repo URL(s) (Enter = cancel): "; or return 0
            test -n "$reply"; and pkg_add_name $reply
    end
end

function pkg_menu
    while true
        echo
        set_color --bold
        echo "Packages   (this system uses: $pm)"
        set_color normal
        echo "  1) List / search the packages"
        echo "  2) Add a package"
        echo "  3) Remove packages"
        echo "  4) Add what is installed here but not listed"
        echo "  5) Install everything in the list now"
        echo "  6) Rename package(s)"
        echo "  7) Record the install script of a git repo (install.sh...)"
        echo "  0) Back"
        ask "Choose: "; or return 0
        switch $reply
            case 1
                pkg_list_menu
            case 2
                add_menu
            case 3
                pkg_remove
            case 4
                pkg_export
            case 5
                pkg_install
            case 6
                pkg_rename
            case 7
                pkg_script
            case 0 ''
                return 0
        end
    end
end

function dir_menu
    while true
        echo
        set_color --bold
        echo "Folders and files that are backed up"
        set_color normal
        echo "  1) List"
        echo "  2) Add a folder or file"
        echo "  3) Remove one"
        echo "  4) Choose which files/dir belong to which de"
        echo "  5) Add a desktop environment (scans ~/.config)"
        echo "  6) Rename directories or files"
        echo "  7) Choose what is NOT copied into the notes"
        echo "  8) Choose what git does NOT track"
        echo "  0) Back"
        ask "Choose: "; or return 0
        switch $reply
            case 1
                dir_list
                while true
                    ask "Filter (words like mango, sddm, private; Enter = back): "; or break
                    test -n "$reply"; or break
                    dir_list "$reply"
                end
            case 2
                dir_add
            case 3
                dir_remove
            case 4
                dir_uses
            case 5
                de_add
            case 6
                dir_rename
            case 7
                exclude_menu
            case 8
                git_menu
            case 0 ''
                return 0
        end
    end
end

# ---------------------------------------------------------------- "not copied" and "not in git" menus
# tracked_opts_of PLACE : the options of that entry in tracked.conf
function tracked_opts_of
    set -l t (string split \t -- (tracked_entry $argv[1]))
    set -q t[3]; and echo $t[3]
end

# tracked_set_excludes PLACE [PATTERN...] : replace ALL exclude= options of that entry by these patterns
function tracked_set_excludes
    set -l place $argv[1]
    set -e argv[1]
    test -f $dirfile; or return 1
    set -l out
    set -l done 0
    for line in (cat $dirfile)
        if string match -qr '^\s*(#|$)' -- "$line"
            set -a out "$line"
            continue
        end
        set -l f (string split '|' -- "$line")
        if test (count $f) -ge 2; and test (string trim -- "$f[2]") = "$place"
            set -l opts
            if set -q f[3]
                for t in (string split -n ' ' -- (string trim -- "$f[3]"))
                    string match -q -- 'exclude=*' $t; or set -a opts $t
                end
            end
            for x in $argv
                set -a opts "exclude=$x"
            end
            set -l nl (string trim -- "$f[1]")" | "(string trim -- "$f[2]")
            test (count $opts) -gt 0; and set nl "$nl | "(string join ' ' -- $opts)
            set -a out "$nl"
            set done 1
        else
            set -a out "$line"
        end
    end
    test $done -eq 1; or return 1
    printf '%s\n' $out >$dirfile
end

# pick_one_tracked PROMPT : choose ONE tracked folder or file. Sets $t_live, $t_place, $t_opts.
function pick_one_tracked
    build_dir_items
    if test (count $items_key) -eq 0
        warn "nothing is tracked yet"
        return 1
    end
    pick_items "$argv[1]"; or return 1
    if test (count $picked) -gt 1
        warn "pick one at a time"
        return 1
    end
    set -l t (string split \t -- (tracked_entry $items_key[$picked[1]]))
    set -g t_live $t[1]
    set -g t_place $t[2]
    set -g t_opts ""
    set -q t[3]; and set -g t_opts $t[3]
    return 0
end

# gitignore_rules_of NAME : the .gitignore lines of that tracked entry (nested entries are not included)
function gitignore_rules_of
    set -l gi $notes/.gitignore
    test -f $gi; or return 0
    set -l base "/"(gi_esc $argv[1])
    set -l nested
    for line in (tracked_list $dirfile)
        set -l t (string split \t -- $line)
        string match -q -- "$argv[1]/*" $t[2]; and set -a nested "/"(gi_esc $t[2])
    end
    for l in (cat $gi)
        set -l body (string trim -- "$l")
        string match -q -- '!*' "$body"; and set body (string sub -s 2 -- "$body")
        if test "$body" = "$base"; or string match -q -- "$base/*" "$body"
            set -l mine 1
            for nb in $nested
                if test "$body" = "$nb"; or string match -q -- "$nb/*" "$body"
                    set mine 0
                end
            end
            test $mine -eq 1; and echo $l
        end
    end
end

# exclude_menu : choose what is NOT copied into the notes (the exclude= list of one tracked folder)
function exclude_menu
    pick_one_tracked "Which folder or file?"; or return 0
    set -l changed 0
    while true
        set -l ex
        for o in (string split -n ' ' -- "$t_opts")
            string match -q -- 'exclude=*' $o; and set -a ex (string replace -- 'exclude=' '' $o)
        end
        echo
        set_color --bold
        echo (string replace -- "$HOME/" '~/' $t_live)
        set_color normal
        if test (count $ex) -eq 0
            echo "  Nothing is excluded: everything in it is copied into the notes directory."
        else
            echo "  EXCLUDED (not copied into the notes directory):"
            for i in (seq (count $ex))
                printf '    %3d) %s\n' $i $ex[$i]
            end
        end
        echo
        echo "  1) Exclude files/directories"
        echo "  2) Add files/directories to track"
        echo "  0) Back"
        ask "Choose: "; or break
        switch $reply
            case 1
                if not test -d $t_live -a ! -L $t_live
                    warn "only a directory can have files/directories excluded. To stop backing up a single file: Folders and files to back up > Remove one"
                    continue
                end
                # same tree as when a folder is added; what is already not copied is hidden from it
                set -g gi_excl $ex
                set -g gi_xf
                for e in $gi_excl
                    set -a gi_xf -not -path "*/$e" -not -path "*/$e/*"
                end
                tree_show $t_live
                echo
                echo "  Choose files/directories to get EXCLUDED from the notes directory"
                echo "    png jpg      every file of that type"
                echo "    cache.db     a file or folder with that name (searched in the folder)"
                echo "    logs/*.log   a path inside the folder"
                ask "  EXCLUDE (names, *.ext or paths; Enter = cancel): "; or break
                test -n "$reply"; or continue
                set -l added
                for pat in (gi_split "$reply" $t_live)
                    set pat (string trim -c "'\"" -- (string trim -- $pat))
                    test -n "$pat"; or continue
                    exclude_check $t_live $pat; or continue
                    for r in $ex_result
                        set r (string replace -a ' ' '?' -- $r)
                        contains -- $r $ex $added; or set -a added $r
                    end
                end
                test (count $added) -gt 0; or continue
                if tracked_set_excludes $t_place $ex $added
                    info "excluded "(count $added)" item(s) from the notes directory: "(string join ', ' -- $added)
                    set changed 1
                else
                    warn "could not save it in tracked.conf"
                end
            case 2
                if test (count $ex) -eq 0
                    warn "nothing is excluded yet, so everything is already copied into the notes directory"
                    continue
                end
                echo
                echo "  Choose which EXCLUDED files/directories to track again (they will be copied into the notes directory)"
                ask "  Choose (number(s) or all; Enter = cancel): "; or break
                test -n "$reply"; or continue
                set -l idx (parse_selection (string replace -ra '\s+' ',' -- $reply) (count $ex)); or continue
                set -l keep
                for i in (seq (count $ex))
                    contains -- $i $idx; or set -a keep $ex[$i]
                end
                if tracked_set_excludes $t_place $keep
                    info "now tracked again: "(count $idx)" item(s) will be copied into the notes directory"
                    set changed 1
                else
                    warn "could not save it in tracked.conf"
                end
            case 0 ''
                break
        end
        set -g t_opts (tracked_opts_of $t_place)
    end
    if test $changed -eq 1
        echo
        echo "The notes directory is updated at the next sync:"
        echo "  - newly excluded files/directories are removed from it (in archive mode they go to the trash first)"
        echo "  - files/directories you track again are copied into it"
        yes_no "Sync now so the notes directory matches?" y; and fish $self --sync --no-git --quiet
    end
end

# git_menu : choose what git does NOT track (the .gitignore rules of one tracked folder or file)
function git_menu
    pick_one_tracked "Which folder or file?"; or return 0
    if not test -e $t_live -o -L $t_live
        warn "it does not exist on this machine"
        return 0
    end
    set -l is_dir 0
    test -d $t_live -a ! -L $t_live; and set is_dir 1
    set -l exs
    for o in (string split -n ' ' -- "$t_opts")
        string match -q -- 'exclude=*' $o; and set -a exs (string replace -- 'exclude=' '' $o)
    end
    while true
        echo
        set_color --bold
        echo (string replace -- "$HOME/" '~/' $t_live)"   ($t_place)"
        set_color normal
        set -l rules (gitignore_rules_of $t_place)
        if test (count $rules) -eq 0
            echo "  Nothing is excluded from git: git tracks all of it."
        else
            echo "  EXCLUDED from git (.gitignore rules):"
            printf '    %s\n' $rules
            if test -d $notes/.git
                set -l ign (git -C $notes ls-files -z -o -i --exclude-standard -- ":(literal)$t_place" 2>/dev/null | string split0)
                echo "  "(count $ign)" file(s) here are excluded from git (still copied into the notes directory):"
                printf '    %s\n' $ign | head -n 15
                test (count $ign) -gt 15; and echo "    ... and "(math (count $ign) - 15)" more"
            end
        end
        echo
        if test $is_dir -eq 1
            echo "  1) Exclude files/directories from git"
        else
            echo "  1) Exclude this file from git"
        end
        echo "  2) Add everything back to git tracking (removes all git exclusions for it)"
        echo "  0) Back"
        ask "Choose: "; or break
        switch $reply
            case 1
                if test $is_dir -eq 1
                    git_ignore_dir $t_live $t_place $exs
                else
                    gitignore_drop_folder $t_place
                    gitignore_add "/"(gi_esc $t_place)
                    if test -d $notes/.git; and git -C $notes ls-files --error-unmatch -- $t_place >/dev/null 2>&1
                        git -C $notes rm -r -q --cached -- $t_place
                        info "git: stopped tracking $t_place (the next sync commits that)"
                    end
                    info "git will not track $t_place"
                end
            case 2
                if test (count $rules) -eq 0
                    info "nothing is excluded from git, it already tracks all of it"
                else
                    gitignore_drop_folder $t_place
                    info "all git exclusions removed: git tracks all of it again (the next sync commits it)"
                end
            case 0 ''
                break
        end
    end
end

function main_menu
    while true
        echo
        set_color --bold
        echo "Notes manager"
        set_color normal
        echo "  1) Packages (install list)"
        echo "  2) Folders and files to back up"
        echo "  0) Quit"
        ask "Choose: "; or return 0
        switch $reply
            case 1
                pkg_menu
            case 2
                dir_menu
            case 0 q ''
                return 0
        end
    end
end

# track_now : bring packages.conf up to date with what was installed or removed by hand since the last
# look (pkg-track.fish update). The tracker normally does this by itself through its watchers; this is
# the safety net, so a sync or opening the package manager never works with an outdated list.
function track_now
    test $dry -eq 0; or return 0
    test -f $extras/pkg-track.fish; or return 0
    if is_tty
        fish $extras/pkg-track.fish update
    else
        fish $extras/pkg-track.fish update </dev/null >/dev/null 2>&1
    end
    return 0
end

# need_lib : the manager needs lib.fish (package manager helpers, packages.conf, tracked.conf)
function need_lib
    test $have_lib -eq 1; and return 0
    warn "missing $extras/lib.fish: the package and folder manager needs it"
    return 1
end

# usage : the comment block at the top of this file
function usage
    sed -n '2,/^$/p' $self | string replace -r '^# ?' ''
end

# manage_cli GROUP SUB [ARG] : sync-notes.sh pkg list|search|add|remove|export|install, dir list|add|remove|rename|uses|de
function manage_cli
    need_lib; or return 1
    switch "$argv[1]"
        case pkg
            track_now
            switch "$argv[2]"
                case list
                    pkg_list "$argv[3]"
                case search
                    pkg_search all "$argv[3]"
                case add
                    pkg_add_name "$argv[3]"
                case remove rm
                    pkg_remove "$argv[3]"
                case export
                    pkg_export
                case rename
                    pkg_rename "$argv[3]" "$argv[4]"
                case script
                    pkg_script "$argv[3]" "$argv[4]"
                case install
                    pkg_install
                case ''
                    pkg_menu
                case '*'
                    usage
                    return 1
            end
        case dir
            switch "$argv[2]"
                case list
                    dir_list "$argv[3]"
                case add
                    dir_add "$argv[3]"
                case remove rm
                    dir_remove
                case uses
                    dir_uses
                case rename
                    dir_rename "$argv[3]" "$argv[4]"
                case de
                    de_add
                case ''
                    dir_menu
                case '*'
                    usage
                    return 1
            end
    end
end

# sync-notes.sh pkg ... / dir ... / help : no sync, just the manager
switch "$argv[1]"
    case pkg dir
        manage_cli $argv
        exit $status
    case -h --help help
        usage
        exit 0
end

# ---------------------------------------------------------------- delete mode
# How a file you deleted live is handled in the notes and the backup copy:
#   mirror   the copy matches live exactly (deleted files are gone, with a mass-delete guard)
#   archive  like mirror, but removed files are moved to a trash folder first (default)
#   keep     never delete anything, only add and update
# Saved outside the notes (like the git URL), so it is never synced, committed or backed up.
set delete_cfg $repo_cfg/delete-mode
set archive_root $HOME/.local/share/os-migrate-notes/deleted
set archive_days 60
set backup_keep 3
set arch_run (date +%F_%H%M%S)
set archived_total 0

set force 0
contains -- --force $argv; and set force 1

function valid_delmode
    contains -- "$argv[1]" mirror archive keep
end

function saved_delmode
    test -f $delete_cfg; and string trim -- (head -n1 $delete_cfg)
end

function delmode_label
    switch $argv[1]
        case mirror
            echo "mirror   - copies match live exactly; deleted files are gone"
        case archive
            echo "archive  - like mirror, but deleted files go to trash first ($archive_days days)"
        case keep
            echo "keep     - never delete anything, only add and update"
    end
end

# the mode for this run: saved choice, else archive; --deletes=MODE overrides for one run
set delmode archive
set saved_dm (saved_delmode)
if test -n "$saved_dm"; and valid_delmode $saved_dm
    set delmode $saved_dm
end
for a in $argv
    if string match -q -- '--deletes=*' $a
        set req_dm (string replace -- '--deletes=' '' $a)
        if valid_delmode $req_dm
            set delmode $req_dm
        else
            warn "unknown delete mode '$req_dm' (use mirror, archive or keep), using $delmode"
        end
    end
end

# set_delmode : ask which mode to use and remember it
function set_delmode
    if not is_tty
        warn "run this by hand in a terminal to choose the delete mode"
        return 1
    end
    echo
    set_color --bold; echo "How should files you deleted be handled?"; set_color normal
    echo "current: $delmode"
    echo "  1) "(delmode_label mirror)
    echo "  2) "(delmode_label archive)
    echo "  3) "(delmode_label keep)
    read -P "Choose [1-3, Enter = cancel]: " c
    set -l new
    switch "$c"
        case 1 mirror
            set new mirror
        case 2 archive
            set new archive
        case 3 keep
            set new keep
        case '*'
            warn "nothing changed"
            return 1
    end
    if test $dry -eq 1
        info "[dry-run] would save delete mode: $new"
        return 0
    end
    mkdir -p $repo_cfg; and chmod 700 $repo_cfg
    printf '%s\n' $new >$delete_cfg; and chmod 600 $delete_cfg
    set -g delmode $new
    info "delete mode saved: $new (in $delete_cfg, outside the notes)"
end

# removal_plan OLD NEW : fills $old_entries (everything in OLD) and $removed_entries
# (what is in OLD but not in NEW), as paths relative to the folders, parents before children
function removal_plan
    set -lx LC_ALL C
    set -g old_entries (find $argv[1] -mindepth 1 -printf '%P\n' | sort)
    set -g removed_entries
    test (count $old_entries) -gt 0; or return 0
    set -g removed_entries (comm -23 (printf '%s\n' $old_entries | psub) (find $argv[2] -mindepth 1 -printf '%P\n' | sort | psub))
end

# removal_is_heavy REMOVED OLD : true when 30%+ of OLD would go, or all of it
function removal_is_heavy
    test $argv[1] -eq $argv[2]; and return 0
    test $argv[2] -ge 10; and test (math "floor($argv[1] * 100 / $argv[2])") -ge 30
end

# archive_removed DST : move everything in $removed_entries out of DST into this run's trash folder
function archive_removed
    set -l dst $argv[1]
    set -l label (string replace -- "$notes/" "" $dst)
    mkdir -p $archive_root; and chmod 700 $archive_root
    for rel in $removed_entries
        set -l item $dst/$rel
        # a removed folder's children are already gone once the folder was moved
        test -e $item -o -L $item; or continue
        set -l target $archive_root/$arch_run/$label/$rel
        mkdir -p (dirname $target); and mv $item $target
        or begin
            warn "could not archive $item, kept old copy of $dst"
            return 1
        end
        set -g archived_total (math $archived_total + 1)
    end
end

# purge_archive : delete trash folders older than $archive_days days
function purge_archive
    test $dry -eq 0; or return 0
    test -d $archive_root; or return 0
    find $archive_root -mindepth 1 -maxdepth 1 -type d -mtime +$archive_days -exec rm -rf {} +
end

# entries of tracked.conf still in the old layout (see --migrate)
set old_layout 0
if test $have_lib -eq 1
    for line in (tracked_list $dirfile)
        set p (string split \t -- $line)
        tracked_name_ok $p[2]; or set old_layout (math $old_layout + 1)
    end
end

# menu: only when run by hand in a terminal and no mode flag was given
set mode sync
if contains -- --set-repo $argv
    set mode repo
else if contains -- --migrate $argv
    set mode migrate
else if contains -- --manage $argv
    set mode manage
else if contains -- --backup $argv
    set mode backup
else if contains -- --set-deletes $argv
    set mode deletes
else if not contains -- --sync $argv; and not string match -q -- '--deletes=*' $argv
    if is_tty
        echo
        set_color --bold; echo "What do you want to do?"; set_color normal
        echo "  1) Sync notes + git backup   (default)"
        echo "  2) Back up to Documents/os-migrate-notes-backup"
        echo "  3) Set or change the git repo URL"
        echo "  4) Manage packages and backed-up folders"
        echo "  5) Choose how deleted files are handled   (now: $delmode)"
        set maxopt 5
        if test $old_layout -gt 0
            echo "  6) Migrate notes to the new layout ($old_layout left)"
            set maxopt 6
        end
        read -P "Choose [1-$maxopt, Enter = 1]: " choice
        switch "$choice"
            case 2 b B
                set mode backup
            case 3
                set mode repo
            case 4
                set mode manage
            case 5
                set mode deletes
            case 6
                test $old_layout -gt 0; and set mode migrate
        end
    end
end

if test $mode = manage
    need_lib; or exit 1
    track_now
    main_menu
    exit 0
end

if test $mode = migrate
    do_migrate
    set mgstatus $status
    info "done."
    exit $mgstatus
end

if test $mode = repo
    set_repo_url
    set rstatus $status
    info "done."
    exit $rstatus
end

if test $mode = deletes
    set_delmode
    set dmstatus $status
    info "done."
    exit $dmstatus
end

if test $mode = backup
    backup_copy
    set bstatus $status
    info "done."
    exit $bstatus
end

# a normal sync first records what you installed or removed by hand (packages.conf), so the git
# step below commits the up-to-date list
test $mode = sync; and track_now

# ---- temporary copies
# pull copies into a hidden ".sync.XXXXXX" folder (or "NAME.sync-tmp" file) next to the destination and
# swaps it in when the copy succeeded. If a run is stopped half way (Ctrl-C, a reboot, a crash) such a
# folder would stay behind, with a full copy of what was being synced, and git would pick it up. So:
#   - every temporary copy is removed when the script exits or is interrupted
#   - leftovers of older runs are swept before the sync starts
#   - .sync.* and *.sync-tmp are put in .gitignore
set sync_tmps
function sync_cleanup --on-event fish_exit
    for t in $sync_tmps
        test -n "$t"; and rm -rf -- $t 2>/dev/null
    end
end
function sync_on_signal --on-signal INT --on-signal TERM --on-signal HUP
    sync_cleanup
    exit 130
end

# sweep_leftovers : delete .sync.* folders and *.sync-tmp files anywhere in the notes (not inside .git) that
# are older than 30 minutes, so a run that is still going is left alone
function sweep_leftovers
    for t in (find $notes -name .git -prune -o \( -name '.sync.??????' -type d -o -name '*.sync-tmp' \) -mmin +30 -print -prune 2>/dev/null)
        rm -rf -- $t
        and info "removed a leftover temporary copy of an interrupted sync: "(string replace -- "$notes/" '' $t)
    end
end

# src_readable SRC : can this user read all of SRC? (a system file may need sudo)
function src_readable
    test -r $argv[1]; or return 1
    if test -d $argv[1] -a ! -L $argv[1]
        test -z (find $argv[1] ! -readable -print -quit 2>/dev/null)
    end
end

# pull SRC DST [EXCLUDE...] : replace DST with a copy of SRC (symlinks preserved).
# Excludes are tar patterns matched anywhere in the path, e.g. .venv or '*.bak'.
function pull
    set src $argv[1]
    set dst $argv[2]
    set excl $argv
    set -e excl[1 2]

    if not test -e $src -o -L $src
        warn "missing, kept old copy: $src"
        return 1
    end
    if contains -- "$dst" "" / $HOME $notes
        warn "refusing to replace $dst"
        return 1
    end
    if test $dry -eq 1
        info "[dry-run] $src -> $dst"
        return 0
    end

    mkdir -p (dirname $dst)

    # a system file the user cannot read: read it with sudo (asked in a terminal; the timer only uses
    # sudo when it needs no password, otherwise the old copy is kept)
    set -l rd env
    set -l via_sudo 0
    if not src_readable $src
        if is_tty
            sudo -v; and set rd sudo; and set via_sudo 1
        else
            sudo -n true 2>/dev/null; and set rd sudo -n; and set via_sudo 1
        end
        if test $via_sudo -eq 0
            warn "needs sudo to read, kept old copy: $src"
            return 1
        end
    end

    if test -d $src -a ! -L $src
        set tmp (mktemp -d (dirname $dst)/.sync.XXXXXX)
        set -ga sync_tmps $tmp
        set targs
        for e in $excl
            set -a targs --exclude=$e
        end
        $rd tar -C $src $targs -cf - . | tar -C $tmp -xf -
        set st $pipestatus
        if test "$st[1]" != 0 -o "$st[2]" != 0
            warn "copy failed, kept old copy: $src"
            rm -rf $tmp
            return 1
        end
        chmod --reference=$src $tmp

        if test $delmode = keep; and test -d $dst -a ! -L $dst
            # keep mode: add and update only, nothing in the notes is deleted
            if not cp -a $tmp/. $dst/
                warn "copy failed, kept old copy: $src"
                rm -rf $tmp
                return 1
            end
            rm -rf $tmp
        else
            if test -d $dst -a ! -L $dst
                removal_plan $dst $tmp
                set -l n_old (count $old_entries)
                set -l n_rm (count $removed_entries)
                if test $n_rm -gt 0
                    if test $delmode = mirror; and test $force -eq 0; and removal_is_heavy $n_rm $n_old
                        warn "kept $dst: sync would delete $n_rm of $n_old items (use --force or archive mode)"
                        rm -rf $tmp
                        return 1
                    end
                    if test $delmode = archive
                        if not archive_removed $dst
                            rm -rf $tmp
                            return 1
                        end
                    end
                end
            end
            rm -rf $dst
            mv $tmp $dst
        end
    else
        set -ga sync_tmps $dst.sync-tmp
        $rd cp -a $src $dst.sync-tmp; and begin
            test $via_sudo -eq 1; and $rd chown (id -u):(id -g) $dst.sync-tmp
            mv -f $dst.sync-tmp $dst
        end
        or begin
            warn "copy failed, kept old copy: $src"
            rm -f $dst.sync-tmp
            return 1
        end
    end
    test $quiet -eq 1; or info (string replace -- $HOME '~' $src)" -> "(string replace -- "$notes/" '' $dst)
end

# ---------------------------------------------------------------- tracked folders
# Everything listed in additional-scripts/tracked.conf (config.fish, ghostty, Keypass,
# .passwords, Music ... and whatever you add with the manager), each saved as Backup/<path>
# or Desktop Environment/<DE>/<path>.
test $quiet -eq 0 -a $delmode != archive; and info "deleted files: $delmode mode"
if test $dry -eq 0
    gitignore_add '.sync.*/'
    gitignore_add '*.sync-tmp'
    sweep_leftovers
end
test $old_layout -gt 0; and warn "tracked.conf still has $old_layout entries in the old layout, they are skipped: run  sync-notes.sh --migrate"
for line in (tracked_list $extras/tracked.conf)
    set p (string split \t -- $line)
    set live $p[1]
    set name $p[2]
    set optstr ""
    set -q p[3]; and set optstr $p[3]
    set excl
    set private 0
    set optional 0
    for o in (string split -n ' ' -- $optstr)
        switch $o
            case 'exclude=*'
                set -a excl (string replace -- 'exclude=' '' $o)
            case private
                set private 1
            case optional
                set optional 1
        end
    end
    if not tracked_name_ok $name
        warn "tracked.conf: '$name' skipped (old layout, run --migrate)"
        continue
    end
    # a Backup entry that only some desktops use (de=): left alone on a machine that uses none of them,
    # so another desktop's config can never overwrite the shared copy
    set tagged (de_tags (string split -n ' ' -- $optstr))
    if test (count $tagged) -gt 0
        set optional 1
        uses_elsewhere (string split -n ' ' -- $optstr); and continue
    end
    # a desktop's own files: back them up when they exist here, stay quiet when they do not
    # (the other desktops' files are not on this machine)
    set de (de_of_name $name)
    test -n "$de"; and set optional 1
    if test $optional -eq 1; and not test -e $live -o -L $live
        continue
    end
    if pull $live $notes/$name $excl
        test $private -eq 1; and test $dry -eq 0; and chmod -R go-rwx $notes/$name
    end
end

# ---------------------------------------------------------------- git backup
# Commits whatever changed and pushes it to origin. Works from the systemd timer too:
# ssh runs in batch mode (never waits for a password), so the key must work without a
# prompt (no passphrase, or an ssh-agent the service can reach). Failures only print a
# warning and make the script exit 1; the files above are already synced either way.
function git_backup
    test $no_git -eq 0; or return 0

    # not a repo / no remote: asks for the URL in a terminal, otherwise skips (never fails)
    ensure_repo; or return 0
    if test $dry -eq 1
        info "[dry-run] would commit and push to origin"
        return 0
    end

    git -C $notes add -A

    # safety net: never commit secrets or media, even if .gitignore is wrong
    set bad (git -C $notes diff --cached --name-only | grep -iE '\.kdbx$|(^|/)\.passwords(/|$)|recovery-codes|\.(mp4|mkv|webm|mov|avi|mp3|flac|wav|m4a|ogg)$')
    if test (count $bad) -gt 0
        git -C $notes reset -q
        warn "git aborted, secret/media files staged (fix .gitignore):"
        printf '    %s\n' $bad
        return 1
    end

    if git -C $notes diff --cached --quiet
        info "git: nothing new to commit"
    else
        if not git -C $notes commit -q -m "Auto sync "(date '+%F %T')
            warn "git commit failed (are user.name and user.email set?)"
            return 1
        end
        info "git: committed"
    end

    set branch (git -C $notes rev-parse --abbrev-ref HEAD)
    set -lx GIT_SSH_COMMAND "ssh -o BatchMode=yes -o ConnectTimeout=15"
    set -lx GIT_TERMINAL_PROMPT 0

    if not timeout 90 git -C $notes push -q -u origin $branch 2>/dev/null
        # the remote has commits we don't: put ours on top of them and try once more
        if timeout 90 git -C $notes pull -q --rebase origin $branch 2>/dev/null
            if not timeout 90 git -C $notes push -q -u origin $branch 2>/dev/null
                warn "git push failed after rebase"
                return 1
            end
        else
            git -C $notes rebase --abort 2>/dev/null
            warn "git push skipped: offline, no ssh access, or a conflict with the remote"
            return 1
        end
    end
    info "git: pushed to origin/$branch"
end

if test $delmode = archive
    test $archived_total -gt 0; and info "archived $archived_total removed item(s) in $archive_root/$arch_run (purged after $archive_days days)"
    purge_archive
end

git_backup
set git_status $status

info "done."
exit $git_status
