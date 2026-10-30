#!/usr/bin/env bash
# Dry-run initual-setup.sh without installing or moving anything on the real system.
#
# How it stays safe:
#   - HOME is a throwaway folder, so every ~/... path the setup writes lands there
#   - commands that change the system (sudo, pacman -S, systemctl, git clone, ufw, python -m venv...)
#     are replaced by stubs that only append the command line to a log
#   - read-only queries (pacman -Q/-Si/-Ss, paru -Ss, flatpak list/search) still reach the real tool,
#     so "package not found on this distro" results are real
#
# Usage: bash test-setup.sh [DESKTOP...]       e.g. bash test-setup.sh mango
#        SETUP=/path/to/initual-setup.sh bash test-setup.sh mango
#
# Needs fish. Everything is kept in ~/.cache/setup-test; delete that folder to clean up.

SETUP="${SETUP:-$HOME/Documents/os-migrate-notes/initual-setup.sh}"
NOTES="$(dirname "$(realpath "$SETUP")")"
BASE="$HOME/.cache/setup-test"
FAKE="$BASE/home"
STUBS="$BASE/stubs"
LOG="$BASE/commands.log"

[ -f "$SETUP" ] || { echo "Not found: $SETUP" >&2; exit 1; }
command -v fish >/dev/null || { echo "fish is required" >&2; exit 1; }

# the setup copies the whole notes folder into the fake home, so check the size first
kb=$(du -sk "$NOTES" 2>/dev/null | cut -f1)
if [ "${kb:-0}" -gt 1048576 ] && [ -z "${FORCE:-}" ]; then
    echo "The notes folder is $((kb / 1024)) MB and the test copies it into $FAKE." >&2
    echo "Run again with FORCE=1 to go ahead anyway." >&2
    exit 1
fi

rm -rf "$BASE"
mkdir -p "$FAKE" "$STUBS"
: > "$LOG"

# real tools for the read-only passthrough (looked up BEFORE the stubs go on PATH)
REAL_PACMAN=$(command -v pacman || true)
REAL_PARU=$(command -v paru || true)
REAL_FLATPAK=$(command -v flatpak || true)

# plain stubs: log the call, do nothing, succeed
for c in sudo systemctl git pipx ufw update-grub grub-mkconfig grub2-mkconfig makepkg \
         apt apt-get dnf zypper update-desktop-database; do
    cat > "$STUBS/$c" <<EOF
#!/bin/sh
echo "$c \$*" >> "$LOG"
exit 0
EOF
    chmod +x "$STUBS/$c"
done

# pacman / paru: queries go to the real tool, anything else is only logged
for pair in "pacman:$REAL_PACMAN" "paru:$REAL_PARU"; do
    name=${pair%%:*}; real=${pair#*:}
    [ -n "$real" ] || continue
    cat > "$STUBS/$name" <<EOF
#!/bin/sh
case "\$1" in
    -Q*|-Si*|-Ss*|-Sl*|-F*|-V|--version|-T) exec "$real" "\$@" ;;
esac
echo "$name \$*" >> "$LOG"
exit 0
EOF
    chmod +x "$STUBS/$name"
done

# flatpak: list/search/info are real, the rest is only logged
if [ -n "$REAL_FLATPAK" ]; then
    cat > "$STUBS/flatpak" <<EOF
#!/bin/sh
case "\$1" in
    list|search|info|remote-ls|--version) exec "$REAL_FLATPAK" "\$@" ;;
esac
echo "flatpak \$*" >> "$LOG"
exit 0
EOF
    chmod +x "$STUBS/flatpak"
fi

# python: no real venv and no pip downloads. "-m venv DIR" makes a fake DIR/bin/pip that logs too.
for c in python python3; do
    cat > "$STUBS/$c" <<EOF
#!/bin/sh
echo "$c \$*" >> "$LOG"
if [ "\$1" = "-m" ] && [ "\$2" = "venv" ]; then
    mkdir -p "\$3/bin"
    printf '#!/bin/sh\necho "pip \$*" >> "$LOG"\n' > "\$3/bin/pip"
    chmod +x "\$3/bin/pip"
fi
exit 0
EOF
    chmod +x "$STUBS/$c"
done

echo "Fake home : $FAKE"
echo "Notes read: $NOTES (only read, never written)"
echo "Command log: $LOG"
echo "---------------------------------------------------------------"

env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME \
    HOME="$FAKE" PATH="$STUBS:$PATH" \
    fish "$SETUP" --no-pkg-track "$@"
status=$?

echo
echo "---------------------------------------------------------------"
echo "Setup exited with status $status"
echo
echo "System-changing commands that were stubbed ($(wc -l < "$LOG") in total, first 60):"
head -n 60 "$LOG"
echo
echo "Top level of the fake home:"
ls -A "$FAKE"
echo
echo "Clean up with: rm -rf $BASE"
