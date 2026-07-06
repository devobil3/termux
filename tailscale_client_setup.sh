#!/data/data/com.termux/files/usr/bin/env bash
# =============================================================================
# Tailscale CLIENT Setup — Android B (This Phone)
# =============================================================================
# This script configures Tailscale on Android B so it can connect to Android A
# (the server) over the Tailnet. Tailscale is assumed to already be installed.
# If not installed, this script will install it automatically.
#
# Run this on Android B (this phone) inside Termux:
#   bash tailscale_client_setup.sh
#
# Required: Android A's Tailscale IP or hostname (you get it after Android A
# runs its setup script).
#   SERVER_IP=100.x.x.x bash tailscale_client_setup.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — edit these if needed
# ---------------------------------------------------------------------------
SERVER_IP="${SERVER_IP:-}"          # Android A's Tailscale IP (optional, set later)
SOCKS5_PORT="${SOCKS5_PORT:-1055}"  # Must match Android A's SSH_PORT? No — this phone's SOCKS5
SSH_PORT="${SSH_PORT:-2222}"        # Must match Android A's SSH_PORT
HOSTNAME_LABEL="android-b-client"  # Name for this device in your Tailnet
# ---------------------------------------------------------------------------

BOLD="\033[1m"; RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; RESET="\033[0m"

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}━━━  $*  ━━━${RESET}"; }

# ════════════════════════════════════════════════════════════════════
header "Step 1: Ensure Tailscale is installed"
# ════════════════════════════════════════════════════════════════════
if command -v tailscaled &>/dev/null; then
    success "Tailscale is already installed."
else
    warn "Tailscale not found. Installing now..."
    pkg update -y -q
    pkg install -y -q curl wget grep dpkg termux-services runit 2>/dev/null || true
    apt --fix-broken install -y -q 2>/dev/null || true

    REPO="bropines/tailscale-termux-cli"
    LATEST_TAG=$(curl -s "https://api.github.com/repos/$REPO/releases/latest" \
        | grep -Po '"tag_name": "\K.*?(?=")')
    [ -z "$LATEST_TAG" ] && die "Could not fetch latest release tag."

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

    TMP_DIR=$(mktemp -d "$HOME/tmp.XXXXXX")
    trap 'rm -rf "$TMP_DIR"' EXIT

    wget -q --show-progress -O "$TMP_DIR/$DEB_FILE" "$DEB_URL"
    pkill -f tailscaled 2>/dev/null || true
    dpkg -i "$TMP_DIR/$DEB_FILE" || true
    apt --fix-broken install -y -q 2>/dev/null || true

    termux-fix-shebang \
        "$PREFIX/bin/tailscale-cli" \
        "$PREFIX/bin/tailscale-test" \
        "$PREFIX/bin/tailscale-update" \
        "$PREFIX/bin/tailscaled-log" \
        "$PREFIX/bin/tailscaled-start" \
        "$PREFIX/bin/tailscaled-stop" 2>/dev/null || true

    success "Tailscale installed."
fi

# ════════════════════════════════════════════════════════════════════
header "Step 2: Configure fixed SOCKS5 port"
# ════════════════════════════════════════════════════════════════════
ENV_FILE="$HOME/.tailscale/.env"
mkdir -p "$HOME/.tailscale"
cat > "$ENV_FILE" <<EOF
# Tailscale environment — sourced by tailscaled-start
TS_SOCKS5_PORT=$SOCKS5_PORT
EOF
success "SOCKS5 port fixed to $SOCKS5_PORT (saved to $ENV_FILE)"

# ════════════════════════════════════════════════════════════════════
header "Step 3: Start tailscaled daemon"
# ════════════════════════════════════════════════════════════════════
info "Stopping any previous tailscaled instance..."
pkill -f tailscaled 2>/dev/null || true
sleep 1

info "Starting tailscaled..."
tailscaled-start
sleep 2

if pgrep -f "tailscaled.*statedir" &>/dev/null; then
    success "tailscaled is running. SOCKS5 at 127.0.0.1:$SOCKS5_PORT"
else
    die "tailscaled failed to start. Check: cat ~/.tailscale/tailscaled.log"
fi

# ════════════════════════════════════════════════════════════════════
header "Step 4: Authenticate to Tailscale"
# ════════════════════════════════════════════════════════════════════
CURRENT_STATUS=$(tailscale-cli status 2>&1 || true)

if echo "$CURRENT_STATUS" | grep -q "Logged out\|NeedsLogin\|not logged in"; then
    echo ""
    echo -e "${YELLOW}This device is not yet authenticated to a Tailnet.${RESET}"
    echo "Make sure you authenticate to the SAME Tailscale account as Android A."
    echo ""
    read -rp "Press ENTER to authenticate now, or Ctrl-C to do it manually later..."
    tailscale-cli up --hostname="$HOSTNAME_LABEL" || warn "Re-run manually: tailscale-cli up --hostname=$HOSTNAME_LABEL"
else
    success "Already authenticated to Tailnet."
    echo "$CURRENT_STATUS"
fi

# ════════════════════════════════════════════════════════════════════
header "Step 5: Install SSH client and helpers"
# ════════════════════════════════════════════════════════════════════
info "Installing openssh and netcat..."
pkg install -y -q openssh netcat-openbsd 2>/dev/null || pkg install -y -q openssh ncat 2>/dev/null || true
success "SSH client tools ready."

# ════════════════════════════════════════════════════════════════════
header "Step 6: Create SSH helper scripts"
# ════════════════════════════════════════════════════════════════════

# --- ssh-to-server: quick connect script ---
SSH_HELPER="$PREFIX/bin/ssh-to-server"
cat > "$SSH_HELPER" <<HELPER_EOF
#!/data/data/com.termux/files/usr/bin/bash
# Quick SSH to Android A's proot-distro over Tailscale.
# Usage: ssh-to-server [user]   (default user: root)
USER="\${1:-root}"
SSH_PORT="${SSH_PORT}"

# Get Android A's Tailscale IP from tailscale status
SERVER_IP="\${SERVER_IP:-$([ -n "$SERVER_IP" ] && echo "$SERVER_IP" || echo "")}"

if [ -z "\$SERVER_IP" ]; then
    echo "Searching for android-a-server in Tailnet..."
    SERVER_IP=\$(tailscale-cli status --json 2>/dev/null \
        | grep -A5 '"HostName": "android-a-server"' \
        | grep -Po '"TailscaleIPs": \["\K[^"]+' | head -1 || true)
fi

if [ -z "\$SERVER_IP" ]; then
    echo "ERROR: Could not find android-a-server in your Tailnet."
    echo "Manually specify: SERVER_IP=100.x.x.x ssh-to-server"
    echo "Or check with:    tailscale-cli status"
    exit 1
fi

echo "Connecting to \$USER@\$SERVER_IP (port \$SSH_PORT) via Tailscale..."
ssh -p "\$SSH_PORT" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "\$USER@\$SERVER_IP" "\$@"
HELPER_EOF
termux-fix-shebang "$SSH_HELPER"
chmod +x "$SSH_HELPER"
success "Created: ssh-to-server"

# --- proxy-env: prints export statements for routing through Tailscale ---
PROXY_HELPER="$PREFIX/bin/tailscale-proxy-env"
cat > "$PROXY_HELPER" <<PHELPER_EOF
#!/data/data/com.termux/files/usr/bin/bash
# Prints proxy environment variables to route traffic through Tailscale SOCKS5.
# Usage: source \$(tailscale-proxy-env)
#    or: eval \$(tailscale-proxy-env)
ADDR=\$(cat "\$HOME/.tailscale/socks_addr" 2>/dev/null || echo "127.0.0.1:${SOCKS5_PORT}")
echo "export ALL_PROXY=socks5://\$ADDR"
echo "export HTTP_PROXY=socks5://\$ADDR"
echo "export HTTPS_PROXY=socks5://\$ADDR"
PHELPER_EOF
termux-fix-shebang "$PROXY_HELPER"
chmod +x "$PROXY_HELPER"
success "Created: tailscale-proxy-env"

# ════════════════════════════════════════════════════════════════════
header "Step 7: Verify Tailnet connectivity"
# ════════════════════════════════════════════════════════════════════
MY_IP=$(tailscale-cli ip -4 2>/dev/null | head -1 || echo "<not yet authenticated>")
echo ""
echo -e "${BOLD}This device (Android B) Tailscale IP: ${CYAN}${MY_IP}${RESET}"

if [ -n "$SERVER_IP" ]; then
    info "Testing connectivity to Android A at $SERVER_IP:$SSH_PORT..."
    if nc -z -w5 "$SERVER_IP" "$SSH_PORT" 2>/dev/null; then
        success "Port $SSH_PORT on $SERVER_IP is reachable! SSH is ready."
    else
        warn "Cannot reach $SERVER_IP:$SSH_PORT. Make sure:"
        echo "    - Android A is running tailscaled-start"
        echo "    - Android A is running proot-sshd-start"
        echo "    - Both devices are on the same Tailnet"
    fi
fi

# ════════════════════════════════════════════════════════════════════
header "Summary"
# ════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}${GREEN}  Android B (Client) Setup Complete!${RESET}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  This device IP  : ${BOLD}${MY_IP}${RESET}"
echo -e "  SOCKS5 Proxy    : ${BOLD}127.0.0.1:${SOCKS5_PORT}${RESET}"
echo -e "  Server SSH Port : ${BOLD}${SSH_PORT}${RESET}"
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo "  Connect to Android A:  ssh-to-server"
echo "  Set proxy for session: eval \$(tailscale-proxy-env)"
echo "  Check Tailnet status:  tailscale-cli status"
echo "  View daemon logs:      cat ~/.tailscale/tailscaled.log"
echo ""
echo -e "${BOLD}Manual SSH (replace IP):${RESET}"
echo "  ssh -p ${SSH_PORT} root@<android-a-tailscale-ip>"
echo ""
