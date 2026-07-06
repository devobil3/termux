#!/data/data/com.termux/files/usr/bin/env bash
# =============================================================================
# Tailscale SERVER Setup — Android A (Server + proot-distro)
# =============================================================================
# This script installs and configures Tailscale in Termux on Android A, then
# sets up OpenSSH inside the proot-distro container so it is reachable from
# Android B over the Tailnet.
#
# Run this script on Android A inside Termux:
#   bash tailscale_server_setup.sh
#
# Optionally specify your proot distro name (default: ubuntu):
#   DISTRO=debian bash tailscale_server_setup.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — edit these if needed
# ---------------------------------------------------------------------------
DISTRO="${DISTRO:-ubuntu}"          # proot-distro name: ubuntu / debian / fedora
SOCKS5_PORT="${SOCKS5_PORT:-1055}"  # fixed SOCKS5 port for reproducibility
SSH_PORT="${SSH_PORT:-2222}"        # port sshd listens on inside proot (host-visible)
# ---------------------------------------------------------------------------

BOLD="\033[1m"; RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; RESET="\033[0m"

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}━━━  $*  ━━━${RESET}"; }

# ════════════════════════════════════════════════════════════════════
header "Step 1: Install dependencies in Termux"
# ════════════════════════════════════════════════════════════════════
info "Updating package lists..."
pkg update -y -q

info "Installing required Termux packages..."
pkg install -y -q curl wget grep dpkg termux-services runit 2>/dev/null || true
apt --fix-broken install -y -q 2>/dev/null || true

# ════════════════════════════════════════════════════════════════════
header "Step 2: Install Tailscale (bropines/tailscale-termux-cli)"
# ════════════════════════════════════════════════════════════════════
if command -v tailscaled &>/dev/null; then
    warn "Tailscale is already installed. Skipping download."
else
    info "Fetching latest tailscale-termux-cli release..."
    REPO="bropines/tailscale-termux-cli"
    LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -Po '"tag_name": "\K.*?(?=")')
    [ -z "$LATEST_TAG" ] && die "Could not fetch latest release tag. Check internet connection."

    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) ARCH="aarch64" ;;
        armv7l|armv8l|arm) ARCH="arm" ;;
        i686|i386) ARCH="i686" ;;
        x86_64|amd64) ARCH="x86_64" ;;
        *) die "Unsupported architecture: $ARCH" ;;
    esac

    DEB_VERSION=$(echo "$LATEST_TAG" | sed 's/^v//' | tr '-' '.')
    DEB_FILE="tailscale-termux_${DEB_VERSION}_${ARCH}.deb"
    DEB_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/$DEB_FILE"

    info "Downloading $DEB_FILE (release $LATEST_TAG)..."
    TMP_DIR=$(mktemp -d "$HOME/tmp.XXXXXX")
    trap 'rm -rf "$TMP_DIR"' EXIT

    wget -q --show-progress -O "$TMP_DIR/$DEB_FILE" "$DEB_URL"

    info "Installing package..."
    pkill -f tailscaled 2>/dev/null || true
    dpkg -i "$TMP_DIR/$DEB_FILE" || true
    apt --fix-broken install -y -q 2>/dev/null || true

    info "Fixing script shebangs for Termux..."
    termux-fix-shebang \
        "$PREFIX/bin/tailscale-cli" \
        "$PREFIX/bin/tailscale-test" \
        "$PREFIX/bin/tailscale-update" \
        "$PREFIX/bin/tailscaled-log" \
        "$PREFIX/bin/tailscaled-start" \
        "$PREFIX/bin/tailscaled-stop" 2>/dev/null || true
fi

success "Tailscale binaries ready."

# ════════════════════════════════════════════════════════════════════
header "Step 3: Configure fixed SOCKS5 port"
# ════════════════════════════════════════════════════════════════════
ENV_FILE="$HOME/.tailscale/.env"
mkdir -p "$HOME/.tailscale"
cat > "$ENV_FILE" <<EOF
# Tailscale environment — sourced by tailscaled-start
TS_SOCKS5_PORT=$SOCKS5_PORT
EOF
success "SOCKS5 port fixed to $SOCKS5_PORT (saved to $ENV_FILE)"

# ════════════════════════════════════════════════════════════════════
header "Step 4: Start tailscaled daemon"
# ════════════════════════════════════════════════════════════════════
info "Starting tailscaled..."
pkill -f tailscaled 2>/dev/null || true
sleep 1
tailscaled-start
sleep 2

if pgrep -f "tailscaled.*statedir" &>/dev/null; then
    success "tailscaled is running. SOCKS5 at 127.0.0.1:$SOCKS5_PORT"
else
    die "tailscaled failed to start. Check logs: cat ~/.tailscale/tailscaled.log"
fi

# ════════════════════════════════════════════════════════════════════
header "Step 5: Authenticate to Tailscale"
# ════════════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}You need to authenticate this device to your Tailnet.${RESET}"
echo "Run the following command and open the printed URL in a browser:"
echo ""
echo -e "  ${BOLD}tailscale-cli up --hostname=android-a-server${RESET}"
echo ""
read -rp "Press ENTER to run this now, or Ctrl-C to skip and run manually later..."
tailscale-cli up --hostname=android-a-server || warn "If it timed out, re-run: tailscale-cli up --hostname=android-a-server"

# ════════════════════════════════════════════════════════════════════
header "Step 6: Install and configure OpenSSH inside proot-distro"
# ════════════════════════════════════════════════════════════════════
info "Checking proot-distro container: $DISTRO"
if ! proot-distro list 2>/dev/null | grep -q "$DISTRO"; then
    die "proot-distro container '$DISTRO' is not installed. Install it with: proot-distro install $DISTRO"
fi

info "Installing openssh-server inside $DISTRO..."
proot-distro login "$DISTRO" -- bash -c "
    set -e
    if command -v apt &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q
        apt-get install -y -q openssh-server sudo
    elif command -v dnf &>/dev/null; then
        dnf install -y -q openssh-server sudo
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm openssh sudo
    else
        echo 'ERROR: No supported package manager found.'
        exit 1
    fi

    mkdir -p /etc/ssh /run/sshd
    if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
        ssh-keygen -A
    fi

    cat > /etc/ssh/sshd_config <<'SSHD_EOF'
Port ${SSH_PORT}
ListenAddress 0.0.0.0
PermitRootLogin yes
PasswordAuthentication yes
ChallengeResponseAuthentication no
UsePAM no
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
AllowTcpForwarding yes
GatewayPorts yes
SSHD_EOF

    echo 'Set a root password (used to SSH in from Android B):'
    passwd root
" || die "Failed to configure SSH inside proot-distro."

success "OpenSSH configured inside $DISTRO on port $SSH_PORT."

# ════════════════════════════════════════════════════════════════════
header "Step 7: Create proot SSH launcher script"
# ════════════════════════════════════════════════════════════════════
PROOT_SSH_RUNNER="$PREFIX/bin/proot-sshd-start"
cat > "$PROOT_SSH_RUNNER" <<RUNNER_EOF
#!/data/data/com.termux/files/usr/bin/bash
# Starts sshd inside proot-distro (${DISTRO}), running in background.
DISTRO="${DISTRO}"
SSH_PORT="${SSH_PORT}"
LOG="\$HOME/.tailscale/proot-sshd.log"

if pgrep -f "sshd -D" &>/dev/null; then
    echo "sshd is already running."
    exit 0
fi

echo "Starting sshd inside \$DISTRO on port \$SSH_PORT..."
nohup proot-distro login "\$DISTRO" -- /usr/sbin/sshd -D -p "\$SSH_PORT" >> "\$LOG" 2>&1 &
sleep 2

if pgrep -f "sshd -D" &>/dev/null; then
    TS_IP=\$(tailscale-cli ip -4 2>/dev/null | head -1 || echo "<tailscale-ip>")
    echo "sshd running. SSH in from Android B:"
    echo "  ssh -p \$SSH_PORT root@\$TS_IP"
else
    echo "ERROR: sshd failed. Check: cat \$LOG"
    exit 1
fi
RUNNER_EOF
termux-fix-shebang "$PROOT_SSH_RUNNER"
chmod +x "$PROOT_SSH_RUNNER"
success "Created launcher: proot-sshd-start"

# ════════════════════════════════════════════════════════════════════
header "Step 8: Summary"
# ════════════════════════════════════════════════════════════════════
sleep 2
TAILSCALE_IP=$(tailscale-cli ip -4 2>/dev/null | head -1 || echo "<not yet authenticated>")

echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  Android A (Server) Setup Complete!${RESET}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  Tailscale IP   : ${BOLD}${TAILSCALE_IP}${RESET}"
echo -e "  SOCKS5 Proxy   : ${BOLD}127.0.0.1:${SOCKS5_PORT}${RESET}"
echo -e "  proot-distro   : ${BOLD}${DISTRO}${RESET}"
echo -e "  SSH Port       : ${BOLD}${SSH_PORT}${RESET}"
echo ""
echo -e "${BOLD}Next steps on Android A:${RESET}"
echo "  1. Start proot SSH:   proot-sshd-start"
echo "  2. Keep Termux open or use termux-services to auto-start tailscaled."
echo ""
echo -e "${BOLD}On Android B:${RESET}"
echo "  1. Run the client setup script: bash tailscale_client_setup.sh"
echo "  2. Then SSH in:  ssh -p ${SSH_PORT} root@${TAILSCALE_IP}"
echo ""
echo -e "  Tailscale daemon logs : ${BOLD}cat ~/.tailscale/tailscaled.log${RESET}"
echo -e "  proot sshd logs       : ${BOLD}cat ~/.tailscale/proot-sshd.log${RESET}"
