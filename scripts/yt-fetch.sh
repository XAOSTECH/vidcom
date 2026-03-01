#!/bin/bash
# yt-fetch.sh - Fetch videos from YouTube playlist via API v3
# Downloads video info and optionally the video files
#
# Usage:
#   ./yt-fetch.sh list <playlist_id>              # List videos in playlist
#   ./yt-fetch.sh download <video_id> [output]    # Download a video
#   ./yt-fetch.sh playlist <playlist_id> [limit]  # Download all from playlist
#
# Requires: YouTube OAuth token (run yt-auth.sh --setup first)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Database for tracking processed videos
PROCESSED_DB="${PROJECT_DIR}/models/processed.db"

# Browser data directory (matches setup-chromium.sh)
BROWSER_DATA_DIR="${PROJECT_DIR}/.browser-data"
COOKIES_FILE="${PROJECT_DIR}/.browser-data/cookies.txt"

# Chromium binary location
CHROMIUM_BIN="${PROJECT_DIR}/chromium/chrome-linux64/chrome"

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

#------------------------------------------------------------------------------
# Initialise processed videos database
#------------------------------------------------------------------------------
init_db() {
    if [[ ! -f "$PROCESSED_DB" ]]; then
        log_info "Creating processed videos database..."
        cat > "$PROCESSED_DB" << 'EOF'
# VIDCOM Processed Videos Database
# Format: VIDEO_ID|STATUS|PROCESSED_AT|OUTPUT_FILE|UPLOAD_ID
# STATUS: pending, downloaded, processed, uploaded, error
EOF
    fi
}

#------------------------------------------------------------------------------
# Check if video was already processed
#------------------------------------------------------------------------------
is_processed() {
    local video_id="$1"
    local status="${2:-}"  # Optional: check specific status
    
    if [[ ! -f "$PROCESSED_DB" ]]; then
        return 1
    fi
    
    if [[ -n "$status" ]]; then
        grep -q "^${video_id}|${status}|" "$PROCESSED_DB" 2>/dev/null
    else
        grep -q "^${video_id}|" "$PROCESSED_DB" 2>/dev/null
    fi
}

#------------------------------------------------------------------------------
# Mark video as processed
#------------------------------------------------------------------------------
mark_processed() {
    local video_id="$1"
    local status="$2"
    local output_file="${3:-}"
    local upload_id="${4:-}"
    local timestamp=$(date -Iseconds)
    
    init_db
    
    # Remove existing entry if any
    if is_processed "$video_id"; then
        sed -i "/^${video_id}|/d" "$PROCESSED_DB"
    fi
    
    # Add new entry
    echo "${video_id}|${status}|${timestamp}|${output_file}|${upload_id}" >> "$PROCESSED_DB"
}

#------------------------------------------------------------------------------
# Get access token
#------------------------------------------------------------------------------
get_token() {
    "$SCRIPT_DIR/yt-auth.sh" 2>/dev/null
}

#------------------------------------------------------------------------------
# List videos in a playlist
#------------------------------------------------------------------------------
cmd_list() {
    local playlist_id="$1"
    local max_results="${2:-50}"
    
    log_step "Fetching playlist: $playlist_id"
    
    local token=$(get_token)
    if [[ -z "$token" ]]; then
        log_error "Failed to get access token. Run: ./yt-auth.sh --setup"
        exit 1
    fi
    
    local response=$(curl -s \
        -H "Authorization: Bearer $token" \
        "https://www.googleapis.com/youtube/v3/playlistItems?part=snippet,contentDetails&playlistId=${playlist_id}&maxResults=${max_results}")
    
    # Check for errors
    local error=$(echo "$response" | jq -r '.error.message // empty')
    if [[ -n "$error" ]]; then
        log_error "API Error: $error"
        exit 1
    fi
    
    # Output as JSON for piping
    echo "$response" | jq -r '.items[] | {
        videoId: .contentDetails.videoId,
        title: .snippet.title,
        publishedAt: .snippet.publishedAt,
        channelTitle: .snippet.channelTitle,
        description: (.snippet.description | split("\n")[0])
    }'
}

#------------------------------------------------------------------------------
# Get video details
#------------------------------------------------------------------------------
cmd_info() {
    local video_id="$1"
    
    local token=$(get_token)
    if [[ -z "$token" ]]; then
        log_error "Failed to get access token"
        exit 1
    fi
    
    curl -s \
        -H "Authorization: Bearer $token" \
        "https://www.googleapis.com/youtube/v3/videos?part=snippet,contentDetails,statistics&id=${video_id}" \
        | jq '.items[0]'
}

#------------------------------------------------------------------------------
# Download video using yt-dlp (falls back to API for metadata only)
#------------------------------------------------------------------------------
cmd_download() {
    local video_id="$1"
    local output_dir="${2:-${PROJECT_DIR}/output/source}"
    
    # Check if already processed
    if is_processed "$video_id" "downloaded"; then
        log_warn "Video $video_id already downloaded, skipping"
        return 0
    fi
    
    mkdir -p "$output_dir"
    
    log_step "Downloading video: $video_id"
    
    # Try yt-dlp first (better quality options)
    if command -v yt-dlp &>/dev/null; then
        local output_file="${output_dir}/${video_id}.mp4"
        
        # Build cookie args
        # yt-dlp can decrypt Chrome cookies if browser profile is available
        local cookie_args=""
        if [[ -f "$COOKIES_FILE" ]] && [[ -s "$COOKIES_FILE" ]]; then
            cookie_args="--cookies $COOKIES_FILE"
            log_info "Using cookies from: $COOKIES_FILE"
        elif [[ -d "$BROWSER_DATA_DIR/Default" ]]; then
            # Use yt-dlp's built-in Chrome cookie decryption
            # Specify the profile directory explicitly
            cookie_args="--cookies-from-browser chrome:$BROWSER_DATA_DIR"
            log_info "Using browser profile: $BROWSER_DATA_DIR"
        fi
        
        # Try download - for your own unlisted videos, may need authentication
        if yt-dlp \
            --format "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/best[height<=1080][ext=mp4]/best" \
            --merge-output-format mp4 \
            --output "$output_file" \
            --no-playlist \
            --no-warnings \
            $cookie_args \
            "https://www.youtube.com/watch?v=${video_id}" 2>&1; then
            
            if [[ -f "$output_file" ]]; then
                mark_processed "$video_id" "downloaded" "$output_file"
                log_info "Downloaded: $output_file"
                echo "$output_file"
                return 0
            fi
        fi
        
        # Fallback: try without cookies (works for public videos)
        log_warn "Trying without cookies..."
        if yt-dlp \
            --format "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/best[height<=1080][ext=mp4]/best" \
            --merge-output-format mp4 \
            --output "$output_file" \
            --no-playlist \
            "https://www.youtube.com/watch?v=${video_id}" 2>&1; then
            
            if [[ -f "$output_file" ]]; then
                mark_processed "$video_id" "downloaded" "$output_file"
                log_info "Downloaded: $output_file"
                echo "$output_file"
                return 0
            fi
        fi
    fi
    
    # Fallback: use API to get stream URL (limited, may not work for all videos)
    log_warn "yt-dlp not available or failed. Install with: pip install yt-dlp"
    log_warn "For your own videos, you may need to use YouTube Studio download."
    
    mark_processed "$video_id" "error" "" ""
    return 1
}

#------------------------------------------------------------------------------
# Process entire playlist
#------------------------------------------------------------------------------
cmd_playlist() {
    local playlist_id="$1"
    local limit="${2:-10}"
    local download="${3:-false}"
    
    log_step "Processing playlist: $playlist_id (limit: $limit)"
    
    init_db
    
    local token=$(get_token)
    local page_token=""
    local processed=0
    local skipped=0
    
    while [[ $processed -lt $limit ]]; do
        local url="https://www.googleapis.com/youtube/v3/playlistItems?part=snippet,contentDetails&playlistId=${playlist_id}&maxResults=50"
        [[ -n "$page_token" ]] && url+="&pageToken=${page_token}"
        
        local response=$(curl -s -H "Authorisation: Bearer $token" "$url")
        
        local error=$(echo "$response" | jq -r '.error.message // empty')
        if [[ -n "$error" ]]; then
            log_error "API Error: $error"
            exit 1
        fi
        
        # Process each video
        while read -r video_id title; do
            if [[ $processed -ge $limit ]]; then
                break
            fi
            
            if is_processed "$video_id"; then
                log_info "Skipping (already processed): $title"
                ((skipped++))
                continue
            fi
            
            echo ""
            log_info "Video $((processed + 1))/$limit: $title"
            log_info "  ID: $video_id"
            
            if [[ "$download" == "true" ]]; then
                cmd_download "$video_id" || true
            else
                mark_processed "$video_id" "pending"
            fi
            
            ((processed++))
        done < <(echo "$response" | jq -r '.items[] | "\(.contentDetails.videoId)\t\(.snippet.title)"')
        
        # Check for next page
        page_token=$(echo "$response" | jq -r '.nextPageToken // empty')
        if [[ -z "$page_token" ]]; then
            break
        fi
    done
    
    echo ""
    log_info "Processed: $processed videos, Skipped: $skipped (already processed)"
}

#------------------------------------------------------------------------------
# Show processed videos status
#------------------------------------------------------------------------------
cmd_status() {
    init_db
    
    echo "=== Processed Videos Status ==="
    echo ""
    
    local total=$(grep -c "^[^#]" "$PROCESSED_DB" 2>/dev/null || echo 0)
    local pending=$(grep -c "|pending|" "$PROCESSED_DB" 2>/dev/null || echo 0)
    local downloaded=$(grep -c "|downloaded|" "$PROCESSED_DB" 2>/dev/null || echo 0)
    local processed=$(grep -c "|processed|" "$PROCESSED_DB" 2>/dev/null || echo 0)
    local uploaded=$(grep -c "|uploaded|" "$PROCESSED_DB" 2>/dev/null || echo 0)
    local errors=$(grep -c "|error|" "$PROCESSED_DB" 2>/dev/null || echo 0)
    
    echo "Total:      $total"
    echo "Pending:    $pending"
    echo "Downloaded: $downloaded"
    echo "Processed:  $processed"
    echo "Uploaded:   $uploaded"
    echo "Errors:     $errors"
    echo ""
    echo "Database: $PROCESSED_DB"
}

#------------------------------------------------------------------------------
# Reset a video's status
#------------------------------------------------------------------------------
cmd_reset() {
    local video_id="$1"
    
    if [[ -f "$PROCESSED_DB" ]]; then
        sed -i "/^${video_id}|/d" "$PROCESSED_DB"
        log_info "Reset status for: $video_id"
    fi
}

#------------------------------------------------------------------------------
# Export cookies from browser profile to Netscape format
#------------------------------------------------------------------------------
cmd_export_cookies() {
    log_step "Exporting cookies from browser profile..."
    
    local cookies_db="$BROWSER_DATA_DIR/Default/Cookies"
    
    if [[ ! -f "$cookies_db" ]]; then
        log_error "Browser cookies database not found: $cookies_db"
        log_info "Run: ./scripts/setup-chromium.sh launch"
        log_info "Then log into YouTube and try again."
        exit 1
    fi
    
    # Check if sqlite3 is available
    if ! command -v sqlite3 &>/dev/null; then
        log_error "sqlite3 not found. Install with: sudo apt install sqlite3"
        exit 1
    fi
    
    # Export YouTube cookies to Netscape format
    log_info "Extracting YouTube cookies..."
    
    # Create temporary copy (Chromium may have it locked)
    local tmp_db=$(mktemp)
    cp "$cookies_db" "$tmp_db"
    
    # Write Netscape cookie header
    echo "# Netscape HTTP Cookie File" > "$COOKIES_FILE"
    echo "# Exported by vidcom yt-fetch.sh" >> "$COOKIES_FILE"
    echo "" >> "$COOKIES_FILE"
    
    # Extract cookies for youtube.com and google.com (for auth)
    # Netscape format: domain, domain_initial_dot, path, secure, expires, name, value
    # domain_initial_dot must be TRUE if domain starts with dot
    sqlite3 -separator $'\t' "$tmp_db" "
        SELECT 
            host_key,
            CASE WHEN host_key LIKE '.%' THEN 'TRUE' ELSE 'FALSE' END,
            path,
            CASE WHEN is_secure THEN 'TRUE' ELSE 'FALSE' END,
            CAST((expires_utc / 1000000 - 11644473600) AS INTEGER),
            name,
            value
        FROM cookies
        WHERE (host_key LIKE '%youtube.com' 
           OR host_key LIKE '%google.com'
           OR host_key LIKE '%googlevideo.com')
           AND value != ''
        ORDER BY host_key, name;
    " 2>/dev/null >> "$COOKIES_FILE" || {
        log_error "Failed to extract cookies from database"
        rm -f "$tmp_db"
        exit 1
    }
    
    rm -f "$tmp_db"
    
    local count=$(grep -c $'\t' "$COOKIES_FILE" 2>/dev/null || echo 0)
    log_info "Exported $count cookies to: $COOKIES_FILE"
    
    if [[ $count -eq 0 ]]; then
        log_warn "No cookies found. Make sure you're logged into YouTube in Chromium."
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
usage() {
    cat << EOF
Usage: $(basename "$0") <command> [options]

Commands:
  list <playlist_id> [limit]      List videos in playlist (JSON output)
  info <video_id>                 Get detailed info for a video
  download <video_id> [outdir]    Download a single video
  playlist <playlist_id> [limit]  Process playlist (marks as pending)
  playlist <playlist_id> [limit] --download  Download all from playlist
  status                          Show processed videos status
  reset <video_id>                Reset a video's processed status
  export-cookies                  Export browser cookies for yt-dlp

Examples:
  $(basename "$0") list PLxxxxxx                    # List playlist contents
  $(basename "$0") playlist PLxxxxxx 5              # Mark 5 videos as pending
  $(basename "$0") playlist PLxxxxxx 5 --download   # Download 5 videos
  $(basename "$0") download dQw4w9WgXcQ             # Download single video
  $(basename "$0") export-cookies                   # Export YouTube cookies
  $(basename "$0") status                           # Show processing status

Environment:
  Videos are tracked in: $PROCESSED_DB
  Downloads go to: $PROJECT_DIR/output/source/
  Cookies file: $COOKIES_FILE
EOF
}

main() {
    case "${1:-}" in
        list)
            [[ -z "${2:-}" ]] && { log_error "Playlist ID required"; exit 1; }
            cmd_list "$2" "${3:-50}"
            ;;
        info)
            [[ -z "${2:-}" ]] && { log_error "Video ID required"; exit 1; }
            cmd_info "$2"
            ;;
        download)
            [[ -z "${2:-}" ]] && { log_error "Video ID required"; exit 1; }
            cmd_download "$2" "${3:-}"
            ;;
        playlist)
            [[ -z "${2:-}" ]] && { log_error "Playlist ID required"; exit 1; }
            local download="false"
            [[ "${4:-}" == "--download" ]] && download="true"
            cmd_playlist "$2" "${3:-10}" "$download"
            ;;
        status)
            cmd_status
            ;;
        reset)
            [[ -z "${2:-}" ]] && { log_error "Video ID required"; exit 1; }
            cmd_reset "$2"
            ;;
        export-cookies)
            cmd_export_cookies
            ;;
        --help|-h|help|"")
            usage
            ;;
        *)
            log_error "Unknown command: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
