#!/usr/bin/env bash
# Antigravity - All-in-One Termux Installer
# Installs CLI, IDE, and/or Antigravity 2.0 in a single run.
set -Eeuo pipefail
MAIN_PID="$$"

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

# Check OS distribution if we are in proot (must be Debian or Ubuntu)
OS_ID=""
OS_ID_LIKE=""
if [[ "$ENV_TYPE" == "proot" ]]; then
  IS_DEBIAN_UBUNTU=0
  if [[ -f /etc/os-release ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^ID=(.*) ]]; then
        OS_ID="${BASH_REMATCH[1]}"
        OS_ID="${OS_ID//[\"\']/}"
      elif [[ "$line" =~ ^ID_LIKE=(.*) ]]; then
        OS_ID_LIKE="${BASH_REMATCH[1]}"
        OS_ID_LIKE="${OS_ID_LIKE//[\"\']/}"
      fi
    done < /etc/os-release
    if [[ "$OS_ID" == "debian" || "$OS_ID" == "ubuntu" || "$OS_ID_LIKE" == *"debian"* || "$OS_ID_LIKE" == *"ubuntu"* ]]; then
      IS_DEBIAN_UBUNTU=1
    fi
  fi
  if [[ $IS_DEBIAN_UBUNTU -ne 1 ]]; then
    printf "\033[31m✖\033[0mPRoot environment must be Debian or Ubuntu.\n" >&2
    exit 1
  fi
elif [[ "$ENV_TYPE" != "termux" ]]; then
  printf "\033[31m✖\033[0mThis script only supports native Termux or PRoot Debian/Ubuntu.\n" >&2
  exit 1
fi

ENV_DISPLAY="$ENV_TYPE"
if [[ "$ENV_TYPE" == "proot" ]]; then
  if [[ "${OS_ID:-}" == "debian" || "${OS_ID_LIKE:-}" == *"debian"* ]]; then
    ENV_DISPLAY="proot debian"
  elif [[ "${OS_ID:-}" == "ubuntu" || "${OS_ID_LIKE:-}" == *"ubuntu"* ]]; then
    ENV_DISPLAY="proot ubuntu"
  fi
fi

# ── Installation Paths ────────────────────────────────────────────────────────
LOCAL_BIN="$HOME/.local/bin"
LOCAL_SHARE="$HOME/.local/share"

if [[ "$ENV_TYPE" == "termux" ]]; then
  TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
  GLOBAL_BIN="${TERMUX_PREFIX}/bin"
  GLOBAL_SHARE="${TERMUX_PREFIX}/share"
else
  GLOBAL_BIN="/usr/bin"
  GLOBAL_SHARE="/usr/share"
fi

CLI_BIN_DIR="$LOCAL_BIN"

IDE_BIN_DIR="$LOCAL_BIN"
IDE_TARGET_DIR="$LOCAL_SHARE/Antigravity IDE"
IDE_APPLICATIONS_DIR="$LOCAL_SHARE/applications"
IDE_ICONS_DIR="$LOCAL_SHARE/icons"

V2_BIN_DIR="$LOCAL_BIN"
V2_TARGET_DIR="$LOCAL_SHARE/Antigravity-arm64"
V2_APPLICATIONS_DIR="$LOCAL_SHARE/applications"
V2_ICONS_DIR="$LOCAL_SHARE/icons"

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  B=$'\e[1m'  D=$'\e[2m'  G=$'\e[32m'  R=$'\e[31m'  C=$'\e[36m'  Y=$'\e[33m'  W=$'\e[37m'  N=$'\e[0m'
else
  B=""  D=""  G=""  R=""  C=""  Y=""  W=""  N=""
fi

# ── Wrapped Printer Helper ────────────────────────────────────────────────────
wrap_print() {
  local prefix="$1"
  local indent="$2"
  shift 2
  local text="$*"
  local esc=$'\e'

  local cols
  cols=$(tput cols </dev/tty 2>/dev/null || echo 60)
  
  local pad_len=4
  local max_w=$((cols - pad_len))
  if [[ $max_w -lt 30 ]]; then
    max_w=30
  fi

  echo "$text" | awk -v w="$max_w" -v pref="$prefix" -v ind="$indent" -v esc="$esc" '
    function strip_ansi(str) {
      gsub(esc "\\[[0-9;]*[a-zA-Z]", "", str)
      return str
    }
    {
      words_count = split($0, words, " ")
      line = ""
      line_clean = ""
      first = 1
      for (i = 1; i <= words_count; i++) {
        word = words[i]
        word_clean = strip_ansi(word)
        
        if (first) {
          line = word
          line_clean = word_clean
          first = 0
        } else {
          test_line_clean = line_clean " " word_clean
          if (length(test_line_clean) <= w) {
            line = line " " word
            line_clean = test_line_clean
          } else {
            if (pref != "") {
              printf "%s%s\n", pref, line
              pref = ""
            } else {
              printf "%s%s\n", ind, line
            }
            line = word
            line_clean = word_clean
          }
        }
      }
      if (line != "") {
        if (pref != "") {
          printf "%s%s\n", pref, line
        } else {
          printf "%s%s\n", ind, line
        }
      }
    }
  '
}

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { wrap_print "${D}⠶${N}" "" "${D}$*${N}"; }
ok()    { wrap_print "${G}✔${N}" "" "$*"; }
warn()  { wrap_print "${Y}⚠${N}" "" "$*"; }
err()   { wrap_print "${R}✖${N}" "" "$*"; }
die() {
  {
    printf "\033[?25h"
    printf '\n'
    if [[ $# -gt 0 ]]; then
      wrap_print "${R}✖${N}" "" "$*"
    else
      wrap_print "${R}✖${N}" "" "Installation failed or was cancelled."
    fi
    printf '\n'
  } >&2
  exit 1
}
sep() {
  printf "%s─────────────────────────%s\n" "${D}" "${N}"
}

safe_read() {
  local _sr_status
  local _sr_winch
  _sr_winch=$((128 + $(kill -l WINCH 2>/dev/null || echo 28)))
  while true; do
    read "$@"
    _sr_status=$?
    if [[ $_sr_status -eq $_sr_winch ]]; then
      continue
    fi
    return $_sr_status
  done
}

ask_confirm() {
  local msg="$1"
  local default="${2:-y}" # y or n
  local choices="[Y/n]"
  [[ "$default" == "n" ]] && choices="[y/N]"
  
  printf '%b%s%b' "${C}❯${N}${B}${msg}${N}" "${choices}"
  
  local ans=""
  safe_read -r ans < /dev/tty || ans="$default"
  if [[ -z "$ans" ]]; then
    ans="$default"
  fi
  # Normalize to lowercase
  ans="${ans,,}"
  if [[ "$ans" =~ ^(y|yes)$ ]]; then
    return 0
  else
    return 1
  fi
}

# ── Optimization Helpers ──────────────────────────────────────────────────────
DOWNLOAD_CACHE_DIR="$HOME/.cache/antigravity-installer"
CURRENT_DOWNLOAD_PID=""
DOWNLOADED_ARCHIVES=()

get_terminal_columns() {
  local cols
  # Try stty first
  cols=$(stty size 2>/dev/null | awk '{print $2}')
  # Try tput cols without /dev/tty
  [[ -z "$cols" ]] && cols=$(tput cols 2>/dev/null)
  # Try tput cols with /dev/tty redirect
  [[ -z "$cols" ]] && cols=$(tput cols </dev/tty 2>/dev/null)
  # Try the COLUMNS env variable
  [[ -z "$cols" ]] && cols="${COLUMNS:-}"
  # Default to 80
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
  
  # Kill any existing leaked wget process downloading this file from a previous session
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

  # Fetch remote content length using HTTP HEAD request following redirects
  local final_headers
  final_headers=$(wget --spider --server-response --tries=3 --timeout=5 "$url" 2>&1 || true)
  
  local status_code
  status_code=$(echo "$final_headers" | grep -i 'HTTP/' | tail -n1 | awk '{print $2}')
  
  local total_size
  total_size=$(echo "$final_headers" | awk '/[Cc]ontent-[Ll]ength:/ {print $2}' | tail -n1 | tr -d '\r' | xargs || echo "")

  # Validate that total_size is numeric to prevent syntax/unbound variable errors in arithmetic expressions
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
      # Check if the partial file is valid (starts with gzip magic bytes)
      if [[ "$dest" == *.tar.gz ]] && ! is_gzip_magic_valid "$dest"; then
        warn "Local partial file is invalid or corrupted. Redownloading from scratch..."
        rm -f "$dest"
      else
        start_size=$check_size
      fi
    fi
  fi

  # Start wget in background with continue option.
  wget -q -c --tries=3 --waitretry=2 -O "$dest" "$url" &>/dev/null &
  CURRENT_DOWNLOAD_PID=$!
  echo "$CURRENT_DOWNLOAD_PID" > "$pid_file"
  DOWNLOADED_ARCHIVES+=("$dest")
  
  # Poll file size and print progress
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
      # Subtract a safety margin of 2 columns to prevent wrapping
      cols=$((cols - 2))
      
      local out_str=""
      if [[ -n "$total_str" ]]; then
        local prefix="Downloading:["
        
        # Build suffix content with speed and remaining time
        local suff_details=""
        [[ -n "$speed_str" ]] && suff_details="${suff_details}${speed_str}"
        [[ -n "$eta_str" ]] && suff_details="${suff_details}${eta_str}"
        
        local suffix="]${p_pct}%(${cur_str}/${total_str})${suff_details}"
        
        # Calculate available width for the progress bar
        local fixed_len=$((${#prefix} + ${#suffix}))
        local bar_width=$((cols - fixed_len))
        
        if (( bar_width >= 10 )); then
          # Draw the dynamic progress bar matching the resized terminal width
          local num_fill=$(( (p_pct * bar_width) / 100 ))
          (( num_fill > bar_width )) && num_fill=$bar_width
          local bar=""
          for ((i=0; i<num_fill; i++)); do bar="${bar}${fill}"; done
          for ((i=num_fill; i<bar_width; i++)); do bar="${bar}${empty}"; done
          out_str="${prefix}${bar}${suffix}"
        elif (( cols >= 45 )); then
          # Terminal too narrow for the progress bar, show text percentage + sizes + speed/eta details
          out_str="Downloading:${p_pct}%(${cur_str}/${total_str})${suff_details}"
        else
          # Extremely narrow terminal, show just percentage
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
        # Do not delete the file here either - let it be, but return error.
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
    
    # Check if we should update progress: only update 10 times (every 10%)
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
  
  # Wait for wget to exit and get status
  wait "$CURRENT_DOWNLOAD_PID"
  local wget_status=$?
  CURRENT_DOWNLOAD_PID=""
  rm -f "$pid_file"
  
  # Print final progress if successful
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
    # Move to the next line if stdout is interactive and we failed (so progress bar is kept)
    if [[ -t 1 ]]; then
      printf "\n"
    fi
  fi
  
  # Check for errors
  if [[ $wget_status -ne 0 ]]; then
    # Do NOT delete the partial file, so it can be resumed next time
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

# Global backup variables for rolling back changes on failure
CLI_AGY_BAK=""
CLI_AGY_CREATED_FRESH=0
CLI_AGY_VA39_BAK=""
CLI_AGY_VA39_CREATED_FRESH=0

IDE_DIR_BAK=""
IDE_DIR_CREATED_FRESH=0
IDE_BIN_BAK=""
IDE_BIN_CREATED_FRESH=0
IDE_DESKTOP_BAK=""
IDE_DESKTOP_CREATED_FRESH=0
IDE_ICON_BAK=""
IDE_ICON_CREATED_FRESH=0

V2_DIR_BAK=""
V2_DIR_CREATED_FRESH=0
V2_WRAPPER_BAK=""
V2_WRAPPER_CREATED_FRESH=0
V2_FILE_BAK=""
V2_FILE_CREATED_FRESH=0
V2_ICON_BAK=""
V2_ICON_CREATED_FRESH=0

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

rollback_dir() {
  local bak="$1"
  local target="$2"
  local fresh="$3"
  if [[ -n "$bak" && -d "$bak" ]]; then
    rm -rf "$target"
    mv "$bak" "$target"
  elif [[ "$fresh" -eq 1 ]]; then
    rm -rf "$target"
  fi
}

cleanup() {
  if [[ "${BASHPID:-$$}" -ne "${MAIN_PID:-$$}" ]]; then
    return 0
  fi
  printf "\033[?25h"
  
  # Kill active download process if interrupted (read from pid file to handle subshell scopes)
  local pid_file="${DOWNLOAD_CACHE_DIR}/download.pid"
  if [[ -f "$pid_file" ]]; then
    local act_pid
    act_pid=$(cat "$pid_file" 2>/dev/null || echo "")
    if [[ -n "$act_pid" ]]; then
      kill -9 "$act_pid" 2>/dev/null || true
    fi
    rm -f "$pid_file" 2>/dev/null || true
  fi

  # Clean up temporary files / build dir
  [[ -n "${BUILD_DIR:-}" && -d "$BUILD_DIR" ]] && rm -rf "$BUILD_DIR"

  if [[ "${ALL_SUCCESS:-0}" -ne 1 ]]; then
    info "Installation failed or interrupted! Reverting all changes..."

    # --- CLI Rollback ---
    rollback_file "$CLI_AGY_BAK" "$CLI_BIN_DIR/agy" "$CLI_AGY_CREATED_FRESH"
    rollback_file "$CLI_AGY_VA39_BAK" "$CLI_BIN_DIR/agy.va39" "$CLI_AGY_VA39_CREATED_FRESH"

    # --- IDE Rollback ---
    rollback_dir "$IDE_DIR_BAK" "$IDE_TARGET_DIR" "$IDE_DIR_CREATED_FRESH"
    rollback_file "$IDE_BIN_BAK" "$IDE_BIN_DIR/antigravity-ide" "$IDE_BIN_CREATED_FRESH"
    rollback_file "$IDE_DESKTOP_BAK" "$IDE_APPLICATIONS_DIR/antigravity-ide.desktop" "$IDE_DESKTOP_CREATED_FRESH"
    rollback_file "$IDE_ICON_BAK" "$IDE_ICONS_DIR/antigravity-ide.png" "$IDE_ICON_CREATED_FRESH"

    # --- 2.0 Rollback ---
    rollback_dir "$V2_DIR_BAK" "$V2_TARGET_DIR" "$V2_DIR_CREATED_FRESH"
    rollback_file "$V2_WRAPPER_BAK" "$V2_BIN_DIR/antigravity" "$V2_WRAPPER_CREATED_FRESH"
    rollback_file "$V2_FILE_BAK" "$V2_APPLICATIONS_DIR/antigravity.desktop" "$V2_FILE_CREATED_FRESH"
    rollback_file "$V2_ICON_BAK" "$V2_ICONS_DIR/antigravity.png" "$V2_ICON_CREATED_FRESH"

    # Keep the partially/fully downloaded archives on failure to make them resumable in the next run
    :
  else
    # Success: delete all backups and only archives that were downloaded in this run
    rm -f "$CLI_AGY_BAK" "$CLI_AGY_VA39_BAK" "$IDE_BIN_BAK" "$IDE_DESKTOP_BAK" "$IDE_ICON_BAK" "$V2_WRAPPER_BAK" "$V2_FILE_BAK" "$V2_ICON_BAK" 2>/dev/null || true
    rm -rf "$IDE_DIR_BAK" "$V2_DIR_BAK" 2>/dev/null || true
    
    for archive in "${DOWNLOADED_ARCHIVES[@]}"; do
      rm -f "$archive" 2>/dev/null || true
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

logo_cols=$(tput cols </dev/tty 2>/dev/null || echo 60)
# Disable line wrapping so terminal resize doesn't corrupt the logo
printf '\033[?7l'
awk -v cols="$logo_cols" -v env="${ENV_DISPLAY}" -v bold="${B}${C}" -v dim="${D}" -v rst="${N}" '
{
  sub(/\r$/, "");
  if (cols >= 48) {
    printf "%s", $0;
    if (NR == 3)      printf "\033[28G %sAntigravity Termux%s", bold, rst;
    else if (NR == 4) printf "\033[28G %sAll-in-One Installer%s", dim, rst;
    else if (NR == 5) printf "\033[28G %s────────────────────%s", dim, rst;
    else if (NR == 6) printf "\033[28G %sEnv:%s    %s", dim, rst, env;
    printf "\033[K\n";
  } else {
    printf "%s\033[K\n", $0;
  }
}' "$TMP_LOGO"
# Re-enable line wrapping
printf '\033[?7h'
echo ""
sep

# ── Architecture Check ────────────────────────────────────────────────────────
[[ "$(uname -m)" == "aarch64" ]] || die "Architecture must be aarch64"

# ── Product Selection ─────────────────────────────────────────────────────────
INSTALL_CLI=0
INSTALL_IDE=0
INSTALL_V2=0

if [[ "$ENV_TYPE" == "termux" ]]; then
  warn "IDE and 2.0 are not supported natively on Termux due to missing GUI library dependencies."
  info "Directly routing to Antigravity CLI installation..."
  INSTALL_CLI=1
else
  printf '\n%b\n\n' "${B}Select products to install:${N}"
  printf '[%b1%b]Antigravity CLI %b(agy — standalone terminal agent)%b\n' "${C}" "${N}" "${D}" "${N}"
  printf '[%b2%b]Antigravity IDE %b(VS Code-based agentic IDE)%b\n' "${C}" "${N}" "${D}" "${N}"
  printf '[%b3%b]Antigravity 2.0 %b(Desktop Electron application)%b\n' "${C}" "${N}" "${D}" "${N}"
  printf '\n%bEnter choice (e.g. %b1%b, %b13%b, %b123%b): ' "${C}❯${N}" "${B}" "${N}" "${B}" "${N}" "${B}" "${N}"

  SELECTION=""
  safe_read -r SELECTION < /dev/tty || true

  if [[ -z "$SELECTION" ]]; then
    die "No selection made."
  fi

  # Deduplicate and validate
  for (( i=0; i<${#SELECTION}; i++ )); do
    ch="${SELECTION:$i:1}"
    case "$ch" in
      1) INSTALL_CLI=1 ;;
      2) INSTALL_IDE=1 ;;
      3) INSTALL_V2=1 ;;
      *) die "Invalid selection: '$ch'. Use 1, 2, or 3." ;;
    esac
  done
fi

# Build selection list
SELECTED_NAMES=()
[[ $INSTALL_CLI -eq 1 ]] && SELECTED_NAMES+=("CLI")
[[ $INSTALL_IDE -eq 1 ]] && SELECTED_NAMES+=("IDE")
[[ $INSTALL_V2 -eq 1 ]] && SELECTED_NAMES+=("2.0")

printf '\n'
ok "Selected: ${B}${SELECTED_NAMES[*]}${N}"
sep

# Ask local vs global for chosen products
OVERRIDE_INSTALL_TYPE=""

ask_install_type() {
  local product="$1"
  local var_name="$2"
  
  if [[ -n "$OVERRIDE_INSTALL_TYPE" ]]; then
    eval "$var_name=\"\$OVERRIDE_INSTALL_TYPE\""
    return 0
  fi
  
  local ans=""
  while true; do
    printf '\n%bChoose installation type for %s:%b\n' "${B}" "${product}" "${N}" >&2
    printf '[1/l]Local ($HOME/.local)\n' >&2
    if [[ "$ENV_TYPE" == "termux" ]]; then
      printf '[2/g]Global (%s)\n' "${TERMUX_PREFIX}" >&2
    else
      printf '[2/g]Global (/usr)\n' >&2
    fi
    printf '%b(l/g applies choice to all remaining products)%b\n' "${D}" "${N}" >&2
    printf '%bEnter choice: ' "${C}❯${N}" >&2
    
    if safe_read -r ans < /dev/tty; then
      ans="${ans,,}"
      case "$ans" in
        1|l)
          if [[ "$ans" == "l" ]]; then
            OVERRIDE_INSTALL_TYPE="local"
          fi
          eval "$var_name=\"local\""
          return 0
          ;;
        2|g)
          if [[ "$ans" == "g" ]]; then
            OVERRIDE_INSTALL_TYPE="global"
          fi
          eval "$var_name=\"global\""
          return 0
          ;;
        *)
          # Invalid input: print error and loop
          printf 'Invalid choice. Please enter 1, 2, l, or g.\n' >&2
          ;;
      esac
    else
      # If safe_read fails or EOF, default to local
      eval "$var_name=\"local\""
      return 0
    fi
  done
}

CLI_INSTALL_TYPE="local"
IDE_INSTALL_TYPE="local"
INSTALL_V2_TYPE="local"

if [[ $INSTALL_CLI -eq 1 ]]; then
  ask_install_type "Antigravity CLI" CLI_INSTALL_TYPE
  if [[ "$CLI_INSTALL_TYPE" == "global" ]]; then
    CLI_BIN_DIR="$GLOBAL_BIN"
  fi
fi
if [[ $INSTALL_IDE -eq 1 ]]; then
  ask_install_type "Antigravity IDE" IDE_INSTALL_TYPE
  if [[ "$IDE_INSTALL_TYPE" == "global" ]]; then
    IDE_BIN_DIR="$GLOBAL_BIN"
    IDE_TARGET_DIR="$GLOBAL_SHARE/Antigravity IDE"
    IDE_APPLICATIONS_DIR="$GLOBAL_SHARE/applications"
    IDE_ICONS_DIR="$GLOBAL_SHARE/icons"
  fi
fi
if [[ $INSTALL_V2 -eq 1 ]]; then
  ask_install_type "Antigravity 2.0" INSTALL_V2_TYPE
  if [[ "$INSTALL_V2_TYPE" == "global" ]]; then
    V2_BIN_DIR="$GLOBAL_BIN"
    V2_TARGET_DIR="$GLOBAL_SHARE/Antigravity-arm64"
    V2_APPLICATIONS_DIR="$GLOBAL_SHARE/applications"
    V2_ICONS_DIR="$GLOBAL_SHARE/icons"
  fi
fi

# ── Interactive Prompts & Confirmations Upfront ───────────────────────────────
RUN_CLI_INSTALL=0
RUN_IDE_INSTALL=0
RUN_V2_INSTALL=0

[[ $INSTALL_CLI -eq 1 ]] && RUN_CLI_INSTALL=1
[[ $INSTALL_IDE -eq 1 ]] && RUN_IDE_INSTALL=1
[[ $INSTALL_V2 -eq 1 ]] && RUN_V2_INSTALL=1

# Exit early if nothing remains to install
if [[ $RUN_CLI_INSTALL -eq 0 && $RUN_IDE_INSTALL -eq 0 && $RUN_V2_INSTALL -eq 0 ]]; then
  echo ""
  sep
  printf '%b\n' "${Y}No installations were attempted.${N}"
  sep
  ALL_SUCCESS=1
  exit 0
fi

# ── Prerequisite Checks & Package Manager Prompts Upfront ─────────────────────
install_dependencies() {
  local deps=()
  if [[ "$ENV_TYPE" == "termux" ]]; then
    deps=("python" "tar" "wget" "jq" "clang" "glibc-repo" "glibc")
  else
    # Base dependencies needed by everything (including CLI on PRoot)
    deps=("python3" "tar" "wget" "jq")
    # Compiler (clang) only needed if IDE or 2.0 is selected
    if [[ $RUN_IDE_INSTALL -eq 1 || $RUN_V2_INSTALL -eq 1 ]]; then
      deps+=("clang")
    fi
  fi
  
  if [[ "$ENV_TYPE" == "termux" ]]; then
    command -v pkg >/dev/null 2>&1 || die "pkg is required but not found to install dependencies"
    
    info "Installing dependencies: ${B}${deps[*]}${N}"
    if [[ " ${deps[*]} " == *" glibc-repo "* ]]; then
      pkg install -y glibc-repo &>/dev/null || true
    fi
    pkg install -y "${deps[@]}" &>/dev/null || die "Failed to install dependencies: ${deps[*]}"
  else
    local target_deps=()
    for d in "${deps[@]}"; do
      target_deps+=("$d")
    done

    # Check privilege helper (use sudo if available and we're not root)
    local helper=""
    [[ "$EUID" -ne 0 ]] && command -v sudo &>/dev/null && helper="sudo "
    local run_cmd=""
    if command -v apt-get &>/dev/null; then
      run_cmd="${helper}DEBIAN_FRONTEND=noninteractive apt-get update && ${helper}DEBIAN_FRONTEND=noninteractive apt-get install -y ${target_deps[*]}"
    else
      die "apt-get is required but not found. Please ensure you are running in Debian/Ubuntu."
    fi
    
    info "Installing dependencies..."
    if [[ -n "$helper" ]]; then sudo -v || die "Authentication failed."; fi
    eval "$run_cmd" &>/dev/null || die "Automatic installation of dependencies failed."
  fi
}

install_dependencies

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
if len(sys.argv) > 3: hi = int(sys.argv[3], 16)
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
  local pkgbuild
  pkgbuild=$(download_file "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=${pkg_name}" "" || echo "")
  [[ -z "$pkgbuild" ]] && die "Failed to retrieve AUR PKGBUILD for $pkg_name."

  local pkgver="" build_num=""
  # Parse both fields in a single awk execution to avoid subprocess spawns
  eval "$(echo "$pkgbuild" | awk -F= '
    /^pkgver=/ { gsub(/^[ \t"\x27]+|[ \t"\x27]+$/, "", $2); print "pkgver=" $2 }
    /^_build=/ { gsub(/^[ \t"\x27]+|[ \t"\x27]+$/, "", $2); print "build_num=" $2 }
  ')"

  [[ -z "$pkgver" || -z "$build_num" ]] && die "Failed to parse pkgver/_build from AUR PKGBUILD for $pkg_name."
  echo "${pkgver}:${build_num}"
}

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL: CLI
# ══════════════════════════════════════════════════════════════════════════════
install_cli() {
  echo ""
  sep
  printf '%b%b❯Installing %s:Antigravity CLI%b\n' "${C}" "${B}" "${TASK_PROGRESS}" "${N}"
  sep

  # Reset CLI backups
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
  if [[ "$ENV_TYPE" == "termux" ]]; then
    if [[ -f "$CLI_BIN_DIR/agy.va39" ]]; then
      CLI_AGY_VA39_BAK="$CLI_BIN_DIR/agy.va39.bak.$$"
      mv -f "$CLI_BIN_DIR/agy.va39" "$CLI_AGY_VA39_BAK"
    else
      CLI_AGY_VA39_CREATED_FRESH=1
    fi
  fi

  local status=0
  set +e
  (
    trap - EXIT
    set -e

    MANIFEST_URL="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json"
    manifest=$(download_file "$MANIFEST_URL" "" || echo "")
    [[ -z "$manifest" ]] && die "CLI: Failed to query manifest from $MANIFEST_URL"

    latest_version=$(echo "$manifest" | jq -r '.version')
    download_url=$(echo "$manifest" | jq -r '.url')
    info "Latest version: v$latest_version"

    # Remove old versions from cache
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

    if [[ "$ENV_TYPE" == "termux" ]]; then
      info "Patching... (this may take longer)"

      cat << 'PYEOF' > "${BUILD_DIR}/agy_update.py"
import sys, urllib.request, json, tarfile, pathlib, shutil, struct

def patch_binary(src_path, dst_path):
    data = bytearray(src_path.read_bytes())
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
    dst_path.write_bytes(data)
    dst_path.chmod(0o755)

def main():
    target_dir = pathlib.Path(sys.argv[1])
    current_version = sys.argv[2]
    auto_confirm = sys.argv[3] == "1"
    
    print("[agy-termux] Querying latest upstream version...")
    manifest_url = "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json"
    try:
        req = urllib.request.Request(manifest_url, headers={"User-Agent": "Termux-Agy"})
        with urllib.request.urlopen(req, timeout=10) as response:
            manifest = json.loads(response.read().decode())
    except Exception as e:
        print(f"[agy-termux] Error checking for updates: {e}")
        sys.exit(1)
        
    latest_version = manifest.get("version")
    download_url = manifest.get("url")
    
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

#ifndef AGY_TERMUX_VERSION
#define AGY_TERMUX_VERSION "1.0.2"
#endif

static int is_native_termux(void);
static int require_resolver_config(const char *prefix);
static int resolve_qemu_for_cpu(const char *prefix, char *qemu_path, size_t qemu_path_len, const char **qemu);

static int agy_is_valid_release_tag(const char *tag) {
    if (tag == NULL || tag[0] == '\0' || tag[0] == '-') {
        return 0;
    }

    for (const unsigned char *cursor = (const unsigned char *)tag; *cursor != '\0'; cursor++) {
        if (!isalnum(*cursor) && *cursor != '.' && *cursor != '_' && *cursor != '-') {
            return 0;
        }
    }

    return 1;
}

static void print_update_usage(void) {
    printf("Usage: agy update [options]\n\n"
           "Options:\n"
           "  -y, --yes, --auto  Apply updates without prompting\n"
           "  -h, --help         Show this help message\n\n"
           "Environment:\n"
           "  AGY_AUTO_UPDATE=1  Apply updates without prompting\n");
}

static int should_perform_update(int auto_update) {
    if (auto_update) {
        printf("[agy-termux] Proceeding with automatic update (non-interactive)...\n");
        return 1;
    }

    if (!isatty(STDIN_FILENO)) {
        printf("[agy-termux] Error: standard input is not a TTY and auto-update is not enabled.\n");
        printf("[agy-termux] Run `agy update -y` or set AGY_AUTO_UPDATE=1 for non-interactive "
               "updates.\n");
        return 0;
    }

    for (;;) {
        printf("[agy-termux] Would you like to update now? [Y/n]: ");
        (void)fflush(stdout);

        char response_line[64] = {0};
        if (fgets(response_line, sizeof(response_line), stdin) == NULL) {
            return 0;
        }
        if (strchr(response_line, '\n') == NULL) {
            int ch = 0;
            while ((ch = getchar()) != '\n' && ch != EOF) {
            }
        }

        if (response_line[0] == '\n' || response_line[0] == '\0') {
            return 1;
        }
        if (response_line[0] == 'y' || response_line[0] == 'Y') {
            return 1;
        }
        if (response_line[0] == 'n' || response_line[0] == 'N') {
            return 0;
        }

        printf("[agy-termux] Invalid selection. Enter y or n.\n");
    }
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
    else
      mkdir -p "$CLI_BIN_DIR"
      install -m 0755 "$CLI_UPSTREAM_BIN" "$CLI_BIN_DIR/agy" || die "CLI: Failed to install agy"
    fi
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
    CLI_INSTALL_STATUS="failed"
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
    CLI_INSTALL_STATUS="success"
    return 0
  fi
}



# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL: ANTIGRAVITY IDE
# ══════════════════════════════════════════════════════════════════════════════
install_ide() {
  echo ""
  sep
  printf '%b%b❯Installing %s:Antigravity IDE%b\n' "${C}" "${B}" "${TASK_PROGRESS}" "${N}"
  sep

  local TARGET_DIR="$IDE_TARGET_DIR"
  local APPLICATIONS_DIR="$IDE_APPLICATIONS_DIR"
  local ICONS_DIR="$IDE_ICONS_DIR"
  local WRAPPER="$IDE_BIN_DIR/antigravity-ide"
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

  local IDE_ARCHIVE="${BUILD_DIR}/ide.tar.gz"

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

    local ver_info
    ver_info=$(fetch_aur_version "antigravity-ide")
    local ide_ver="${ver_info%%:*}"
    local ide_build="${ver_info#*:}"
    info "Latest IDE: v${ide_ver}-${ide_build}"

    # Remove old versions from cache
    for f in "$DOWNLOAD_CACHE_DIR"/ide_v*.tar.gz; do
      if [[ -e "$f" && "$(basename "$f")" != "ide_v${ide_ver}-${ide_build}.tar.gz" ]]; then
        info "Removing old IDE installer archive: $(basename "$f")"
        rm -f "$f"
      fi
    done

    IDE_ARCHIVE="${DOWNLOAD_CACHE_DIR}/ide_v${ide_ver}-${ide_build}.tar.gz"

    info "Downloading IDE archive..."
    download_file "https://dl.google.com/release2/j0qc3/antigravity/stable/${ide_ver}-${ide_build}/linux-arm/Antigravity%20IDE.tar.gz" "$IDE_ARCHIVE" || die "IDE: Download failed."
    info "Patching... (this may take longer)"
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
        mv "$ls_path" "${ls_path}.va39"
        python3 "${BUILD_DIR}/va39_patch.py" "${ls_path}.va39" "${ls_path}.va39" >/dev/null
        clang -O2 -DPATCHED_BIN_NAME="\"$ls_bin.va39\"" -o "$ls_path" "${BUILD_DIR}/ide_ls_helper.c"
        chmod 755 "$ls_path" "${ls_path}.va39"
      fi
    done

    # Create launcher wrapper script (symlink or script)
      mkdir -p "$IDE_BIN_DIR"
    local IDE_SCRIPT="$TARGET_DIR/bin/antigravity-ide"
    if [[ -f "$IDE_SCRIPT" ]]; then
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

    ok "IDE installed successfully → ${D}${WRAPPER}${N}"
    IDE_INSTALL_STATUS="success"
    return 0
  fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL: ANTIGRAVITY 2.0
# ══════════════════════════════════════════════════════════════════════════════
install_V2() {
  echo ""
  sep
  printf '%b%b❯Installing %s:Antigravity 2.0%b\n' "${C}" "${B}" "${TASK_PROGRESS}" "${N}"
  sep

  local TARGET_DIR="$V2_TARGET_DIR"
  local ICON_SRC="$TARGET_DIR/icon.png"
  local ICON_DST="$V2_ICONS_DIR/antigravity.png"
  local DESKTOP_FILE="$V2_APPLICATIONS_DIR/antigravity.desktop"
  local WRAPPER="$V2_BIN_DIR/antigravity"

  # Reset global flags
  V2_DIR_BAK=""
  V2_DIR_CREATED_FRESH=0
  V2_WRAPPER_BAK=""
  V2_WRAPPER_CREATED_FRESH=0
  V2_FILE_BAK=""
  V2_FILE_CREATED_FRESH=0
  V2_ICON_BAK=""
  V2_ICON_CREATED_FRESH=0

  local V2_ARCHIVE="${BUILD_DIR}/2.0.tar.gz"

  if [[ -d "$TARGET_DIR" ]]; then
    V2_DIR_BAK="${TARGET_DIR}.bak.$$"
  else
    V2_DIR_CREATED_FRESH=1
  fi

  if [[ -f "$WRAPPER" ]]; then
    V2_WRAPPER_BAK="${WRAPPER}.bak.$$"
  else
    V2_WRAPPER_CREATED_FRESH=1
  fi

  if [[ -f "$DESKTOP_FILE" ]]; then
    V2_FILE_BAK="${DESKTOP_FILE}.bak.$$"
  else
    V2_FILE_CREATED_FRESH=1
  fi

  if [[ -f "$ICON_DST" ]]; then
    V2_ICON_BAK="${ICON_DST}.bak.$$"
  else
    V2_ICON_CREATED_FRESH=1
  fi

  local status=0
  set +e
  (
    trap - EXIT
    set -e

    # Perform backups
    [[ -n "$V2_DIR_BAK" ]] && mv "$TARGET_DIR" "$V2_DIR_BAK"
    [[ -n "$V2_WRAPPER_BAK" ]] && mv "$WRAPPER" "$V2_WRAPPER_BAK"
    [[ -n "$V2_FILE_BAK" ]] && mv "$DESKTOP_FILE" "$V2_FILE_BAK"
    [[ -n "$V2_ICON_BAK" ]] && mv "$ICON_DST" "$V2_ICON_BAK"

    local ver_info
    ver_info=$(fetch_aur_version "antigravity")
    local desktop_ver="${ver_info%%:*}"
    local desktop_build="${ver_info#*:}"
    info "Latest 2.0: v${desktop_ver}-${desktop_build}"

    # Remove old versions from cache
    for f in "$DOWNLOAD_CACHE_DIR"/2.0_v*.tar.gz; do
      if [[ -e "$f" && "$(basename "$f")" != "2.0_v${desktop_ver}-${desktop_build}.tar.gz" ]]; then
        info "Removing old 2.0 installer archive: $(basename "$f")"
        rm -f "$f"
      fi
    done

    V2_ARCHIVE="${DOWNLOAD_CACHE_DIR}/2.0_v${desktop_ver}-${desktop_build}.tar.gz"

    info "Downloading 2.0 archive..."
    download_file "https://storage.googleapis.com/antigravity-public/antigravity-hub/${desktop_ver}-${desktop_build}/linux-arm/Antigravity.tar.gz" "$V2_ARCHIVE" || die "2.0: Download failed."
    info "Patching... (this may take longer)"
    extract_tar "$V2_ARCHIVE" "${BUILD_DIR}/desktop_extract" || die "2.0: Extraction failed."
    local SRC_DIR="${BUILD_DIR}/desktop_extract/Antigravity-arm64"
    [[ -d "$SRC_DIR" ]] || die "2.0: Antigravity-arm64 folder not found in archive."

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

    # Apply 2.0 Fix (VA39/Termux/PRoot)
    local APP_DIR="$TARGET_DIR"
    local BIN_DIR="$APP_DIR/resources/bin"
    local INTERPOSER_SO="$APP_DIR/libmmap_va39_fix.so"

    # 1. Backups
    [[ -f "$BIN_DIR/language_server" && ! -f "$BIN_DIR/language_server.orig" ]] && cp "$BIN_DIR/language_server" "$BIN_DIR/language_server.orig"

    # 2. Setup Interposer
    cp "${BUILD_DIR}/libmmap_va39_fix.so" "$INTERPOSER_SO"

    # 3. Surgical Patch for Language Server
    python3 "${BUILD_DIR}/va39_patch.py" "$BIN_DIR/language_server.orig" "$BIN_DIR/language_server" "0x060dc2e0" >/dev/null

    # 4. Create Wrapper
    mkdir -p "$V2_BIN_DIR"
    cat > "$WRAPPER" << EOF
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="$V2_TARGET_DIR"
INTERPOSER="\$APP_DIR/libmmap_va39_fix.so"
export LD_LIBRARY_PATH="/usr/lib/aarch64-linux-gnu:/lib/aarch64-linux-gnu:\$APP_DIR"
[[ -d "/data/data/com.termux/files/usr/bin" ]] && unset LD_PRELOAD
export LD_PRELOAD="\$INTERPOSER"
if [[ -f "/data/data/com.termux/files/usr/etc/tls/cert.pem" ]]; then
    export SSL_CERT_FILE="/data/data/com.termux/files/usr/etc/tls/cert.pem"
elif [[ -f "/etc/ssl/certs/ca-certificates.crt" ]]; then
    export SSL_CERT_FILE="/etc/ssl/certs/ca-certificates.crt"
fi
export LIBGL_ALWAYS_SOFTWARE=1
export ELECTRON_ENABLE_LOGGING=1
eval \$(gnome-keyring-daemon --start --components=secrets)
export DBUS_SESSION_BUS_ADDRESS
echo -n "" | gnome-keyring-daemon --unlock || true
exec "\$APP_DIR/antigravity" \\
    --no-sandbox --disable-gpu --disable-gpu-compositing \\
    --disable-gpu-rasterization --disable-dev-shm-usage \\
    --ignore-certificate-errors --remote-allow-origins=* "\$@"
EOF
    chmod +x "$WRAPPER"

    # Desktop entry
    mkdir -p "$(dirname "$DESKTOP_FILE")"
    cat > "$DESKTOP_FILE" <<DEOF
[Desktop Entry]
Name=Antigravity 2.0
Comment=Antigravity 2.0 Electron App
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
    if [[ -f "$V2_ARCHIVE" ]]; then
      warn "If the 2.0 archive is corrupted, please manually delete: $V2_ARCHIVE"
    fi

    # ROLLBACK:
    if [[ -n "$V2_DIR_BAK" && -d "$V2_DIR_BAK" ]]; then
      rm -rf "$TARGET_DIR"
      mv "$V2_DIR_BAK" "$TARGET_DIR"
    elif [[ "$V2_DIR_CREATED_FRESH" -eq 1 ]]; then
      rm -rf "$TARGET_DIR"
    fi

    if [[ -n "$V2_WRAPPER_BAK" && -f "$V2_WRAPPER_BAK" ]]; then
      rm -f "$WRAPPER"
      mv "$V2_WRAPPER_BAK" "$WRAPPER"
    elif [[ "$V2_WRAPPER_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$WRAPPER"
    fi

    if [[ -n "$V2_FILE_BAK" && -f "$V2_FILE_BAK" ]]; then
      rm -f "$DESKTOP_FILE"
      mv "$V2_FILE_BAK" "$DESKTOP_FILE"
    elif [[ "$V2_FILE_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$DESKTOP_FILE"
    fi

    if [[ -n "$V2_ICON_BAK" && -f "$V2_ICON_BAK" ]]; then
      rm -f "$ICON_DST"
      mv "$V2_ICON_BAK" "$ICON_DST"
    elif [[ "$V2_ICON_CREATED_FRESH" -eq 1 ]]; then
      rm -f "$ICON_DST"
    fi

    # Reset variables
    V2_DIR_BAK=""
    V2_DIR_CREATED_FRESH=0
    V2_WRAPPER_BAK=""
    V2_WRAPPER_CREATED_FRESH=0
    V2_FILE_BAK=""
    V2_FILE_CREATED_FRESH=0
    V2_ICON_BAK=""
    V2_ICON_CREATED_FRESH=0

    warn "2.0 installation failed."
    INSTALL_V2_STATUS="failed"
    return 1
  else
    # SUCCESS: clean backups
    [[ -n "$V2_DIR_BAK" && -d "$V2_DIR_BAK" ]] && rm -rf "$V2_DIR_BAK"
    [[ -n "$V2_WRAPPER_BAK" && -f "$V2_WRAPPER_BAK" ]] && rm -f "$V2_WRAPPER_BAK"
    [[ -n "$V2_FILE_BAK" && -f "$V2_FILE_BAK" ]] && rm -f "$V2_FILE_BAK"
    [[ -n "$V2_ICON_BAK" && -f "$V2_ICON_BAK" ]] && rm -f "$V2_ICON_BAK"

    # Reset variables
    V2_DIR_BAK=""
    V2_DIR_CREATED_FRESH=0
    V2_WRAPPER_BAK=""
    V2_WRAPPER_CREATED_FRESH=0
    V2_FILE_BAK=""
    V2_FILE_CREATED_FRESH=0
    V2_ICON_BAK=""
    V2_ICON_CREATED_FRESH=0

    ok "2.0 installed successfully → ${D}${WRAPPER}${N}"
    INSTALL_V2_STATUS="success"
    return 0
  fi
}

# ── Queue selected installs and run in strict order ───────────────────────────
QUEUE=()
[[ $RUN_CLI_INSTALL -eq 1 ]]     && QUEUE+=("cli")
[[ $RUN_IDE_INSTALL -eq 1 ]]     && QUEUE+=("ide")
[[ $RUN_V2_INSTALL -eq 1 ]]      && QUEUE+=("2.0")

TOTAL_TASKS=${#QUEUE[@]}
CURRENT_TASK=0

# Compile shared compatibility layer if needed
NEED_MMAP_COMPILATION=0
if [[ $RUN_IDE_INSTALL -eq 1 || $RUN_V2_INSTALL -eq 1 ]]; then
  NEED_MMAP_COMPILATION=1
fi

if [[ $NEED_MMAP_COMPILATION -eq 1 && $TOTAL_TASKS -gt 0 ]]; then
  clang -O2 -fPIC -shared -o "${BUILD_DIR}/libmmap_va39_fix.so" "${BUILD_DIR}/mmap_va39_fix.c" -ldl
fi

CLI_INSTALL_STATUS="skipped"
IDE_INSTALL_STATUS="skipped"
INSTALL_V2_STATUS="skipped"

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
    2.0)
      install_V2 || true
      ;;
  esac
done

# ── Final Summary ─────────────────────────────────────────────────────────────
ALL_SUCCESS=1
if [[ "$CLI_INSTALL_STATUS" == "failed" || "$IDE_INSTALL_STATUS" == "failed" || "$INSTALL_V2_STATUS" == "failed" ]]; then
  ALL_SUCCESS=0
fi

echo ""
sep
if [[ $ALL_SUCCESS -eq 1 ]]; then
  ok "${B}Installation completed successfully!${N}"
else
  warn "${B}Installation completed with errors.${N}"
fi

# Print status of each component
if [[ $RUN_CLI_INSTALL -eq 1 ]]; then
  if [[ "$CLI_INSTALL_STATUS" == "success" ]]; then
    ok "CLI: Installed successfully (${D}${CLI_BIN_DIR}/agy${N})"
  else
    err "CLI: Installation failed (reverted)"
  fi
fi

if [[ $RUN_IDE_INSTALL -eq 1 ]]; then
  if [[ "$IDE_INSTALL_STATUS" == "success" ]]; then
    ok "IDE: Installed successfully (${D}${IDE_BIN_DIR}/antigravity-ide${N})"
  else
    err "IDE: Installation failed (reverted)"
  fi
fi

if [[ $RUN_V2_INSTALL -eq 1 ]]; then
  if [[ "$INSTALL_V2_STATUS" == "success" ]]; then
    ok "2.0: Installed successfully (${D}${V2_BIN_DIR}/antigravity${N})"
  else
    err "2.0: Installation failed (reverted)"
  fi
fi

# Add PATH advice if anything succeeded
ANY_SUCCESS=0
[[ "$CLI_INSTALL_STATUS" == "success" ]] && ANY_SUCCESS=1
[[ "$IDE_INSTALL_STATUS" == "success" ]] && ANY_SUCCESS=1
[[ "$INSTALL_V2_STATUS" == "success" ]] && ANY_SUCCESS=1

if [[ $ANY_SUCCESS -eq 1 ]]; then
  # Gather unique bin dirs used in successful installations
  UNIQUE_BIN_DIRS=()
  [[ "$CLI_INSTALL_STATUS" == "success" ]] && UNIQUE_BIN_DIRS+=("$CLI_BIN_DIR")
  [[ "$IDE_INSTALL_STATUS" == "success" ]] && UNIQUE_BIN_DIRS+=("$IDE_BIN_DIR")
  [[ "$INSTALL_V2_STATUS" == "success" ]] && UNIQUE_BIN_DIRS+=("$V2_BIN_DIR")
  
  # Deduplicate
  DEDUPED_BIN_DIRS=($(echo "${UNIQUE_BIN_DIRS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
  
  for bdir in "${DEDUPED_BIN_DIRS[@]}"; do
    case ":$PATH:" in
      *":$bdir:"*) ;;
      *)
        printf '\n'
        warn "${B}${bdir}${N} is not in your PATH."
        info "Add to ~/.bashrc: ${B}export PATH=\"${bdir}:\$PATH\"${N}"
        ;;
    esac
  done
fi
echo ""
