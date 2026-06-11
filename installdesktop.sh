#!/usr/bin/env bash
# Merged: Antigravity Desktop Installer & VA39/Termux Fix Automator (PRoot ARM64)
set -euo pipefail

# ---- Configuration ----
ARCHIVE="Antigravity.tar.gz"
TARGET_DIR="$HOME/.local/share/Antigravity-arm64"
BIN_DIR="$HOME/.local/bin"
ICON_SRC="$TARGET_DIR/icon.png"
ICON_DST="$HOME/.local/share/icons/antigravity.png"
DESKTOP_FILE="$HOME/.local/share/applications/antigravity.desktop"

# Fix-specific paths
FIX_DIR="$(pwd)"
INTERPOSER_SRC="$FIX_DIR/mmap_va39_fix.c"
INTERPOSER_SO="$TARGET_DIR/libmmap_va39_fix.so"
WRAPPER="$BIN_DIR/antigravity"

# State tracking for the cleanup trap
SUCCESS=0
TMPDIR=""
BACKUP_DIR=""
HAD_PREVIOUS_INSTALL=0
CREATED_WRAPPER=0
CREATED_DESKTOP=0
CREATED_ICON=0
DOWNLOADED_ARCHIVE=0

# ---- Helper function ----
log() {
    echo "==> $1"
}

# ---- Error Handling & Cleanup Trap (Nuclear Option) ----
cleanup() {
    if [[ $SUCCESS -eq 1 ]]; then
        log "Process completed successfully! Cleaning up temporary backups..."
        rm -f "$TARGET_DIR/antigravity.orig"
        rm -f "$TARGET_DIR/resources/bin/language_server.orig"
        if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
            rm -rf "$BACKUP_DIR"
        fi
    else
        log "Script failed or interrupted! Initiating rollback..."
        
        # Remove wrapper if created during this run
        [[ $CREATED_WRAPPER -eq 1 && -f "$WRAPPER" ]] && rm -f "$WRAPPER"
        
        # Remove desktop shortcut if created during this run
        [[ $CREATED_DESKTOP -eq 1 && -f "$DESKTOP_FILE" ]] && rm -f "$DESKTOP_FILE"
        
        # Remove icon if created during this run
        [[ $CREATED_ICON -eq 1 && -f "$ICON_DST" ]] && rm -f "$ICON_DST"

        # Remove downloaded archive if it didn't exist before
        [[ $DOWNLOADED_ARCHIVE -eq 1 && -f "$ARCHIVE" ]] && rm -f "$ARCHIVE"

        # Restore or completely clear the target directory
        if [[ $HAD_PREVIOUS_INSTALL -eq 1 && -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
            log "Restoring previous installation version..."
            rm -rf "$TARGET_DIR"
            mv "$BACKUP_DIR" "$TARGET_DIR"
        else
            log "No previous installation found. Cleaning target directory completely..."
            rm -rf "$TARGET_DIR"
        fi
    fi
    
    [[ -n "$TMPDIR" && -d "$TMPDIR" ]] && rm -rf "$TMPDIR"
}
trap cleanup EXIT

# ---- Architecture Verification ----
SYS_ARCH=$(uname -m)
if [[ "$SYS_ARCH" != "aarch64" && "$SYS_ARCH" != "arm64" ]]; then
    echo "Error: This script strictly supports ARM64/AArch64 PRoot environments. Detected: $SYS_ARCH" >&2
    exit 1
fi

# ---- Environment Detection & Dependency Resolver ----
log "Checking system requirements for PRoot ARM64..."
MISSING_DEPS=()
for cmd in curl python3 tar gcc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_DEPS+=("$cmd")
    fi
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    log "Missing required dependencies: ${MISSING_DEPS[*]}"
    
    # Determine the execution prefix (omit sudo if already running as root inside PRoot)
    SUDO_PREFIX="sudo "
    if [[ $(id -u) -eq 0 ]]; then
        SUDO_PREFIX=""
    fi

    # Determine package manager command
    INSTALL_CMD=""
    if command -v apt-get >/dev/null 2>&1; then
        PKGS=""
        for dep in "${MISSING_DEPS[@]}"; do
            [[ "$dep" == "gcc" ]] && dep="build-essential"
            PKGS="$PKGS $dep"
        done
        INSTALL_CMD="${SUDO_PREFIX}apt-get update && ${SUDO_PREFIX}apt-get install -y$PKGS"
    elif command -v pacman >/dev/null 2>&1; then
        PKGS=""
        for dep in "${MISSING_DEPS[@]}"; do
            [[ "$dep" == "gcc" ]] && dep="base-devel"
            PKGS="$PKGS $dep"
        done
        INSTALL_CMD="${SUDO_PREFIX}pacman -Sy --noconfirm$PKGS"
    else
        INSTALL_CMD="# Please install manually: ${MISSING_DEPS[*]}"
    fi

    echo "--------------------------------------------------------"
    echo "How would you like to handle these missing dependencies?"
    echo "1) Execute install command now (uses sudo if not root)."
    echo "2) Copy the install command to clipboard and exit."
    echo "--------------------------------------------------------"
    read -rp "Select an option (1/2): " DEP_CHOICE

    if [[ "$DEP_CHOICE" == "1" ]]; then
        log "Executing: $INSTALL_CMD"
        eval "$INSTALL_CMD"
    elif [[ "$DEP_CHOICE" == "2" ]]; then
        if command -v xclip >/dev/null 2>&1; then
            echo "$INSTALL_CMD" | xclip -selection clipboard
            log "Command copied to clipboard! Exiting."
        elif command -v wl-copy >/dev/null 2>&1; then
            echo "$INSTALL_CMD" | wl-copy
            log "Command copied to clipboard! Exiting."
        else
            echo "Clipboard manager not found. Here is the command to copy manually:"
            echo -e "\n$INSTALL_CMD\n"
        fi
        SUCCESS=1 
        exit 0
    else
        echo "Invalid choice. Exiting script." >&2
        exit 1
    fi
fi

# ---- 0. Installation Detection & Dynamic Backup ----
if [[ -d "$TARGET_DIR" ]]; then
    log "Existing installation detected at $TARGET_DIR"
    HAD_PREVIOUS_INSTALL=1
    BACKUP_DIR=$(mktemp -d -t antigravity-backup-XXXXXX)
    log "Backing up old instance safely to $BACKUP_DIR..."
    cp -a "$TARGET_DIR/." "$BACKUP_DIR/"
fi

# ---- 1. Verify or Download archive ----
if [[ ! -f "$ARCHIVE" ]]; then
    log "$ARCHIVE not found locally. Fetching online..."
    DOWNLOADED_ARCHIVE=1

    log "Fetching latest version data from AUR..."
    # Note: Using the GCS layout for Antigravity 2.0 based on your image configuration
    AUR_PKG_URL="https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=antigravity"
    
    PKG_DATA=$(curl -fsSL "$AUR_PKG_URL")
    VER=$(echo "$PKG_DATA" | grep -E '^pkgver=' | cut -d= -f2 | tr -d '"'\''')
    BUILD=$(echo "$PKG_DATA" | grep -E '^_build=' | cut -d= -f2 | tr -d '"'\''')

    if [[ -z "$VER" || -z "$BUILD" ]]; then
        echo "Error: Could not retrieve version or build number from AUR." >&2
        exit 1
    fi

    log "Found Antigravity Version: $VER, Build: $BUILD"
    DOWNLOAD_URL="https://storage.googleapis.com/antigravity-public/antigravity-hub/${VER}-${BUILD}/linux-arm/Antigravity.tar.gz"
    
    log "Downloading from: $DOWNLOAD_URL"
    if ! curl -fL --url "$DOWNLOAD_URL" -o "$ARCHIVE"; then
        echo "Error: Failed to download $ARCHIVE from server." >&2
        exit 1
    fi
fi

# ---- 2. Extract archive to temporary location ----
TMPDIR=$(mktemp -d)
log "Extracting $ARCHIVE to $TMPDIR..."
tar -xf "$ARCHIVE" -C "$TMPDIR"

SRC_DIR="$TMPDIR/Antigravity-arm64"
if [[ ! -d "$SRC_DIR" ]]; then
    echo "Error: extracted Antigravity-arm64 directory missing" >&2
    exit 1
fi

# ---- 3. Move application to target location ----
log "Installing to $TARGET_DIR..."
mkdir -p "$(dirname "$TARGET_DIR")"
if [[ -d "$TARGET_DIR" ]]; then
    rm -rf "$TARGET_DIR"
fi
mv "$SRC_DIR" "$TARGET_DIR"

# ---- 4. Install icon ----
log "Copying icon..."
mkdir -p "$(dirname "$ICON_DST")"
if [[ -f "$ICON_SRC" ]]; then
    cp -f "$ICON_SRC" "$ICON_DST"
    CREATED_ICON=1
else
    if [[ -f "$TARGET_DIR/resources/app.asar" ]]; then
        log "Attempting to extract icon.png from app.asar using Python..."
        if python3 -c '
import sys, json, struct
def find_file(node, target):
    if "files" in node:
        for k, v in node["files"].items():
            if k == target and "offset" in v: return v
            res = find_file(v, target)
            if res: return res
    return None
try:
    with open(sys.argv[1], "rb") as f:
        f.read(4) # magic
        hps = struct.unpack("<I", f.read(4))[0] # header_pickle_size
        f.read(4) # header_size
        ss = struct.unpack("<I", f.read(4))[0] # string_size
        hs = f.read(ss).decode("utf-8")
        info = find_file(json.loads(hs), "icon.png")
        if info:
            f.seek(8 + hps + int(info["offset"]))
            with open(sys.argv[2], "wb") as out:
                out.write(f.read(int(info["size"])))
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
' "$TARGET_DIR/resources/app.asar" "$ICON_DST"; then
            log "Icon extracted successfully from asar."
            CREATED_ICON=1
        else
            log "Warning: icon extraction failed."
        fi
    fi
fi

# ---- 5. Apply Desktop Fixes (VA39/mmap) ----
log "Applying binary patches and fixes..."

[[ -f "$TARGET_DIR/antigravity" ]] && cp "$TARGET_DIR/antigravity" "$TARGET_DIR/antigravity.orig"
[[ -f "$TARGET_DIR/resources/bin/language_server" ]] && cp "$TARGET_DIR/resources/bin/language_server" "$TARGET_DIR/resources/bin/language_server.orig"

log "Preparing and compiling mmap interposer..."
if [[ ! -f "$INTERPOSER_SRC" ]]; then
    log "mmap_va39_fix.c missing. Downloading..."
    if ! curl -fsSL "https://raw.githubusercontent.com/wallentx/antigravity-cli-termux/dev/lib/mmap_va39_fix.c" -o "$INTERPOSER_SRC"; then
        echo "Error: Failed to download mmap interposer source."
        rm -f "$INTERPOSER_SRC"
        exit 1
    fi
fi
gcc -O2 -fPIC -shared -o "$INTERPOSER_SO" "$INTERPOSER_SRC" -ldl

log "Applying surgical binary patch to language_server..."
python3 - "$TARGET_DIR/resources/bin/language_server.orig" "$TARGET_DIR/resources/bin/language_server" << 'PY'
import sys, shutil, struct, pathlib
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
data = bytearray(src.read_bytes())
def get(off): return struct.unpack_from("<I", data, off)[0]
def put(off, word): struct.pack_into("<I", data, off, word)

hi = 0x060dc2e0
counts = {"ubfx": 0, "lsl": 0, "mask": 0, "mmap": 0, "f2": 0}

for off in range(0, hi, 4):
    w = get(off)
    if (w & 0x7F800000) == 0x53000000:
        immr, imms = (w >> 16) & 0x3F, (w >> 10) & 0x3F
        if immr == 42 and imms == 44:
            put(off, (w & ~((0x3F << 16) | (0x3F << 10))) | (35 << 16) | (37 << 10)); counts["ubfx"] += 1
        elif immr == 22 and imms == 21:
            put(off, (w & ~((0x3F << 16) | (0x3F << 10))) | (29 << 16) | (28 << 10)); counts["lsl"] += 1

for off in range(0, hi - 4, 4):
    if get(off) == 0x92D3800A and get(off + 4) == 0xF2E0000A:
        put(off, 0x9280000A); put(off + 4, 0xD35DFD4A); counts["mask"] += 1

for off in range(0, hi, 4):
    if get(off) == 0xF2E00029: put(off, 0xD3596129); counts["mmap"] += 1

word_rewrites = {
    0xD2C20009: 0xD2C00409, 0xD2C2000A: 0xD2C0040A, 0xF2C20008: 0xF2DFF408,
    0xF2C20009: 0xF2DFF409, 0xD2C10009: 0xD2C00209, 0xD2C1000A: 0xD2C0020A,
    0xF2C38008: 0xF2DFF708, 0xF2C38009: 0xF2DFF709, 0x92560A6C: 0x925D0A6C,
    0x92560A6A: 0x925D0A6A, 0xD2C3000D: 0xD2C0060D, 0xD2C3000C: 0xD2C0060C,
    0xD2C08008: 0xD2C00108,
}
for off in range(0, hi, 4):
    w = get(off)
    if w in word_rewrites: put(off, word_rewrites[w])

for off in range(0, hi - 12, 4):
    if get(off) == 0xAA1F03E5 and get(off + 4) == 0xAA1F03E6 and get(off + 8) == 0xD28036E0 and (get(off + 12) & 0xFC000000) == 0x94000000:
        put(off + 8, 0xD2800600); counts["f2"] += 1

dst.write_bytes(data)
dst.chmod(0o755)
print(f"Patched: {counts}")
PY

# ---- 6. Create Wrapper ----
log "Creating launcher wrapper ($WRAPPER)..."
mkdir -p "$BIN_DIR"
cat > "$WRAPPER" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="$HOME/.local/share/Antigravity-arm64"
INTERPOSER="$APP_DIR/libmmap_va39_fix.so"
export LD_LIBRARY_PATH="/usr/lib/aarch64-linux-gnu:/lib/aarch64-linux-gnu:$APP_DIR"
[[ -d "/data/data/com.termux/files/usr/bin" ]] && unset LD_PRELOAD
export LD_PRELOAD="$INTERPOSER"

if [[ -f "/data/data/com.termux/files/usr/etc/tls/cert.pem" ]]; then
    export SSL_CERT_FILE="/data/data/com.termux/files/usr/etc/tls/cert.pem"
elif [[ -f "/etc/ssl/certs/ca-certificates.crt" ]]; then
    export SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"
fi

export LIBGL_ALWAYS_SOFTWARE=1
export ELECTRON_ENABLE_LOGGING=1
eval $(gnome-keyring-daemon --start --components=secrets) 2>/dev/null || true
export DBUS_SESSION_BUS_ADDRESS
echo -n "" | gnome-keyring-daemon --unlock 2>/dev/null || true

exec "$APP_DIR/antigravity" \
    --no-sandbox --disable-gpu --disable-gpu-compositing \
    --disable-gpu-rasterization --disable-dev-shm-usage \
    --ignore-certificate-errors --remote-allow-origins=* "$@"
EOF
chmod +x "$WRAPPER"
CREATED_WRAPPER=1

# ---- 7. Create desktop entry ----
log "Creating desktop entry $DESKTOP_FILE..."
mkdir -p "$(dirname "$DESKTOP_FILE")"
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Antigravity
Comment=Antigravity Desktop Application
Exec=$WRAPPER %U
Icon=$ICON_DST
Terminal=false
Type=Application
Categories=Utility;Development;
MimeType=text/plain;
StartupNotify=true
EOF
CREATED_DESKTOP=1

# ---- 8. Refresh desktop database ----
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$(dirname "$DESKTOP_FILE")"
fi

# Set success flag so trap commits everything and trims backups safely
SUCCESS=1

log "Installation and Patching complete!"
log "To run the application inside PRoot, use: antigravity"
