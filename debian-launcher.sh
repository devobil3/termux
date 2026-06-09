#!/bin/bash
{
    # 1. Clean up any previous stuck instances
    pkill -9 -f termux.x11
    killall -9 pulseaudio virgl_test_server_android
    # 2. Setup environment and start background services
    export XDG_RUNTIME_DIR=${TMPDIR}
    termux-x11 :0 -ac & X=$!
    pulseaudio --start --exit-idle-time=-1
    pacmd load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1
    virgl_test_server_android & V=$!

    # 3. Open the Termux:X11 Android App View
    am start --user 0 -n com.termux.x11/com.termux.x11.MainActivity

    # 4. Boot Debian (Blocks inside the subshell until you logout)
    proot-distro login debian --user USERNAME --shared-tmp -- bash -c \
    "export DISPLAY=:0 PULSE_SERVER=tcp:127.0.0.1 GALLIUM_DRIVER=virpipe MESA_GL_VERSION_OVERRIDE=4.0; \
    dbus-launch --exit-with-session startxfce4"

    # 5. Cleanup when Debian exits
    kill $X $V; pulseaudio --kill
} >/dev/null 2>&1 &