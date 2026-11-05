#!/usr/bin/env bash
# Deletes everything inside ~/Pictures/Screenshots (the folder itself is kept).
# Run every 2 hours via cron (see below).

DIR="$HOME/Pictures/Screenshots"

# Safety checks: folder must exist and path must not be empty or root
[ -d "$DIR" ] || exit 0
[ -n "$DIR" ] && [ "$DIR" != "/" ] || exit 1

# Delete files and subfolders inside, not the folder itself
find "$DIR" -mindepth 1 -delete

# Optional: only delete files older than 2 hours instead of everything.
# Replace the find line above with:
# find "$DIR" -mindepth 1 -mmin +120 -delete
