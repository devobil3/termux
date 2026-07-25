#!/usr/bin/env bash
# Automates antigravity-cli (agy) installation for native Termux host environment
set -euo pipefail

TMP_DIR=""
cleanup() {
    if [ -n "${TMP_DIR:-}" ] && [ -d "$TMP_DIR" ]; then
        echo "==> Cleaning up temporary installation files..."
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

echo "==> Checking and preparing Termux host dependencies..."
apt update && apt upgrade -y
apt install -y curl bash ca-certificates
apt install -y tur-repo glibc-repo
apt install -y glibc glibc-runner

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"

TMP_BASE="${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}"
mkdir -p "$TMP_BASE"
TMP_DIR=$(mktemp -d "$TMP_BASE/agy_install.XXXXXX" 2>/dev/null || mktemp -d)

download_file() {
    local url="$1"
    local output="$2"
    if command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1; then
        curl -4 -L -s -f "$url" -o "$output" || wget -q -O "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$output" "$url"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import urllib.request; urllib.request.urlretrieve('$url', '$output')"
    else
        echo "Fatal: Neither curl, wget, nor python3 could download $url" >&2
        exit 1
    fi
}

echo "==> Querying release repository for latest version..."
MANIFEST_URL="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json"
MANIFEST_FILE="$TMP_DIR/manifest.json"

download_file "$MANIFEST_URL" "$MANIFEST_FILE"

DOWNLOAD_URL=$(sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST_FILE")
VERSION=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST_FILE")

if [ -z "$DOWNLOAD_URL" ]; then
    echo "Fatal: Failed to parse download URL from release manifest." >&2
    exit 1
fi

echo "==> Downloading antigravity-cli (version $VERSION)..."
TARBALL="$TMP_DIR/cli_linux_arm64.tar.gz"
download_file "$DOWNLOAD_URL" "$TARBALL"

echo "==> Extracting binary to $BIN_DIR/agy-bin..."
tar -xzf "$TARBALL" -C "$TMP_DIR"

if [ -f "$TMP_DIR/antigravity" ]; then
    mv "$TMP_DIR/antigravity" "$BIN_DIR/agy-bin"
elif [ -f "$TMP_DIR/agy" ]; then
    mv "$TMP_DIR/agy" "$BIN_DIR/agy-bin"
else
    echo "Fatal: Extracted binary not found in download archive." >&2
    exit 1
fi

chmod +x "$BIN_DIR/agy-bin"

echo "==> Creating launcher wrapper at $BIN_DIR/agy..."
cat << 'EOF' > "$BIN_DIR/agy"
#!/usr/bin/env bash
export GODEBUG=netdns=go+4
TARGET_BINARY="$HOME/.local/bin/agy-bin"
if [ ! -f "$TARGET_BINARY" ]; then
    echo "Error: antigravity-cli binary not found at $TARGET_BINARY" >&2
    exit 1
fi
exec glibc-runner "$TARGET_BINARY" "$@"
EOF

chmod +x "$BIN_DIR/agy"

echo "==> Configuring shell PATH..."
SHELL_CONFIGS=("$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile")
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

for config in "${SHELL_CONFIGS[@]}"; do
    if [ -f "$config" ] || [ "$config" = "$HOME/.bashrc" ]; then
        touch "$config"
        if ! grep -q '\.local/bin' "$config"; then
            echo "$PATH_LINE" >> "$config"
        fi
    fi
done

export PATH="$HOME/.local/bin:$PATH"

echo "==> Verifying installation..."
if "$BIN_DIR/agy" --version >/dev/null 2>&1; then
    VER=$("$BIN_DIR/agy" --version 2>&1)
    echo "✓ Success: antigravity-cli $VER installed successfully!"
    echo "You can now run 'agy' from anywhere in Termux."
else
    echo "Fatal: Verification failed. Could not execute 'agy'." >&2
    exit 1
fi
