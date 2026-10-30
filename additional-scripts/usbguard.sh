#!/usr/bin/env fish
# usb-allow.fish
# Pick which blocked USBGuard devices to allow (all, a range, or a comma list),
# then rewrite /etc/usbguard/rules.conf from the devices that are allowed.
#
# Selection examples at the prompt:
#   all        every blocked device in the list
#   3          only device 3
#   1-4        devices 1 to 4
#   1,4,6      devices 1, 4 and 6
#   1-3,7,9-10 any mix
#   Enter / q  stop and save

set hub_delay 3       # wait after allowing hubs so downstream devices enumerate
set dev_delay 1.5     # pause between non-hub devices
set rules /etc/usbguard/rules.conf

function blocked_lines
    sudo usbguard list-devices -b
end

function dev_id
    string match -rg '^(\d+):' -- $argv[1]
end

function dev_name
    string match -rg 'name "([^"]*)"' -- $argv[1]
end

function dev_usbid
    string match -rg ' id ([0-9a-fA-F*]+:[0-9a-fA-F*]+)' -- $argv[1]
end

function is_hub
    string match -qr 'with-interface (\{ )?09:' -- $argv[1]
end

function allow_dev
    printf 'allowing #%s  %s\n' $argv[1] $argv[2]
    if not sudo usbguard allow-device -p $argv[1]
        printf '  failed: #%s\n' $argv[1]
        return 1
    end
end

# Turn "all", "3", "1-4" or "1,4,6-8" into a sorted list of unique numbers.
# $argv[1] = input text, $argv[2] = how many devices are listed.
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

# --- preflight: make usbguard safe to start, then start + enable it
set conf /etc/usbguard/usbguard-daemon.conf

function set_conf
    if sudo grep -q "^$argv[1]=" $conf
        sudo sed -i "s/^$argv[1]=.*/$argv[1]=$argv[2]/" $conf
    else
        echo "$argv[1]=$argv[2]" | sudo tee -a $conf >/dev/null
    end
end

sudo -v; or exit 1

if not sudo test -f $conf
    echo "usbguard is not installed (missing $conf): sudo pacman -S usbguard"
    exit 1
end

# A fresh install has an empty policy. With the default apply-policy and
# ImplicitPolicyTarget=block, starting the daemon would block the keyboard
# and mouse. Let devices present at boot through first.
set_conf PresentDevicePolicy allow
set_conf PresentControllerPolicy allow

# the daemon needs the rule file to exist (root only, mode 600)
sudo mkdir -p /etc/usbguard
if not sudo test -f $rules
    sudo install -m 600 -o root -g root /dev/null $rules
end

if not systemctl is-active --quiet usbguard
    echo "starting and enabling usbguard..."
end
sudo systemctl enable --now usbguard
sleep 2
if not systemctl is-active --quiet usbguard
    echo "usbguard failed to start:"
    journalctl -u usbguard -b --no-pager | tail -15
    exit 1
end

# --- choose and allow loop
# Each pass lists what is blocked right now. Devices behind a hub only show up
# after the hub is allowed, so they appear in a later pass.
while true
    set lines (blocked_lines)
    if test (count $lines) -eq 0
        echo "No blocked devices left."
        break
    end

    echo
    printf '== %s blocked device(s) ==\n' (count $lines)
    set n 0
    for l in $lines
        set n (math $n + 1)
        set tag ""
        is_hub $l; and set tag " [hub]"
        printf '%3s) %-10s %s%s\n' $n (dev_usbid $l) (dev_name $l) $tag
    end
    echo

    # ask until the selection is valid, or the user stops
    set idx
    set stop 0
    while true
        read -P "Allow which? (all, 1-3, 1,4,6, Enter/q = stop): " choice
        or begin
            set stop 1
            break
        end
        if test -z "$choice" -o "$choice" = q -o "$choice" = Q
            set stop 1
            break
        end
        set idx (parse_selection "$choice" (count $lines)); and break
    end
    test $stop -eq 1; and break

    # 1) selected hubs first
    set hubs_allowed 0
    for i in $idx
        set l $lines[$i]
        if is_hub $l
            allow_dev (dev_id $l) "HUB: "(dev_name $l); and set hubs_allowed (math $hubs_allowed + 1)
            sleep 0.5
        end
    end
    test $hubs_allowed -gt 0; and sleep $hub_delay

    # 2) the rest of the selection
    for i in $idx
        set l $lines[$i]
        is_hub $l; and continue
        allow_dev (dev_id $l) (dev_name $l)
        sleep $dev_delay
    end

    sleep 1
end

# --- persist: 'allow-device -p' did not stick on this system, so write the policy directly.
# Only devices that are allowed right now become rules, so anything you left blocked stays
# blocked after a reboot. (list-devices lines are valid rules once the "N: " prefix is removed.)
echo
set tmp (mktemp)
sudo usbguard list-devices -a | string replace -r '^\d+: ' '' >$tmp
if test (count (cat $tmp)) -eq 0
    echo "No allowed devices found, leaving $rules unchanged."
    rm -f $tmp
    exit 1
end
sudo install -m 600 -o root -g root $tmp $rules
rm -f $tmp
printf 'saved %s allow rules to %s\n' (sudo grep -c '^allow' $rules) $rules

set left (blocked_lines)
if test (count $left) -gt 0
    printf '%s device(s) left blocked (no rule written for them).\n' (count $left)
end
