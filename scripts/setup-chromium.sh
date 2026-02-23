#!/bin/bash
# setup-chromium.sh - Download and configure Chromium for VIDCOM
#
# This downloads a standalone Chromium build that can be:
# - Used for OAuth flows (launched to host display via X11)
# - Run headless for automated tasks
# - Used to view the dashboard with proper account context
#
# The chromium/ directory is gitignored - each user downloads their own.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CHROMIUM_DIR="$PROJECT_DIR/chromium"
USER_DATA_DIR="$PROJECT_DIR/.browser-data"

# Chromium for Testing (official builds from Google)
# https://googlechromelabs.github.io/chrome-for-testing/
CHROMIUM_VERSION="145.0.7632.26"
CHROMIUM_PLATFORM="linux64"
CHROMIUM_URL="https://storage.googleapis.com/chrome-for-testing-public/${CHROMIUM_VERSION}/${CHROMIUM_PLATFORM}/chrome-${CHROMIUM_PLATFORM}.zip"

log() { echo "[chromium] $*"; }
warn() { echo "[chromium] WARNING: $*" >&2; }
die() { echo "[chromium] ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [command] [options]

Commands:
  install       Download and install Chromium (default)
  uninstall     Remove Chromium and user data
  launch        Launch Chromium with isolated profile
  headless      Check headless mode works
  oauth         Open OAuth URL in Chromium
  dashboard     Open dashboard in Chromium
  status        Show installation status
  clean         Remove browser locks and session data (keeps logins)

Options:
  --display=DISPLAY   X11 display (default: \$DISPLAY or :0)
  --url=URL           URL to open (for oauth/launch)
  --headless          Run in headless mode
  --force             Force launch by clearing stale locks (container-safe)
  --help              Show this help

Examples:
  $(basename "$0") install
  $(basename "$0") launch --display=:0
  $(basename "$0") launch --force          # Clear stale locks first
  $(basename "$0") oauth --url="https://accounts.google.com/..."
  $(basename "$0") dashboard
  $(basename "$0") clean                   # Fix "profile in use" errors
EOF
}

#------------------------------------------------------------------------------
# Clear stale profile locks (safe in container environments)
# Note: Lock files are symlinks, so we use -L (or -h) instead of -e
#       because -e returns false for broken symlinks
#------------------------------------------------------------------------------
clear_profile_locks() {
    local force="${1:-false}"
    local lock_files=(
        "$USER_DATA_DIR/SingletonLock"
        "$USER_DATA_DIR/SingletonSocket"
        "$USER_DATA_DIR/SingletonCookie"
    )
    
    local found_locks=false
    for lock in "${lock_files[@]}"; do
        # Use -L to detect symlinks (locks are symlinks, often broken after container restart)
        if [[ -L "$lock" ]] || [[ -e "$lock" ]]; then
            found_locks=true
            break
        fi
    done
    
    if [[ "$found_locks" == "false" ]]; then
        return 0
    fi
    
    # Detect container/devcontainer environment where locks are always stale
    # after restart (no persistent Chrome process survives container rebuild)
    local in_container=false
    if [[ -f /.dockerenv ]] \
        || grep -q 'docker\|containerd' /proc/1/cgroup 2>/dev/null \
        || [[ -n "${REMOTE_CONTAINERS:-}" ]] \
        || [[ -n "${CODESPACES:-}" ]] \
        || [[ -d "/workspaces" ]] \
        || [[ -f /run/.containerenv ]]; then
        in_container=true
    fi
    
    if [[ "$force" == "true" ]] || [[ "$in_container" == "true" ]]; then
        log "Clearing stale profile locks..."
        for lock in "${lock_files[@]}"; do
            # Use -L to detect symlinks (even broken ones)
            if [[ -L "$lock" ]] || [[ -e "$lock" ]]; then
                rm -f "$lock"
                log "  Removed: $(basename "$lock")"
            fi
        done
        return 0
    else
        warn "Profile appears locked. Use --force to clear locks."
        warn "Lock files found in: $USER_DATA_DIR"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Set up Chrome preferences for VIDCOM use case
# - Disable password saving prompts
# - Set homepage to VIDCOM dashboard
# - Optimise for container/testing environment
#------------------------------------------------------------------------------
setup_chrome_preferences() {
    local prefs_dir="$USER_DATA_DIR/Default"
    local prefs_file="$prefs_dir/Preferences"
    
    mkdir -p "$prefs_dir"
    
    # Only create if doesn't exist (don't overwrite user customizations)
    if [[ ! -f "$prefs_file" ]]; then
        log "Initialising Chrome preferences for VIDCOM..."
        cat > "$prefs_file" << 'PREFS_EOF'
{
  "credentials_enable_service": false,
  "credentials_enable_autosignin": false,
  "profile": {
    "password_manager_enabled": false,
    "default_content_setting_values": {
      "notifications": 2,
      "geolocation": 2,
      "media_stream_mic": 2,
      "media_stream_camera": 2,
      "automatic_downloads": 2,
      "midi_sysex": 2,
      "push_messaging": 2,
      "ssl_cert_decisions": 2,
      "metro_switch_to_desktop": 2,
      "protected_media_identifier": 2,
      "ppapi_broker": 2,
      "site_engagement": 2,
      "durable_storage": 2,
      "usb_guard": 2,
      "bluetooth_guard": 2,
      "background_sync": 2,
      "sensors": 2,
      "clipboard": 2,
      "payment_handler": 2,
      "usb_chooser_data": 2,
      "file_system_write_guard": 2,
      "serial_guard": 2,
      "hid_guard": 2,
      "window_placement": 2,
      "local_fonts": 2,
      "idle_detection": 2
    },
    "content_settings": {
      "exceptions": {
        "cookies": {
          "*,*": {
            "setting": 1
          }
        }
      }
    },
    "block_third_party_cookies": true
  },
  "enable_do_not_track": true,
  "safebrowsing": {
    "enabled": true,
    "enhanced": false
  },
  "privacy_sandbox": {
    "m1": {
      "topics_enabled": false,
      "fledge_enabled": false,
      "ad_measurement_enabled": false
    },
    "anti_abuse_initialized": true
  },
  "savefile": {
    "default_directory": "/workspaces/vidcom/output"
  },
  "download": {
    "default_directory": "/workspaces/vidcom/output",
    "prompt_for_download": false
  },
  "browser": {
    "show_home_button": true,
    "check_default_browser": false,
    "custom_chrome_frame": false,
    "has_seen_welcome_page": true
  },
  "bookmark_bar": {
    "show_on_all_tabs": true
  },
  "session": {
    "restore_on_startup": 4,
    "startup_urls": [
      "http://localhost:8765"
    ]
  },
  "translate_blocked_languages": ["en"],
  "translate": {
    "enabled": false
  },
  "autofill": {
    "profile_enabled": false,
    "credit_card_enabled": false
  },
  "search": {
    "suggest_enabled": false
  },
  "alternate_error_pages": {
    "enabled": false
  },
  "dns_prefetching": {
    "enabled": false
  },
  "net": {
    "network_prediction_options": 2
  },
  "webkit": {
    "webprefs": {
      "hyperlink_auditing_enabled": false
    }
  },
  "hardware_acceleration_mode": {
    "enabled": false
  }
}
PREFS_EOF
    fi
    
    # Set up bookmarks for quick access
    local bookmarks_file="$prefs_dir/Bookmarks"
    if [[ ! -f "$bookmarks_file" ]]; then
        cat > "$bookmarks_file" << 'BOOKMARKS_EOF'
{
   "checksum": "vidcom_default",
   "roots": {
      "bookmark_bar": {
         "children": [
            {
               "name": "VIDCOM Dashboard",
               "type": "url",
               "url": "http://localhost:8765"
            },
            {
               "name": "YouTube Studio",
               "type": "url",
               "url": "https://studio.youtube.com"
            },
            {
               "name": "YouTube Uploads",
               "type": "url",
               "url": "https://www.youtube.com/my_videos"
            }
         ],
         "name": "Bookmarks bar",
         "type": "folder"
      },
      "other": {
         "children": [],
         "name": "Other bookmarks",
         "type": "folder"
      },
      "synced": {
         "children": [],
         "name": "Mobile bookmarks",
         "type": "folder"
      }
   },
   "version": 1
}
BOOKMARKS_EOF
    fi
}

cmd_clean() {
    log "Cleaning browser session data..."
    
    if [[ ! -d "$USER_DATA_DIR" ]]; then
        log "No browser data directory found."
        return 0
    fi
    
    # Remove lock files
    clear_profile_locks "true"
    
    # Remove crash reports and temp data (keeps logins/cookies)
    local clean_dirs=(
        "$USER_DATA_DIR/BrowserMetrics"
        "$USER_DATA_DIR/DeferredBrowserMetrics"
        "$USER_DATA_DIR/Crashpad"
        "$USER_DATA_DIR/ShaderCache"
        "$USER_DATA_DIR/GrShaderCache"
        "$USER_DATA_DIR/GPUCache"
    )
    
    for dir in "${clean_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            rm -rf "$dir"
            log "  Removed: $(basename "$dir")/"
        fi
    done
    
    log "Clean complete. Login data preserved."
    log ""
    log "TIP: To fully reset the browser profile, run:"
    log "     $0 uninstall"
}

get_chromium_path() {
    # Check various possible locations for chrome binary
    local candidates=(
        "$CHROMIUM_DIR/chrome-linux64/chrome"
        "$CHROMIUM_DIR/chrome-linux/chrome"
        "$CHROMIUM_DIR"/*/chrome
    )
    
    for candidate in "${candidates[@]}"; do
        # Handle glob expansion
        for path in $candidate; do
            if [[ -x "$path" ]]; then
                echo "$path"
                return 0
            fi
        done
    done
    
    # Fall back to system chromium
    if command -v chromium-browser &>/dev/null; then
        echo "chromium-browser"
    elif command -v chromium &>/dev/null; then
        echo "chromium"
    elif command -v google-chrome &>/dev/null; then
        echo "google-chrome"
    else
        echo ""
    fi
}

cmd_status() {
    log "Chromium Status:"
    
    local chrome_path
    chrome_path=$(get_chromium_path)
    
    if [[ -n "$chrome_path" ]]; then
        log "  Binary: $chrome_path"
        if [[ -x "$chrome_path" ]]; then
            local version
            version=$("$chrome_path" --version 2>/dev/null || echo "unknown")
            log "  Version: $version"
        fi
    else
        log "  Binary: NOT INSTALLED"
    fi
    
    if [[ -d "$USER_DATA_DIR" ]]; then
        local size
        size=$(du -sh "$USER_DATA_DIR" 2>/dev/null | cut -f1)
        log "  User data: $USER_DATA_DIR ($size)"
    else
        log "  User data: not created yet"
    fi
    
    if [[ -n "${DISPLAY:-}" ]]; then
        log "  Display: $DISPLAY"
    else
        log "  Display: not set (GUI won't work)"
    fi
}

cmd_install() {
    log "Installing Chromium for Testing v${CHROMIUM_VERSION}..."
    
    # Check if already installed
    if [[ -x "$CHROMIUM_DIR/chrome-linux64/chrome" ]]; then
        log "Chromium already installed at $CHROMIUM_DIR"
        cmd_status
        return 0
    fi
    
    # Create directory
    mkdir -p "$CHROMIUM_DIR"
    
    # Ensure unzip is available (small dep, easier than finding tar.xz builds)
    if ! command -v unzip &>/dev/null; then
        log "Installing unzip..."
        sudo apt-get update -qq && sudo apt-get install -y -qq unzip || die "Failed to install unzip"
    fi
    
    # Download
    local zip_file="$CHROMIUM_DIR/chrome.zip"
    log "Downloading from $CHROMIUM_URL..."
    curl -fSL --progress-bar "$CHROMIUM_URL" -o "$zip_file" || die "Download failed"
    
    # Extract
    log "Extracting..."
    unzip -q "$zip_file" -d "$CHROMIUM_DIR" || die "Extract failed"
    rm -f "$zip_file"
    
    # Find and normalise the chrome binary location
    # Different builds have different directory structures
    local chrome_path=""
    for candidate in \
        "$CHROMIUM_DIR/chrome-linux64/chrome" \
        "$CHROMIUM_DIR/chrome-linux/chrome" \
        "$CHROMIUM_DIR"/*/chrome; do
        if [[ -x "$candidate" ]]; then
            chrome_path="$candidate"
            break
        fi
    done
    if [[ ! -x "$chrome_path" ]]; then
        die "Installation failed - chrome binary not found"
    fi
    
    # Install dependencies (Chromium needs these)
    log "Checking dependencies..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
        libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 \
        libxfixes3 libxrandr2 libgbm1 libasound2 \
        libpango-1.0-0 libcairo2 2>/dev/null || warn "Some deps may be missing"
    
    log "Chromium installed successfully!"
    cmd_status
}

cmd_uninstall() {
    log "Removing Chromium..."
    
    if [[ -d "$CHROMIUM_DIR" ]]; then
        rm -rf "$CHROMIUM_DIR"
        log "Removed $CHROMIUM_DIR"
    fi
    
    read -p "Also remove browser user data? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$USER_DATA_DIR"
        log "Removed $USER_DATA_DIR"
    fi
    
    log "Done"
}

cmd_launch() {
    local url="${1:-}"
    local headless="${HEADLESS:-false}"
    local force="${FORCE:-false}"
    
    local chrome_path
    chrome_path=$(get_chromium_path)
    
    if [[ -z "$chrome_path" ]]; then
        die "Chromium not installed. Run: $0 install"
    fi
    
    # Create user data dir and initialise preferences
    mkdir -p "$USER_DATA_DIR"
    
    # Fix permissions: .config must be writable for Chrome crashpad handler
    if [[ -d "$HOME/.config" ]]; then
        sudo chmod 755 "$HOME/.config" 2>/dev/null || true
        sudo chown -R "$(whoami):$(id -gn)" "$HOME/.config/google-chrome-for-testing" 2>/dev/null || true
    fi
    
    # Fix ownership if Chrome was previously run as root
    if [[ -d "$USER_DATA_DIR" ]] && [[ ! -O "$USER_DATA_DIR" ]]; then
        log "Fixing browser data ownership..."
        sudo chown -R $(id -u):$(id -g) "$USER_DATA_DIR"
    fi
    
    setup_chrome_preferences
    
    # Clear stale locks if --force or in container
    if ! clear_profile_locks "$force"; then
        die "Profile locked. Try: $0 launch --force"
    fi
    
    # Detect display server (prefer Wayland if available)
    local display_type="x11"
    local display_info=""
    
    if [[ -n "${WAYLAND_DISPLAY:-}" ]] || [[ -S "${XDG_RUNTIME_DIR:-/run/user/1000}/wayland-0" ]]; then
        display_type="wayland"
        display_info="${WAYLAND_DISPLAY:-wayland-0}"
    elif [[ -n "${DISPLAY:-}" ]]; then
        display_type="x11"
        display_info="${DISPLAY}"
    else
        warn "No display detected. Trying Wayland anyway..."
        display_type="wayland"
    fi
    
    # Build args - optimised for container/devcontainer environments
    local args=(
        "--user-data-dir=$USER_DATA_DIR"
        "--no-first-run"
        "--no-default-browser-check"
        "--no-sandbox"
        "--disable-background-networking"
        "--disable-sync"
        "--disable-translate"
        # Disable password manager prompts (we use OAuth tokens, not saved passwords)
        "--password-store=basic"
        # Container-friendly: disable features that need D-Bus/dconf
        "--disable-features=PasswordManager,TranslateUI"
        "--disable-infobars"
        # Container-friendly: use shared memory alternatives
        "--disable-dev-shm-usage"
        # Suppress D-Bus errors (no system bus in containers)
        "--disable-dbus"
    )
    
    # Display server specific args
    if [[ "$display_type" == "wayland" ]]; then
        args+=(
            "--ozone-platform=wayland"
            "--enable-features=UseOzonePlatform"
        )
        # Ensure Wayland socket is accessible
        export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
    else
        export DISPLAY="${DISPLAY:-:0}"
    fi
    
    if [[ "$headless" == "true" ]]; then
        args+=("--headless=new")
    fi
    
    if [[ -n "$url" ]]; then
        args+=("$url")
    fi
    
    log "Launching Chromium..."
    log "  Display: $display_type ($display_info)"
    log "  Profile: $USER_DATA_DIR"
    [[ -n "$url" ]] && log "  URL: $url"
    
    "$chrome_path" "${args[@]}" 2>/dev/null &
}

cmd_oauth() {
    local url="${1:-}"
    
    if [[ -z "$url" ]]; then
        # Check if we have a pending OAuth URL
        local oauth_file="$HOME/.config/vidcom/oauth_url.txt"
        if [[ -f "$oauth_file" ]]; then
            url=$(cat "$oauth_file")
            rm -f "$oauth_file"
        else
            die "No URL provided. Usage: $0 oauth --url=<oauth_url>"
        fi
    fi
    
    log "Opening OAuth URL in Chromium..."
    cmd_launch "$url"
}

cmd_dashboard() {
    local port="${DASHBOARD_PORT:-8765}"
    local url="http://localhost:$port"
    
    log "Opening dashboard at $url"
    cmd_launch "$url"
}

cmd_headless() {
    log "Testing headless mode..."
    
    local chrome_path
    chrome_path=$(get_chromium_path)
    
    if [[ -z "$chrome_path" ]]; then
        die "Chromium not installed"
    fi
    
    mkdir -p "$USER_DATA_DIR"
    
    # Quick headless test
    local output
    output=$("$chrome_path" \
        --headless=new \
        --disable-gpu \
        --user-data-dir="$USER_DATA_DIR" \
        --dump-dom "data:text/html,<h1>VIDCOM Headless Test</h1>" 2>/dev/null)
    
    if echo "$output" | grep -q "VIDCOM Headless Test"; then
        log "✓ Headless mode working"
        return 0
    else
        warn "Headless mode may have issues"
        return 1
    fi
}

# Parse arguments
DISPLAY_OPT=""
URL_OPT=""
HEADLESS="false"
FORCE="false"
CMD="${1:-install}"

shift || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --display=*) DISPLAY_OPT="${1#*=}" ;;
        --url=*) URL_OPT="${1#*=}" ;;
        --headless) HEADLESS="true" ;;
        --force|-f) FORCE="true" ;;
        --help|-h) usage; exit 0 ;;
        *) URL_OPT="$1" ;;  # Assume it's a URL
    esac
    shift
done

[[ -n "$DISPLAY_OPT" ]] && export DISPLAY="$DISPLAY_OPT"

# Dispatch command
case "$CMD" in
    install)    cmd_install ;;
    uninstall)  cmd_uninstall ;;
    launch)     cmd_launch "$URL_OPT" ;;
    headless)   cmd_headless ;;
    oauth)      cmd_oauth "$URL_OPT" ;;
    dashboard)  cmd_dashboard ;;
    status)     cmd_status ;;
    clean)      cmd_clean ;;
    --help|-h)  usage ;;
    *)          die "Unknown command: $CMD" ;;
esac
