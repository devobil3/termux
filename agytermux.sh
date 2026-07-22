#!/usr/bin/env bash
# Antigravity - Native Termux Installer
# Installs Antigravity CLI natively in Termux.
set -Eeuo pipefail
MAIN_PID="$$"

# ── Environment Detection ─────────────────────────────────────────────────────
if [[ -z "${TERMUX_VERSION:-}" ]] || [[ ":$PATH:" != *":/data/data/com.termux/files/usr/bin:"* ]]; then
  printf "\033[31m✖\033[0m This script only supports native Termux.\n" >&2
  exit 1
fi

# ── Installation Paths ────────────────────────────────────────────────────────
LOCAL_BIN="$HOME/.local/bin"
TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLOBAL_BIN="${TERMUX_PREFIX}/bin"

CLI_BIN_DIR="$LOCAL_BIN"

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  B=$'\e[1m'  D=$'\e[2m'  G=$'\e[32m'  R=$'\e[31m'  C=$'\e[36m'  Y=$'\e[33m'  W=$'\e[37m'  N=$'\e[0m'
else
  B=""  D=""  G=""  R=""  C=""  Y=""  W=""  N=""
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
info() { printf "%s⠶%s %s\n" "${D}" "${N}" "$*"; }
ok()   { printf "%s✔%s %s\n" "${G}" "${N}" "$*"; }
warn() { printf "%s⚠%s %s\n" "${Y}" "${N}" "$*"; }
err()  { printf "%s✖%s %s\n" "${R}" "${N}" "$*" >&2; }
die()  { printf "\033[?25h\n%s✖%s %s\n\n" "${R}" "${N}" "${1:-Installation failed or was cancelled.}" >&2; exit 1; }
sep()  { printf "%s─────────────────────────%s\n" "${D}" "${N}"; }

safe_read() {
  local _sr_status _sr_winch
  _sr_winch=$((128 + $(kill -l WINCH 2>/dev/null || echo 28)))
  while true; do
    read "$@"
    _sr_status=$?
    [[ $_sr_status -ne $_sr_winch ]] && return $_sr_status
  done
}

# ── Optimization Helpers ──────────────────────────────────────────────────────
DOWNLOAD_CACHE_DIR="$HOME/.cache/antigravity-installer"
CURRENT_DOWNLOAD_PID=""

get_terminal_columns() {
  local cols
  cols=$(stty size 2>/dev/null | awk '{print $2}')
  [[ -z "$cols" ]] && cols=$(tput cols 2>/dev/null)
  [[ -z "$cols" ]] && cols=$(tput cols </dev/tty 2>/dev/null)
  [[ -z "$cols" ]] && cols="${COLUMNS:-}"
  if [[ -z "$cols" || ! "$cols" =~ ^[0-9]+$ || "$cols" -le 0 ]]; then
    cols=80
  fi
  echo "$cols"
}

format_size() {
  local bytes="$1"
  if (( bytes >= 1073741824 )); then
    printf "%.1fG" "$(awk -v b="$bytes" 'BEGIN {print b / 1073741824}')"
  elif (( bytes >= 1048576 )); then
    printf "%.1fM" "$(awk -v b="$bytes" 'BEGIN {print b / 1048576}')"
  elif (( bytes >= 1024 )); then
    printf "%.1fk" "$(awk -v b="$bytes" 'BEGIN {print b / 1024}')"
  else
    printf "%dB" "$bytes"
  fi
}

format_speed() {
  local bytes_per_sec="$1"
  awk -v b="$bytes_per_sec" 'BEGIN {
    if (b >= 1073741824) {
      v = b / 1073741824; u = "GB/s"
    } else if (b >= 1048576) {
      v = b / 1048576; u = "MB/s"
    } else if (b >= 1024) {
      v = b / 1024; u = "kB/s"
    } else {
      v = b; u = "B/s"
    }
    
    if (v >= 99.95) {
      printf "%.0f %s", v, u
    } else if (v >= 9.995) {
      printf "%.1f %s", v, u
    } else {
      printf "%.2f %s", v, u
    }
  }'
}

format_time() {
  local sec="$1"
  if (( sec < 0 )); then
    echo "--"
  elif (( sec >= 3600 )); then
    printf "%dh%dm%ds" $((sec / 3600)) $(( (sec % 3600) / 60 )) $((sec % 60))
  elif (( sec >= 60 )); then
    printf "%dm%ds" $((sec / 60)) $((sec % 60))
  else
    printf "%ds" "$sec"
  fi
}

is_archive_valid() {
  local archive="$1"
  [[ -f "$archive" ]] || return 1
  if command -v pigz &>/dev/null; then
    tar -I pigz -tf "$archive" &>/dev/null
  else
    tar -tf "$archive" &>/dev/null
  fi
}

is_gzip_magic_valid() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  local magic
  magic=$(od -An -tx1 -N2 "$file" 2>/dev/null | tr -d '[:space:]')
  [[ "$magic" == "1f8b" ]]
}

download_file_attempt() {
  local url="$1"
  local dest="$2"
  
  mkdir -p "$(dirname "$dest")"
  
  local pid_file="${DOWNLOAD_CACHE_DIR}/download.pid"
  if [[ -f "$pid_file" ]]; then
    local old_pid
    old_pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      local proc_name=""
      proc_name=$(cat "/proc/${old_pid}/comm" 2>/dev/null || cat "/proc/${old_pid}/status" 2>/dev/null | awk '/^Name:/ {print $2}' 2>/dev/null || echo "")
      if [[ "$proc_name" == *"wget"* ]]; then
        kill -9 "$old_pid" 2>/dev/null || true
      fi
    fi
    rm -f "$pid_file"
  fi

  local final_headers
  final_headers=$(wget --spider --server-response --tries=3 --timeout=5 "$url" 2>&1 || true)
  
  local status_code
  status_code=$(echo "$final_headers" | grep -i 'HTTP/' | tail -n1 | awk '{print $2}')
  
  local total_size
  total_size=$(echo "$final_headers" | awk '/[Cc]ontent-[Ll]ength:/ {print $2}' | tail -n1 | tr -d '\r' | xargs || echo "")

  if [[ -n "$total_size" && ! "$total_size" =~ ^[0-9]+$ ]]; then
    total_size=""
  fi
  
  local start_size=0
  if [[ -f "$dest" ]]; then
    local check_size
    check_size=$(wc -c < "$dest" 2>/dev/null || echo 0)
    check_size=${check_size//[[:space:]]/}
    
    if [[ -n "$total_size" && "$total_size" -gt 0 && "$check_size" -eq "$total_size" ]]; then
      if [[ "$dest" == *.tar.gz ]]; then
        if is_archive_valid "$dest"; then
          info "File is already fully downloaded."
          return 0
        else
          warn "Local file is corrupted. Redownloading from scratch..."
          rm -f "$dest"
        fi
      else
        info "File is already fully downloaded."
        return 0
      fi
    elif [[ -z "$total_size" || "$total_size" -le 0 ]] && [[ "$dest" == *.tar.gz ]] && is_archive_valid "$dest"; then
      info "File is already fully downloaded."
      return 0
    elif [[ -n "$total_size" && "$total_size" -gt 0 && "$check_size" -gt "$total_size" ]]; then
      warn "Local file size ($check_size) exceeds remote size ($total_size). Redownloading from scratch..."
      rm -f "$dest"
    else
      if [[ "$dest" == *.tar.gz ]] && ! is_gzip_magic_valid "$dest"; then
        warn "Local partial file is invalid or corrupted. Redownloading from scratch..."
        rm -f "$dest"
      else
        start_size=$check_size
      fi
    fi
  fi

  wget -q -c --tries=3 --waitretry=2 -O "$dest" "$url" &>/dev/null &
  CURRENT_DOWNLOAD_PID=$!
  echo "$CURRENT_DOWNLOAD_PID" > "$pid_file"
  
  local start_time
  start_time=$(date +%s)
  local last_printed=-10
  
  local fill="█"
  local empty="░"
  
  print_progress() {
    local p_pct="$1"
    local p_cur_size="$2"
    local p_speed="$3"
    
    local cur_str
    cur_str=$(format_size "$p_cur_size")
    local total_str=""
    [[ -n "$total_size" && "$total_size" -gt 0 ]] && total_str=$(format_size "$total_size")
    
    local speed_str=""
    if (( p_speed > 0 )); then
      speed_str=$(format_speed "$p_speed")
    fi
    
    local eta_str=""
    if [[ -n "$total_size" && "$total_size" -gt 0 && p_speed -gt 0 ]]; then
      local remaining=$((total_size - p_cur_size))
      if (( remaining > 0 )); then
        local eta=$((remaining / p_speed))
        eta_str=$(format_time "$eta")
      else
        eta_str=$(format_time 0)
      fi
    fi
    
    if [[ -t 1 ]]; then
      local cols
      cols=$(get_terminal_columns)
      cols=$((cols - 2))
      
      local out_str=""
      if [[ -n "$total_str" ]]; then
        local prefix="Downloading:["
        
        local suff_details=""
        [[ -n "$speed_str" ]] && suff_details="${suff_details}${speed_str}"
        [[ -n "$eta_str" ]] && suff_details="${suff_details}${eta_str}"
        
        local suffix="]${p_pct}%(${cur_str}/${total_str})${suff_details}"
        
        local fixed_len=$((${#prefix} + ${#suffix}))
        local bar_width=$((cols - fixed_len))
        
        if (( bar_width >= 10 )); then
          local num_fill=$(( (p_pct * bar_width) / 100 ))
          (( num_fill > bar_width )) && num_fill=$bar_width
          local bar=""
          for ((i=0; i<num_fill; i++)); do bar="${bar}${fill}"; done
          for ((i=num_fill; i<bar_width; i++)); do bar="${bar}${empty}"; done
          out_str="${prefix}${bar}${suffix}"
        elif (( cols >= 45 )); then
          out_str="Downloading:${p_pct}%(${cur_str}/${total_str})${suff_details}"
        else
          out_str="Downloading:${p_pct}%"
        fi
      else
        local elapsed_str
        elapsed_str=$(format_time "$elapsed")
        local out_str=""
        if (( cols >= 60 )); then
          out_str="Downloading:${cur_str}|${speed_str}avg|elapsed${elapsed_str}"
        elif (( cols >= 45 )); then
          out_str="Downloading:${cur_str}|${speed_str}avg"
        else
          out_str="Downloading:${cur_str}"
        fi
      fi
      printf "\r%s\033[K" "$out_str"
    else
      if [[ -n "$total_str" ]]; then
        local suff_details=""
        [[ -n "$speed_str" ]] && suff_details="${suff_details}${speed_str}"
        [[ -n "$eta_str" ]] && suff_details="${suff_details}${eta_str}"
        info "Downloading:${p_pct}%(${cur_str}/${total_str})${suff_details}"
      else
        local suff_details=""
        [[ -n "$speed_str" ]] && suff_details="${suff_details}${speed_str}"
        info "Downloading:${cur_str}${suff_details}"
      fi
    fi
  }

  while kill -0 "$CURRENT_DOWNLOAD_PID" 2>/dev/null; do
    sleep 1
    local current_size=0
    if [[ -f "$dest" ]]; then
      current_size=$(wc -c < "$dest" 2>/dev/null || echo 0)
      current_size=${current_size//[[:space:]]/}
    fi
    
    if [[ -n "$total_size" && "$total_size" -gt 0 ]]; then
      if (( current_size > total_size )); then
        warn "Downloaded size ($current_size) exceeded total size ($total_size). The file is likely corrupted."
        kill -9 "$CURRENT_DOWNLOAD_PID" 2>/dev/null || true
        wait "$CURRENT_DOWNLOAD_PID" 2>/dev/null || true
        return 1
      fi
    fi
    
    local pct=0
    if [[ -n "$total_size" && "$total_size" -gt 0 ]]; then
      pct=$(( (current_size * 100) / total_size ))
    fi
    
    local downloaded=$((current_size - start_size))
    local current_time
    current_time=$(date +%s)
    local elapsed=$((current_time - start_time))
    
    local speed=0
    if (( elapsed > 0 )); then
      speed=$((downloaded / elapsed))
    fi
    
    local should_update=0
    if [[ -n "$total_size" && "$total_size" -gt 0 ]]; then
      if (( pct >= last_printed + 10 || (pct == 100 && last_printed < 100) )); then
        should_update=1
        last_printed=$(( (pct / 10) * 10 ))
      fi
    else
      if (( elapsed >= last_printed + 5 )); then
        should_update=1
        last_printed=$elapsed
      fi
    fi
    
    if [[ "$should_update" -eq 1 ]]; then
      print_progress "$pct" "$current_size" "$speed"
    fi
  done
  
  wait "$CURRENT_DOWNLOAD_PID"
  local wget_status=$?
  CURRENT_DOWNLOAD_PID=""
  rm -f "$pid_file"
  
  if [[ $wget_status -eq 0 && -f "$dest" ]]; then
    local current_size=0
    if [[ -f "$dest" ]]; then
      current_size=$(wc -c < "$dest" 2>/dev/null || echo 0)
      current_size=${current_size//[[:space:]]/}
    fi
    
    local current_time
    current_time=$(date +%s)
    local elapsed=$((current_time - start_time))
    
    local speed=0
    if (( elapsed > 0 )); then
      speed=$(( (current_size - start_size) / elapsed ))
    fi
    
    local size_str speed_str time_str
    size_str=$(format_size "$current_size")
    speed_str=$(format_speed "$speed")
    time_str=$(format_time "$elapsed")
    
    if [[ -t 1 ]]; then
      printf "\r\033[K"
    fi
    info "Downloaded:$size_str|$speed_str|$time_str"
  else
    if [[ -t 1 ]]; then
      printf "\n"
    fi
  fi
  
  if [[ $wget_status -ne 0 ]]; then
    return $wget_status
  fi
  
  return 0
}

download_file() {
  local url="$1"
  local dest="${2:-}"
  if [[ -z "$dest" ]]; then
    wget -q -O - "$url"
    return $?
  fi

  local max_attempts=3
  local attempt=1
  while (( attempt <= max_attempts )); do
    if download_file_attempt "$url" "$dest"; then
      if [[ "$dest" == *.tar.gz ]]; then
        if is_archive_valid "$dest"; then
          return 0
        else
          warn "Archive verification failed for $dest. Retrying download (attempt $((attempt + 1))/$max_attempts)..."
          rm -f "$dest"
        fi
      else
        return 0
      fi
    else
      warn "Download attempt $attempt failed. Retrying (attempt $((attempt + 1))/$max_attempts)..."
    fi
    attempt=$((attempt + 1))
  done
  err "Failed to download $url after $max_attempts attempts."
  return 1
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

# ── Temp dir & cleanup ────────────────────────────────────────────────────────
BUILD_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'agy-build')
ALL_SUCCESS=0

CLI_AGY_BAK=""
CLI_AGY_CREATED_FRESH=0
CLI_AGY_VA39_BAK=""
CLI_AGY_VA39_CREATED_FRESH=0

rollback_file() {
  local bak="$1"
  local target="$2"
  local fresh="$3"
  if [[ -n "$bak" && -f "$bak" ]]; then
    rm -f "$target"
    mv "$bak" "$target"
  elif [[ "$fresh" -eq 1 ]]; then
    rm -f "$target"
  fi
}

cleanup() {
  if [[ "${BASHPID:-$$}" -ne "${MAIN_PID:-$$}" ]]; then
    return 0
  fi
  printf "\033[?25h"
  
  local pid_file="${DOWNLOAD_CACHE_DIR}/download.pid"
  if [[ -f "$pid_file" ]]; then
    local act_pid
    act_pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ -n "$act_pid" ]]; then
      kill -9 "$act_pid" 2>/dev/null || true
    fi
    rm -f "$pid_file" 2>/dev/null || true
  fi

  [[ -n "${BUILD_DIR:-}" && -d "$BUILD_DIR" ]] && rm -rf "$BUILD_DIR"

  if [[ "${ALL_SUCCESS:-0}" -ne 1 ]]; then
    info "Installation failed or interrupted! Reverting changes..."
    rollback_file "$CLI_AGY_BAK" "$CLI_BIN_DIR/agy" "$CLI_AGY_CREATED_FRESH"
    rollback_file "$CLI_AGY_VA39_BAK" "$CLI_BIN_DIR/agy.va39" "$CLI_AGY_VA39_CREATED_FRESH"
  else
    rm -f "$CLI_AGY_BAK" "$CLI_AGY_VA39_BAK" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'die "Installation cancelled by user."' INT TERM

# ── Header ────────────────────────────────────────────────────────────────────
echo ""
printf "%s=== Antigravity Termux CLI Installer ===%s\n" "${B}${C}" "${N}"
sep

# ── Architecture Check ────────────────────────────────────────────────────────
[[ "$(uname -m)" == "aarch64" ]] || die "Architecture must be aarch64"

# ── Installation Location Selection ──────────────────────────────────────────
printf '\n%bChoose installation type:%b\n' "${B}" "${N}"
printf '[l] Local  ($HOME/.local/bin)\n'
printf '[g] Global (%s/bin)\n' "${TERMUX_PREFIX}"
printf '%bEnter choice [l/g] (default: l): ' "${C}❯${N}"

ans=""
safe_read -r ans < /dev/tty || ans="l"
if [[ "${ans,,}" == "g" ]]; then
  CLI_BIN_DIR="$GLOBAL_BIN"
else
  CLI_BIN_DIR="$LOCAL_BIN"
fi
printf '\n'
ok "Installation directory: ${B}${CLI_BIN_DIR}${N}"
sep

# ── Prerequisite Checks & Dependencies ────────────────────────────────────────
install_dependencies() {
  local deps=("python" "tar" "wget" "clang" "glibc-repo" "glibc")
  command -v pkg >/dev/null 2>&1 || die "pkg is required but not found to install dependencies"
  
  info "Installing dependencies: ${B}${deps[*]}${N}"
  if [[ " ${deps[*]} " == *" glibc-repo "* ]]; then
    pkg install -y glibc-repo &>/dev/null || true
  fi
  pkg install -y "${deps[@]}" &>/dev/null || die "Failed to install dependencies: ${deps[*]}"
}

install_dependencies

# ── Shared: VA39 Python Patcher ───────────────────────────────────────────────
cat << 'PYEOF' > "${BUILD_DIR}/va39_patch.py"
import sys, shutil, struct, pathlib

def patch_binary(src_path, dst_path):
    src = pathlib.Path(src_path)
    dst = pathlib.Path(dst_path)
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

if __name__ == "__main__":
    if len(sys.argv) >= 3:
        patch_binary(sys.argv[1], sys.argv[2])
PYEOF

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL: CLI
# ══════════════════════════════════════════════════════════════════════════════
install_cli() {
  echo ""
  sep
  printf '%b%b❯Installing Antigravity CLI%b\n' "${C}" "${B}" "${N}"
  sep

  CLI_AGY_BAK=""
  CLI_AGY_CREATED_FRESH=0
  CLI_AGY_VA39_BAK=""
  CLI_AGY_VA39_CREATED_FRESH=0

  if [[ -f "$CLI_BIN_DIR/agy" ]]; then
    CLI_AGY_BAK="$CLI_BIN_DIR/agy.bak.$$"
    mv -f "$CLI_BIN_DIR/agy" "$CLI_AGY_BAK"
  else
    CLI_AGY_CREATED_FRESH=1
  fi
  if [[ -f "$CLI_BIN_DIR/agy.va39" ]]; then
    CLI_AGY_VA39_BAK="$CLI_BIN_DIR/agy.va39.bak.$$"
    mv -f "$CLI_BIN_DIR/agy.va39" "$CLI_AGY_VA39_BAK"
  else
    CLI_AGY_VA39_CREATED_FRESH=1
  fi

  local status=0
  set +e
  (
    trap - EXIT
    set -e

    GITHUB_RELEASES_URL="https://api.github.com/repos/google-antigravity/antigravity-cli/releases/latest"
    release_json=$(download_file "$GITHUB_RELEASES_URL" "" || echo "")
    [[ -z "$release_json" ]] && die "CLI: Failed to query GitHub releases from $GITHUB_RELEASES_URL"

    latest_version=""
    download_url=""
    eval "$(echo "$release_json" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    ver = data.get("tag_name", "").lstrip("v")
    url = ""
    for asset in data.get("assets", []):
        name = asset.get("name", "")
        if "linux_arm64" in name or "arm64" in name:
            url = asset.get("browser_download_url", "")
            break
    print(f"latest_version=\"{ver}\"")
    print(f"download_url=\"{url}\"")
except Exception:
    pass
')"
    [[ -z "${latest_version:-}" || -z "${download_url:-}" ]] && die "CLI: Failed to parse GitHub release info."
    info "Latest version: v$latest_version"

    for f in "$DOWNLOAD_CACHE_DIR"/cli_upstream_v*.tar.gz; do
      if [[ -e "$f" && "$(basename "$f")" != "cli_upstream_v${latest_version}.tar.gz" ]]; then
        info "Removing old CLI installer archive: $(basename "$f")"
        rm -f "$f"
      fi
    done
    local CLI_ARCHIVE="${DOWNLOAD_CACHE_DIR}/cli_upstream_v${latest_version}.tar.gz"

    info "Downloading CLI binary..."
    download_file "$download_url" "$CLI_ARCHIVE" || die "CLI: Download failed"
    extract_tar "$CLI_ARCHIVE" "${BUILD_DIR}/" || die "CLI: Extraction failed"

    if [[ -f "${BUILD_DIR}/antigravity" ]]; then
      CLI_UPSTREAM_BIN="${BUILD_DIR}/antigravity"
    elif [[ -f "${BUILD_DIR}/agy" ]]; then
      CLI_UPSTREAM_BIN="${BUILD_DIR}/agy"
    else
      die "CLI: Could not find extracted binary."
    fi

    info "Patching... (this may take longer)"

    cat << 'PYEOF' > "${BUILD_DIR}/agy_update.py"
import sys, urllib.request, json, tarfile, pathlib, shutil, struct

def patch_binary(src_path, dst_path):
    src, dst = pathlib.Path(src_path), pathlib.Path(dst_path)
    if src.resolve() != dst.resolve(): shutil.copyfile(src, dst)
    data = bytearray(dst.read_bytes())
    def get(off): return struct.unpack_from("<I", data, off)[0]
    def put(off, word): struct.pack_into("<I", data, off, word)
    lo, hi = 0, len(data)
    for off in range(lo, hi, 4):
        w = get(off)
        if (w & 0x7F800000) == 0x53000000:
            immr, imms = (w >> 16) & 0x3F, (w >> 10) & 0x3F
            if immr == 42 and imms == 44: put(off, (w & ~((0x3F << 16) | (0x3F << 10))) | (35 << 16) | (37 << 10))
            elif immr == 22 and imms == 21: put(off, (w & ~((0x3F << 16) | (0x3F << 10))) | (29 << 16) | (28 << 10))
    for off in range(lo, hi - 4, 4):
        if get(off) == 0x92D3800A and get(off + 4) == 0xF2E0000A: put(off, 0x9280000A); put(off + 4, 0xD35DFD4A)
    for off in range(lo, hi, 4):
        if get(off) == 0xF2E00029: put(off, 0xD3596129)
    rw = {0xD2C20009: 0xD2C00409, 0xD2C2000A: 0xD2C0040A, 0xF2C20008: 0xF2DFF408, 0xF2C20009: 0xF2DFF409, 0xD2C10009: 0xD2C00209, 0xD2C1000A: 0xD2C0020A, 0xF2C38008: 0xF2DFF708, 0xF2C38009: 0xF2DFF709, 0x92560A6C: 0x925D0A6C, 0x92560A6A: 0x925D0A6A, 0xD2C3000D: 0xD2C0060D, 0xD2C3000C: 0xD2C0060C, 0xD2C08008: 0xD2C00108}
    for off in range(lo, hi, 4):
        w = get(off)
        if w in rw: put(off, rw[w])
    for off in range(0, len(data) - 12, 4):
        if (get(off) == 0xAA1F03E5 and get(off + 4) == 0xAA1F03E6 and get(off + 8) == 0xD28036E0 and (get(off + 12) & 0xFC000000) == 0x94000000): put(off + 8, 0xD2800600)
    dst.write_bytes(data)
    dst.chmod(0o755)

def main():
    target_dir = pathlib.Path(sys.argv[1])
    current_version = sys.argv[2]
    auto_confirm = sys.argv[3] == "1"
    
    print("[agy-termux] Querying latest upstream version from GitHub...")
    releases_url = "https://api.github.com/repos/google-antigravity/antigravity-cli/releases/latest"
    try:
        req = urllib.request.Request(releases_url, headers={"User-Agent": "Termux-Agy"})
        with urllib.request.urlopen(req, timeout=10) as response:
            release_data = json.loads(response.read().decode())
    except Exception as e:
        print(f"[agy-termux] Error checking for updates: {e}")
        sys.exit(1)
        
    latest_version = release_data.get("tag_name", "").lstrip("v")
    download_url = ""
    for asset in release_data.get("assets", []):
        name = asset.get("name", "")
        if "linux_arm64" in name or "arm64" in name:
            download_url = asset.get("browser_download_url", "")
            break
            
    if not latest_version or not download_url:
        print("[agy-termux] Error: Could not find matching Linux ARM64 release asset on GitHub.")
        sys.exit(1)
    
    v_latest = latest_version.lstrip("v")
    v_curr = current_version.lstrip("v")
    
    print(f"[agy-termux] Current version: v{v_curr}")
    print(f"[agy-termux] Latest version : v{v_latest}")
    
    if v_latest == v_curr:
        print("[agy-termux] You are already up to date.")
        sys.exit(0)
        
    print(f"\nA new update (v{v_latest}) is available!")
    if not auto_confirm:
        try:
            ans = input("[agy-termux] Would you like to update now? [Y/n]: ").strip().lower()
            if ans not in ("", "y", "yes"):
                print("[agy-termux] Update cancelled.")
                sys.exit(0)
        except KeyboardInterrupt:
            print("\n[agy-termux] Update cancelled.")
            sys.exit(0)
            
    print("[agy-termux] Downloading and applying update...")
    tmp_dir = target_dir / "agy-update-tmp"
    if tmp_dir.exists():
        shutil.rmtree(tmp_dir)
    tmp_dir.mkdir(parents=True, exist_ok=True)
    
    target_va39 = target_dir / "agy.va39"
    backup_va39 = target_dir / "agy.va39.bak"
    backup_made = False

    try:
        tar_path = tmp_dir / "agy.tar.gz"
        urllib.request.urlretrieve(download_url, tar_path)
        with tarfile.open(tar_path, "r:gz") as tar:
            tar.extractall(path=tmp_dir)
        
        extracted_bin = tmp_dir / "antigravity"
        if not extracted_bin.exists():
            extracted_bin = tmp_dir / "agy"
        if not extracted_bin.exists():
            for p in tmp_dir.iterdir():
                if p.is_file() and p.name not in ("agy.tar.gz",):
                    extracted_bin = p
                    break
                    
        if not extracted_bin or not extracted_bin.exists():
            raise FileNotFoundError("Could not find extracted binary in update archive.")
        
        print("[agy-termux] Patching binary...")
        if target_va39.exists():
            shutil.copyfile(target_va39, backup_va39)
            backup_made = True

        patch_binary(extracted_bin, target_va39)
        if backup_made and backup_va39.exists():
            backup_va39.unlink()
        print("[agy-termux] Update completed successfully! Please restart the CLI.")

    except BaseException as e:
        print(f"\n[agy-termux] Update failed or interrupted: {e}")
        if backup_made and backup_va39.exists():
            try:
                shutil.move(backup_va39, target_va39)
                print("[agy-termux] Restored previous binary.")
            except Exception as re:
                print(f"[agy-termux] Critical: failed to restore backup: {re}")
        sys.exit(1)
        
    finally:
        if tmp_dir.exists():
            shutil.rmtree(tmp_dir)

if __name__ == "__main__":
    main()
PYEOF

    python3 -c "
import pathlib
py_path = pathlib.Path('${BUILD_DIR}/agy_update.py')
py_data = py_path.read_bytes()
hex_bytes = ', '.join(f'0x{b:02x}' for b in py_data)
pathlib.Path('${BUILD_DIR}/agy_update_bytes.h').write_text(
    '// clang-format off\n'
    '#include <stddef.h>\n'
    f'static const unsigned char agy_update_py[] = {{ {hex_bytes} }};\n'
    f'static const size_t agy_update_py_len = {len(py_data)};\n'
    '// clang-format on\n'
)
"

    cat << 'EOF' > "${BUILD_DIR}/agy_helper.c"
#include "agy_update_bytes.h"
#include <asm/hwcap.h>
#include <ctype.h>
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <unistd.h>

#ifndef HWCAP_ATOMICS
#define HWCAP_ATOMICS (1 << 8)
#endif

static int is_native_termux(void);
static int require_resolver_config(const char *prefix);
static int resolve_qemu_for_cpu(const char *prefix, char *qemu_path, size_t qemu_path_len, const char **qemu);

static void print_update_usage(void) {
    printf("Usage: agy update [options]\n\n"
           "Options:\n"
           "  -y, --yes, --auto  Apply updates without prompting\n"
           "  -h, --help         Show this help message\n\n"
           "Environment:\n"
           "  AGY_AUTO_UPDATE=1  Apply updates without prompting\n");
}

static int write_and_run_updater(const char *dir, const char *current_version, int auto_update) {
    const char *tmp = getenv("TMPDIR");
    if (!tmp || tmp[0] == '\0') {
        tmp = "/tmp";
    }
    char py_path[PATH_MAX];
    snprintf(py_path, sizeof(py_path), "%s/agy_update.py", tmp);

    FILE *fp = fopen(py_path, "wb");
    if (!fp) {
        fprintf(stderr, "[agy-termux] Error: Could not write temporary updater script.\n");
        return 1;
    }

    size_t written_bytes = fwrite(agy_update_py, 1, agy_update_py_len, fp);
    if (fclose(fp) != 0 || written_bytes != agy_update_py_len) {
        unlink(py_path);
        fprintf(stderr, "[agy-termux] Error: Could not write temporary updater script completely.\n");
        return 1;
    }

    char cmd[PATH_MAX * 2 + 128];
    snprintf(cmd, sizeof(cmd), "python3 \"%s\" \"%s\" \"%s\" %d", py_path, dir, current_version, auto_update);

    int status = system(cmd);
    unlink(py_path);
    return status;
}

static int is_update_help_flag(const char *arg) {
    return strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0;
}

static int is_update_auto_flag(const char *arg) {
    return strcmp(arg, "-y") == 0 || strcmp(arg, "--yes") == 0 || strcmp(arg, "--auto") == 0;
}

static int update_command_requests_help(int argc, char **argv) {
    for (int i = 2; i < argc; i++) {
        if (is_update_help_flag(argv[i])) {
            return 1;
        }
    }
    return 0;
}

static int is_update_command(int argc, char **argv) {
    return argc >= 2 && strcmp(argv[1], "update") == 0;
}

static int env_requests_auto_update(void) {
    const char *env_auto = getenv("AGY_AUTO_UPDATE");
    return env_auto != NULL && (strcmp(env_auto, "1") == 0 || strcmp(env_auto, "true") == 0);
}

static int handle_update_command(const char *dir, int argc, char **argv) {
    int auto_update = env_requests_auto_update();
    for (int i = 2; i < argc; i++) {
        if (is_update_help_flag(argv[i])) {
            print_update_usage();
            return 0;
        }
        if (is_update_auto_flag(argv[i])) {
            auto_update = 1;
        }
    }
    
    const char *prefix = getenv("PREFIX");
    if (!prefix || prefix[0] == '\0') {
        prefix = "/data/data/com.termux/files/usr";
    }
    const char *qemu = NULL;
    char qemu_path[PATH_MAX];
    resolve_qemu_for_cpu(prefix, qemu_path, sizeof(qemu_path), &qemu);
    char cmd[PATH_MAX * 4 + 128];
    if (qemu) {
        snprintf(cmd, sizeof(cmd),
                 "\"%s\" \"%s/glibc/lib/ld-linux-aarch64.so.1\" --library-path \"%s/glibc/lib\" \"%s/agy.va39\" --version 2>/dev/null",
                 qemu, prefix, prefix, dir);
    } else {
        snprintf(cmd, sizeof(cmd),
                 "\"%s/glibc/lib/ld-linux-aarch64.so.1\" --library-path \"%s/glibc/lib\" \"%s/agy.va39\" --version 2>/dev/null",
                 prefix, prefix, dir);
    }
    FILE *fp = popen(cmd, "r");
    static char version[128] = "0.0.0";
    if (fp) {
        char out[128];
        if (fgets(out, sizeof(out) - 1, fp) != NULL) {
            out[strcspn(out, "\r\n")] = '\0';
            char *vptr = strchr(out, 'v');
            if (vptr && isdigit(vptr[1])) {
                strncpy(version, vptr, sizeof(version) - 1);
            } else {
                for (int i = 0; out[i] != '\0'; i++) {
                    if (isdigit(out[i])) {
                        strncpy(version, &out[i], sizeof(version) - 1);
                        break;
                    }
                }
            }
        }
        pclose(fp);
    }
    
    return write_and_run_updater(dir, version, auto_update);
}

static int is_native_termux(void) {
    const char *termux_version = getenv("TERMUX_VERSION");
    const char *prefix = getenv("PREFIX");
    char bin_path[PATH_MAX];
    int written = 0;

    if (termux_version == NULL || termux_version[0] == '\0') {
        return 0;
    }
    if (prefix == NULL || prefix[0] == '\0') {
        return 0;
    }
    written = snprintf(bin_path, sizeof(bin_path), "%s/bin", prefix);
    if (written < 0 || written >= (int)sizeof(bin_path)) {
        return 0;
    }
    if (access(bin_path, F_OK) != 0) {
        return 0;
    }
    return 1;
}

static void print_non_termux_message(void) {
    (void)fprintf(stderr, "[agy-termux] This standalone port is only for native Termux.\n"
                          "[agy-termux] PRoot environments can use Google's official "
                          "Antigravity CLI binary directly.\n"
                          "[agy-termux] Install it with:\n"
                          "  curl -fsSL https://antigravity.google/cli/install.sh | bash\n");
}

static int require_resolver_config(const char *prefix) {
    char resolv_path[PATH_MAX];
    int written = snprintf(resolv_path, sizeof(resolv_path), "%s/etc/resolv.conf", prefix);
    if (written < 0 || written >= (int)sizeof(resolv_path)) {
        return 0;
    }
    if (access(resolv_path, R_OK) != 0) {
        (void)fprintf(stderr, "[agy-termux] Missing resolver configuration: %s\n", resolv_path);
        (void)fprintf(stderr, "[agy-termux] Install it with: pkg install resolv-conf\n");
        (void)fprintf(stderr, "[agy-termux] Without this file, login and OAuth network requests may fail.\n");
        return 0;
    }
    return 1;
}

static int resolve_qemu_for_cpu(const char *prefix, char *qemu_path, size_t qemu_path_len,
                                const char **qemu) {
    unsigned long hwcap = getauxval(AT_HWCAP);
    *qemu = NULL;
    if ((hwcap & HWCAP_ATOMICS) != 0) {
        return 1;
    }
    int qemu_written = snprintf(qemu_path, qemu_path_len, "%s/bin/qemu-aarch64", prefix);
    if (qemu_written > 0 && (size_t)qemu_written < qemu_path_len && access(qemu_path, F_OK) == 0) {
        *qemu = qemu_path;
        return 1;
    }
    (void)fprintf(stderr, "[agy-termux] CPU lacks LSE atomics, and qemu-aarch64 was not found.\n");
    (void)fprintf(stderr, "[agy-termux] You may need to install the qemu-user-aarch64 package.\n");
    return 0;
}

int main(int argc, char **argv) {
    char exec_path[PATH_MAX];
    char lib_path[PATH_MAX + 16];
    char patched_bin[PATH_MAX];
    char dynamic_loader[PATH_MAX];
    char cert_path[PATH_MAX];
    char prefix_path[PATH_MAX];
    char qemu_path[PATH_MAX];
    const char *prefix = getenv("PREFIX");
    const char *loader = NULL;
    const char *dir = NULL;
    const char *qemu = NULL;
    const char *exec_target = NULL;
    const char *exec_error = NULL;
    char **new_argv = NULL;
    int arg_idx = 0;
    int written = 0;
    ssize_t read_len = 0;

    if (!is_native_termux()) {
        print_non_termux_message();
        return 1;
    }

    if (!resolve_qemu_for_cpu(prefix, qemu_path, sizeof(qemu_path), &qemu)) {
        return 1;
    }
    written = snprintf(prefix_path, sizeof(prefix_path), "%s", prefix);
    if (written < 0 || written >= (int)sizeof(prefix_path)) {
        return 1;
    }
    written = snprintf(dynamic_loader, sizeof(dynamic_loader), "%s/glibc/lib/ld-linux-aarch64.so.1",
                       prefix_path);
    if (written < 0 || written >= (int)sizeof(dynamic_loader)) {
        return 1;
    }
    loader = dynamic_loader;
    exec_target = loader;
    exec_error = "[agy-termux] execv failed";

    if (access(loader, F_OK) != 0) {
        (void)fprintf(stderr, "[agy-termux] Missing Termux glibc loader: %s\n", loader);
        (void)fprintf(stderr, "[agy-termux] You may need to install the glibc-repo and glibc packages.\n");
        return 1;
    }

    unsetenv("LD_PRELOAD");
    unsetenv("LD_LIBRARY_PATH");

    setenv("GODEBUG", "netdns=cgo", 1);
    written = snprintf(cert_path, sizeof(cert_path), "%s/etc/tls/cert.pem", prefix_path);
    if (written < 0 || written >= (int)sizeof(cert_path)) {
        return 1;
    }
    setenv("SSL_CERT_FILE", cert_path, 1);

    read_len = readlink("/proc/self/exe", exec_path, sizeof(exec_path) - 1);
    if (read_len < 0 || read_len >= (ssize_t)sizeof(exec_path)) {
        return 1;
    }
    exec_path[read_len] = '\0';
    dir = dirname(exec_path);

    if (is_update_command(argc, argv)) {
        if (update_command_requests_help(argc, argv)) {
            return handle_update_command(dir, argc, argv);
        }
        if (!require_resolver_config(prefix_path)) {
            return 1;
        }
        return handle_update_command(dir, argc, argv);
    }

    if (!require_resolver_config(prefix_path)) {
        return 1;
    }

    written = snprintf(lib_path, sizeof(lib_path), "%s/glibc/lib", prefix_path);
    if (written < 0 || written >= (int)sizeof(lib_path)) {
        return 1;
    }

    written = snprintf(patched_bin, sizeof(patched_bin), "%s/agy.va39", dir);
    if (written < 0 || written >= (int)sizeof(patched_bin)) {
        return 1;
    }

    int new_argc = argc + 6;
    new_argv = malloc((size_t)new_argc * sizeof(*new_argv));
    if (!new_argv) {
        return 1;
    }

    arg_idx = 0;
    if (qemu) {
        new_argv[arg_idx++] = (char *)qemu;
        exec_target = qemu;
        exec_error = "[agy-termux] execv (qemu) failed";
    }
    new_argv[arg_idx++] = (char *)loader;
    new_argv[arg_idx++] = "--library-path";
    new_argv[arg_idx++] = lib_path;
    new_argv[arg_idx++] = patched_bin;

    for (int i = 1; i < argc; i++) {
        new_argv[arg_idx++] = argv[i];
    }
    new_argv[arg_idx] = NULL;

    if (execv(exec_target, new_argv) == -1) {
        perror(exec_error);
        free(new_argv);
        return 1;
    }
}
EOF

    if ! clang -O2 -I"${BUILD_DIR}" -o "${BUILD_DIR}/agy" "${BUILD_DIR}/agy_helper.c"; then
      die "CLI: Failed to compile native C bootstrapper."
    fi
    chmod +x "${BUILD_DIR}/agy"

    python3 "${BUILD_DIR}/va39_patch.py" "$CLI_UPSTREAM_BIN" "${BUILD_DIR}/agy.va39" >/dev/null

    mkdir -p "$CLI_BIN_DIR"
    install -m 0755 "${BUILD_DIR}/agy" "$CLI_BIN_DIR/agy" || die "CLI: Failed to install agy"
    install -m 0755 "${BUILD_DIR}/agy.va39" "$CLI_BIN_DIR/agy.va39" || die "CLI: Failed to install agy.va39"
  )
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    if [[ -n "${CLI_UPSTREAM_BIN:-}" && -f "$CLI_UPSTREAM_BIN" && "$CLI_UPSTREAM_BIN" != "${BUILD_DIR}"* ]]; then
      warn "If the local CLI binary is corrupted, please manually delete: $CLI_UPSTREAM_BIN"
    fi
    if [[ -n "$CLI_AGY_BAK" && -f "$CLI_AGY_BAK" ]]; then
      rm -f "$CLI_BIN_DIR/agy"
      mv "$CLI_AGY_BAK" "$CLI_BIN_DIR/agy"
      info "Restored previous Antigravity CLI binary."
    fi
    if [[ -n "$CLI_AGY_VA39_BAK" && -f "$CLI_AGY_VA39_BAK" ]]; then
      rm -f "$CLI_BIN_DIR/agy.va39"
      mv "$CLI_AGY_VA39_BAK" "$CLI_BIN_DIR/agy.va39"
      info "Restored previous Antigravity CLI va39 binary."
    fi
    CLI_AGY_BAK=""
    CLI_AGY_VA39_BAK=""
    warn "CLI installation failed."
    return 1
  else
    if [[ -n "$CLI_AGY_BAK" && -f "$CLI_AGY_BAK" ]]; then
      rm -f "$CLI_AGY_BAK"
    fi
    if [[ -n "$CLI_AGY_VA39_BAK" && -f "$CLI_AGY_VA39_BAK" ]]; then
      rm -f "$CLI_AGY_VA39_BAK"
    fi
    CLI_AGY_BAK=""
    CLI_AGY_VA39_BAK=""
    ok "CLI installed successfully → ${D}${CLI_BIN_DIR}/agy${N}"
    return 0
  fi
}

install_cli || true

# ── Final Summary ─────────────────────────────────────────────────────────────
ALL_SUCCESS=1

echo ""
sep
if [[ $ALL_SUCCESS -eq 1 ]]; then
  ok "${B}Installation completed successfully!${N}"
else
  warn "${B}Installation completed with errors.${N}"
fi

case ":$PATH:" in
  *":$CLI_BIN_DIR:"*) ;;
  *)
    printf '\n'
    warn "${B}${CLI_BIN_DIR}${N} is not in your PATH."
    info "Add to ~/.bashrc: ${B}export PATH=\"${CLI_BIN_DIR}:\$PATH\"${N}"
    ;;
esac
echo ""
