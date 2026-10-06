#!/bin/bash

#Requirement: zenity, xinput, networkmanager, pulseaudio or pipewire-pulse
#Authors: Nizam (nizam@europe.com), Lanchon (https://github.com/Lanchon)

ENABLE_FAN_MODE=1

VPC="/sys/bus/platform/devices/VPC2004\:*"

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

get_fan_mode_status() {
    cat $VPC/fan_mode | awk '{
        if ($1 == "133" || $1 == "0") print "Super Silent";
        else if ($1 == "1") print "Standard";
        else if ($1 == "2") print "Dust Cleaning";
        else if ($1 == "4") print "Efficient Thermal Dissipation";
        else print "Unknown (" $1 ")";
    }'
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
                local submenu="$(show_submenu "Fan Mode" "$(get_fan_mode_status)" --height 250 --width 300 \
                    "Super Silent" \
                    "Standard" \
                    "Dust Cleaning" \
                    "Efficient Thermal Dissipation" \
                )"
                case "$submenu" in
                    "Super Silent") echo "0" | pkexec tee $VPC/fan_mode ;;
                    "Standard") echo "1" | pkexec tee $VPC/fan_mode ;;
                    "Dust Cleaning") echo "2" | pkexec tee $VPC/fan_mode ;;
                    "Efficient Thermal Dissipation") echo "4" | pkexec tee $VPC/fan_mode ;;
                esac
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

