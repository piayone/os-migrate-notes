
#!/usr/bin/env fish

set -l engine linux-wallpaperengine
set -l assets "$HOME/Games/steamapps/common/wallpaper_engine/assets"
set -l workshop "$HOME/Games/steamapps/workshop/content/431960"
set -l screen HDMI-A-1
set -l logfile "$HOME/Desktop/workshop.txt"
set -l wpe_scripts "$HOME/.config/mango/scripts"

# Verify paths and executable
if not type -q $engine
    echo "Error: linux-wallpaperengine not found."
    exit 1
end

if not test -d "$assets"
    echo "Error: Assets directory not found: $assets"
    exit 1
end

if not test -d "$workshop"
    echo "Error: Workshop directory not found: $workshop"
    exit 1
end

if not test -d "$HOME/Desktop"
    echo "Error: Desktop directory not found."
    exit 1
end

touch "$logfile"

# Stop Mango WPE helper scripts
echo "Stopping Mango WPE helper scripts..."
pkill -TERM -f "$wpe_scripts/wpe-(trace|resume-watch|autopause)\.sh"
sleep 1

# Stop existing wallpaper engine instances
echo "Stopping existing linux-wallpaperengine instances..."
pkill -TERM -x linux-wallpaperengine
sleep 2

# Collect workshop directories in sorted order
set -l wallpapers (find "$workshop" -mindepth 1 -maxdepth 1 -type d | sort)

if test (count $wallpapers) -eq 0
    echo "No wallpaper directories found."
    exit 1
end

echo "Found "(count $wallpapers)" wallpapers."
echo "Target display: $screen"
echo "Rejected IDs log: $logfile"

for wallpaper in $wallpapers
    set -l id (basename "$wallpaper")

    echo
    echo "========================================"
    echo "Wallpaper: $id"
    echo "========================================"

    # Start wallpaper preview
    $engine \
        --assets-dir "$assets" \
        --screen-root "$screen" \
        --layer bottom\
        --bg "$wallpaper" &

    set -l pid $last_pid

    sleep 3

    echo
    echo "Keep wallpaper $id?"
    echo "  y = Yes, keep it and continue"
    echo "  n = No, record ID and continue"

    read -l -P "[y/n] " answer

    switch $answer
        case y Y
            echo "Keeping wallpaper $id."
            # Leave it running and continue.

        case n N
            if not contains -- "$id" (cat "$logfile")
                echo "$id" >> "$logfile"
            end
            echo "Recorded rejected wallpaper $id."
            kill -TERM $pid 2>/dev/null
            wait $pid 2>/dev/null

        case '*'
            echo "Invalid choice; stopping this preview."
            kill -TERM $pid 2>/dev/null
            wait $pid 2>/dev/null
    end
end

echo
echo "Finished cycling through all wallpapers."
