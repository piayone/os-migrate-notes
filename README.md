# os-migrate-notes

Personal notes to migrate setup on fresh install

The idea is a loop:

1. **`sync-notes.sh`** copies your live configs into this folder (and commits/pushes them).
2. **`initual-setup.sh`** on a new machine installs your packages and puts those configs back.
3. **`pkg-track.fish`** keeps the package list up to date while you use the system.

## Folder layout

```
os-migrate-notes/
├── initual-setup.sh          the setup script (run this on a new machine)
├── Backup/                   files restored on every machine, same paths as your home folder
│   └── .config/..., Documents/..., Music/..., sddm/...
├── Desktop Environment/      one folder per desktop; the folder name is the desktop's name
│   ├── Kde/
│   └── mango/                 each can hold its own files plus pre.fish / post.fish
└── additional-scripts/       helper scripts and lists (below)
    └── test-scripts/         dry-run and wallpaper tools (below)
```

`Backup/` and `Desktop Environment/<DE>/` mirror your home folder: `~/.config/fish/config.fish` is stored as `Backup/.config/fish/config.fish`.

---

## initual-setup.sh

The initial setup. It is a fish script and sits in the notes root.

```fish
./initual-setup.sh                   # asks which desktop and how to handle deleted files
./initual-setup.sh mango             # use these desktops without asking (or: none)
./initual-setup.sh --no-system       # skip System/ files (they need sudo)
./initual-setup.sh --no-pkg-track    # do not install the package tracker
```

**What it does, in order**

1. **Questions first.** Which desktop(s) to set up (auto-detect, pick from the backed-up ones, or none) and the backup delete mode (`mirror`, `archive` (default) or `keep`). Both answers are saved in `~/.config/os-migrate-notes/`, outside the notes.
2. **Packages.** Detects the package manager, offers to install `paru` on Arch, then installs everything from `packages.conf` (native, Flatpak, pipx, snap, git repos). Packages a distro does not have are skipped and listed at the end.
3. **Firewall.** If `ufw` is present, opens the ports for KDE Connect, LocalSend and AudioRelay and enables it.
4. **GRUB (optional, asked).** Can hide the boot menu (timeout 0) and regenerates the GRUB config with `grub-mkconfig` (`grub2-mkconfig` on Fedora/openSUSE). The prompt explains the risk first.
5. **Update + desktop pre-hooks.** Updates the system, then runs each chosen desktop's `pre.fish`. Configs are restored only after this so no package can overwrite them with defaults.
6. **Restore configs.** Copies everything listed in `tracked.conf` back into your home folder. Files outside the home folder (stored under `System/`) are restored with sudo after one confirmation.
7. **Python venvs (asked).** For every `requirements.txt` found in restored folders or cloned repos, asks whether to build a `.venv` next to it.
8. **Desktop post-hooks.** Runs each chosen desktop's `post.fish` (enabling services, manual steps).
9. **Notes.** Makes sure `~/Documents/os-migrate-notes` exists. If it is missing or empty, the whole folder the script ran from is copied there.
10. **Auto-sync timer.** Installs a user systemd timer that runs `sync-notes.sh` 3 minutes after login, then hourly. This is last, so a sync can never overwrite your notes with fresh-install defaults.
11. **Package tracker.** Installs `pkg-track.fish` with the current packages as the baseline.

Everything that needs a terminal answer is skipped safely when there is no terminal.

---

## additional-scripts/

| File | What it is |
|---|---|
| `lib.fish` | Shared helpers sourced by the setup, sync and tracker scripts (package manager detection, reading and writing the lists, install functions). Not run directly. |
| `sync-notes.sh` | The reverse of the setup: copies live configs into the notes, then commits and pushes to git. Also the manager for the lists. |
| `pkg-track.fish` | Keeps `packages.conf` in step with what you install or remove by hand. |
| `mangohud-env.sh` | Turns MangoHud on for one program by editing its launcher. |
| `usbguard.sh` | Interactive USBGuard setup and device allow-list. |
| `packages.conf` | The list of packages the setup installs. |
| `tracked.conf` | The list of files and folders that are backed up and restored. |
| `shared.conf` | Which desktops use shared things that are not in `tracked.conf` (the SDDM login screen). |
| `pkg-ignore.conf` | Package names or patterns the tracker should never add automatically. |

### sync-notes.sh

Run it from a terminal for a small menu (Enter = normal sync), or let the timer run it.

```fish
./sync-notes.sh                # sync everything, then commit and push
./sync-notes.sh --dry-run      # only show what would be replaced
./sync-notes.sh --no-git       # sync but skip commit and push
./sync-notes.sh --backup       # make a full copy for a USB drive or phone
./sync-notes.sh --manage       # package and folder manager
./sync-notes.sh --set-deletes  # choose mirror / archive / keep
./sync-notes.sh --set-repo     # set the git remote URL
./sync-notes.sh help           # full list of commands
```

Good to know:

- **Delete modes.** `mirror` makes copies match live files exactly (with a mass-delete guard), `archive` moves deleted files to a trash folder first and purges them after 60 days, `keep` never deletes.
- **Safety.** If a live source is missing, the old copy is kept. Folders are copied to a temp location and swapped in only on success. The git commit is refused if a secret or media file (`.kdbx`, `.passwords`, audio, video...) is about to be committed.
- **Backup copy.** `--backup` builds `~/Documents/os-migrate-notes-backup` with everything except git files, keeping the 3 previous versions.
- **Manager commands.** `pkg list|search|add|remove|export|install|script|rename` edit `packages.conf`; `dir list|add|remove|de|uses` edit `tracked.conf` and the desktop folders.
- **Git URL** is stored in `~/.config/os-migrate-notes/git-url`, outside the notes, so it is never synced.

### pkg-track.fish

Compares the list of packages you explicitly installed with a saved baseline and updates `packages.conf` to match. Dependencies and system updates are ignored.

```fish
./pkg-track.fish install     # take a baseline and set up the triggers (needs sudo)
./pkg-track.fish uninstall   # remove the triggers (packages.conf is left alone)
./pkg-track.fish init        # take a new baseline without touching packages.conf
./pkg-track.fish update      # compare now (--force allows a large removal)
./pkg-track.fish status      # baseline, triggers and last changes
./pkg-track.fish log         # last 40 log lines
```

- Covers pacman (any front end), apt, dnf, zypper, Flatpak, snap, pipx and git clones made in `~/Documents`.
- Triggers are a pacman or apt hook, plus user systemd path units for the other sources.
- A single run never removes more than 15 entries, in case a package query breaks. A git clone that disappears is never removed from the list.
- The baseline and log live in `~/.local/state/os-migrate-notes/`. After a change, `packages.conf` is committed and pushed on its own.

### mangohud-env.sh

Enables MangoHud for a single program by putting `MANGOHUD=1` in its launcher.

```bash
./mangohud-env.sh            # menu: add, list, remove
./mangohud-env.sh <name>     # add MangoHud to <name> right away
./mangohud-env.sh --list     # programs that have it enabled
./mangohud-env.sh --remove   # take it out again (numbers, ranges, names)
```

- System launchers are copied to `~/.local/share/applications` first, so package updates never touch your edit. Your own launchers are edited in place with a `.bak` copy.
- Flatpak launchers get `--env=MANGOHUD=1` so the variable reaches the sandbox.
- From a keybind (no terminal) it uses rofi and desktop notifications.
- Enabling it on the Steam launcher only affects the Steam client. For games, set the launch option `mangohud %command%` in Steam.

### usbguard.sh

A fish script that sets up USBGuard and lets you choose which blocked USB devices to allow.

- **Preflight.** Makes the daemon safe to start (devices present at boot are let through so the keyboard and mouse are not blocked), then enables and starts it.
- **Selection.** Lists blocked devices (hubs are tagged) and accepts `all`, `3`, `1-4`, `1,4,6` or any mix. Hubs are allowed first, with a short wait so devices behind them appear in the next pass.
- **Save.** Writes the currently allowed devices to `/etc/usbguard/rules.conf` as the new policy. Anything left blocked stays blocked after a reboot.

### The .conf files

All of these are plain text with comments at the top explaining the format. Edit them with `sync-notes.sh --manage` or by hand.

- **`packages.conf`**: the packages the setup installs, split by type (native, Flatpak, snap, pipx, git), with optional per-distro names and desktop filters. `pkg-track.fish` also edits it.
- **`tracked.conf`**: the live files and folders to back up, where they are stored in the notes, and per-entry options such as permissions and desktop filters.
- **`shared.conf`**: which desktops use the shared SDDM setup.
- **`pkg-ignore.conf`**: names or patterns the tracker never adds on its own.

---

## additional-scripts/test-scripts/

### test-setup.sh

Dry-runs `initual-setup.sh` without installing or changing anything on the real system.

```bash
bash test-setup.sh             # asks the same questions as the real setup
bash test-setup.sh mango       # choose the desktop up front
SETUP=/path/to/initual-setup.sh bash test-setup.sh mango
FORCE=1 bash test-setup.sh     # allow a notes folder larger than 1 GB
```

- `HOME` becomes a throwaway folder (`~/.cache/setup-test/home`), so every `~/...` path lands there. The notes are only read.
- Commands that change the system (`sudo`, `systemctl`, `ufw`, `git`, `pipx`, the GRUB tools, `python -m venv`, installs through pacman, paru and flatpak) are replaced by stubs that only log the command line.
- Read-only queries (`pacman -Q/-Si/-Ss`, `paru -Ss`, `flatpak list/search`) still reach the real tools, so "package not found" results are real.
- The tracker is skipped (`--no-pkg-track`).
- At the end it prints the exit status, the stubbed commands (first 60) and the top level of the fake home. Clean up with `rm -rf ~/.cache/setup-test`.
- Needs `fish`.

### Wallpaper Engine tools

Helpers for going through installed Wallpaper Engine workshop items with `linux-wallpaperengine`. They default to `~/Games/steamapps/...`; edit the variables at the top of each script if yours is elsewhere.

| File | What it does |
|---|---|
| `wpe-scan.sh` | Plays every installed item for a few seconds and records the ones where the engine prints an "Unsupported ..." error. Writes its results to a list in the folder you run it from. Usage: `bash wpe-scan.sh [MONITOR]`. |
| `wpe-review.sh` | Goes through each item one at a time with a live preview: Enter/`y` keeps it, `n` rejects it, `o` opens its Steam workshop page, `q` quits and saves progress. `--reset` starts over. |
| `test-wpe.sh` | An older fish version of the review loop. Previews each item, then asks keep or reject and logs the rejected IDs. It first stops the mango WPE helper scripts and running engine instances. |

`wpe-review.sh` writes its lists in the folder you run it from, so run it from `test-scripts/` to keep them there.# os-migrate-notes
# os-migrate-notes
