#!/usr/bin/env bash
# Antigravity - All-in-One Termux Installer
# Installs CLI, IDE, and/or Antigravity 2.0 Desktop in a single run.
set -Eeuo pipefail

# ── Environment Detection ─────────────────────────────────────────────────────
tp=$(awk '/^TracerPid:/ {print $2}' /proc/self/status 2>/dev/null || echo 0)
tn=""
if [[ "$tp" -gt 0 ]]; then
  tn=$(awk '/^Name:/ {print $2}' "/proc/$tp/status" 2>/dev/null || cat "/proc/$tp/comm" 2>/dev/null || true)
fi

ENV_TYPE="unknown"
case "$tn" in
  proot|proot-*|proot_*) ENV_TYPE="proot" ;;
  *)
    if [[ -n "${TERMUX_VERSION:-}" ]]; then
      ENV_TYPE="termux"
    fi
    ;;
esac

if [[ "$ENV_TYPE" == "unknown" ]]; then
  if [[ "$(uname -s)" == "Linux" ]]; then
    ENV_TYPE="linux"
  else
    printf "  \033[31m✗\033[0m This script requires Linux (native Termux, PRoot, or generic Linux).\n" >&2
    exit 1
  fi
fi

INSTALL_BIN_DIR="$HOME/.local/bin"

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  B=$'\e[1m'  D=$'\e[2m'  G=$'\e[32m'  R=$'\e[31m'  C=$'\e[36m'  Y=$'\e[33m'  W=$'\e[37m'  N=$'\e[0m'
else
  B=""  D=""  G=""  R=""  C=""  Y=""  W=""  N=""
fi
BOLD="$B" DIM="$D" GREEN="$G" RED="$R" CYAN="$C" YELLOW="$Y" RESET="$N"

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { printf '  %b\n' "${D}⠶${N} ${D}$*${N}"; }
ok()    { printf '  %b\n' "${G}✓${N} $*"; }
warn()  { printf '  %b\n' "${Y}!${N} $*"; }
die() {
  {
    printf "\033[?25h"
    printf '\n'
    if [[ $# -gt 0 ]]; then
      printf '  %b\n' "${R}✗${N} $*"
    else
      printf '  %b\n' "${R}✗${N} Installation failed or was cancelled."
    fi
    printf '\n'
  } >&2
  exit 1
}
sep() { printf '  %b\n' "${D}─────────────────────────────────${N}"; }

# ── Optimization Helpers ──────────────────────────────────────────────────────
download_file() {
  local url="$1"
  local dest="${2:-}"
  if [[ -n "$dest" ]]; then
    curl -fsSL --retry 3 --retry-connrefused --retry-delay 2 -o "$dest" "$url"
  else
    curl -fsSL --retry 3 --retry-connrefused --retry-delay 2 "$url"
  fi
}

extract_tar() {
  local archive="$1"
  local dest_dir="$2"
  mkdir -p "$dest_dir"
  if command -v pigz &>/dev/null; then
    tar -I pigz -xf "$archive" -C "$dest_dir"
  else
    tar -xf "$archive" -C "$dest_dir"
  fi
}

check_disk_space() {
  local dest_dir="$1"
  local required_kb="$2"
  local test_dir="$dest_dir"
  while [[ ! -d "$test_dir" && "$test_dir" != "/" ]]; do
    test_dir=$(dirname "$test_dir")
  done
  local available_kb
  available_kb=$(df -Pk "$test_dir" 2>/dev/null | awk 'NR==2 {print $4}')
  if [[ -n "$available_kb" && "$available_kb" -lt "$required_kb" ]]; then
    local required_mb=$((required_kb / 1024))
    local available_mb=$((available_kb / 1024))
    warn "Low disk space on $dest_dir: Available: ${available_mb}MB, Required: ${required_mb}MB"
    printf '  Continue anyway? [y/N]: '
    local space_ans=""
    read -r space_ans < /dev/tty || space_ans="n"
    [[ "$space_ans" =~ ^[Yy]$ ]] || die "Installation cancelled due to low disk space."
  fi
}

create_bash_wrapper() {
  local wrapper_path="$1"
  local patched_bin_name="$2"
  
  cat << 'EOF' > "$wrapper_path"
#!/usr/bin/env bash
# Antigravity Dynamic Loader Wrapper
set -eu

# Resolve directory dynamically
DIR="$(dirname "$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")")"

unset LD_LIBRARY_PATH
export GODEBUG=netdns=cgo

if [[ -f "/etc/ssl/certs/ca-certificates.crt" ]]; then
  export SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"
fi

# Search for interposer up directory tree
INTERPOSER=""
TEMP_DIR="$DIR"
while [[ "$TEMP_DIR" != "/" && "$TEMP_DIR" != "." ]]; do
  if [[ -f "$TEMP_DIR/libmmap_va39_fix.so" ]]; then
    INTERPOSER="$TEMP_DIR/libmmap_va39_fix.so"
    break
  fi
  TEMP_DIR=$(dirname "$TEMP_DIR")
done

if [[ -z "$INTERPOSER" ]]; then
  if [[ -f "$HOME/.local/share/Antigravity IDE/libmmap_va39_fix.so" ]]; then
    INTERPOSER="$HOME/.local/share/Antigravity IDE/libmmap_va39_fix.so"
  elif [[ -f "$HOME/.local/lib/libmmap_va39_fix.so" ]]; then
    INTERPOSER="$HOME/.local/lib/libmmap_va39_fix.so"
  fi
fi

LOADER="/lib/ld-linux-aarch64.so.1"
LIB_PATH="$DIR:$DIR/../lib:/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu:/lib64:/usr/lib64:/lib:/usr/lib"
PATCHED_BIN="$DIR/PATCHED_BIN_PLACEHOLDER"

if [[ -n "$INTERPOSER" && -f "$INTERPOSER" ]]; then
  exec "$LOADER" --preload "$INTERPOSER" --library-path "$LIB_PATH" "$PATCHED_BIN" "$@"
else
  exec "$LOADER" --library-path "$LIB_PATH" "$PATCHED_BIN" "$@"
fi
EOF

  sed -i "s|PATCHED_BIN_PLACEHOLDER|$patched_bin_name|g" "$wrapper_path"
  chmod +x "$wrapper_path"
}

# ── Temp dir & cleanup ────────────────────────────────────────────────────────
BUILD_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'agy-build')
ALL_SUCCESS=0

# Global rollback registries
declare -A BACKUPS
declare -A CREATED_FRESH

# Helper to register a backup
register_backup() {
  local target="$1"
  local bak_path="$2"
  BACKUPS["$target"]="$bak_path"
}

# Helper to register a freshly created file/dir
register_fresh() {
  local target="$1"
  CREATED_FRESH["$target"]=1
}

cleanup() {
  printf "\033[?25h"
  # Clean up temporary files / build dir
  [[ -n "${BUILD_DIR:-}" && -d "$BUILD_DIR" ]] && rm -rf "$BUILD_DIR"

  if [[ "${ALL_SUCCESS:-0}" -ne 1 ]]; then
    info "Installation failed or interrupted! Reverting all changes..."
    
    # Generic rollback: restore backed up items
    for target in "${!BACKUPS[@]}"; do
      local bak="${BACKUPS[$target]}"
      if [[ -e "$bak" ]]; then
        rm -rf "$target"
        mv "$bak" "$target"
      fi
    done
    
    # Delete freshly created items
    for target in "${!CREATED_FRESH[@]}"; do
      if [[ -e "$target" ]]; then
        rm -rf "$target"
      fi
    done
  else
    # Success: delete all backups
    for target in "${!BACKUPS[@]}"; do
      local bak="${BACKUPS[$target]}"
      [[ -f "$bak" || -d "$bak" ]] && rm -rf "$bak"
    done
  fi
}
trap cleanup EXIT
trap 'die "Installation cancelled by user."' INT TERM

# ── Show Header / Logo ────────────────────────────────────────────────────────
printf "\033[?25l"
echo ""
TMP_LOGO="${BUILD_DIR}/logo.ans"
base64 -d << 'EOF' > "$TMP_LOGO"
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
EOF

COLS=$(tput cols </dev/tty 2>/dev/null || echo 60)
awk -v cols="$COLS" -v env="${ENV_TYPE}" -v bold="${B}${C}" -v dim="${D}" -v rst="${N}" '
{
  sub(/\r$/, "");
  if (cols >= 48) {
    printf "%s", $0;
    if (NR == 3)      printf "\033[28G %sAntigravity Termux%s", bold, rst;
    else if (NR == 4) printf "\033[28G %sAll-in-One Installer%s", dim, rst;
    else if (NR == 5) printf "\033[28G %s────────────────────%s", dim, rst;
    else if (NR == 6) printf "\033[28G %sEnv:%s    %s", dim, rst, env;
    printf "\n";
  } else {
    print $0;
  }
}
END {
  if (cols < 48) {
    printf "\n";
    printf "  %sAntigravity Termux%s\n", bold, rst;
    printf "  %sAll-in-One Installer%s\n", dim, rst;
    printf "  %s────────────────────%s\n", dim, rst;
    printf "  %sEnv:%s    %s\n", dim, rst, env;
  }
}' "$TMP_LOGO"
echo ""
sep

# ── Architecture Check ────────────────────────────────────────────────────────
[[ "$(uname -m)" == "aarch64" ]] || die "Architecture must be aarch64"

# ── Product Selection ─────────────────────────────────────────────────────────
INSTALL_CLI=0
INSTALL_IDE=0
INSTALL_DESKTOP=0

if [[ "$ENV_TYPE" == "termux" ]]; then
  warn "IDE and Desktop are not supported natively on Termux due to missing GUI library dependencies."
  info "Directly routing to Antigravity CLI installation..."
  INSTALL_CLI=1
else
  printf '\n'
  printf '  %b\n' "${B}Select products to install:${N}"
  printf '\n'
  printf '  %b\n' "${C}1${N}  Antigravity CLI ${D}(agy — standalone terminal agent)${N}"
  printf '  %b\n' "${C}2${N}  Antigravity IDE ${D}(VS Code-based agentic IDE)${N}"
  printf '  %b\n' "${C}3${N}  Antigravity 2.0 ${D}(Desktop Electron application)${N}"
  printf '\n'
  printf '  %b' "${D}Enter choice (e.g. ${N}${B}1${N}${D}, ${N}${B}13${N}${D}, ${N}${B}123${N}${D}):${N} "

  SELECTION=""
  read -r SELECTION < /dev/tty || true

  if [[ -z "$SELECTION" ]]; then
    die "No selection made."
  fi

  # Deduplicate and validate
  for (( i=0; i<${#SELECTION}; i++ )); do
    ch="${SELECTION:$i:1}"
    case "$ch" in
      1) INSTALL_CLI=1 ;;
      2) INSTALL_IDE=1 ;;
      3) INSTALL_DESKTOP=1 ;;
      *) die "Invalid selection: '$ch'. Use 1, 2, or 3." ;;
    esac
  done
fi

# Build summary
SELECTED_NAMES=()
[[ $INSTALL_CLI -eq 1 ]] && SELECTED_NAMES+=("CLI")
[[ $INSTALL_IDE -eq 1 ]] && SELECTED_NAMES+=("IDE")
[[ $INSTALL_DESKTOP -eq 1 ]] && SELECTED_NAMES+=("Desktop 2.0")

printf '\n'
ok "Selected: ${B}${SELECTED_NAMES[*]}${N}"
sep

# ── Compiler Detection ────────────────────────────────────────────────────────
detect_compiler() {
  if [[ -x "/data/data/com.termux/files/usr/bin/clang" ]]; then
    echo "/data/data/com.termux/files/usr/bin/clang"
    return 0
  fi
  if command -v clang &>/dev/null; then
    echo "clang"
    return 0
  elif command -v gcc &>/dev/null; then
    echo "gcc"
    return 0
  fi
  return 1
}

check_glibc() {
  if [[ "$ENV_TYPE" == "termux" ]]; then
    [[ -d "${TERMUX_PREFIX}/glibc" ]]
  else
    ldd --version 2>&1 | grep -qi -E '(glibc|gnu libc)'
  fi
}

# ── Determine what needs downloading ──────────────────────────────────────────
NEED_DOWNLOAD=0
CLI_UPSTREAM_BIN=""

# CLI: check for local binary
if [[ $INSTALL_CLI -eq 1 ]]; then
  if [[ -f "./antigravity" ]]; then
    CLI_UPSTREAM_BIN="./antigravity"
  elif [[ -f "./agy" ]]; then
    CLI_UPSTREAM_BIN="./agy"
  else
    NEED_DOWNLOAD=1
  fi
fi

# Desktop: check for local archive
DESKTOP_ARCHIVE_NAME="Antigravity.tar.gz"
if [[ -f "$DESKTOP_ARCHIVE_NAME" ]]; then
  info "Using local archive: $DESKTOP_ARCHIVE_NAME"
  DESKTOP_ARCHIVE="$(pwd)/$DESKTOP_ARCHIVE_NAME"
else
  if [[ $INSTALL_DESKTOP -eq 1 ]]; then
    NEED_DOWNLOAD=1
  fi
  DESKTOP_ARCHIVE="${BUILD_DIR}/$DESKTOP_ARCHIVE_NAME"
fi

# IDE: check for local archive
IDE_ARCHIVE_NAME="Antigravity IDE.tar.gz"
if [[ -f "$IDE_ARCHIVE_NAME" ]]; then
  info "Using local archive: $IDE_ARCHIVE_NAME"
  IDE_ARCHIVE="$(pwd)/$IDE_ARCHIVE_NAME"
else
  if [[ $INSTALL_IDE -eq 1 ]]; then
    NEED_DOWNLOAD=1
  fi
  IDE_ARCHIVE="${BUILD_DIR}/$IDE_ARCHIVE_NAME"
fi

# ── Prerequisite Check & Install ──────────────────────────────────────────────
check_and_install_dependencies() {
  while true; do
    local missing=()
    local tools=(python3 tar)

    # curl is needed for any download; CLI also needs jq
    if [[ $NEED_DOWNLOAD -eq 1 ]]; then
      tools+=(curl)
    fi
    if [[ $INSTALL_CLI -eq 1 && -z "$CLI_UPSTREAM_BIN" ]]; then
      tools+=(jq)
    fi

    for cmd in "${tools[@]}"; do
      if ! command -v "$cmd" &>/dev/null; then
        missing+=("$cmd")
      fi
    done

    local compiler_found=0
    if detect_compiler &>/dev/null; then
      compiler_found=1
    fi

    local glibc_missing=0
    if ! check_glibc; then
      glibc_missing=1
    fi

    if [[ ${#missing[@]} -eq 0 && $compiler_found -eq 1 && $glibc_missing -eq 0 ]]; then
      break
    fi

    if [[ "$ENV_TYPE" == "termux" ]]; then
      command -v pkg >/dev/null 2>&1 || die "pkg is required but not found to install missing dependencies"

      local to_install=()
      for tool in "${missing[@]}"; do
        if [[ "$tool" == "python3" ]]; then
          to_install+=("python")
        else
          to_install+=("$tool")
        fi
      done
      [[ $compiler_found -eq 0 ]] && to_install+=("clang")
      if [[ $glibc_missing -eq 1 ]]; then
        to_install+=("glibc-repo" "glibc")
      fi

      printf '\n  %b\n' "${R}✗${N} Missing: ${B}${to_install[*]}${N}"
      printf '  Install now? [Y/n]: '
      read -r -n 1 ans < /dev/tty || ans="y"
      printf "\n"
      if [[ "$ans" =~ ^[Yy]$ ]] || [[ -z "$ans" ]]; then
        info "Installing requirements: ${to_install[*]}..."
        if [[ " ${to_install[*]} " =~ " glibc-repo " ]]; then
          pkg install -y glibc-repo &>/dev/null || true
        fi
        pkg install -y "${to_install[@]}" &>/dev/null || die "Failed to install: ${to_install[*]}"
      else
        die "Required: ${to_install[*]}."
      fi
    else
      [[ $glibc_missing -eq 1 ]] && die "glibc is required but not found. Please install glibc using your distribution's package manager."

      local apt_packages=() apk_packages=() pacman_packages=() dnf_packages=()

      for tool in "${missing[@]}"; do
        case "$tool" in
          python3) apt_packages+=("python3"); apk_packages+=("python3"); pacman_packages+=("python"); dnf_packages+=("python3") ;;
          *)       apt_packages+=("$tool");    apk_packages+=("$tool");  pacman_packages+=("$tool");  dnf_packages+=("$tool") ;;
        esac
      done
      if [[ $compiler_found -eq 0 ]]; then
        apt_packages+=("build-essential"); apk_packages+=("build-base")
        pacman_packages+=("base-devel"); dnf_packages+=("gcc" "gcc-c++" "make")
      fi

      local helper=""
      [[ "$EUID" -ne 0 ]] && command -v sudo &>/dev/null && helper="sudo "

      local show_cmd="" run_cmd=""
      if command -v apt-get &>/dev/null; then
        show_cmd="${helper}apt-get update && ${helper}apt-get install -y ${apt_packages[*]}"
        run_cmd="${helper}DEBIAN_FRONTEND=noninteractive apt-get update &>/dev/null && ${helper}DEBIAN_FRONTEND=noninteractive apt-get install -y ${apt_packages[*]} &>/dev/null"
      elif command -v apk &>/dev/null; then
        show_cmd="${helper}apk add ${apk_packages[*]}"
        run_cmd="${helper}apk add ${apk_packages[*]} &>/dev/null"
      elif command -v pacman &>/dev/null; then
        show_cmd="${helper}pacman -Sy --noconfirm ${pacman_packages[*]}"
        run_cmd="${helper}pacman -Sy --noconfirm ${pacman_packages[*]} &>/dev/null"
      elif command -v dnf &>/dev/null; then
        show_cmd="${helper}dnf install -y ${dnf_packages[*]}"
        run_cmd="${helper}dnf install -y ${dnf_packages[*]} &>/dev/null"
      fi

      [[ -z "$show_cmd" ]] && die "No supported package manager found. Install manually: ${missing[*]}"

      printf '\n  %b\n' "${R}✗${N} Missing: ${B}${missing[*]}${N} $([[ $compiler_found -eq 0 ]] && echo "${B}clang/gcc${N}" || echo '')"
      printf '  %b\n\n' "${D}$ ${N}${show_cmd}"
      printf '  Enter to install, c to cancel: '
      local ans=""; read -r ans < /dev/tty || ans="c"
      [[ "$ans" =~ ^[Cc]$ ]] && die "Installation cancelled by user."
      if [[ -n "$helper" ]]; then sudo -v || die "Authentication failed."; fi
      info "Installing requirements..."
      eval "$run_cmd" || die "Automatic installation failed."
    fi
  done
}

info "Checking system requirements..."
check_and_install_dependencies
local_cc=$(detect_compiler)
info "Selected compiler: $local_cc"

# ── Shared: VA39 Python Patcher ───────────────────────────────────────────────
cat << 'PYEOF' > "${BUILD_DIR}/va39_patch.py"
import sys, shutil, struct, pathlib

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
if src.resolve() != dst.resolve():
    shutil.copyfile(src, dst)
data = bytearray(dst.read_bytes())

def get(off): return struct.unpack_from("<I", data, off)[0]
def put(off, word): struct.pack_into("<I", data, off, word)

lo, hi = 0, len(data)
ubfx_count = lsl_count = mask_count = mmap_count = faccessat2_count = 0

for off in range(lo, hi, 4):
    w = get(off)
    if (w & 0x7F800000) == 0x53000000:
        immr, imms = (w >> 16) & 0x3F, (w >> 10) & 0x3F
        if immr == 42 and imms == 44:
            put(off, (w & ~((0x3F << 16) | (0x3F << 10))) | (35 << 16) | (37 << 10)); ubfx_count += 1
        elif immr == 22 and imms == 21:
            put(off, (w & ~((0x3F << 16) | (0x3F << 10))) | (29 << 16) | (28 << 10)); lsl_count += 1

for off in range(lo, hi - 4, 4):
    if get(off) == 0x92D3800A and get(off + 4) == 0xF2E0000A:
        put(off, 0x9280000A); put(off + 4, 0xD35DFD4A); mask_count += 1

for off in range(lo, hi, 4):
    if get(off) == 0xF2E00029: put(off, 0xD3596129); mmap_count += 1

word_rewrites = {
    0xD2C20009: 0xD2C00409, 0xD2C2000A: 0xD2C0040A, 0xF2C20008: 0xF2DFF408,
    0xF2C20009: 0xF2DFF409, 0xD2C10009: 0xD2C00209, 0xD2C1000A: 0xD2C0020A,
    0xF2C38008: 0xF2DFF708, 0xF2C38009: 0xF2DFF709, 0x92560A6C: 0x925D0A6C,
    0x92560A6A: 0x925D0A6A, 0xD2C3000D: 0xD2C0060D, 0xD2C3000C: 0xD2C0060C,
    0xD2C08008: 0xD2C00108,
}
for off in range(lo, hi, 4):
    w = get(off)
    if w in word_rewrites: put(off, word_rewrites[w])

for off in range(0, len(data) - 12, 4):
    if (get(off) == 0xAA1F03E5 and get(off + 4) == 0xAA1F03E6
            and get(off + 8) == 0xD28036E0
            and (get(off + 12) & 0xFC000000) == 0x94000000):
        put(off + 8, 0xD2800600); faccessat2_count += 1

dst.write_bytes(data)
dst.chmod(0o755)
print(f"  Patched: ubfx={ubfx_count}, lsl={lsl_count}, mask={mask_count}, mmap={mmap_count}, faccessat2={faccessat2_count}")
PYEOF

# ── Shared: mmap_va39_fix.c ───────────────────────────────────────────────────
cat << 'EOF' > "${BUILD_DIR}/mmap_va39_fix.c"
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

enum { max_va_bits = 39 };
static const uintptr_t va_boundary = (uintptr_t)1 << max_va_bits;

void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    static void *(*real_mmap)(void *, size_t, int, int, int, off_t) = NULL;
    if (!real_mmap) {
        void *symbol = dlsym(RTLD_NEXT, "mmap");
        memcpy(&real_mmap, &symbol, sizeof(real_mmap));
    }

    int is_fixed = (flags & MAP_FIXED) != 0;
#ifdef MAP_FIXED_NOREPLACE
    is_fixed = is_fixed || (flags & MAP_FIXED_NOREPLACE) != 0;
#endif

    if (!is_fixed && (uintptr_t)addr >= va_boundary) {
        addr = NULL;
    }

    return real_mmap(addr, length, prot, flags, fd, offset);
}
EOF



# Compile shared interposer .so once
info "Compiling mmap compatibility layer..."
"$local_cc" -O2 -fPIC -shared -o "${BUILD_DIR}/libmmap_va39_fix.so" "${BUILD_DIR}/mmap_va39_fix.c" -ldl

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL: CLI
# ══════════════════════════════════════════════════════════════════════════════
install_cli() {
  echo ""
  sep
  printf '  %b\n' "${B}${C}[1/3] Antigravity CLI${N}"
  sep

  # ── Existing Installation Check ──
  if [[ -f "$INSTALL_BIN_DIR/agy" ]]; then
    warn "An existing installation of Antigravity CLI was detected at $INSTALL_BIN_DIR/agy."
    info "Reinstalling will update the application binary. Your user data (configurations, logs, and databases in ~/.gemini/ and other directories) will NOT be lost or affected."
    printf '  Proceed with reinstalling/updating CLI? [Y/n]: '
    local run_ans=""
    read -r run_ans < /dev/tty || run_ans="y"
    if [[ ! "$run_ans" =~ ^[Yy]$ && -n "$run_ans" ]]; then
      info "Skipping CLI installation."
      return 0
    fi
  fi

  # ── Option to install using official script ──
  printf '\n  %b\n' "${B}Antigravity CLI Installation Options:${N}"
  printf '  - %bY%b: Continue CLI installation using this script but WITHOUT patching/wrapping.%b\n' "${G}" "${N}" "${N}"
  printf '  - %bN%b: Skip CLI installation in this script (e.g. to copy the official command and run it manually in another session: %bcurl -fsSL https://antigravity.google/cli/install.sh | bash%b).%b\n' "${R}" "${N}" "${C}" "${N}" "${N}"
  printf '  Continue with unpatched installation in this script? [Y/n]: '
  local opt_ans=""
  read -r opt_ans < /dev/tty || opt_ans="y"
  if [[ ! "$opt_ans" =~ ^[Yy]$ && -n "$opt_ans" ]]; then
    info "Skipping CLI installation in this script."
    info "You can copy and run this command in a different terminal session:"
    printf '  %bcurl -fsSL https://antigravity.google/cli/install.sh | bash%b\n\n' "${C}" "${N}"
    return 0
  fi

  # ── Disk Space Check ──
  check_disk_space "$INSTALL_BIN_DIR" 51200 # 50MB

  # ── Resolve or download upstream binary ──
  if [[ -n "$CLI_UPSTREAM_BIN" ]]; then
    CLI_UPSTREAM_BIN=$(readlink -f "$CLI_UPSTREAM_BIN" 2>/dev/null || realpath "$CLI_UPSTREAM_BIN" 2>/dev/null || echo "$CLI_UPSTREAM_BIN")
    [[ -r "$CLI_UPSTREAM_BIN" ]] || die "CLI: Specified binary not readable: $CLI_UPSTREAM_BIN"
    info "Using local binary: $CLI_UPSTREAM_BIN"
  else
    info "Querying latest CLI version from Google..."
    MANIFEST_URL="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json"
    manifest=$(download_file "$MANIFEST_URL" "" || echo "")
    [[ -z "$manifest" ]] && die "CLI: Failed to query manifest from $MANIFEST_URL"

    latest_version=$(echo "$manifest" | jq -r .version)
    download_url=$(echo "$manifest" | jq -r .url)
    info "Latest version: v$latest_version"

    info "Downloading CLI binary..."
    download_file "$download_url" "${BUILD_DIR}/cli_upstream.tar.gz" || die "CLI: Download failed"
    extract_tar "${BUILD_DIR}/cli_upstream.tar.gz" "${BUILD_DIR}/" || die "CLI: Extraction failed"

    if [[ -f "${BUILD_DIR}/antigravity" ]]; then
      CLI_UPSTREAM_BIN="${BUILD_DIR}/antigravity"
    elif [[ -f "${BUILD_DIR}/agy" ]]; then
      CLI_UPSTREAM_BIN="${BUILD_DIR}/agy"
    else
      die "CLI: Could not find extracted binary."
    fi
  fi

  # ── Install unpatched binary ──
  mkdir -p "$INSTALL_BIN_DIR"

  if [[ -f "$INSTALL_BIN_DIR/agy" ]]; then
    local cli_bak="$INSTALL_BIN_DIR/agy.bak.$$"
    mv -f "$INSTALL_BIN_DIR/agy" "$cli_bak"
    register_backup "$INSTALL_BIN_DIR/agy" "$cli_bak"
  else
    register_fresh "$INSTALL_BIN_DIR/agy"
  fi

  install -m 0755 "$CLI_UPSTREAM_BIN" "$INSTALL_BIN_DIR/agy" || die "CLI: Failed to install agy"

  ok "CLI installed → ${D}${INSTALL_BIN_DIR}/agy${N}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL: ANTIGRAVITY 2.0 DESKTOP
# ══════════════════════════════════════════════════════════════════════════════
install_desktop() {
  local TARGET_DIR="$HOME/.local/share/Antigravity-arm64"
  local ICON_SRC="$TARGET_DIR/icon.png"
  local ICON_DST="$HOME/.local/share/icons/antigravity.png"
  local DESKTOP_FILE="$HOME/.local/share/applications/antigravity.desktop"
  local WRAPPER="$INSTALL_BIN_DIR/antigravity"

  echo ""
  sep
  printf '  %b\n' "${B}${C}[2/3] Antigravity 2.0 Desktop${N}"
  sep

  # ── Existing Installation Check ──
  if [[ -d "$TARGET_DIR" ]]; then
    warn "An existing installation of Antigravity Desktop was detected at $TARGET_DIR."
    info "Reinstalling will update the application files. Your user data, configurations, and application state (stored outside the installation directory) will NOT be lost or affected."
    printf '  Proceed with reinstalling/updating Desktop? [Y/n]: '
    local run_ans=""
    read -r run_ans < /dev/tty || run_ans="y"
    if [[ ! "$run_ans" =~ ^[Yy]$ && -n "$run_ans" ]]; then
      info "Skipping Desktop installation."
      return 0
    fi
  fi

  # ── Disk Space Check ──
  check_disk_space "$TARGET_DIR" 307200 # 300MB

  # ── Download if needed ──
  if [[ ! -f "$DESKTOP_ARCHIVE" ]]; then
    info "Fetching latest Desktop release from Arch Linux AUR..."
    local pkgbuild pkgver _build
    pkgbuild=$(download_file "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=antigravity" "" || echo "")
    [[ -z "$pkgbuild" ]] && die "Desktop: Failed to retrieve AUR PKGBUILD."
    pkgver=$(echo "$pkgbuild" | grep -E "^pkgver=" | cut -d= -f2 | xargs)
    _build=$(echo "$pkgbuild" | grep -E "^_build=" | cut -d= -f2 | xargs)
    [[ -z "$pkgver" || -z "$_build" ]] && die "Desktop: Failed to parse pkgver/_build."
    info "Latest: v${pkgver}-${_build}"
    info "Downloading $DESKTOP_ARCHIVE..."
    download_file "https://storage.googleapis.com/antigravity-public/antigravity-hub/${pkgver}-${_build}/linux-arm/Antigravity.tar.gz" "$DESKTOP_ARCHIVE" || { rm -f "$DESKTOP_ARCHIVE"; die "Desktop: Download failed."; }
    ok "Downloaded $DESKTOP_ARCHIVE"
  fi

  # ── Extract ──
  info "Extracting $DESKTOP_ARCHIVE..."
  extract_tar "$DESKTOP_ARCHIVE" "${BUILD_DIR}/desktop_extract"
  local SRC_DIR="${BUILD_DIR}/desktop_extract/Antigravity-arm64"
  [[ -d "$SRC_DIR" ]] || die "Desktop: Antigravity-arm64 folder not found in archive."

  # Backup existing Desktop files to allow rollback
  if [[ -d "$TARGET_DIR" ]]; then
    info "Backing up existing Desktop installation directory..."
    local dir_bak="${TARGET_DIR}.bak.$$"
    mv "$TARGET_DIR" "$dir_bak"
    register_backup "$TARGET_DIR" "$dir_bak"
  else
    register_fresh "$TARGET_DIR"
  fi

  if [[ -f "$WRAPPER" ]]; then
    local wrapper_bak="${WRAPPER}.bak.$$"
    mv "$WRAPPER" "$wrapper_bak"
    register_backup "$WRAPPER" "$wrapper_bak"
  else
    register_fresh "$WRAPPER"
  fi

  if [[ -f "$DESKTOP_FILE" ]]; then
    local file_bak="${DESKTOP_FILE}.bak.$$"
    mv "$DESKTOP_FILE" "$file_bak"
    register_backup "$DESKTOP_FILE" "$file_bak"
  else
    register_fresh "$DESKTOP_FILE"
  fi

  if [[ -f "$ICON_DST" ]]; then
    local icon_bak="${ICON_DST}.bak.$$"
    mv "$ICON_DST" "$icon_bak"
    register_backup "$ICON_DST" "$icon_bak"
  else
    register_fresh "$ICON_DST"
  fi

  mkdir -p "$(dirname "$TARGET_DIR")"
  mv "$SRC_DIR" "$TARGET_DIR"

  # ── Icon ──
  mkdir -p "$(dirname "$ICON_DST")"
  if [[ -f "$ICON_SRC" ]]; then
    cp -f "$ICON_SRC" "$ICON_DST"
  elif [[ -f "$TARGET_DIR/resources/icon.png" ]]; then
    cp -f "$TARGET_DIR/resources/icon.png" "$ICON_DST"
  fi

  # ── Compile interposer into target ──
  cp "${BUILD_DIR}/libmmap_va39_fix.so" "$TARGET_DIR/libmmap_va39_fix.so"
  chmod 755 "$TARGET_DIR/libmmap_va39_fix.so"

  # ── Patch language_server ──
  if [[ -f "$TARGET_DIR/resources/bin/language_server" ]]; then
    info "Patching language_server..."
    mv "$TARGET_DIR/resources/bin/language_server" "$TARGET_DIR/resources/bin/language_server.va39"
    python3 "${BUILD_DIR}/va39_patch.py" "$TARGET_DIR/resources/bin/language_server.va39" "$TARGET_DIR/resources/bin/language_server.va39"
    create_bash_wrapper "$TARGET_DIR/resources/bin/language_server" "language_server.va39"
  fi

  # ── Wrap main binary ──
  info "Wrapping main Electron binary..."
  mv "$TARGET_DIR/antigravity" "$TARGET_DIR/antigravity.va39"
  create_bash_wrapper "$TARGET_DIR/antigravity" "antigravity.va39"
  chmod 755 "$TARGET_DIR/antigravity"

  # ── Create launcher wrapper ──
  mkdir -p "$INSTALL_BIN_DIR"
  cat > "$WRAPPER" << 'WEOF'
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="$HOME/.local/share/Antigravity-arm64"
if [[ -f "/data/data/com.termux/files/usr/etc/tls/cert.pem" ]]; then
    export SSL_CERT_FILE="/data/data/com.termux/files/usr/etc/tls/cert.pem"
elif [[ -f "/etc/ssl/certs/ca-certificates.crt" ]]; then
    export SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"
fi
export LIBGL_ALWAYS_SOFTWARE=1 ELECTRON_ENABLE_LOGGING=1
if command -v gnome-keyring-daemon &>/dev/null; then
    eval $(gnome-keyring-daemon --start --components=secrets 2>/dev/null || true)
    export DBUS_SESSION_BUS_ADDRESS
    echo -n "" | gnome-keyring-daemon --unlock 2>/dev/null || true
fi
exec "$APP_DIR/antigravity" \
    --no-sandbox --disable-gpu --disable-gpu-compositing \
    --disable-gpu-rasterization --disable-dev-shm-usage \
    --ignore-certificate-errors --remote-allow-origins=* "$@"
WEOF
  chmod +x "$WRAPPER"

  # ── Desktop entry ──
  mkdir -p "$(dirname "$DESKTOP_FILE")"
  cat > "$DESKTOP_FILE" <<DEOF
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
DEOF
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true

  ok "Desktop installed → ${D}antigravity${N}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL: ANTIGRAVITY IDE
# ══════════════════════════════════════════════════════════════════════════════
install_ide() {
  local INSTALL_DIR="$HOME/.local/share/Antigravity IDE"
  local APPLICATIONS_DIR="$HOME/.local/share/applications"
  local ICONS_DIR="$HOME/.local/share/icons"
  local LIB_DIR="$INSTALL_DIR"
  local LS_DIR="$INSTALL_DIR/resources/app/extensions/antigravity/bin"
  local LS_BIN="language_server_linux_arm"
  local LS_PATH="$LS_DIR/$LS_BIN"

  echo ""
  sep
  printf '  %b\n' "${B}${C}[3/3] Antigravity IDE${N}"
  sep

  # ── Existing Installation Check ──
  if [[ -d "$INSTALL_DIR" ]]; then
    warn "An existing installation of Antigravity IDE was detected at $INSTALL_DIR."
    info "Reinstalling will update the application files. Your custom extensions, settings, and workspace data (stored outside the installation directory) will NOT be lost or affected."
    printf '  Proceed with reinstalling/updating IDE? [Y/n]: '
    local run_ans=""
    read -r run_ans < /dev/tty || run_ans="y"
    if [[ ! "$run_ans" =~ ^[Yy]$ && -n "$run_ans" ]]; then
      info "Skipping IDE installation."
      return 0
    fi
  fi

  # ── Disk Space Check ──
  check_disk_space "$INSTALL_DIR" 819200 # 800MB

  # ── Download if needed ──
  if [[ ! -f "$IDE_ARCHIVE" ]]; then
    info "Fetching latest IDE release from Arch Linux AUR..."
    local pkgbuild pkgver _build
    pkgbuild=$(download_file "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=antigravity-ide" "" || echo "")
    [[ -z "$pkgbuild" ]] && die "IDE: Failed to retrieve AUR PKGBUILD."
    pkgver=$(echo "$pkgbuild" | grep -E "^pkgver=" | cut -d= -f2 | xargs)
    _build=$(echo "$pkgbuild" | grep -E "^_build=" | cut -d= -f2 | xargs)
    [[ -z "$pkgver" || -z "$_build" ]] && die "IDE: Failed to parse pkgver/_build."
    info "Latest: v${pkgver}-${_build}"
    info "Downloading $IDE_ARCHIVE..."
    download_file "https://dl.google.com/release2/j0qc3/antigravity/stable/${pkgver}-${_build}/linux-arm/Antigravity%20IDE.tar.gz" "$IDE_ARCHIVE" || { rm -f "$IDE_ARCHIVE"; die "IDE: Download failed."; }
    ok "Downloaded $IDE_ARCHIVE"
  fi

  # Backup existing IDE files to allow rollback
  if [[ -d "$INSTALL_DIR" ]]; then
    info "Backing up existing IDE installation directory..."
    local dir_bak="${INSTALL_DIR}.bak.$$"
    mv "$INSTALL_DIR" "$dir_bak"
    register_backup "$INSTALL_DIR" "$dir_bak"
  else
    register_fresh "$INSTALL_DIR"
  fi

  local ide_bin="$INSTALL_BIN_DIR/antigravity-ide"
  if [[ -f "$ide_bin" || -L "$ide_bin" ]]; then
    local bin_bak="${ide_bin}.bak.$$"
    mv "$ide_bin" "$bin_bak"
    register_backup "$ide_bin" "$bin_bak"
  else
    register_fresh "$ide_bin"
  fi

  local ide_desktop="$APPLICATIONS_DIR/antigravity-ide.desktop"
  if [[ -f "$ide_desktop" ]]; then
    local ds_bak="${ide_desktop}.bak.$$"
    mv "$ide_desktop" "$ds_bak"
    register_backup "$ide_desktop" "$ds_bak"
  else
    register_fresh "$ide_desktop"
  fi

  local ide_icon="$ICONS_DIR/antigravity-ide.png"
  if [[ -f "$ide_icon" ]]; then
    local icon_bak="${ide_icon}.bak.$$"
    mv "$ide_icon" "$icon_bak"
    register_backup "$ide_icon" "$icon_bak"
  else
    register_fresh "$ide_icon"
  fi

  mkdir -p "$INSTALL_BIN_DIR" "$APPLICATIONS_DIR" "$ICONS_DIR" "$LIB_DIR"
  extract_tar "$IDE_ARCHIVE" "$HOME/.local/share/"

  # ── Adjust Electron startup ──
  local IDE_SCRIPT="$INSTALL_DIR/bin/antigravity-ide"
  [[ -f "$IDE_SCRIPT" ]] || die "IDE: Entrypoint wrapper not found in archive."
  sed -i 's|ELECTRON_RUN_AS_NODE=1 "$ELECTRON" "$CLI" "$@"|ELECTRON_RUN_AS_NODE=1 "$ELECTRON" "$CLI" --no-sandbox "$@"|g' "$IDE_SCRIPT"
  chmod +x "$IDE_SCRIPT"

  # ── Interposer ──
  cp "${BUILD_DIR}/libmmap_va39_fix.so" "$LIB_DIR/libmmap_va39_fix.so"
  chmod 755 "$LIB_DIR/libmmap_va39_fix.so"

  # ── Patch language server ──
  if [[ -f "$LS_PATH" ]]; then
    info "Patching IDE language server..."
    mv "$LS_PATH" "${LS_PATH}.va39"
    python3 "${BUILD_DIR}/va39_patch.py" "${LS_PATH}.va39" "${LS_PATH}.va39"
    create_bash_wrapper "$LS_PATH" "language_server_linux_arm.va39"
    chmod 755 "${LS_PATH}.va39"
  else
    die "IDE: Language server not found at $LS_PATH."
  fi

  # ── Wrap main IDE binary ──
  local IDE_BIN="$INSTALL_DIR/antigravity-ide"
  if [[ -f "$IDE_BIN" ]]; then
    info "Wrapping main IDE binary..."
    mv "$IDE_BIN" "${IDE_BIN}.va39"
    create_bash_wrapper "$IDE_BIN" "antigravity-ide.va39"
    chmod 755 "${IDE_BIN}.va39"
  else
    die "IDE: Main binary not found."
  fi

  # ── System shortcuts ──
  ln -sf "$IDE_SCRIPT" "$INSTALL_BIN_DIR/antigravity-ide"

  local ICON_SOURCE="$INSTALL_DIR/resources/app/resources/linux/code.png"
  local ICON_DEST="$ICONS_DIR/antigravity-ide.png"
  [[ -f "$ICON_SOURCE" ]] && cp -f "$ICON_SOURCE" "$ICON_DEST"

  local DESKTOP_FILE="$APPLICATIONS_DIR/antigravity-ide.desktop"
  cat > "$DESKTOP_FILE" << IEOF
[Desktop Entry]
Name=Antigravity IDE
Comment=Antigravity IDE
Exec="$INSTALL_BIN_DIR/antigravity-ide" --no-sandbox %F
Icon=$ICON_DEST
Type=Application
StartupNotify=true
Categories=Utility;TextEditor;Development;IDE;
MimeType=text/plain;inode/directory;
Actions=new-empty-window;

[Desktop Action new-empty-window]
Name=New Empty Window
Exec="$INSTALL_BIN_DIR/antigravity-ide" --no-sandbox --new-window %F
Icon=$ICON_DEST
IEOF
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPLICATIONS_DIR" 2>/dev/null || true

  ok "IDE installed → ${D}antigravity-ide${N}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  Execute Selected Installations
# ══════════════════════════════════════════════════════════════════════════════
[[ $INSTALL_CLI -eq 1 ]]     && install_cli
[[ $INSTALL_DESKTOP -eq 1 ]] && install_desktop
[[ $INSTALL_IDE -eq 1 ]]     && install_ide

# ── Final Summary ─────────────────────────────────────────────────────────────
ALL_SUCCESS=1
echo ""
sep
printf '  %b\n' "${G}${B}All done.${N} Installed: ${B}${SELECTED_NAMES[*]}${N}"

case ":$PATH:" in
  *":$INSTALL_BIN_DIR:"*) ;;
  *)
    printf '\n  %b\n' "${R}!${N} ${B}${INSTALL_BIN_DIR}${N} is not in your PATH."
    printf '  %b\n' "${D}Add to ~/.bashrc:${N}  export PATH=\"${INSTALL_BIN_DIR}:\$PATH\""
    ;;
esac

echo ""
[[ $INSTALL_CLI -eq 1 ]]     && printf '  %b\n' "${D}CLI:${N}     ${C}agy${N}"
[[ $INSTALL_DESKTOP -eq 1 ]] && printf '  %b\n' "${D}Desktop:${N} ${C}antigravity${N}"
[[ $INSTALL_IDE -eq 1 ]]     && printf '  %b\n' "${D}IDE:${N}     ${C}antigravity-ide${N}"
echo ""
