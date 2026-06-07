#!/usr/bin/env bash
# Antigravity - Combined Termux Installer & Builder
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
  printf "\033[31m[ERR]\033[0m This install script is exclusively designed for native Termux or Termux PRoot distro environments.\n" >&2
  exit 1
fi

if [[ "$ENV_TYPE" == "termux" ]]; then
  TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
  INSTALL_BIN_DIR="${TERMUX_PREFIX}/bin"
else
  INSTALL_BIN_DIR="$HOME/.local/bin"
fi
INSTALL_SUCCESS=0

# ── Cleanup Hook ──────────────────────────────────────────────────────────────
cleanup() {
  printf "\033[?25h" # Restore cursor if cancelled
  [[ -n "${BUILD_DIR:-}" && -d "$BUILD_DIR" ]] && rm -rf "$BUILD_DIR"
  if [[ "${INSTALL_SUCCESS:-0}" -ne 1 ]]; then
    # FAILURE CLEANUP: Restore backup if exists, otherwise delete failed installation files
    if [[ -n "${AGY_BAK:-}" && -f "$AGY_BAK" ]]; then
      mv -f "$AGY_BAK" "$INSTALL_BIN_DIR/agy" || true
    else
      rm -f "$INSTALL_BIN_DIR/agy" || true
    fi

    if [[ -n "${AGY_VA39_BAK:-}" && -f "$AGY_VA39_BAK" ]]; then
      mv -f "$AGY_VA39_BAK" "$INSTALL_BIN_DIR/agy.va39" || true
    else
      rm -f "$INSTALL_BIN_DIR/agy.va39" || true
    fi
  else
    # SUCCESS: Keep installed files, clean up backup files permanently
    [[ -n "${AGY_BAK:-}" && -f "$AGY_BAK" ]] && rm -f "$AGY_BAK" || true
    [[ -n "${AGY_VA39_BAK:-}" && -f "$AGY_VA39_BAK" ]] && rm -f "$AGY_VA39_BAK" || true
  fi
}

handle_cancel() {
  cleanup
  die
}

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'
  DIM=$'\e[2m'
  GREEN=$'\e[32m'
  RED=$'\e[31m'
  CYAN=$'\e[36m'
  RESET=$'\e[0m'
else
  BOLD="" DIM="" GREEN="" RED="" CYAN="" RESET=""
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { printf '%b\n' " ${CYAN}[..]${RESET} ${DIM}$*${RESET}"; }
ok()      { printf '%b\n' " ${GREEN}[OK]${RESET} $*"; }
die() {
  {
    printf "\033[?25h" # Restore cursor
    if [[ $# -gt 0 ]]; then
      printf '\n%b\n' " ${RED}[ERR]${RESET} $*"
    else
      printf '\n%b\n' " ${RED}[ERR]${RESET} Installation failed or was cancelled."
    fi
    printf "For manual patching and installation:\n"
    printf "%bhttps://gist.github.com/Brajesh2022/e42160d29b55417db6c18c52dd1d6d37%b\n\n" "$CYAN" "$RESET"
  } >&2
  exit 1
}
divider() { printf '%b\n' "${DIM}────────────────────────────────────────${RESET}"; }

show_help() {
  cat <<EOF
Usage: \$(basename "\$0") [path_to_upstream_antigravity]

Compiles the native C bootstrapper, applies VA39 memory patches to the
provided Google binary, and installs them locally.

Arguments:
  [path_to_upstream_antigravity]   Optional. Path to the original raw arm64 binary from Google.
                                   If omitted, checks for './antigravity' or './agy' locally,
                                   or downloads it from Google's official source automatically.

Requirements:
  - clang or gcc
  - python3
EOF
}

# Check for help flag
if [[ "${1:-}" = "-h" || "${1:-}" = "--help" ]]; then
  show_help
  exit 0
fi

# ── Create Temporary Build Directory ──────────────────────────────────────────
BUILD_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'agy-build')
trap cleanup EXIT
trap handle_cancel INT TERM

# ── Show Header / Logo ────────────────────────────────────────────────────────
echo ""
TMP_LOGO="${BUILD_DIR}/logo.ans"
base64 -d << 'EOF' > "$TMP_LOGO"
G1s/MjVsG1swbSAgICAgICAgICAgICAgICAgICAgICAgIBtbMG0KICAgICAgICAgICAgICAgICAg
ICAgICAgG1swbQogICAgICAgICAbWzM4OzI7MTU0OzE1OTs1M23iloQbWzM4OzI7MTg5OzE3MTs2
NTs0ODsyOzE4NjsxNDM7MzZt4paEG1szODsyOzE5ODsxNDY7Njg7NDg7MjsyMjg7MTQzOzQ2beKW
hBtbMzg7MjsyMTI7MTIwOzcwOzQ4OzI7MjM0OzExMzs1M23iloQbWzM4OzI7MjI3Ozk3OzY4OzQ4
OzI7MTk4Ozc1OzQ4beKWhBtbMG0bWzM4OzI7MTk5OzY3OzU0beKWhBtbMG0gICAgICAgICAbWzBt
CiAgICAgICAgG1szODsyOzEwNjsxNjE7ODdt4paEG1szODsyOzExMzsxNzg7MTE2OzQ4OzI7MTQ4
OzE4NTs4OG3iloQbWzM4OzI7MTA5OzE2NDsxMzA7NDg7MjsxNDg7MTY4Ozk1beKWhBtbMzg7Mjsx
MTg7MTQ3OzEzNzs0ODsyOzE1OTsxNDg7OTlt4paEG1szODsyOzE0MDsxMzA7MTM1OzQ4OzI7MTgw
OzEyNjs5N23iloQbWzM4OzI7MTY4OzExMjsxMjI7NDg7MjsyMDI7MTA1Ozg5beKWhBtbMzg7Mjsx
OTY7OTY7MTA2OzQ4OzI7MjIzOzg3Ozc5beKWhBtbMG0bWzM4OzI7MTY2OzY4Ozc0beKWhBtbMG0g
ICAgICAgIBtbMG0KICAgICAgIBtbMzg7Mjs0NTs5MTs2OW3iloQbWzM4OzI7Nzc7MTcxOzE1NTs0
ODsyOzEwMDsxODI7MTI2beKWhBtbMzg7Mjs2NTsxNTk7MTgwOzQ4OzI7ODQ7MTY5OzE0OG3iloQb
WzM4OzI7NjA7MTQ5OzE5OTs0ODsyOzc4OzE1NzsxNjZt4paEG1szODsyOzYzOzE0MTsyMTA7NDg7
Mjs4NDsxNDQ7MTc3beKWhBtbMzg7Mjs3NTsxMzM7MjEwOzQ4OzI7MTAyOzEzMjsxNzVt4paEG1sz
ODsyOzk4OzEyNjsyMDA7NDg7MjsxMzA7MTE5OzE2M23iloQbWzM4OzI7MTI3OzExNjsxODI7NDg7
MjsxNjI7MTA2OzE0M23iloQbWzM4OzI7MTU3OzEwNzsxNTk7NDg7MjsxOTE7OTQ7MTIxbeKWhBtb
MG0gICAgICAgIBtbMG0KICAgICAgIBtbMzg7Mjs1ODsxNTg7MTg0OzQ4OzI7NTc7MTM0OzEyOG3i
loQbWzM4OzI7NTM7MTUwOzIxMDs0ODsyOzYyOzE2MDsxODRt4paEG1szODsyOzUwOzE0MjsyMjg7
NDg7Mjs1NDsxNDk7MjA3beKWhBtbMzg7Mjs0OTsxMzc7MjQwOzQ4OzI7NTE7MTYyOzIyNG3iloQb
WzM4OzI7NDk7MTM1OzI0Njs0ODsyOzUzOzEzODsyMzNt4paEG1szODsyOzUzOzEzNDsyNDc7NDg7
Mjs2MDsxMzQ7MjM0beKWhBtbMzg7Mjs2MjsxMzM7MjQ0OzQ4OzI7NzU7MTMwOzIyOG3iloQbWzM4
OzI7NzY7MTMxOzIzNzs0ODsyOzk3OzEyNjsyMTVt4paEG1szODsyOzk3OzEyOTsyMjU7NDg7Mjsx
MjQ7MTIwOzE5N23iloQbWzM4OzI7MTE4OzEyNDsyMDc7NDg7MjsxMTE7ODY7MTM2beKWhBtbMG0g
ICAgICAgG1swbQogICAgICAbWzM4OzI7Mjk7OTY7MTM5beKWhBtbMzg7Mjs0NzsxNDI7MjI4OzQ4
OzI7NTE7MTQ5OzIwOW3iloQbWzM4OzI7NDg7MTM3OzI0Mjs0ODsyOzUwOzE0MjsyMjlt4paEG1sz
ODsyOzM1Ozk3OzE...
EOF

COLS=$(tput cols </dev/tty 2>/dev/null || echo 60)
awk -v cols="$COLS" -v arch="$(uname -m)" -v bold="${BOLD}${CYAN}" -v dim="${DIM}" -v grn="${GREEN}" -v rst="${RESET}" '
{
  sub(/\r$/, "");
  if (cols >= 48) {
    printf "%s", $0;
    if (NR == 3)      printf "\033[28G %sAntigravity Termux%s", bold, rst;
    else if (NR == 4) printf "\033[28G %sStandalone Installer%s", dim, rst;
    else if (NR == 5) printf "\033[28G %s────────────────────%s", dim, rst;
    else if (NR == 6) printf "\033[28G %sTarget:%s  %s", dim, rst, (cols >= 54 ? "Termux/PRoot" : "Termux");
    else if (NR == 7) printf "\033[28G %sArch:%s    %s", dim, rst, arch;
    else if (NR == 8) printf "\033[28G %sStatus:%s  %sOffline Build%s", dim, rst, grn, rst;
    printf "\n";
  } else {
    print $0;
  }
}
END {
  if (cols < 48) {
    printf "\n";
    printf "  %sAntigravity Termux%s\n", bold, rst;
    printf "  %sStandalone Installer%s\n", dim, rst;
    printf "  %s────────────────────%s\n", dim, rst;
    printf "  %sTarget:%s  Termux/PRoot\n", dim, rst;
    printf "  %sArch:%s    %s\n", dim, rst, arch;
    printf "  %sStatus:%s  %sOffline Build%s\n", dim, rst, grn, rst;
  }
}' "$TMP_LOGO"
echo ""
divider

# ── Architecture Check ────────────────────────────────────────────────────────
[[ "$(uname -m)" == "aarch64" ]] || die "Architecture must be aarch64"

# ── Find Google Binary ────────────────────────────────────────────────────────
UPSTREAM_BIN=""
if [[ $# -gt 0 ]]; then
  UPSTREAM_BIN="$1"
fi

if [[ -z "$UPSTREAM_BIN" ]]; then
  if [[ -f "./antigravity" ]]; then
    UPSTREAM_BIN="./antigravity"
  elif [[ -f "./agy" ]]; then
    UPSTREAM_BIN="./agy"
  fi
fi

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

# ── Package Manager Detection (PRoot) ─────────────────────────────────────────
detect_proot_pm() {
  if command -v apt-get &>/dev/null; then
    echo "apt"
  elif command -v apk &>/dev/null; then
    echo "apk"
  elif command -v pacman &>/dev/null; then
    echo "pacman"
  elif command -v dnf &>/dev/null; then
    echo "dnf"
  elif command -v yum &>/dev/null; then
    echo "yum"
  else
    echo "unknown"
  fi
}

# ── Prerequisite Setup ────────────────────────────────────────────────────────
check_glibc() {
  if [[ "$ENV_TYPE" == "termux" ]]; then
    [[ -d "${TERMUX_PREFIX}/glibc" ]]
  else
    ldd --version 2>&1 | grep -qi -E '(glibc|gnu libc)'
  fi
}

# Unified check that returns 0 if all conditions are satisfied, 1 otherwise
check_all_dependencies() {
  MISSING_TOOLS=()
  MISSING_COMPILER=0
  MISSING_GLIBC=0

  local tools=(python3)
  if [[ -z "${UPSTREAM_BIN:-}" ]]; then
    tools+=(curl jq tar)
  fi

  for cmd in "${tools[@]:-}"; do
    if ! command -v "$cmd" &>/dev/null; then
      MISSING_TOOLS+=("$cmd")
    fi
  done

  if ! detect_compiler &>/dev/null; then
    MISSING_COMPILER=1
  fi

  if ! check_glibc; then
    MISSING_GLIBC=1
  fi

  if [[ ${#MISSING_TOOLS[@]} -eq 0 && $MISSING_COMPILER -eq 0 && $MISSING_GLIBC -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}

resolve_dependencies() {
  while true; do
    # Run the validation check
    if check_all_dependencies; then
      ok "All prerequisites are satisfied."
      return 0
    fi

    # Display what needs resolving
    printf "\n  %b[!]%b Missing required prerequisites:\n" "$RED" "$RESET"
    if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
      printf "    - Missing command(s): %b%s%b\n" "$BOLD" "${MISSING_TOOLS[*]:-}" "$RESET"
    fi
    if [[ $MISSING_COMPILER -eq 1 ]]; then
      printf "    - Missing compiler: %bclang%b or %bgcc%b\n" "$BOLD" "$RESET" "$BOLD" "$RESET"
    fi
    if [[ $MISSING_GLIBC -eq 1 ]]; then
      printf "    - Missing C Library: %bglibc%b\n" "$BOLD" "$RESET"
    fi
    divider

    # ── Termux Core Installation Path ──
    if [[ "$ENV_TYPE" == "termux" ]]; then
      command -v pkg >/dev/null 2>&1 || die "pkg is required but not found to install missing build tools"
      
      local to_install=()
      for tool in "${MISSING_TOOLS[@]:-}"; do
        if [[ "$tool" == "python3" ]]; then
          to_install+=("python")
        else
          to_install+=("$tool")
        fi
      done
      if [[ $MISSING_COMPILER -eq 1 ]]; then
        to_install+=("clang")
      fi
      
      local glibc_repo_needed=0
      if [[ $MISSING_GLIBC -eq 1 ]]; then
        glibc_repo_needed=1
        to_install+=("glibc")
      fi

      printf "  Would you like to install the missing prerequisites (%s) now via pkg? [Y/n]: " "${to_install[*]:-}"
      read -r ans < /dev/tty || ans="y"
      ans=$(echo "$ans" | tr '[:upper:]' '[:lower:]')
      
      if [[ "$ans" =~ ^[Yy]$ || -z "$ans" ]]; then
        if [[ $glibc_repo_needed -eq 1 ]]; then
          info "Setting up glibc-repo..."
          pkg install -y glibc-repo || true
        fi
        info "Installing packages: ${to_install[*]:-}..."
        if pkg install -y "${to_install[@]:-}"; then
          ok "Termux package installer run completed. Verifying dependencies..."
        else
          info "Warning: Package installer reported errors. Re-running checklist..."
        fi
      else
        die "Cannot continue. Required prerequisites are missing: ${to_install[*]:-}."
      fi

    # ── PRoot Core Installation Path ──
    else
      local pm
      pm=$(detect_proot_pm)
      
      local pm_install_cmd=""
      local install_list=()
      
      # Build precise target install syntax based on localized distribution package manager
      if [[ "$pm" == "apt" ]]; then
        for tool in "${MISSING_TOOLS[@]:-}"; do
          install_list+=("$tool")
        done
        [[ $MISSING_COMPILER -eq 1 ]] && install_list+=("build-essential")
        [[ $MISSING_GLIBC -eq 1 ]] && install_list+=("libc6")
        pm_install_cmd="apt-get update && apt-get install -y ${install_list[*]:-}"
      elif [[ "$pm" == "apk" ]]; then
        for tool in "${MISSING_TOOLS[@]:-}"; do
          if [[ "$tool" == "python3" ]]; then
            install_list+=("python3")
          else
            install_list+=("$tool")
          fi
        done
        [[ $MISSING_COMPILER -eq 1 ]] && install_list+=("build-base")
        [[ $MISSING_GLIBC -eq 1 ]] && install_list+=("gcompat")
        pm_install_cmd="apk update && apk add ${install_list[*]:-}"
      elif [[ "$pm" == "pacman" ]]; then
        for tool in "${MISSING_TOOLS[@]:-}"; do
          install_list+=("$tool")
        done
        [[ $MISSING_COMPILER -eq 1 ]] && install_list+=("base-devel")
        pm_install_cmd="pacman -Sy --noconfirm ${install_list[*]:-}"
      elif [[ "$pm" == "dnf" || "$pm" == "yum" ]]; then
        for tool in "${MISSING_TOOLS[@]:-}"; do
          install_list+=("$tool")
        done
        [[ $MISSING_COMPILER -eq 1 ]] && install_list+=("gcc" "gcc-c++" "make")
        pm_install_cmd="$pm install -y ${install_list[*]:-}"
      fi

      printf "  We detected a PRoot distro using package manager: %b%s%b\n" "$BOLD" "$pm" "$RESET"
      printf "  How would you like to handle the missing dependencies?\n"
      printf "    [1] Enter sudo password to execute automatic installation\n"
      printf "    [2] Install them manually and then confirm\n"
      printf "  Select an option [1-2] (default 1): "
      read -r choice < /dev/tty || choice="1"
      [[ -z "$choice" ]] && choice="1"

      if [[ "$choice" == "1" ]]; then
        if [[ -n "$pm_install_cmd" ]]; then
          info "Invoking sudo to run: ${pm_install_cmd}"
          if sudo bash -c "$pm_install_cmd"; then
            ok "Automatic installation finished. Checking verification..."
          else
            info "Sudo helper run returned an error code or was cancelled."
          fi
        else
          printf "  %b[!]%b No automatic installer package config is available for: %s\n" "$RED" "$RESET" "$pm"
          printf "  Proceeding to manual confirmation path...\n"
          choice="2"
        fi
      fi

      if [[ "$choice" == "2" ]]; then
        printf "\n  Please run your distribution's installer manually to install these prerequisites:\n"
        printf "  - Core utilities: %s\n" "${MISSING_TOOLS[*]:-}"
        [[ $MISSING_COMPILER -eq 1 ]] && printf "  - C Compiler: clang, gcc, or equivalent development toolkit\n"
        [[ $MISSING_GLIBC -eq 1 ]] && printf "  - Library: GNU glibc framework (or gcompat on Alpine)\n"
        
        printf "\n  Type %by%b in the prompt and hit enter once done to re-verify: " "$BOLD" "$RESET"
        read -r confirm_ans < /dev/tty || confirm_ans=""
        confirm_ans=$(echo "$confirm_ans" | tr '[:upper:]' '[:lower:]')
        if [[ "$confirm_ans" != "y" ]]; then
          die "Installation aborted by the user."
        fi
      fi
    fi
  done
}

# Resolve all structural dependencies first
resolve_dependencies

ok "Environment check passed: ${ENV_TYPE} (aarch64)"

# ── Resolve or Download Google Binary ─────────────────────────────────────────
if [[ -n "$UPSTREAM_BIN" ]]; then
  UPSTREAM_BIN=$(readlink -f "$UPSTREAM_BIN" 2>/dev/null || realpath "$UPSTREAM_BIN" 2>/dev/null || echo "$UPSTREAM_BIN")
  if [[ ! -r "$UPSTREAM_BIN" ]]; then
    die "Specified Google binary is not readable: $UPSTREAM_BIN"
  fi
  info "Using local Google binary: $UPSTREAM_BIN"
else
  # Auto-download from Google
  info "No local binary specified. Querying latest official version from Google..."
  MANIFEST_URL="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json"
  manifest=$(curl -fsSL "$MANIFEST_URL" || echo "")
  if [[ -z "$manifest" ]]; then
    die "Failed to query manifest from $MANIFEST_URL"
  fi

  latest_version=$(echo "$manifest" | jq -r .version)
  download_url=$(echo "$manifest" | jq -r .url)

  info "Latest official version found: v$latest_version"
  info "Downloading original binary from Google..."
  if ! curl -fsSL -o "${BUILD_DIR}/upstream.tar.gz" "$download_url"; then
    die "Failed to download upstream binary from $download_url"
  fi

  info "Extracting original binary..."
  if ! tar -xzf "${BUILD_DIR}/upstream.tar.gz" -C "${BUILD_DIR}/"; then
    die "Failed to extract original binary."
  fi

  if [[ -f "${BUILD_DIR}/antigravity" ]]; then
    UPSTREAM_BIN="${BUILD_DIR}/antigravity"
  elif [[ -f "${BUILD_DIR}/agy" ]]; then
    UPSTREAM_BIN="${BUILD_DIR}/agy"
  else
    die "Could not find extracted binary in Google package."
  fi
fi

# ── Compiler Setup ────────────────────────────────────────────────────────────
local_cc=$(detect_compiler)
info "Selected compiler: $local_cc"

# ── Write Source Files ────────────────────────────────────────────────────────
info "Writing embedded source code..."

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

cat << 'EOF' > "${BUILD_DIR}/agy_helper.c"
#include "mmap_va39_fix_bytes.h"
#include <ctype.h>
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef AGY_TERMUX_VERSION
#define AGY_TERMUX_VERSION "1.0.2"
#endif


// Returns the path of the unpacked .so on success, NULL on failure
const char *unpack_mmap_fixer(void) {
    static char unpacked_path[PATH_MAX];

    // Resolve temp directory priority: $TMPDIR -> /tmp
    const char *tmp = getenv("TMPDIR");
    if (!tmp || tmp[0] == '\0') {
        tmp = "/tmp";
    }

    int written = snprintf(unpacked_path, sizeof(unpacked_path), "%s/libmmap_va39_fix.so", tmp);
    if (written < 0 || written >= (int)sizeof(unpacked_path)) {
        return NULL;
    }

    // Check if the file already exists and matches the expected size to avoid redundant writes
    struct stat st;
    if (stat(unpacked_path, &st) == 0 && st.st_size == (off_t)mmap_va39_fix_so_len) {
        return unpacked_path;
    }

    // Unpack the bytes
    FILE *fp = fopen(unpacked_path, "wb");
    if (!fp) {
        return NULL;
    }

    size_t written_bytes = fwrite(mmap_va39_fix_so, 1, mmap_va39_fix_so_len, fp);

    if (fclose(fp) != 0 || written_bytes != mmap_va39_fix_so_len) {
        unlink(unpacked_path);
        return NULL;
    }

    // Ensure it is executable
    if (chmod(unpacked_path, 0755) != 0) {
        return NULL;
    }

    return unpacked_path;
}

int main(int argc, char **argv) {
    // 1. Consolidate variables at top to avoid shadowing (-Wshadow)
    char exec_path[PATH_MAX];
    char lib_path[PATH_MAX * 3];
    char patched_bin[PATH_MAX];
    const char *loader = "/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1";
    const char *dir = NULL;
    const char *fixer_path = NULL;
    char **new_argv = NULL;
    int is_termux = 0;
    int arg_idx = 0;
    int written = 0;
    ssize_t read_len = 0;

    // Detect if running in native Termux
    is_termux = (access("/data/data/com.termux/files/usr/bin", F_OK) == 0);

    // 2. Clear conflicting Android Bionic preloads and search paths
    if (is_termux) {
        unsetenv("LD_PRELOAD");
    }
    unsetenv("LD_LIBRARY_PATH");

    // 3. Set dynamic Go resolver and SSL configurations
    setenv("GODEBUG", "netdns=cgo", 1);
    if (is_termux) {
        setenv("SSL_CERT_FILE", "/data/data/com.termux/files/usr/etc/tls/cert.pem", 1);
    } else if (access("/etc/ssl/certs/ca-certificates.crt", F_OK) == 0) {
        setenv("SSL_CERT_FILE", "/etc/ssl/certs/ca-certificates.crt", 1);
    }

    // 4. Resolve executable directory
    read_len = readlink("/proc/self/exe", exec_path, sizeof(exec_path) - 1);
    if (read_len == -1) {
        return 1;
    }
    exec_path[read_len] = '\0';
    dir = dirname(exec_path);


    // 6. Handle interposer unpacking in non-Termux (chroot) environments
    if (!is_termux) {
        fixer_path = unpack_mmap_fixer();
        if (!fixer_path) {
            (void)fprintf(stderr,
                          "[ERR] Failed to extract PRoot compatibility layer. Please check /tmp "
                          "permissions.\n");
            return 1;
        }
    }

    // 7. Resolve dynamic loader path
    if (access(loader, F_OK) != 0) {
        loader = "/lib/ld-linux-aarch64.so.1";
    }

    // 8. Construct relocatable library search path
    if (is_termux) {
        written = snprintf(lib_path, sizeof(lib_path),
                           "%s/../lib:/data/data/com.termux/files/usr/glibc/lib", dir);
    } else {
        written = snprintf(lib_path, sizeof(lib_path),
                           "%s/../lib:/lib/aarch64-linux-gnu:/usr/lib/aarch64-linux-gnu:/lib64:/"
                           "usr/lib64:/lib:/usr/lib",
                           dir);
    }
    if (written < 0 || written >= (int)sizeof(lib_path)) {
        return 1;
    }

    // Construct path to the patched binary
    written = snprintf(patched_bin, sizeof(patched_bin), "%s/agy.va39", dir);
    if (written < 0 || written >= (int)sizeof(patched_bin)) {
        return 1;
    }

    // 9. Construct new argument array
    // We allocate enough space for: loader + "--preload" + fixer_path + "--library-path" + lib_path
    // + patched_bin + user args + NULL
    int new_argc = argc + 8;
    new_argv = malloc((size_t)new_argc * sizeof(*new_argv));
    if (!new_argv) {
        return 1;
    }

    arg_idx = 0;
    new_argv[arg_idx++] = (char *)loader;

    // Inject the interposer dynamic library as a preload if unpacked successfully
    if (fixer_path) {
        new_argv[arg_idx++] = "--preload";
        new_argv[arg_idx++] = (char *)fixer_path;
    }

    new_argv[arg_idx++] = "--library-path";
    new_argv[arg_idx++] = lib_path;
    new_argv[arg_idx++] = patched_bin;

    for (int i = 1; i < argc; i++) {
        new_argv[arg_idx++] = argv[i];
    }
    new_argv[arg_idx] = NULL;

    // 10. Execute the glibc dynamic loader
    if (execv(loader, new_argv) == -1) {
        perror("[agy-termux] execv failed");
        free(new_argv);
        return 1;
    }
}

EOF

# ── Compile Interposer & Generate Hex Header ──────────────────────────────────
info "Compiling mmap compatibility layer..."
if ! "$local_cc" -O2 -fPIC -shared -o "${BUILD_DIR}/libmmap_va39_fix.so" "${BUILD_DIR}/mmap_va39_fix.c" -ldl; then
  die "Failed to compile compatibility interposer."
fi

info "Generating byte header..."
python3 -c "
import pathlib
so_path = pathlib.Path('${BUILD_DIR}/libmmap_va39_fix.so')
if not so_path.exists():
    raise FileNotFoundError('libmmap_va39_fix.so not found')
so_data = so_path.read_bytes()
hex_bytes = ', '.join(f'0x{b:02x}' for b in so_data)
pathlib.Path('${BUILD_DIR}/mmap_va39_fix_bytes.h').write_text(
    '// clang-format off\n'
    '#include <stddef.h>\n'
    f'static const unsigned char mmap_va39_fix_so[] = {{ {hex_bytes} }};\n'
    f'static const size_t mmap_va39_fix_so_len = {len(so_data)};\n'
    '// clang-format on\n'
)
"

# ── Compile Bootstrapper ──────────────────────────────────────────────────────
info "Compiling bootstrapper..."
if ! "$local_cc" -O2 -I"${BUILD_DIR}" -o "${BUILD_DIR}/agy" "${BUILD_DIR}/agy_helper.c"; then
  die "Failed to compile native C bootstrapper."
fi
chmod +x "${BUILD_DIR}/agy"

# ── Patch Google Binary ───────────────────────────────────────────────────────
info "Applying VA39 memory patches to upstream binary..."
patch_output=$(python3 - "$UPSTREAM_BIN" "${BUILD_DIR}/agy.va39" <<'PY'
import sys, shutil, struct, pathlib
src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
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
    if get(off) == 0xAA1F03E5 and get(off + 4) == 0xAA1F03E6 and get(off + 8) == 0xD28036E0 and (get(off + 12) & 0xFC000000) == 0x94000000:
        put(off + 8, 0xD2800600); faccessat2_count += 1
dst.write_bytes(data)
dst.chmod(0o755)
print(f"Patched parameters: ubfx={ubfx_count}, lsl={lsl_count}, mask={mask_count}, mmap={mmap_count}, faccessat2={faccessat2_count}")
PY
)
info "$patch_output"

# ── Installation ──────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_BIN_DIR"

AGY_BAK=""
AGY_VA39_BAK=""
if [[ -f "$INSTALL_BIN_DIR/agy" ]]; then
  AGY_BAK="$INSTALL_BIN_DIR/agy.bak.$$"
  mv -f "$INSTALL_BIN_DIR/agy" "$AGY_BAK" || die "Failed to back up existing agy binary from $INSTALL_BIN_DIR"
fi
if [[ -f "$INSTALL_BIN_DIR/agy.va39" ]]; then
  AGY_VA39_BAK="$INSTALL_BIN_DIR/agy.va39.bak.$$"
  mv -f "$INSTALL_BIN_DIR/agy.va39" "$AGY_VA39_BAK" || die "Failed to back up existing agy.va39 binary from $INSTALL_BIN_DIR"
fi

info "Installing binaries to $INSTALL_BIN_DIR..."
install -m 0755 "${BUILD_DIR}/agy" "$INSTALL_BIN_DIR/agy" || die "Failed to install agy binary to $INSTALL_BIN_DIR"
install -m 0755 "${BUILD_DIR}/agy.va39" "$INSTALL_BIN_DIR/agy.va39" || die "Failed to install agy.va39 binary to $INSTALL_BIN_DIR"

# ── Verification ──────────────────────────────────────────────────────────────
if [[ ! -f "$INSTALL_BIN_DIR/agy" || ! -f "$INSTALL_BIN_DIR/agy.va39" ]]; then
  rm -f "$INSTALL_BIN_DIR/agy" "$INSTALL_BIN_DIR/agy.va39"
  die "Verification failed: binaries not found in $INSTALL_BIN_DIR"
fi

ok "Verification completed."

# ── Done ──────────────────────────────────────────────────────────────────────
printf '\n%b\n' "${GREEN}${BOLD}Installation Complete.${RESET}"
divider
info "Installed binaries to: ${BOLD}$INSTALL_BIN_DIR${RESET}"

case ":$PATH:" in
  *":$INSTALL_BIN_DIR:"*) ;;
  *)
    cat >&2 <<EOF
${RED}${BOLD}Warning:${RESET} ${BOLD}$INSTALL_BIN_DIR${RESET} is not in PATH for this shell.
Please add this to your shell profile (e.g., ~/.bashrc or ~/.zshrc):

  export PATH="$INSTALL_BIN_DIR:\$PATH"

EOF
    ;;
esac

# ── Launch ────────────────────────────────────────────────────────────────────
info "Launching Antigravity CLI..."

export PATH="$INSTALL_BIN_DIR:$PATH"
INSTALL_SUCCESS=1
cleanup
exec "$INSTALL_BIN_DIR/agy"