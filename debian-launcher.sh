#!/bin/bash

DEFAULT_COUNTDOWN=10
COUNTDOWN=$DEFAULT_COUNTDOWN
APP_CMD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "Usage: debian [OPTIONS] [COMMAND]"
            echo "Options:"
            echo "  -ct, --countdown-time <secs>  Set default countdown timer (does not launch Debian)"
            echo "  -h, --help                    Show this help message"
            echo "COMMAND: The application to launch at startup (e.g., firefox). Starts alongside XFCE4."
            exit 0
            ;;
        -ct|--countdown-time)
            if [[ "$2" =~ ^[0-9]+$ ]]; then
                sed -i "s/^DEFAULT_COUNTDOWN=.*/DEFAULT_COUNTDOWN=$2/" "$0"
                echo "Default countdown changed to $2 seconds."
            else
                echo "Error: Invalid time. Must be a number."
            fi
            exit 0
            ;;
        -*)
            echo "Invalid option: $1"
            "$0" --help
            exit 1
            ;;
        *)
            APP_CMD="$*"
            break
            ;;
    esac
done

if [[ -n "$APP_CMD" ]]; then
    # Changed the process monitor from xfwm4 to xfce4-panel to ensure the desktop environment is fully initialized
    SESSION_CMD="(while ! pidof xfce4-panel >/dev/null; do sleep 1; done; sleep 2; $APP_CMD) & dbus-launch --exit-with-session startxfce4"
else
    SESSION_CMD="dbus-launch --exit-with-session startxfce4"
fi

{
    pkill -9 -f termux.x11
    killall -9 pulseaudio virgl_test_server_android
    export XDG_RUNTIME_DIR=${TMPDIR}
    termux-x11 :0 -ac & X=$!
    pulseaudio --start --exit-idle-time=-1
    pacmd load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1
    virgl_test_server_android & V=$!
    proot-distro login debian --user USERNAME --shared-tmp -- bash -c "export DISPLAY=:0 PULSE_SERVER=tcp:127.0.0.1 GALLIUM_DRIVER=virpipe MESA_GL_VERSION_OVERRIDE=4.0; $SESSION_CMD"
    kill $X $V 2>/dev/null; pulseaudio --kill
} >/dev/null 2>&1 &

tput civis; stty -echo
trap 'tput cnorm; stty echo 2>/dev/null' EXIT
clr() { printf "\033[3A\r\033[J"; }
trap 'clr; pkill -9 -f termux.x11 2>/dev/null; killall -9 pulseaudio virgl_test_server_android 2>/dev/null; echo "Aborted."; exit 1' INT
trap '' TSTP QUIT HUP
launch() { clr; am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity >/dev/null 2>&1; echo "Debian Launched!"; exit; }
run_countdown() {
    local secs=$1
    local cols=$(tput cols 2>/dev/null || echo 80)
    local bar_width=$(( cols - 12 ))
    (( bar_width < 10 )) && bar_width=10
    local steps=$((secs * 3))
    printf "Booting Debian...\n[%-${bar_width}s] %ds\n[ENTER] Open now  [CTRL+C] Abort\n" "" "$secs"
    for i in $(seq 1 $steps); do
        local filled=$(( i * bar_width / steps ))
        local bar=""
        for ((j=0; j<filled; j++)); do bar+="#"; done
        local t=$(date +%s%3N)
        printf "\033[2A\r[%-${bar_width}s] %ds\033[K\033[2B\r" "$bar" $(( (steps-i)/3+1 ))
        while (( $(date +%s%3N) - t < 333 )); do
            IFS= read -rs -n1 -t0.05 k; rc=$?
            [[ $rc -eq 0 && -z "$k" ]] && launch
            while IFS= read -rs -n1 -t0 _ 2>/dev/null; do :; done
        done
    done
    launch
}
run_countdown "$COUNTDOWN"