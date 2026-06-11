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
    if [[ -n "${TERMUX_VERSION:-}" ]] && [[ ":$PATH:" == *":/data/data/com.termux/files/usr/bin:"* ]]; then
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

# ── Temp dir & cleanup ────────────────────────────────────────────────────────
BUILD_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'agy-build')
ALL_SUCCESS=0

# Global backup variables for rolling back changes on failure
CLI_AGY_BAK=""

DESKTOP_DIR_BAK=""
DESKTOP_DIR_CREATED_FRESH=0
DESKTOP_WRAPPER_BAK=""
DESKTOP_WRAPPER_CREATED_FRESH=0
DESKTOP_FILE_BAK=""
DESKTOP_FILE_CREATED_FRESH=0
DESKTOP_ICON_BAK=""
DESKTOP_ICON_CREATED_FRESH=0

IDE_DIR_BAK=""
IDE_DIR_CREATED_FRESH=0
IDE_BIN_BAK=""
IDE_BIN_CREATED_FRESH=0
IDE_DESKTOP_BAK=""
IDE_DESKTOP_CREATED_FRESH=0
IDE_ICON_BAK=""
IDE_ICON_CREATED_FRESH=0

cleanup() {
  printf "\033[?25h"
  # Clean up temporary files / build dir
  [[ -n "${BUILD_DIR:-}" && -d "$BUILD_DIR" ]] && rm -rf "$BUILD_DIR"

  if [[ "${ALL_SUCCESS:-0}" -ne 1 ]]; then
    info "Installation failed or interrupted! Reverting all changes..."

    # --- CLI Rollback ---
    if [[ -n "$CLI_AGY_BAK" && -f "$CLI_AGY_BAK" ]]; then
      rm -f "$INSTALL_BIN_DIR/agy"
      mv "$CLI_AGY_BAK" "$INSTALL_BIN_DIR/agy"
    fi

    # --- Desktop Rollback ---
    local desktop_target_dir="$HOME/.local/share/Antigravity-arm64"
    local desktop_wrapper="$INSTALL_BIN_DIR/antigravity"
    local desktop_file="$HOME/.local/share/applications/antigravity.desktop"
    local desktop_icon="$HOME/.local/share/icons/antigravity.png"

    if [[ -n "$DESKTOP_DIR_BAK" && -d "$DESKTOP_DIR_BAK" ]]; then
      rm -rf "$desktop_target_dir"
      mv "$DESKTOP_DIR_BAK" "$desktop_target_dir"
      info "Restored previous Desktop target directory."
    elif [[ "$DESKTOP_DIR_CREATED_FRESH" -eq 1 ]]; then
      rm -rf "$desktop_target_dir"
    fi
    
    if [[ -n "$DESKTOP_WRAPPER_BAK" && -f "$DESKTOP_WRAPPER_BAK" ]]; then
      rm -f "$desktop_wrapper"
      mv "$DESKTOP_WRAPPER_BAK" "$desktop_wrapper"
    elif [[ "$DESKTOP_WRAPPER_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$desktop_wrapper"
    fi
    
    if [[ -n "$DESKTOP_FILE_BAK" && -f "$DESKTOP_FILE_BAK" ]]; then
      rm -f "$desktop_file"
      mv "$DESKTOP_FILE_BAK" "$desktop_file"
    elif [[ "$DESKTOP_FILE_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$desktop_file"
    fi

    if [[ -n "$DESKTOP_ICON_BAK" && -f "$DESKTOP_ICON_BAK" ]]; then
      rm -f "$desktop_icon"
      mv "$DESKTOP_ICON_BAK" "$desktop_icon"
    elif [[ "$DESKTOP_ICON_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$desktop_icon"
    fi

    # --- IDE Rollback ---
    local ide_target_dir="$HOME/.local/share/Antigravity IDE"
    local ide_bin="$INSTALL_BIN_DIR/antigravity-ide"
    local ide_desktop="$HOME/.local/share/applications/antigravity-ide.desktop"
    local ide_icon="$HOME/.local/share/icons/antigravity-ide.png"

    if [[ -n "$IDE_DIR_BAK" && -d "$IDE_DIR_BAK" ]]; then
      rm -rf "$ide_target_dir"
      mv "$IDE_DIR_BAK" "$ide_target_dir"
      info "Restored previous IDE target directory."
    elif [[ "$IDE_DIR_CREATED_FRESH" -eq 1 ]]; then
      rm -rf "$ide_target_dir"
    fi

    if [[ -n "$IDE_BIN_BAK" && -f "$IDE_BIN_BAK" ]]; then
      rm -f "$ide_bin"
      mv "$IDE_BIN_BAK" "$ide_bin"
    elif [[ "$IDE_BIN_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$ide_bin"
    fi

    if [[ -n "$IDE_DESKTOP_BAK" && -f "$IDE_DESKTOP_BAK" ]]; then
      rm -f "$ide_desktop"
      mv "$IDE_DESKTOP_BAK" "$ide_desktop"
    elif [[ "$IDE_DESKTOP_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$ide_desktop"
    fi

    if [[ -n "$IDE_ICON_BAK" && -f "$IDE_ICON_BAK" ]]; then
      rm -f "$ide_icon"
      mv "$IDE_ICON_BAK" "$ide_icon"
    elif [[ "$IDE_ICON_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$ide_icon"
    fi
  else
    # Success: delete all backups
    [[ -n "$CLI_AGY_BAK" && -f "$CLI_AGY_BAK" ]] && rm -f "$CLI_AGY_BAK"
    
    [[ -n "$DESKTOP_DIR_BAK" && -d "$DESKTOP_DIR_BAK" ]] && rm -rf "$DESKTOP_DIR_BAK"
    [[ -n "$DESKTOP_WRAPPER_BAK" && -f "$DESKTOP_WRAPPER_BAK" ]] && rm -f "$DESKTOP_WRAPPER_BAK"
    [[ -n "$DESKTOP_FILE_BAK" && -f "$DESKTOP_FILE_BAK" ]] && rm -f "$DESKTOP_FILE_BAK"
    [[ -n "$DESKTOP_ICON_BAK" && -f "$DESKTOP_ICON_BAK" ]] && rm -f "$DESKTOP_ICON_BAK"
    
    [[ -n "$IDE_DIR_BAK" && -d "$IDE_DIR_BAK" ]] && rm -rf "$IDE_DIR_BAK"
    [[ -n "$IDE_BIN_BAK" && -f "$IDE_BIN_BAK" ]] && rm -f "$IDE_BIN_BAK"
    [[ -n "$IDE_DESKTOP_BAK" && -f "$IDE_DESKTOP_BAK" ]] && rm -f "$IDE_DESKTOP_BAK"
    [[ -n "$IDE_ICON_BAK" && -f "$IDE_ICON_BAK" ]] && rm -f "$IDE_ICON_BAK"
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

# Build selection list
SELECTED_NAMES=()
[[ $INSTALL_CLI -eq 1 ]] && SELECTED_NAMES+=("CLI")
[[ $INSTALL_IDE -eq 1 ]] && SELECTED_NAMES+=("IDE")
[[ $INSTALL_DESKTOP -eq 1 ]] && SELECTED_NAMES+=("Desktop 2.0")

printf '\n'
ok "Selected: ${B}${SELECTED_NAMES[*]}${N}"
sep

# ── Interactive Prompts & Confirmations Upfront ───────────────────────────────
RUN_CLI_INSTALL=0
RUN_CLI_UNPATCHED=0
RUN_DESKTOP_INSTALL=0
RUN_IDE_INSTALL=0

[[ $INSTALL_CLI -eq 1 ]] && RUN_CLI_INSTALL=1
[[ $INSTALL_DESKTOP -eq 1 ]] && RUN_DESKTOP_INSTALL=1
[[ $INSTALL_IDE -eq 1 ]] && RUN_IDE_INSTALL=1

# 1. CLI Confirmations
if [[ $INSTALL_CLI -eq 1 ]]; then
  if [[ -f "$INSTALL_BIN_DIR/agy" ]]; then
    warn "An existing installation of Antigravity CLI was detected at $INSTALL_BIN_DIR/agy."
    info "Reinstalling will update the application binary. Your user data (configurations, logs, and databases in ~/.gemini/ and other directories) will NOT be lost or affected."
    printf '  Proceed with reinstalling/updating CLI? [Y/n]: '
    run_ans=""
    read -r run_ans < /dev/tty || run_ans="y"
    if [[ ! "$run_ans" =~ ^[Yy]$ && -n "$run_ans" ]]; then
      info "Skipping CLI installation in this script."
      RUN_CLI_INSTALL=0
    fi
  fi

  if [[ $RUN_CLI_INSTALL -eq 1 ]]; then
    printf '\n  %b\n' "${B}Antigravity CLI Installation Options:${N}"
    printf '  - %bY%b: Continue CLI installation using this script but WITHOUT patching/wrapping.%b\n' "${G}" "${N}" "${N}"
    printf '  - %bN%b: Skip CLI installation in this script (e.g. to copy the official command and run it manually in another session: %bcurl -fsSL https://antigravity.google/cli/install.sh | bash%b).%b\n' "${R}" "${N}" "${C}" "${N}" "${N}"
    printf '  Continue with unpatched installation in this script? [Y/n]: '
    opt_ans=""
    read -r opt_ans < /dev/tty || opt_ans="y"
    if [[ ! "$opt_ans" =~ ^[Yy]$ && -n "$opt_ans" ]]; then
      info "Skipping CLI installation in this script."
      info "You can copy and run this command in a different terminal session:"
      printf '  %bcurl -fsSL https://antigravity.google/cli/install.sh | bash%b\n\n' "${C}" "${N}"
      RUN_CLI_INSTALL=0
    else
      RUN_CLI_UNPATCHED=1
    fi
  fi
fi

# 2. Desktop Confirmations
if [[ $INSTALL_DESKTOP -eq 1 ]]; then
  desktop_target_dir="$HOME/.local/share/Antigravity-arm64"
  if [[ -d "$desktop_target_dir" ]]; then
    warn "An existing installation of Antigravity Desktop was detected at $desktop_target_dir."
    info "Reinstalling will update the application files. Your user data, configurations, and application state (stored outside the installation directory) will NOT be lost or affected."
    printf '  Proceed with reinstalling/updating Desktop? [Y/n]: '
    run_ans=""
    read -r run_ans < /dev/tty || run_ans="y"
    if [[ ! "$run_ans" =~ ^[Yy]$ && -n "$run_ans" ]]; then
      info "Skipping Desktop installation."
      RUN_DESKTOP_INSTALL=0
    fi
  fi
fi

# 3. IDE Confirmations
if [[ $INSTALL_IDE -eq 1 ]]; then
  ide_target_dir="$HOME/.local/share/Antigravity IDE"
  if [[ -d "$ide_target_dir" ]]; then
    warn "An existing installation of Antigravity IDE was detected at $ide_target_dir."
    info "Reinstalling will update the application files. Your custom extensions, settings, and workspace data (stored outside the installation directory) will NOT be lost or affected."
    printf '  Proceed with reinstalling/updating IDE? [Y/n]: '
    run_ans=""
    read -r run_ans < /dev/tty || run_ans="y"
    if [[ ! "$run_ans" =~ ^[Yy]$ && -n "$run_ans" ]]; then
      info "Skipping IDE installation."
      RUN_IDE_INSTALL=0
    fi
  fi
fi

# Exit early if nothing remains to install
if [[ $RUN_CLI_INSTALL -eq 0 && $RUN_DESKTOP_INSTALL -eq 0 && $RUN_IDE_INSTALL -eq 0 ]]; then
  echo ""
  sep
  printf '  %b\n' "${Y}No installations were attempted.${N}"
  sep
  ALL_SUCCESS=1
  exit 0
fi

# 4. Total Disk Space Check Upfront
total_required_kb=0
[[ $RUN_CLI_INSTALL -eq 1 ]] && total_required_kb=$((total_required_kb + 51200))
[[ $RUN_DESKTOP_INSTALL -eq 1 ]] && total_required_kb=$((total_required_kb + 307200))
[[ $RUN_IDE_INSTALL -eq 1 ]] && total_required_kb=$((total_required_kb + 819200))

if [[ $total_required_kb -gt 0 ]]; then
  check_disk_space "$HOME/.local" "$total_required_kb"
fi

# ── Prerequisite Checks & Package Manager Prompts Upfront ─────────────────────
detect_compiler() {
  if [[ "$ENV_TYPE" == "termux" ]] && [[ -x "/data/data/com.termux/files/usr/bin/clang" ]]; then
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

# Determine what needs downloading
NEED_DOWNLOAD=0
CLI_UPSTREAM_BIN=""

if [[ $RUN_CLI_INSTALL -eq 1 ]]; then
  if [[ -f "./antigravity" ]]; then
    CLI_UPSTREAM_BIN="./antigravity"
  elif [[ -f "./agy" ]]; then
    CLI_UPSTREAM_BIN="./agy"
  else
    NEED_DOWNLOAD=1
  fi
fi

DESKTOP_ARCHIVE_NAME="Antigravity.tar.gz"
if [[ -f "$DESKTOP_ARCHIVE_NAME" ]]; then
  info "Using local archive: $DESKTOP_ARCHIVE_NAME"
  DESKTOP_ARCHIVE="$(pwd)/$DESKTOP_ARCHIVE_NAME"
else
  if [[ $RUN_DESKTOP_INSTALL -eq 1 ]]; then
    NEED_DOWNLOAD=1
  fi
  DESKTOP_ARCHIVE="${BUILD_DIR}/$DESKTOP_ARCHIVE_NAME"
fi

IDE_ARCHIVE_NAME="Antigravity IDE.tar.gz"
if [[ -f "$IDE_ARCHIVE_NAME" ]]; then
  info "Using local archive: $IDE_ARCHIVE_NAME"
  IDE_ARCHIVE="$(pwd)/$IDE_ARCHIVE_NAME"
else
  if [[ $RUN_IDE_INSTALL -eq 1 ]]; then
    NEED_DOWNLOAD=1
  fi
  IDE_ARCHIVE="${BUILD_DIR}/$IDE_ARCHIVE_NAME"
fi

check_and_install_dependencies() {
  while true; do
    local missing=()
    local tools=(python3 tar)

    if [[ $NEED_DOWNLOAD -eq 1 ]]; then
      tools+=(curl)
    fi
    if [[ $RUN_CLI_INSTALL -eq 1 && -z "$CLI_UPSTREAM_BIN" ]]; then
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
      printf '\n  %b\n' "${R}✗${N} Missing: ${B}${missing[*]}${N}"
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
print(f"Patched: ubfx={ubfx_count} lsl={lsl_count} mask={mask_count} mmap={mmap_count} faccessat2={faccessat2_count}")
PYEOF
# ── Shared: ide_ls_helper.c (IDE Language Server Wrapper) ─────────────────────
cat << 'EOF' > "${BUILD_DIR}/ide_ls_helper.c"
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define INTERPOSER_ENVVAR "AGY_MMAP_INTERPOSER"

#ifndef PATCHED_BIN_NAME
#define PATCHED_BIN_NAME "language_server_linux_arm.va39"
#endif

int main(int argc, char **argv) {
    char exec_path[PATH_MAX];
    char patched_bin[PATH_MAX];
    char lib_path[PATH_MAX * 3];
    const char *loader_primary   = "/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1";
    const char *loader_fallback  = "/lib/ld-linux-aarch64.so.1";
    const char *loader;
    const char *dir;
    const char *interposer;
    char **new_argv;
    ssize_t read_len;
    int written, arg_idx, new_argc;

    unsetenv("LD_PRELOAD");
    unsetenv("LD_LIBRARY_PATH");
    setenv("GODEBUG", "netdns=cgo", 1);

    if (access("/data/data/com.termux/files/usr/etc/tls/cert.pem", F_OK) == 0) {
        setenv("SSL_CERT_FILE", "/data/data/com.termux/files/usr/etc/tls/cert.pem", 1);
    } else if (access("/etc/ssl/certs/ca-certificates.crt", F_OK) == 0) {
        setenv("SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt", 1);
    }

    read_len = readlink("/proc/self/exe", exec_path, sizeof(exec_path) - 1);
    if (read_len == -1) {
        perror("[ide-ls] readlink /proc/self/exe failed");
        return 1;
    }
    exec_path[read_len] = '\0';
    dir = dirname(exec_path);

    written = snprintf(patched_bin, sizeof(patched_bin),
                       "%s/%s", dir, PATCHED_BIN_NAME);
    if (written < 0 || written >= (int)sizeof(patched_bin)) {
        fprintf(stderr, "[ide-ls] Path too long.\n");
        return 1;
    }

    interposer = getenv(INTERPOSER_ENVVAR);
    if (!interposer || interposer[0] == '\0') {
        const char *home = getenv("HOME");
        static char interposer_buf[PATH_MAX];
        if (home) {
            snprintf(interposer_buf, sizeof(interposer_buf),
                     "%s/.local/share/Antigravity IDE/libmmap_va39_fix.so", home);
            interposer = interposer_buf;
        }
    }

    if (access(loader_primary, F_OK) == 0) {
        loader = loader_primary;
    } else {
        loader = loader_fallback;
    }

    if (access("/data/data/com.termux/files/usr/glibc/lib", F_OK) == 0) {
        written = snprintf(lib_path, sizeof(lib_path),
                           "%s/../lib:/data/data/com.termux/files/usr/glibc/lib", dir);
    } else {
        written = snprintf(lib_path, sizeof(lib_path),
                           "%s/../lib:/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu:/lib64:/usr/lib64:/lib:/usr/lib", dir);
    }

    new_argc = argc + 8;
    new_argv = malloc((size_t)new_argc * sizeof(*new_argv));
    if (!new_argv) {
        perror("[ide-ls] malloc failed");
        return 1;
    }

    arg_idx = 0;
    new_argv[arg_idx++] = (char *)loader;

    if (interposer && access(interposer, F_OK) == 0) {
        new_argv[arg_idx++] = "--preload";
        new_argv[arg_idx++] = (char *)interposer;
    }

    new_argv[arg_idx++] = "--library-path";
    new_argv[arg_idx++] = lib_path;
    new_argv[arg_idx++] = patched_bin;

    for (int i = 1; i < argc; i++) {
        new_argv[arg_idx++] = argv[i];
    }
    new_argv[arg_idx] = NULL;

    execv(loader, new_argv);
    perror("[ide-ls] execv failed");
    free(new_argv);
    return 1;
}
EOF

# ── Shared compatibility fix source (mmap_va39_fix.c) ────────────────────────
cat << 'EOF' > "${BUILD_DIR}/mmap_va39_fix.c"
// NOLINTNEXTLINE(bugprone-reserved-identifier,cert-dcl37-c,cert-dcl51-cpp)
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>

/*
 * TCMalloc assumes a 48-bit Virtual Address (VA) space.
 * Many ARM64 Android kernels (and chroots running on them) are limited to 39 bits.
 * This interposer intercepts mmap calls and clears the hint address if it
 * exceeds the 39-bit boundary, allowing the kernel to pick a safe address.
 */

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

enum { max_va_bits = 39 };
static const uintptr_t va_boundary = (uintptr_t)1 << max_va_bits;

// NOLINTNEXTLINE(readability-inconsistent-declaration-parameter-name)
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

# Fetch PKGBUILD version helper
fetch_aur_version() {
  local pkg_name="$1"
  info "Fetching latest version details for $pkg_name from AUR..." >&2
  local pkgbuild
  pkgbuild=$(download_file "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=${pkg_name}" "" || echo "")
  [[ -z "$pkgbuild" ]] && die "Failed to retrieve AUR PKGBUILD for $pkg_name."
  local pkgver
  pkgver=$(echo "$pkgbuild" | grep -E "^pkgver=" | cut -d= -f2 | xargs)
  local build_num
  build_num=$(echo "$pkgbuild" | grep -E "^_build=" | cut -d= -f2 | xargs)
  [[ -z "$pkgver" || -z "$build_num" ]] && die "Failed to parse pkgver/_build from AUR PKGBUILD for $pkg_name."
  echo "${pkgver}:${build_num}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL: CLI
# ══════════════════════════════════════════════════════════════════════════════
install_cli() {
  echo ""
  sep
  printf '  %b\n' "${B}${C}Installing ${TASK_PROGRESS}: Antigravity CLI${N}"
  sep

  # Reset CLI backups
  CLI_AGY_BAK=""

  if [[ -f "$INSTALL_BIN_DIR/agy" ]]; then
    CLI_AGY_BAK="$INSTALL_BIN_DIR/agy.bak.$$"
  fi

  local status=0
  set +e
  (
    trap - EXIT
    set -e
    if [[ -n "$CLI_AGY_BAK" ]]; then
      mv -f "$INSTALL_BIN_DIR/agy" "$CLI_AGY_BAK"
    fi

    info "Querying latest CLI version..."
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

    mkdir -p "$INSTALL_BIN_DIR"
    install -m 0755 "$CLI_UPSTREAM_BIN" "$INSTALL_BIN_DIR/agy" || die "CLI: Failed to install agy"
  )
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    if [[ -n "${CLI_UPSTREAM_BIN:-}" && -f "$CLI_UPSTREAM_BIN" && "$CLI_UPSTREAM_BIN" != "${BUILD_DIR}"* ]]; then
      warn "If the local CLI binary is corrupted, please manually delete: $CLI_UPSTREAM_BIN"
    fi
    if [[ -n "$CLI_AGY_BAK" && -f "$CLI_AGY_BAK" ]]; then
      rm -f "$INSTALL_BIN_DIR/agy"
      mv "$CLI_AGY_BAK" "$INSTALL_BIN_DIR/agy"
      info "Restored previous Antigravity CLI binary."
    fi
    CLI_AGY_BAK=""
    warn "CLI installation failed."
    CLI_INSTALL_STATUS="failed"
    return 1
  else
    if [[ -n "$CLI_AGY_BAK" && -f "$CLI_AGY_BAK" ]]; then
      rm -f "$CLI_AGY_BAK"
    fi
    CLI_AGY_BAK=""
    ok "CLI installed → ${D}${INSTALL_BIN_DIR}/agy${N}"
    CLI_INSTALL_STATUS="success"
    return 0
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL: ANTIGRAVITY 2.0 DESKTOP
# ══════════════════════════════════════════════════════════════════════════════
install_desktop() {
  echo ""
  sep
  printf '  %b\n' "${B}${C}Installing ${TASK_PROGRESS}: Antigravity 2.0 Desktop${N}"
  sep

  local TARGET_DIR="$HOME/.local/share/Antigravity-arm64"
  local ICON_SRC="$TARGET_DIR/icon.png"
  local ICON_DST="$HOME/.local/share/icons/antigravity.png"
  local DESKTOP_FILE="$HOME/.local/share/applications/antigravity.desktop"
  local WRAPPER="$INSTALL_BIN_DIR/antigravity"

  # Reset global flags
  DESKTOP_DIR_BAK=""
  DESKTOP_DIR_CREATED_FRESH=0
  DESKTOP_WRAPPER_BAK=""
  DESKTOP_WRAPPER_CREATED_FRESH=0
  DESKTOP_FILE_BAK=""
  DESKTOP_FILE_CREATED_FRESH=0
  DESKTOP_ICON_BAK=""
  DESKTOP_ICON_CREATED_FRESH=0

  if [[ -d "$TARGET_DIR" ]]; then
    DESKTOP_DIR_BAK="${TARGET_DIR}.bak.$$"
  else
    DESKTOP_DIR_CREATED_FRESH=1
  fi

  if [[ -f "$WRAPPER" ]]; then
    DESKTOP_WRAPPER_BAK="${WRAPPER}.bak.$$"
  else
    DESKTOP_WRAPPER_CREATED_FRESH=1
  fi

  if [[ -f "$DESKTOP_FILE" ]]; then
    DESKTOP_FILE_BAK="${DESKTOP_FILE}.bak.$$"
  else
    DESKTOP_FILE_CREATED_FRESH=1
  fi

  if [[ -f "$ICON_DST" ]]; then
    DESKTOP_ICON_BAK="${ICON_DST}.bak.$$"
  else
    DESKTOP_ICON_CREATED_FRESH=1
  fi

  local status=0
  set +e
  (
    trap - EXIT
    set -e

    # Perform backups
    [[ -n "$DESKTOP_DIR_BAK" ]] && mv "$TARGET_DIR" "$DESKTOP_DIR_BAK"
    [[ -n "$DESKTOP_WRAPPER_BAK" ]] && mv "$WRAPPER" "$DESKTOP_WRAPPER_BAK"
    [[ -n "$DESKTOP_FILE_BAK" ]] && mv "$DESKTOP_FILE" "$DESKTOP_FILE_BAK"
    [[ -n "$DESKTOP_ICON_BAK" ]] && mv "$ICON_DST" "$DESKTOP_ICON_BAK"

    # Download if needed
    if [[ ! -f "$DESKTOP_ARCHIVE" ]]; then
      local ver_info
      ver_info=$(fetch_aur_version "antigravity")
      local desktop_ver="${ver_info%%:*}"
      local desktop_build="${ver_info#*:}"
      info "Latest Desktop: v${desktop_ver}-${desktop_build}"
      info "Downloading $DESKTOP_ARCHIVE..."
      download_file "https://storage.googleapis.com/antigravity-public/antigravity-hub/${desktop_ver}-${desktop_build}/linux-arm/Antigravity.tar.gz" "$DESKTOP_ARCHIVE" || { rm -f "$DESKTOP_ARCHIVE"; die "Desktop: Download failed."; }
      ok "Downloaded $DESKTOP_ARCHIVE"
    fi

    # Extract
    info "Extracting $DESKTOP_ARCHIVE..."
    extract_tar "$DESKTOP_ARCHIVE" "${BUILD_DIR}/desktop_extract" || die "Desktop: Extraction failed."
    local SRC_DIR="${BUILD_DIR}/desktop_extract/Antigravity-arm64"
    [[ -d "$SRC_DIR" ]] || die "Desktop: Antigravity-arm64 folder not found in archive."

    mkdir -p "$(dirname "$TARGET_DIR")"
    mv "$SRC_DIR" "$TARGET_DIR"

    # Icon
    mkdir -p "$(dirname "$ICON_DST")"
    if [[ -f "$ICON_SRC" ]]; then
      cp -f "$ICON_SRC" "$ICON_DST"
    elif [[ -f "$TARGET_DIR/resources/app.asar" ]]; then
      python3 -c '
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
        f.read(4); hps = struct.unpack("<I", f.read(4))[0]; f.read(4)
        ss = struct.unpack("<I", f.read(4))[0]; hs = f.read(ss).decode("utf-8")
        info = find_file(json.loads(hs), "icon.png")
        if info:
            f.seek(8 + hps + int(info["offset"]))
            with open(sys.argv[2], "wb") as out: out.write(f.read(int(info["size"])))
            sys.exit(0)
except Exception: pass
sys.exit(1)
' "$TARGET_DIR/resources/app.asar" "$ICON_DST" 2>/dev/null || true
    fi

    # Apply Desktop Fix (VA39/Termux/PRoot)
    local APP_DIR="$TARGET_DIR"
    local BIN_DIR="$APP_DIR/resources/bin"
    local INTERPOSER_SO="$APP_DIR/libmmap_va39_fix.so"

    # 1. Backups
    info "Backing up original binaries..."
    [[ -f "$APP_DIR/antigravity" && ! -f "$APP_DIR/antigravity.orig" ]] && cp "$APP_DIR/antigravity" "$APP_DIR/antigravity.orig"
    [[ -f "$BIN_DIR/language_server" && ! -f "$BIN_DIR/language_server.orig" ]] && cp "$BIN_DIR/language_server" "$BIN_DIR/language_server.orig"

    # 2. Compile Interposer
    info "Compiling mmap interposer..."
    cat << 'COF' > "${BUILD_DIR}/desktop_mmap_va39_fix.c"
// NOLINTNEXTLINE(bugprone-reserved-identifier,cert-dcl37-c,cert-dcl51-cpp)
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>

/*
 * TCMalloc assumes a 48-bit Virtual Address (VA) space.
 * Many ARM64 Android kernels (and chroots running on them) are limited to 39 bits.
 * This interposer intercepts mmap calls and clears the hint address if it
 * exceeds the 39-bit boundary, allowing the kernel to pick a safe address.
 */

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

enum { max_va_bits = 39 };
static const uintptr_t va_boundary = (uintptr_t)1 << max_va_bits;

// NOLINTNEXTLINE(readability-inconsistent-declaration-parameter-name)
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
COF
    "$local_cc" -O2 -fPIC -shared -o "$INTERPOSER_SO" "${BUILD_DIR}/desktop_mmap_va39_fix.c" -ldl

    # 3. Surgical Patch for Language Server
    info "Applying surgical binary patch to language_server..."
    python3 - "$BIN_DIR/language_server.orig" "$BIN_DIR/language_server" << 'PY'
import sys, shutil, struct, pathlib
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
data = bytearray(src.read_bytes())
def get(off): return struct.unpack_from("<I", data, off)[0]
def put(off, word): struct.pack_into("<I", data, off, word)

# Segment 01 (R E) for language_server ends at 0x060dc2e0
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
print(f"  Patched: {counts}")
PY

    # 4. Create Wrapper
    info "Creating launcher wrapper..."
    mkdir -p "$INSTALL_BIN_DIR"
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
eval $(gnome-keyring-daemon --start --components=secrets)
export DBUS_SESSION_BUS_ADDRESS
echo -n "" | gnome-keyring-daemon --unlock || true
exec "$APP_DIR/antigravity" \
    --no-sandbox --disable-gpu --disable-gpu-compositing \
    --disable-gpu-rasterization --disable-dev-shm-usage \
    --ignore-certificate-errors --remote-allow-origins=* "$@"
EOF
    chmod +x "$WRAPPER"

    # Desktop entry
    mkdir -p "$(dirname "$DESKTOP_FILE")"
    cat > "$DESKTOP_FILE" <<DEOF
[Desktop Entry]
Name=Antigravity 2.0 Desktop
Comment=Antigravity 2.0 Desktop Electron App
Exec="$WRAPPER"
Icon=$ICON_DST
Terminal=false
Type=Application
Categories=Utility;Development;
MimeType=text/plain;
StartupNotify=true
DEOF
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$(dirname "$DESKTOP_FILE")" 2>/dev/null || true
  )
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    if [[ -f "$DESKTOP_ARCHIVE" ]]; then
      warn "If the Desktop archive is corrupted, please manually delete: $DESKTOP_ARCHIVE"
    fi

    # ROLLBACK:
    if [[ -n "$DESKTOP_DIR_BAK" && -d "$DESKTOP_DIR_BAK" ]]; then
      rm -rf "$TARGET_DIR"
      mv "$DESKTOP_DIR_BAK" "$TARGET_DIR"
    elif [[ "$DESKTOP_DIR_CREATED_FRESH" -eq 1 ]]; then
      rm -rf "$TARGET_DIR"
    fi

    if [[ -n "$DESKTOP_WRAPPER_BAK" && -f "$DESKTOP_WRAPPER_BAK" ]]; then
      rm -f "$WRAPPER"
      mv "$DESKTOP_WRAPPER_BAK" "$WRAPPER"
    elif [[ "$DESKTOP_WRAPPER_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$WRAPPER"
    fi

    if [[ -n "$DESKTOP_FILE_BAK" && -f "$DESKTOP_FILE_BAK" ]]; then
      rm -f "$DESKTOP_FILE"
      mv "$DESKTOP_FILE_BAK" "$DESKTOP_FILE"
    elif [[ "$DESKTOP_FILE_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$DESKTOP_FILE"
    fi

    if [[ -n "$DESKTOP_ICON_BAK" && -f "$DESKTOP_ICON_BAK" ]]; then
      rm -f "$ICON_DST"
      mv "$DESKTOP_ICON_BAK" "$ICON_DST"
    elif [[ "$DESKTOP_ICON_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$ICON_DST"
    fi

    # Reset variables
    DESKTOP_DIR_BAK=""
    DESKTOP_DIR_CREATED_FRESH=0
    DESKTOP_WRAPPER_BAK=""
    DESKTOP_WRAPPER_CREATED_FRESH=0
    DESKTOP_FILE_BAK=""
    DESKTOP_FILE_CREATED_FRESH=0
    DESKTOP_ICON_BAK=""
    DESKTOP_ICON_CREATED_FRESH=0

    warn "Desktop installation failed."
    DESKTOP_INSTALL_STATUS="failed"
    return 1
  else
    # SUCCESS: clean backups
    [[ -n "$DESKTOP_DIR_BAK" && -d "$DESKTOP_DIR_BAK" ]] && rm -rf "$DESKTOP_DIR_BAK"
    [[ -n "$DESKTOP_WRAPPER_BAK" && -f "$DESKTOP_WRAPPER_BAK" ]] && rm -f "$DESKTOP_WRAPPER_BAK"
    [[ -n "$DESKTOP_FILE_BAK" && -f "$DESKTOP_FILE_BAK" ]] && rm -f "$DESKTOP_FILE_BAK"
    [[ -n "$DESKTOP_ICON_BAK" && -f "$DESKTOP_ICON_BAK" ]] && rm -f "$DESKTOP_ICON_BAK"

    # Reset variables
    DESKTOP_DIR_BAK=""
    DESKTOP_DIR_CREATED_FRESH=0
    DESKTOP_WRAPPER_BAK=""
    DESKTOP_WRAPPER_CREATED_FRESH=0
    DESKTOP_FILE_BAK=""
    DESKTOP_FILE_CREATED_FRESH=0
    DESKTOP_ICON_BAK=""
    DESKTOP_ICON_CREATED_FRESH=0

    ok "Desktop installed successfully → ${D}antigravity${N}"
    DESKTOP_INSTALL_STATUS="success"
    return 0
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL: ANTIGRAVITY IDE
# ══════════════════════════════════════════════════════════════════════════════
install_ide() {
  echo ""
  sep
  printf '  %b\n' "${B}${C}Installing ${TASK_PROGRESS}: Antigravity IDE${N}"
  sep

  local TARGET_DIR="$HOME/.local/share/Antigravity IDE"
  local APPLICATIONS_DIR="$HOME/.local/share/applications"
  local ICONS_DIR="$HOME/.local/share/icons"
  local WRAPPER="$INSTALL_BIN_DIR/antigravity-ide"
  local DESKTOP_FILE="$APPLICATIONS_DIR/antigravity-ide.desktop"
  local ICON_DST="$ICONS_DIR/antigravity-ide.png"

  # Reset global flags
  IDE_DIR_BAK=""
  IDE_DIR_CREATED_FRESH=0
  IDE_BIN_BAK=""
  IDE_BIN_CREATED_FRESH=0
  IDE_DESKTOP_BAK=""
  IDE_DESKTOP_CREATED_FRESH=0
  IDE_ICON_BAK=""
  IDE_ICON_CREATED_FRESH=0

  if [[ -d "$TARGET_DIR" ]]; then
    IDE_DIR_BAK="${TARGET_DIR}.bak.$$"
  else
    IDE_DIR_CREATED_FRESH=1
  fi

  if [[ -f "$WRAPPER" || -L "$WRAPPER" ]]; then
    IDE_BIN_BAK="${WRAPPER}.bak.$$"
  else
    IDE_BIN_CREATED_FRESH=1
  fi

  if [[ -f "$DESKTOP_FILE" ]]; then
    IDE_DESKTOP_BAK="${DESKTOP_FILE}.bak.$$"
  else
    IDE_DESKTOP_CREATED_FRESH=1
  fi

  if [[ -f "$ICON_DST" ]]; then
    IDE_ICON_BAK="${ICON_DST}.bak.$$"
  else
    IDE_ICON_CREATED_FRESH=1
  fi

  local status=0
  set +e
  (
    trap - EXIT
    set -e

    # Perform backups
    [[ -n "$IDE_DIR_BAK" ]] && mv "$TARGET_DIR" "$IDE_DIR_BAK"
    [[ -n "$IDE_BIN_BAK" ]] && mv "$WRAPPER" "$IDE_BIN_BAK"
    [[ -n "$IDE_DESKTOP_BAK" ]] && mv "$DESKTOP_FILE" "$IDE_DESKTOP_BAK"
    [[ -n "$IDE_ICON_BAK" ]] && mv "$ICON_DST" "$IDE_ICON_BAK"

    # Download if needed
    if [[ ! -f "$IDE_ARCHIVE" ]]; then
      local ver_info
      ver_info=$(fetch_aur_version "antigravity-ide")
      local ide_ver="${ver_info%%:*}"
      local ide_build="${ver_info#*:}"
      info "Latest IDE: v${ide_ver}-${ide_build}"
      info "Downloading $IDE_ARCHIVE..."
      download_file "https://dl.google.com/release2/j0qc3/antigravity/stable/${ide_ver}-${ide_build}/linux-arm/Antigravity%20IDE.tar.gz" "$IDE_ARCHIVE" || { rm -f "$IDE_ARCHIVE"; die "IDE: Download failed."; }
      ok "Downloaded $IDE_ARCHIVE"
    fi

    # Extract
    info "Extracting $IDE_ARCHIVE..."
    extract_tar "$IDE_ARCHIVE" "${BUILD_DIR}/ide_extract" || die "IDE: Extraction failed."

    local SRC_DIR=""
    if [[ -d "${BUILD_DIR}/ide_extract/Antigravity IDE-arm64" ]]; then
      SRC_DIR="${BUILD_DIR}/ide_extract/Antigravity IDE-arm64"
    elif [[ -d "${BUILD_DIR}/ide_extract/Antigravity IDE" ]]; then
      SRC_DIR="${BUILD_DIR}/ide_extract/Antigravity IDE"
    else
      SRC_DIR=$(find "${BUILD_DIR}/ide_extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    fi
    [[ -n "$SRC_DIR" && -d "$SRC_DIR" ]] || die "IDE: Extracted folder not found in archive."

    mkdir -p "$(dirname "$TARGET_DIR")"
    mv "$SRC_DIR" "$TARGET_DIR"

    # Copy mmap compatibility library
    cp "${BUILD_DIR}/libmmap_va39_fix.so" "$TARGET_DIR/libmmap_va39_fix.so"
    chmod 755 "$TARGET_DIR/libmmap_va39_fix.so"

    # Patch language server(s) if present
    for ls_bin in language_server_linux_arm language_server; do
      local ls_path="$TARGET_DIR/resources/app/extensions/antigravity/bin/$ls_bin"
      if [[ -f "$ls_path" ]]; then
        info "Patching $ls_bin..."
        mv "$ls_path" "${ls_path}.va39"
        python3 "${BUILD_DIR}/va39_patch.py" "${ls_path}.va39" "${ls_path}.va39"
        "$local_cc" -O2 -DPATCHED_BIN_NAME="\"$ls_bin.va39\"" -o "$ls_path" "${BUILD_DIR}/ide_ls_helper.c"
        chmod 755 "$ls_path" "${ls_path}.va39"
      fi
    done

    # Create launcher wrapper script (symlink or script)
    mkdir -p "$INSTALL_BIN_DIR"
    local IDE_SCRIPT="$TARGET_DIR/bin/antigravity-ide"
    if [[ -f "$IDE_SCRIPT" ]]; then
      info "Adjusting Electron initialization parameters for container isolation..."
      sed -i 's|ELECTRON_RUN_AS_NODE=1 "$ELECTRON" "$CLI" "$@"|ELECTRON_RUN_AS_NODE=1 "$ELECTRON" "$CLI" --no-sandbox "$@"|g' "$IDE_SCRIPT"
      chmod +x "$IDE_SCRIPT"
    fi
    ln -sf "$IDE_SCRIPT" "$WRAPPER"

    # Copy Icon if available
    mkdir -p "$ICONS_DIR"
    local ICON_SOURCE="$TARGET_DIR/resources/app/resources/linux/code.png"
    if [[ -f "$ICON_SOURCE" ]]; then
      cp -f "$ICON_SOURCE" "$ICON_DST"
    fi

    # Create Desktop entry
    mkdir -p "$APPLICATIONS_DIR"
    cat > "$DESKTOP_FILE" << IEOF
[Desktop Entry]
Name=Antigravity IDE
Comment=Antigravity IDE
Exec="$WRAPPER" --no-sandbox %F
Icon=$ICON_DST
Type=Application
StartupNotify=true
Categories=Utility;TextEditor;Development;IDE;
MimeType=text/plain;inode/directory;
Actions=new-empty-window;

[Desktop Action new-empty-window]
Name=New Empty Window
Exec="$WRAPPER" --no-sandbox --new-window %F
Icon=$ICON_DST
IEOF
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPLICATIONS_DIR" 2>/dev/null || true
  )
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    if [[ -f "$IDE_ARCHIVE" ]]; then
      warn "If the IDE archive is corrupted, please manually delete: $IDE_ARCHIVE"
    fi

    # ROLLBACK:
    if [[ -n "$IDE_DIR_BAK" && -d "$IDE_DIR_BAK" ]]; then
      rm -rf "$TARGET_DIR"
      mv "$IDE_DIR_BAK" "$TARGET_DIR"
    elif [[ "$IDE_DIR_CREATED_FRESH" -eq 1 ]]; then
      rm -rf "$TARGET_DIR"
    fi

    if [[ -n "$IDE_BIN_BAK" && -f "$IDE_BIN_BAK" ]]; then
      rm -f "$WRAPPER"
      mv "$IDE_BIN_BAK" "$WRAPPER"
    elif [[ "$IDE_BIN_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$WRAPPER"
    fi

    if [[ -n "$IDE_DESKTOP_BAK" && -f "$IDE_DESKTOP_BAK" ]]; then
      rm -f "$DESKTOP_FILE"
      mv "$IDE_DESKTOP_BAK" "$DESKTOP_FILE"
    elif [[ "$IDE_DESKTOP_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$DESKTOP_FILE"
    fi

    if [[ -n "$IDE_ICON_BAK" && -f "$IDE_ICON_BAK" ]]; then
      rm -f "$ICON_DST"
      mv "$IDE_ICON_BAK" "$ICON_DST"
    elif [[ "$IDE_ICON_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$ICON_DST"
    fi

    # Reset variables
    IDE_DIR_BAK=""
    IDE_DIR_CREATED_FRESH=0
    IDE_BIN_BAK=""
    IDE_BIN_CREATED_FRESH=0
    IDE_DESKTOP_BAK=""
    IDE_DESKTOP_CREATED_FRESH=0
    IDE_ICON_BAK=""
    IDE_ICON_CREATED_FRESH=0

    warn "IDE installation failed."
    IDE_INSTALL_STATUS="failed"
    return 1
  else
    # SUCCESS: clean backups
    [[ -n "$IDE_DIR_BAK" && -d "$IDE_DIR_BAK" ]] && rm -rf "$IDE_DIR_BAK"
    [[ -n "$IDE_BIN_BAK" && -f "$IDE_BIN_BAK" ]] && rm -f "$IDE_BIN_BAK"
    [[ -n "$IDE_DESKTOP_BAK" && -f "$IDE_DESKTOP_BAK" ]] && rm -f "$IDE_DESKTOP_BAK"
    [[ -n "$IDE_ICON_BAK" && -f "$IDE_ICON_BAK" ]] && rm -f "$IDE_ICON_BAK"

    # Reset variables
    IDE_DIR_BAK=""
    IDE_DIR_CREATED_FRESH=0
    IDE_BIN_BAK=""
    IDE_BIN_CREATED_FRESH=0
    IDE_DESKTOP_BAK=""
    IDE_DESKTOP_CREATED_FRESH=0
    IDE_ICON_BAK=""
    IDE_ICON_CREATED_FRESH=0

    ok "IDE installed successfully → ${D}antigravity-ide${N}"
    IDE_INSTALL_STATUS="success"
    return 0
  fi
}

# ── Queue selected installs and run in strict order ───────────────────────────
QUEUE=()
[[ $RUN_CLI_INSTALL -eq 1 ]]     && QUEUE+=("cli")
[[ $RUN_IDE_INSTALL -eq 1 ]]     && QUEUE+=("ide")
[[ $RUN_DESKTOP_INSTALL -eq 1 ]] && QUEUE+=("desktop")

TOTAL_TASKS=${#QUEUE[@]}
CURRENT_TASK=0

# Compile shared compatibility layer if needed
if [[ $RUN_IDE_INSTALL -eq 1 ]]; then
  info "Compiling mmap compatibility layer..."
  "$local_cc" -O2 -fPIC -shared -o "${BUILD_DIR}/libmmap_va39_fix.so" "${BUILD_DIR}/mmap_va39_fix.c" -ldl
fi

CLI_INSTALL_STATUS="skipped"
IDE_INSTALL_STATUS="skipped"
DESKTOP_INSTALL_STATUS="skipped"

for task in "${QUEUE[@]}"; do
  CURRENT_TASK=$((CURRENT_TASK + 1))
  TASK_PROGRESS="${CURRENT_TASK}/${TOTAL_TASKS}"
  case "$task" in
    cli)
      install_cli || true
      ;;
    ide)
      install_ide || true
      ;;
    desktop)
      install_desktop || true
      ;;
  esac
done

# ── Final Summary ─────────────────────────────────────────────────────────────
ALL_SUCCESS=1
if [[ "$CLI_INSTALL_STATUS" == "failed" || "$IDE_INSTALL_STATUS" == "failed" || "$DESKTOP_INSTALL_STATUS" == "failed" ]]; then
  ALL_SUCCESS=0
fi

echo ""
sep
if [[ $ALL_SUCCESS -eq 1 ]]; then
  printf '  %b\n' "${G}${B}Installation completed successfully!${N}"
else
  printf '  %b\n' "${Y}${B}Installation completed with errors.${N}"
fi

# Print status of each component
if [[ $RUN_CLI_INSTALL -eq 1 ]]; then
  if [[ "$CLI_INSTALL_STATUS" == "success" ]]; then
    printf '  %b\n' "${G}✓${N} CLI: Installed successfully (${D}${INSTALL_BIN_DIR}/agy${N})"
  else
    printf '  %b\n' "${R}✗${N} CLI: Installation failed (reverted)"
  fi
fi

if [[ $RUN_IDE_INSTALL -eq 1 ]]; then
  if [[ "$IDE_INSTALL_STATUS" == "success" ]]; then
    printf '  %b\n' "${G}✓${N} IDE: Installed successfully (${D}${INSTALL_BIN_DIR}/antigravity-ide${N})"
  else
    printf '  %b\n' "${R}✗${N} IDE: Installation failed (reverted)"
  fi
fi

if [[ $RUN_DESKTOP_INSTALL -eq 1 ]]; then
  if [[ "$DESKTOP_INSTALL_STATUS" == "success" ]]; then
    printf '  %b\n' "${G}✓${N} Desktop: Installed successfully (${D}${INSTALL_BIN_DIR}/antigravity${N})"
  else
    printf '  %b\n' "${R}✗${N} Desktop: Installation failed (reverted)"
  fi
fi

# Add PATH advice if anything succeeded
ANY_SUCCESS=0
[[ "$CLI_INSTALL_STATUS" == "success" ]] && ANY_SUCCESS=1
[[ "$IDE_INSTALL_STATUS" == "success" ]] && ANY_SUCCESS=1
[[ "$DESKTOP_INSTALL_STATUS" == "success" ]] && ANY_SUCCESS=1

if [[ $ANY_SUCCESS -eq 1 ]]; then
  case ":$PATH:" in
    *":$INSTALL_BIN_DIR:"*) ;;
    *)
      printf '\n  %b\n' "${R}!${N} ${B}${INSTALL_BIN_DIR}${N} is not in your PATH."
      printf '  %b\n' "${D}Add to ~/.bashrc:${N}  export PATH=\"${INSTALL_BIN_DIR}:\$PATH\""
      ;;
  esac
fi
echo ""
