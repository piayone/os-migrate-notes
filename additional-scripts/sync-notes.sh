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
#   ./sync-notes.sh dir list            list the tracked folders
#   ./sync-notes.sh dir add [path]      start backing up a folder or file. It is saved under Backup/ with
#                                       the same path it has in your home folder (~/Downloads/clean.py ->
#                                       Backup/Downloads/clean.py), or, when you say it belongs to one
#                                       desktop, under Desktop Environment/<that desktop>/
#                                       For a folder it first shows what is inside (a tree like eza --tree,
#                                       hidden files included). "Keep it out of git" can then ignore only
#                                       part of it: *.log (every folder that has some), logs/*.log, one
#                                       file or one folder; the paths written to .gitignore are listed
#   ./sync-notes.sh dir remove          stop backing one up
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
    warn "missing $extras/lib.fish: the folders in tracked.conf are skipped and the manager is unavailable"
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
        warn "that does not look like a git URL (https://..., git@host:user/repo.git, ssh://...)"
        return 1
    end
    if test $dry -eq 1
        info "[dry-run] would save the URL and set origin to "(mask_url $url)
        return 0
    end
    mkdir -p $repo_cfg; and chmod 700 $repo_cfg
    printf '%s\n' $url >$repo_url_file; and chmod 600 $repo_url_file
    info "repo URL saved in $repo_url_file (outside the notes, not synced or backed up)"
    if test -d $notes/.git
        apply_remote $url; and info "git: origin -> "(mask_url $url)
    else
        info "this folder is not a git repository yet; the next sync offers to set it up"
    end
end

# ensure_repo : make sure the notes folder is a git repo with an origin.
# Returns 1 when the git step has to be skipped.
function ensure_repo
    if not type -q git
        warn "git backup skipped: git is not installed"
        return 1
    end

    if not test -d $notes/.git
        if test $dry -eq 1; or not is_tty
            warn "git backup skipped: $notes is not a git repository (run sync-notes.sh by hand and choose 3 to set one up)"
            return 1
        end
        read -P "$notes is not a git repository. Set one up here? [y/N]: " yn
        if not string match -qri '^y' -- $yn
            warn "git backup skipped"
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
            warn "git backup skipped: no 'origin' remote and no saved URL (run sync-notes.sh by hand and choose 3)"
            return 1
        end
    end

    # the backup copy leaves .gitignore out, so a restored folder may lack one: without it
    # "git add -A" would commit images and logs that are meant to stay private
    if not test -f $notes/.gitignore
        warn "git backup skipped: no .gitignore in $notes, add one first so private files are not committed"
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
    set -l hint "numbers like 1,3-5, all"
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
        ask "$argv[1] ($hint, or words to filter; Enter = cancel): "; or return 1
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
            echo "  not in the list: $unknown (showing everything that matches your words)"
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
            set alt "$alt $alias"
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
            warn "flatpak is not installed (add the package 'flatpak' to the list and run: sync-notes.sh pkg install)"
        end
    end
    if test (count $todo_snap) -gt 0
        if type -q snap
            for n in $todo_snap
                sudo snap install $n
            end
        else
            warn "snap is not installed, so the snap package(s) were only added to the list"
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
            warn "pipx is not installed (add python-pipx to the list), so the pipx package(s) were only added to the list"
        end
    end
    if test (count $todo_git) -gt 0
        if type -q git
            mkdir -p $HOME/Documents
            for u in $todo_git
                git clone $u (git_dest $u); and git_ask_install $pkgfile $u
            end
        else
            warn "git is not installed, so the repo(s) were only added to the list"
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
                echo "     an app from git or a path is added as pipx:git+https://github.com/user/repo"
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
        ask "Package name(s) (flatpak id like org.gimp.GIMP, pipx:name, or a git URL): "; or return 1
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
        warn "nothing found for '$term'. Check the spelling, or use \"Add by name\" in the Add menu"
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
            if test $items_key[$i] = $argv[1]; or contains -- $argv[1] $alts
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
        warn "packages.conf has no packages"
        return 1
    end
    set -g picked
    set -l want $argv[1]
    if test -n "$want"
        for i in (seq (count $items_key))
            set -l al (string split -n ' ' -- $items_alt[$i])
            if test $items_key[$i] = "$want"; or contains -- $want $al
                set -a picked $i
            end
        end
        if test (count $picked) -eq 0
            warn "nothing called '$want' in packages.conf"
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
        test -n "$items_name[$i]"; and echo "  name now: $items_name[$i]"
        set -l new $argv[2]
        if test -z "$new"
            ask "  new name (letters, digits . _ + -, no spaces; '-' = no name; Enter = leave it): "; or return 1
            set new $reply
        end
        test -n "$new"; or continue
        test "$new" = -; and set new ""
        if test -n "$new"
            if not alias_valid $new
                warn "'$new' is not a usable name (letters, digits and . _ + - only, no spaces)"
                continue
            end
            if test "$new" = "$items_name[$i]"
                info "already called $new"
                continue
            end
            # the name has to point at one entry only
            set -l clash 0
            for j in (seq (count $items_key))
                test $j -eq $i; and continue
                if test $items_key[$j] = $new -o "$items_name[$j]" = $new
                    set clash 1
                end
            end
            if test $clash -eq 1
                warn "'$new' is already used by another entry"
                continue
            end
        end
        if conf_set_alias $pkgfile $sec $key "$new"
            if test -n "$new"
                info "$shown is now called $new"
            else
                info "$shown has no name of its own any more"
            end
        else
            warn "could not rename $shown"
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
        else if test $items_key[$i] = "$want"; or contains -- $want (string split -n ' ' -- $items_alt[$i])
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
                warn "$repo is not cloned here ($dir), so its scripts cannot be listed; give the path: pkg script $repo PATH"
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
        echo "Nothing new: everything installed by hand is already in packages.conf."
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
    info "these are already installed here, so there is nothing to install now"
end

function pkg_install
    ensure_pkgfile
    # install_packages handles every section: native, flatpak, snap, pipx and git
    install_packages $pkgfile
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
    set -g items_header (printf '%-42s %-26s %s' "LIVE PATH" WHERE OPTIONS)
    set -g items_noun "folders and files"
    set -g items_foot ""
    for line in (tracked_list $dirfile)
        set -l p (string split \t -- $line)
        set -l shown (string replace -- "$HOME/" '~/' $p[1])
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
        set -l o ""
        set -q p[3]; and set o $p[3]
        set -a items_key $p[2]
        set -a items_label (printf '%-42s %-26s %s%s' $shown $where $o $mark)
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
    set -l items (command ls -A -- $dir 2>/dev/null)
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
    set -g tree_lines 0
    set -g tree_cut 0
    echo
    set_color --bold
    echo (string replace -- "$HOME/" '~/' $dir)
    set_color normal
    tree_walk $dir ""
    if test $tree_cut -eq 1
        echo "  ... stopped after $tree_max lines ("(find $dir -mindepth 1 | count)" items in all)"
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
    gitignore_add $ig
    info "git will ignore $ig (the whole folder)"
    echo "  "(find $p -mindepth 1 | count)" items inside, all of them ignored by git"
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
    find $p -mindepth 1 -not -path '*/.git/*' $how $pat -printf '%P\n' | sort
end

# gi_resolve P T REL : find out which path(s) inside the folder P the user means by REL (T is what
# they typed, REL the same relative to the folder). Sets the global $gi_picked (paths from P).
#   - a path that exists (data/cache.db) is taken as it is
#   - a name is searched for anywhere under P: one hit is used, several are listed to pick from
#   - when nothing has that exact name, files and folders with a similar name are offered
# No tree: just the paths. Status 1 = nothing picked.
function gi_resolve
    set -l p $argv[1]
    set -l t $argv[2]
    set -l rel $argv[3]
    set -l shown (string replace -- "$HOME/" '~/' $p)
    set -g gi_picked

    if string match -q '*/*' -- $rel; and test -e $p/$rel -o -L $p/$rel
        set -g gi_picked $rel
        return 0
    end

    set -l name (string replace -r -- '^.*/' '' $rel)
    set -l hits (gi_find $p $name exact)
    set -l head ""
    if string match -q '*/*' -- $rel
        test (count $hits) -gt 0; and set head "'$t' is not there, but '$name' exists elsewhere in $shown:"
    else if test (count $hits) -eq 1
        set -g gi_picked $hits
        info "found: $hits[1]"
        return 0
    else if test (count $hits) -gt 1
        set head "'$name' is in "(count $hits)" places in $shown:"
    end
    if test (count $hits) -eq 0
        set hits (gi_find $p $name partial)
        if test (count $hits) -eq 0
            warn "'$t' was not found inside $shown, skipped"
            return 1
        end
        set head "Nothing is called '$name' in $shown. Possible matches:"
    end

    set -l cap 30
    set -l total (count $hits)
    test $total -gt $cap; and set hits $hits[1..$cap]
    echo
    echo $head
    for i in (seq (count $hits))
        set -l kind file
        test -d $p/$hits[$i] -a ! -L $p/$hits[$i]; and set kind folder
        printf '  %3d) %s   (%s)\n' $i $hits[$i] $kind
    end
    test $total -gt $cap; and echo "  ... $total matches, only the first $cap are shown (type a longer name to narrow it down)"
    ask "Which one(s)? (numbers like 1,3 or all; Enter = skip): "; or return 1
    if test -z "$reply"
        echo "  skipped '$t'"
        return 1
    end
    set -l idx (parse_selection (string replace -ra '\s+' ',' -- $reply) (count $hits)); or return 1
    for k in $idx
        set -a gi_picked $hits[$k]
    end
    return 0
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

    echo
    echo "Is there anything specific to keep out of git? Type what to leave out, separated by commas"
    echo "(or by spaces; use commas when a name has spaces):"
    echo "  *.log         every .log file, in every folder that has some (each folder gets its own line)"
    echo "  logs/*.log    the .log files of one folder"
    echo "  cache.db      a file or folder by name: it is searched for inside the folder; if it is in several"
    echo "                places (or only a similar name exists) you pick which path(s) to ignore"
    echo "  data/.venv    a file or folder by its path from the folder"
    ask "Leave out (Enter = the whole folder): "; or return 1

    set -l words (string split -n ' ' -- (string replace -a , ' ' -- $reply))
    if test -z "$reply"; or contains -- . $words
        gi_whole $p $name
        return 0
    end

    set -l toks
    if string match -q '*,*' -- $reply
        set toks (string split -n , -- $reply)
    else
        set toks (string split -n ' ' -- $reply)
    end

    set -l lines        # the lines for .gitignore
    set -l ign_dirs     # folders (from the tracked folder) that are ignored whole
    set -l ign_files    # files (from the tracked folder) that are ignored
    for t in $toks
        set t (string trim -- $t)
        set t (string trim -c "'\"" -- $t)
        test -n "$t"; or continue
        set -l rel $t
        # a typed ~/... or full path inside the folder becomes a path from the folder
        set rel (string replace -r -- '^~' "$HOME" $rel)
        if string match -q -- "$p/*" $rel
            set rel (string sub -s (math (string length -- "$p/") + 1) -- $rel)
        end
        set rel (string replace -r -- '^(\./)+' '' $rel)
        set rel (string trim -r -c / -- $rel)
        if test -z "$rel"; or string match -q -- '/*' $rel; or string match -qr '(^|/)\.\.(/|$)' -- $rel
            warn "'$t' is not inside $shown, skipped"
            continue
        end

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
            else
                # *.log : every folder that holds such files, each recorded with its own path
                set -l files (find $p \( -type f -o -type l \) -name $bpart -printf '%P\n' | sort)
                if test (count $files) -eq 0
                    warn "'$t': no file like that was found inside $shown, nothing added for it"
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
            end
        else
            # one file or one folder: search for the name, and pick when it is in several places
            gi_resolve $p $t $rel; or continue
            for r in $gi_picked
                set -l ln "$base/"(gi_esc $r)
                if test -d $p/$r -a ! -L $p/$r
                    set ln "$ln/"
                    set -a ign_dirs $r
                else
                    set -a ign_files $r
                end
                contains -- $ln $lines; or set -a lines $ln
            end
        end
    end

    if test (count $lines) -eq 0
        warn "nothing was added to .gitignore"
        return 1
    end
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

    # everything that is ignored now
    set -l ud
    set -l uf
    test (count $ign_dirs) -gt 0; and set ud (printf '%s\n' $ign_dirs | sort -u)
    test (count $ign_files) -gt 0; and set uf (printf '%s\n' $ign_files | sort -u)
    set -l out
    for d in $ud
        set -a out "$name/$d/   (folder, "(find "$p/$d" -mindepth 1 | count)" items)"
    end
    set -l nfiles 0
    for f in $uf
        set -l inside 0
        for d in $ud
            string match -q -- "$d/*" $f; and set inside 1
        end
        test $inside -eq 1; and continue
        set nfiles (math $nfiles + 1)
        set -a out "$name/$f"
    end
    echo
    if test (count $out) -eq 0
        echo "Nothing matches yet; files that appear later and match these rules will be ignored."
    else
        echo "Git will ignore these (paths as they are in the notes folder): "(count $ud)" folder(s), $nfiles file(s) outside those folders"
        printf '  %s\n' $out | head -n $tree_max
        test (count $out) -gt $tree_max; and echo "  ... and "(math (count $out) - $tree_max)" more"
    end
    return 0
end

function dir_list
    build_dir_items
    if test (count $items_key) -eq 0
        echo "No tracked folders yet. Add one with: sync-notes.sh dir add"
        return 0
    end
    echo
    printf '  %-42s %-26s %s\n' "LIVE PATH" WHERE OPTIONS
    for l in $items_label
        echo "  $l"
    end
    echo
    echo "  (Backup = restored on every machine; Backup: a,b = kept in Backup but restored only for those"
    echo "   desktops; DE: name = restored only for that desktop. Change who uses what: sync-notes.sh dir uses)"
end

# choose_de [GUESS] : ask whether a path belongs to one desktop environment. Sets the global
# $picked_de to that desktop's folder name in "Desktop Environment/", or to nothing when it goes
# to Backup/. Status 1 when cancelled.
function choose_de
    set -g picked_de
    set -l des (de_dirs $notes)
    set -l guess $argv[1]
    set -l dflt n
    test -n "$guess"; and set dflt y
    yes_no "Is it part of one desktop environment's setup? (then it is restored only for that desktop)" $dflt; or return 0

    echo
    echo "Which desktop?"
    for i in (seq (count $des))
        echo "  $i) $des[$i]"
    end
    set -l hint "type the name of a new one"
    test (count $des) -gt 0; and set hint "number or name, or type the name of a new one"
    test -n "$guess"; and set hint "$hint; Enter = $guess"
    ask "Desktop ($hint): "; or return 1

    set -l pick $reply
    if test -z "$pick"
        test -n "$guess"; or return 1
        set pick $guess
    else if string match -qr '^[0-9]+$' -- $pick
        if test $pick -ge 1 -a $pick -le (count $des)
            set pick $des[$pick]
        else
            warn "no desktop number $pick"
            return 1
        end
    end

    # a folder that matches in another letter case is the same desktop
    set -l ex (de_dir_name $notes $pick)
    if test -n "$ex"
        set pick $ex
    else
        if not string match -qr '^[A-Za-z][A-Za-z0-9._-]*$' -- $pick
            warn "'$pick' is not a good desktop name (start with a letter; letters, digits, . _ - only)"
            return 1
        end
        yes_no "There is no desktop called '$pick' yet. Create it?" y; or return 1
    end
    set -g picked_de $pick
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
    echo "Which desktops use it? (it stays in $layout_backup/; only the restore is limited to them)"
    for i in (seq (count $des))
        set -l mark ""
        contains -- $des_lc[$i] $found; and set mark "   <- their files mention '$word'"
        echo "  $i) $des[$i]$mark"
    end
    echo "  a) all of them (restored on every machine)"
    set -l dl all
    test (count $dflt) -gt 0; and set dl (string join ' ' -- $dflt)
    set -l hint "numbers or names, e.g. '1 2'; a new name is fine too"
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

function dir_add
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

    # a folder: show what is inside (hidden files too), so it is clear what is about to be backed up
    if test -d $p -a ! -L $p
        tree_show $p
    end

    # outside the home folder (/etc, /usr/local/bin...): allowed, but it is a system file. Reading it
    # may need sudo, and restoring it on a new machine needs sudo and replaces what is there.
    set -l is_sys 0
    string match -q -- "$HOME/*" $p; or set is_sys 1
    if test $is_sys -eq 1
        echo
        warn "$p is outside your home folder (a system file)"
        echo "   - it is copied into the notes under $layout_system/ (reading it may ask for your sudo password)"
        echo "   - initual-setup.sh puts it back with sudo, as root, and replaces whatever is there"
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
    if test $is_sys -eq 0
        choose_de $guess; or begin
            echo "cancelled"
            return 1
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

    # Backup/ is restored on every machine, unless only some desktops use it (rofi, ...). It stays in
    # Backup/ either way: the desktops are just a limit on the restore.
    set -l uses
    if test -z "$picked_de"
        set -l hit
        test $is_sys -eq 0; and set hit (de_mentions $def)
        set -l ud n
        test (count $hit) -gt 0; and set ud y
        if yes_no "Do only some desktops use it? (it stays in "(test $is_sys -eq 1; and echo $layout_system; or echo $layout_backup)"/, but is restored only for them)" $ud
            choose_uses $def; or return 1
            set uses $picked_uses
        end
    end

    set -l opts
    yes_no "Does it hold secrets? (locked down, and kept out of git)" n; and set -a opts private
    yes_no "Make its .sh and .py files executable when restored?" n; and set -a opts exec
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
            yes_no "It mentions /home/...: rewrite that to the new machine's home folder and user when restored?" y; and set -a opts rehome
        end
    end
    ask "Leave anything out? (names or patterns like .venv or *.log, space separated; Enter = nothing): "; or return 1
    for pat in (string split -n ' ' -- (string replace -a , ' ' -- "$reply"))
        set -a opts "exclude=$pat"
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
        info "new desktop '$picked_de': optional pre.fish / post.fish in $layout_de/$picked_de run during the setup"
    end

    # keep it out of git? (separate from "secrets": the files are still copied into the
    # notes folder and the USB backup copy, git just never sees them)
    set -l gi_default n
    contains -- private $opts; and set gi_default y
    if yes_no "Keep it out of git? (still backed up in the notes folder and the USB copy)" $gi_default
        if test -d $p -a ! -L $p
            # a folder: ask whether only some types / files / folders should be left out
            git_ignore_dir $p $name
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
    end
    if yes_no "Copy it into the notes now? (a sync without the git step)" y
        fish $self --sync --no-git
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
        if tracked_name_ok $n; and test -e $notes/$n -o -L $notes/$n
            if yes_no "Also delete the copy in the notes ($n)?" n
                rm -rf $notes/$n
                info "deleted $notes/$n"
                prune_empty (dirname $notes/$n)
            end
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
        echo "Some are saved in a desktop's folder, so they are restored only for that desktop."
        echo "To share them, their copies move to $layout_backup/ and only the desktops you pick restore them."
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
            de_dir_name $notes $names[$i] >/dev/null; and set mark "   (already in the notes)"
            printf '  %d) %-10s %s%s\n' $i $names[$i] $paths[$i] $mark
        end
        echo "  p) none of these: type a path instead"
        ask "Choose [1-"(count $names)", p; Enter = cancel]: "; or return 1
        if test -z "$reply"
            echo "cancelled"
            return 0
        end
        set choice (string lower -- $reply)
    else
        echo "Could not tell which desktop you use from ~/.config (nothing known was found)."
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
        ask "Path of its config folder or file (type it, or drag it here; Enter = cancel): "; or return 1
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
        warn "'$de' is not a good desktop name (start with a letter; letters, digits, . _ - only)"
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
    echo "Config to back up for $de (saved under $layout_de/$de/, restored only when $de is chosen):"
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
        echo "(a thing several desktops share can be limited to them later with: sync-notes.sh dir uses)"
        ask "Add which to $de? (numbers like 1,3-4, all; Enter = none): "; or return 1
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
        echo "Already backed up in $layout_backup/, restored only for other desktops:"
        for i in (seq (count $share_name))
            echo "  $share_name[$i]   (now: $share_tags[$i])"
        end
        yes_no "Does $de use them too? (it is added to their desktops; nothing is moved)" y; and set do_share 1
    end
    set -l want_exec 0
    yes_no "Make the .sh and .py files in those folders executable when restored?" y; and set want_exec 1
    ask "Packages to install for $de (names separated by spaces; Enter = none): "; or return 1
    set -l pkgs (string split -n ' ' -- (string replace -a , ' ' -- $reply))

    if test $dry -eq 1
        info "[dry-run] would create $layout_de/$de with pre.fish and post.fish and track the config above"
        return 0
    end

    mkdir -p $notes/$layout_de/$de
    de_starter $notes/$layout_de/$de/pre.fish pre $de
    de_starter $notes/$layout_de/$de/post.fish post $de
    info "$layout_de/$de is ready (edit pre.fish / post.fish for its own setup steps)"

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
        track_add $lp (tracked_name_for $lp $de) $opts
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
    info "setup will now list '$de'. Auto-detect picks it when '$delc' is in the desktop name of the session"
    info "(\$XDG_CURRENT_DESKTOP / \$DESKTOP_SESSION); otherwise choose it from the list."
    if yes_no "Copy the config into the notes now? (a sync without the git step)" y
        fish $self --sync --no-git
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
        info "tracked.conf is already in the Backup / Desktop Environment layout, nothing to migrate"
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
            info "$layout_de/$mig_de_result/$kind.fish is already there, removed additional-scripts/de/"(basename $h)
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
    info "migrated. Run sync-notes.sh to refresh the copies; git will see the moves as renames."
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
    echo "  5) pipx (a PyPI name, or pipx:git+https://... for an app that is not on PyPI)"
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
            ask "pipx app(s): a PyPI name, or a git address / path (spaces or commas; Enter = cancel): "; or return 0
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
        echo "  6) Rename a package (give any entry a name of your own)"
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
        echo "  4) Choose which desktops use one (rofi...)"
        echo "  5) Add a desktop environment (scans ~/.config)"
        echo "  0) Back"
        ask "Choose: "; or return 0
        switch $reply
            case 1
                dir_list
            case 2
                dir_add
            case 3
                dir_remove
            case 4
                dir_uses
            case 5
                de_add
            case 0 ''
                return 0
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

# manage_cli GROUP SUB [ARG] : sync-notes.sh pkg list|search|add|remove|export|install, dir list|add|remove
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
                    dir_list
                case add
                    dir_add "$argv[3]"
                case remove rm
                    dir_remove
                case uses
                    dir_uses
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
            echo "archive  - like mirror, but deleted files go to a trash folder first (kept $archive_days days)"
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
            echo "  6) Move the notes to the new layout (Backup / Desktop Environment)   (still to move: $old_layout)"
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
                        warn "kept old copy of $dst: this sync would delete $n_rm of $n_old items (30%+ or everything)."
                        warn "if that is intended run with --force, or switch to archive mode (--set-deletes)"
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
    info "$src -> $dst"
end

# ---------------------------------------------------------------- tracked folders
# Everything listed in additional-scripts/tracked.conf (config.fish, ghostty, Keypass,
# .passwords, Music ... and whatever you add with the manager), each saved as Backup/<path>
# or Desktop Environment/<DE>/<path>.
info "deleted files: $delmode mode"
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
        warn "tracked.conf: '$name' is not in the Backup / Desktop Environment layout, skipped (run: sync-notes.sh --migrate)"
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
        warn "git backup aborted, these files must not be committed (fix .gitignore):"
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
