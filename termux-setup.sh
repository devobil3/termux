#!/bin/bash
set -e

while :; do
    read -p "Enter username: " user </dev/tty
    [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] && break || echo "Invalid username."
done

while :; do
    read -s -p "Enter password for '$user': " pw </dev/tty; echo
    read -s -p "Confirm password: " cpw </dev/tty; echo
    [[ -n "$pw" && "$pw" == "$cpw" ]] && break || echo "Mismatch. Retry."
done

read -s -p "Enter root password (Press Enter to reuse user password): " r_pw </dev/tty; echo
[[ -z "$r_pw" ]] && r_pw="$pw"

start_time=$(date +%s)


tz=$(getprop persist.sys.timezone); tz=${tz:-${TZ:-Etc/UTC}}
loc=$(getprop persist.sys.locale);  loc="${loc:-en_US}"; loc="${loc//-/_}.UTF-8"

export DEBIAN_FRONTEND=noninteractive
pkg upgrade -y -o Dpkg::Options::="--force-confold"

pkg i -y x11-repo
pkg i -y termux-x11-nightly proot-distro pulseaudio virglrenderer-android

pd i debian

pd login debian --shared-tmp -- sh -c '
    set -e
    u="$1"; p="$2"; rp="$3"; t="$4"; l="$5"

    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
        sudo xfce4 xfce4-terminal dbus-x11 locales fastfetch firefox-esr

    for g in storage wheel video; do groupadd -f "$g"; done
    useradd -m -g users -G wheel,audio,video,storage -s /bin/bash "$u"
    printf "root:%s\n%s:%s\n" "$rp" "$u" "$p" | chpasswd
    
    echo "$u ALL=(ALL:ALL) ALL" >> /etc/sudoers

    ln -sf "/usr/share/zoneinfo/$t" /etc/localtime || ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime
    printf "en_US.UTF-8 UTF-8\n%s UTF-8\n" "$l" > /etc/locale.gen
    
    locale-gen && echo "LANG=$l" > /etc/locale.conf
' bash "$user" "$pw" "$r_pw" "$tz" "$loc"

# Replaced the embedded EOF script block with a download command from GitHub using the "GITHUB" placeholder
curl -sL "https://raw.githubusercontent.com/devobil3/termux/refs/heads/main/debian-laucher.sh" > "$PREFIX/bin/debian"

sed -i "s/USERNAME/$user/g" "$PREFIX/bin/debian"

chmod +x "$PREFIX/bin/debian"

end_time=$(date +%s)
elapsed=$((end_time - start_time))
elapsed_min=$((elapsed / 60))
elapsed_sec=$((elapsed % 60))

echo "Installation Complete in ${elapsed_min}m ${elapsed_sec}s! You can now start Debian by typing 'debian' in your terminal."