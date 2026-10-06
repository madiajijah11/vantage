#!/bin/bash

#Requirement: zenity, xinput, networkmanager, pulseaudio or pipewire-pulse
#Authors: Nizam (nizam@europe.com), Lanchon (https://github.com/Lanchon)

ENABLE_FAN_MODE=1

VPC="/sys/bus/platform/devices/VPC2004\:*"

# Resolve the platform glob in this shell: $VPC is passed to `pkexec sh -c` as a
# double-quoted literal later, and sh -c does not glob-expand it.
vpc_resolve() {
    local resolved
    resolved="$(echo $VPC/$1 2>/dev/null)"
    [ -e "$resolved" ] && echo "$resolved"
}

# Touchpad: xinput is absent on Wayland/libinput-only systems (Pop!_OS 24.04+).
# Fall back to the GNOME/Plasma desktop schema, which needs no root.
touchpad_backend="none"
touchpad_id=""
if command -v xinput >/dev/null && touchpad_id="$(xinput list | grep "Touchpad" | cut -d '=' -f2 | awk '{print $1}')" && [ -n "$touchpad_id" ]; then
    touchpad_backend="xinput"
elif command -v gsettings >/dev/null && gsettings list-schemas | grep -q "peripherals.touchpad"; then
    touchpad_backend="gsettings"
fi

# Refuse to run on hardware without the Lenovo Ideapad ACPI platform: the $VPC
# glob would expand to nothing and every status read below would fail.
if [ ! -e $VPC/conservation_mode ] && [ ! -e $VPC/fn_lock ]; then
    if command -v zenity >/dev/null; then
        zenity --error --title="Lenovo Vantage" \
            --text="No Lenovo Ideapad ACPI platform found (VPC2004).\n\nThis tool only supports Lenovo IdeaPad and ThinkPad laptops." 2>/dev/null
    else
        echo "No Lenovo Ideapad ACPI platform found (VPC2004)." >&2
    fi
    exit 1
fi

get_conservation_mode_status() {
    cat $VPC/conservation_mode | awk '{print ($1 == "1") ? "On" : "Off"}'
}

get_usb_charging_status() {
    if [ -e $VPC/usb_charging ]; then
        cat $VPC/usb_charging | awk '{print ($1 == "1") ? "On" : "Off"}'
    else
        echo "Not available on this model"
    fi
}

# Fan mode: the kernel sysfs ABI documents 0/1/2/4, but firmware does not
# always use the documented encoding. Observed on IdeaPad Gaming 3 (VPC2004):
#   write 0 -> reads back 133   (Super Silent, reported as 0x85)
#   write 1 -> reads back 3     (Standard)
#   write 2/4 -> readback unchanged (firmware accepts, silently no-ops)
# So the read value must be decoded through a map, and a write must be verified
# against a fresh read before the UI claims success.
FAN_MODE_VALUES=(0 1 2 4)

fan_mode_label_for_value() {
    case "$1" in
        0) echo "Super Silent" ;;
        1) echo "Standard" ;;
        2) echo "Dust Cleaning" ;;
        4) echo "Efficient Thermal Dissipation" ;;
    esac
}

fan_mode_label_for() {
    case "$1" in
        0|133) echo "Super Silent" ;;
        1|3)   echo "Standard" ;;
        2)     echo "Dust Cleaning" ;;
        4)     echo "Efficient Thermal Dissipation" ;;
        *)     echo "Unknown ($1)" ;;
    esac
}

get_fan_mode_status() {
    fan_mode_label_for "$(cat "$(vpc_resolve fan_mode)" 2>/dev/null)"
}

# Modes the firmware actually applies. Probed once and cached: writing a mode
# the firmware ignores reports success at the sysfs level but changes nothing.
FAN_MODE_PROBE_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/vantage/fan-mode-supported"

fan_modes_supported() {
    if [ -r "$FAN_MODE_PROBE_CACHE" ]; then
        cat "$FAN_MODE_PROBE_CACHE"
        return
    fi

    local fan_path current supported value before readback attempt restored
    fan_path="$(vpc_resolve fan_mode)"
    [ -n "$fan_path" ] || { echo ""; return; }

    current="$(cat "$fan_path" 2>/dev/null)"
    supported=""
    for value in "${FAN_MODE_VALUES[@]}"; do
        before="$(cat "$fan_path" 2>/dev/null)"
        pkexec sh -c "echo $value > $fan_path" >/dev/null 2>&1 || continue
        # EC apply is asynchronous; poll until the readback settles.
        attempt=0
        readback="$before"
        while [ $attempt -lt 6 ]; do
            sleep 0.5
            readback="$(cat "$fan_path" 2>/dev/null)"
            [ "$readback" != "$before" ] && break
            attempt=$((attempt + 1))
        done
        [ "$readback" != "$before" ] && supported="$supported $value"
    done

    # Restore whatever the user had before probing. Firmware readback values are
    # not always the documented write values (the kernel rejects anything >4), so
    # map back where known and tell the user when we cannot restore exactly.
    local restored=1
    case "$current" in
        0|1|2|4) pkexec sh -c "echo $current > $fan_path" >/dev/null 2>&1 ;;
        133) pkexec sh -c "echo 0 > $fan_path" >/dev/null 2>&1 ;;
        3)   pkexec sh -c "echo 1 > $fan_path" >/dev/null 2>&1 ;;
        "")  restored=0 ;;
        *)   restored=0 ;;  # undocumented encoding, not writable
    esac
    [ $restored -eq 0 ] && notify_error \
        "Fan mode was '$current' before this probe, an encoding this tool cannot write back. It is now '$(get_fan_mode_status)'."

    mkdir -p "$(dirname "$FAN_MODE_PROBE_CACHE")"
    echo "$supported" > "$FAN_MODE_PROBE_CACHE"
    echo "$supported"
}

fan_mode_set() {
    local value="$1" expected="$2" attempt=0 readback="" fan_path
    fan_path="$(vpc_resolve fan_mode)"
    [ -n "$fan_path" ] || { notify_error "fan_mode is not available on this model."; return 1; }

    if ! pkexec sh -c "echo $value > $fan_path" >/dev/null 2>&1; then
        notify_error "Could not write fan mode (permission or firmware error)."
        return 1
    fi
    # EC apply is asynchronous; give it up to 3s to settle, then verify.
    while [ $attempt -lt 6 ]; do
        sleep 0.5
        readback="$(cat "$fan_path" 2>/dev/null)"
        attempt=$((attempt + 1))
        [ "$(fan_mode_label_for "$readback")" = "$expected" ] && return 0
    done
    notify_error "Firmware did not apply '$expected' (fan mode reads $readback)."
    return 1
}

get_fn_lock_status() {
    cat $VPC/fn_lock | awk '{print ($1 == "1") ? "Off" : "On"}'
}

get_camera_status() {
    lsmod | grep -q 'uvcvideo' && echo "On" || echo "Off"
}

get_microphone_status() {
    pactl get-source-mute @DEFAULT_SOURCE@ | awk '{print ($2 == "yes") ? "Muted" : "Active"}'
}

get_touchpad_status() {
    case $touchpad_backend in
        xinput)
            xinput --list-props "$touchpad_id" | grep "Device Enabled" | cut -d ':' -f2 | awk '{print ($1 == "1") ? "On" : "Off"}'
            ;;
        gsettings)
            gsettings get org.gnome.desktop.peripherals.touchpad send-events | tr -d "'" | awk '{print ($1 == "enabled") ? "On" : "Off"}'
            ;;
        *)
            echo "Unsupported"
            ;;
    esac
}

touchpad_set_enabled() {
    local state="$1" # true | false
    case $touchpad_backend in
        xinput) xinput --enable "$touchpad_id" "$([ "$state" = true ] && echo 1 || echo 0)" ;;
        gsettings) gsettings set org.gnome.desktop.peripherals.touchpad send-events "$([ "$state" = true ] && echo enabled || echo disabled)" ;;
        *) echo "Touchpad control unsupported on this system." >&2; return 1 ;;
    esac
}

get_wifi_status() {
    nmcli radio wifi | awk '{print ($1 == "enabled") ? "On" : "Off"}'
}

SUBMENU_ON="Activate"
SUBMENU_OFF="Deactivate"

notify_error() {
    command -v zenity >/dev/null && \
        zenity --error --title="Lenovo Vantage" --text="$1" 2>/dev/null
    [ $? -ne 0 ] && echo "$1" >&2
    return 0
}

show_submenu() {
    local title="$1"
    local status="$2"
    zenity --list --title "$title" --text "Status: $status" --column "Menu" "${@:3}"
}

show_submenu_on_off() {
    show_submenu "$@" "$SUBMENU_ON" "$SUBMENU_OFF"
}

main() {
    while :; do
        local options=()
        test -f $VPC/conservation_mode && options+=("Conservation Mode" "$(get_conservation_mode_status)")
        test -f $VPC/usb_charging && options+=("Always-On USB" "$(get_usb_charging_status)")
        test -f $VPC/fan_mode && test "$ENABLE_FAN_MODE" = 1 && options+=("Fan Mode" "$(get_fan_mode_status)")
        test -f $VPC/fn_lock && options+=("FN Lock" "$(get_fn_lock_status)")
        modinfo -n uvcvideo >/dev/null && options+=("Camera" "$(get_camera_status)")
        which pactl >/dev/null && options+=("Microphone" "$(get_microphone_status)")
        test "$touchpad_backend" != none && options+=("Touchpad" "$(get_touchpad_status)")
        which nmcli >/dev/null && options+=("WiFi" "$(get_wifi_status)")

        local menu="$(zenity --list --title "Lenovo Vantage" --text "Select function:" --column "Function" --column "Status" "${options[@]}" --height 340 --width 350)"
        case "$menu" in
            "Conservation Mode")
                local submenu="$(show_submenu_on_off "Conservation Mode" "$(get_conservation_mode_status)")"
                case "$submenu" in
                    "$SUBMENU_ON") echo "1" | pkexec tee $VPC/conservation_mode ;;
                    "$SUBMENU_OFF") echo "0" | pkexec tee $VPC/conservation_mode ;;
                esac
                ;;
            "Always-On USB")
                local submenu="$(show_submenu_on_off "Always-On USB" "$(get_usb_charging_status)")"
                case "$submenu" in
                    "$SUBMENU_ON") echo "1" | pkexec tee $VPC/usb_charging ;;
                    "$SUBMENU_OFF") echo "0" | pkexec tee $VPC/usb_charging ;;
                esac
                ;;
            "Fan Mode")
                # Only offer modes the firmware actually applies on this model.
                # fan_map[label] = sysfs write value (indexes are not parallel:
                # fan_items only holds the supported subset).
                local -a fan_items=()
                declare -A fan_map=()
                local supported supported_list
                supported_list=" $(fan_modes_supported) "
                for supported in "${FAN_MODE_VALUES[@]}"; do
                    case "$supported_list" in
                        *" $supported "*)
                            fan_map["$(fan_mode_label_for_value "$supported")"]="$supported"
                            fan_items+=("$(fan_mode_label_for_value "$supported")")
                            ;;
                    esac
                done
                if [ ${#fan_items[@]} -eq 0 ]; then
                    notify_error "No fan mode could be applied on this model."
                    break
                fi
                local submenu="$(show_submenu "Fan Mode" "$(get_fan_mode_status)" --height 250 --width 300 "${fan_items[@]}")"
                [ -n "${fan_map[$submenu]:-}" ] && fan_mode_set "${fan_map[$submenu]}" "$submenu"
                ;;
            "FN Lock")
                local submenu="$(show_submenu_on_off "FN Lock" "$(get_fn_lock_status)")"
                case "$submenu" in
                    "$SUBMENU_ON") echo "0" | pkexec tee $VPC/fn_lock ;;
                    "$SUBMENU_OFF") echo "1" | pkexec tee $VPC/fn_lock ;;
                esac
                ;;
            "Camera")
                local submenu="$(show_submenu_on_off "Camera" "$(get_camera_status)")"
                case "$submenu" in
                    "$SUBMENU_ON") pkexec modprobe uvcvideo ;;
                    "$SUBMENU_OFF") pkexec modprobe -r uvcvideo ;;
                esac
                ;;
            "Microphone")
                local submenu="$(show_submenu "Microphone" "$(get_microphone_status)" \
                    "Mute" \
                    "Unmute" \
                )"
                case "$submenu" in
                    "Mute") pactl set-source-mute @DEFAULT_SOURCE@ 1 ;;
                    "Unmute") pactl set-source-mute @DEFAULT_SOURCE@ 0 ;;
                esac
                ;;
            "Touchpad")
                local submenu="$(show_submenu_on_off "Touchpad" "$(get_touchpad_status)")"
                case "$submenu" in
                    "$SUBMENU_ON") touchpad_set_enabled true ;;
                    "$SUBMENU_OFF") touchpad_set_enabled false ;;
                esac
                ;;
            "WiFi")
                local submenu="$(show_submenu_on_off "WiFi" "$(get_wifi_status)")"
                case "$submenu" in
                    "$SUBMENU_ON") nmcli radio wifi on ;;
                    "$SUBMENU_OFF") nmcli radio wifi off ;;
                esac
                ;;
            *)
                break
                ;;
        esac
    done
}

main "$@"

