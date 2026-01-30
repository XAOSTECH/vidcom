#!/bin/bash
# yt-upload.sh - Upload video to YouTube using Data API v3
# Uses two-phase resumable upload protocol
#
# Usage:
#   ./yt-upload.sh video.mp4 "Title" "Description" "tag1,tag2" [category_id] [privacy]
#
# Category IDs:
#   20 = Gaming (default)
#   24 = Entertainment
#   22 = People & Blogs
#   28 = Science & Technology
#
# Privacy: public, unlisted, private (default: unlisted)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

#------------------------------------------------------------------------------
# Parse arguments
#------------------------------------------------------------------------------
if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <video_file> <title> <description> [tags] [category_id] [privacy]"
    echo ""
    echo "Arguments:"
    echo "  video_file   Path to video file (mp4, mov, etc.)"
    echo "  title        Video title (max 100 chars)"
    echo "  description  Video description (max 5000 chars)"
    echo "  tags         Comma-separated tags (optional)"
    echo "  category_id  YouTube category ID (default: 20=Gaming)"
    echo "  privacy      public, unlisted, private (default: unlisted)"
    echo ""
    echo "Category IDs:"
    echo "  20 = Gaming"
    echo "  24 = Entertainment"
    echo "  22 = People & Blogs"
    echo "  28 = Science & Technology"
    echo ""
    echo "Example:"
    echo "  $0 highlight.mp4 \"Epic Gaming Moment\" \"Check out this play!\" \"gaming,highlights\" 20 unlisted"
    exit 1
fi

VIDEO_FILE="$1"
TITLE="$2"
DESCRIPTION="$3"
TAGS="${4:-}"
CATEGORY_ID="${5:-20}"
PRIVACY="${6:-unlisted}"

# Validate inputs
if [[ ! -f "$VIDEO_FILE" ]]; then
    log_error "Video file not found: $VIDEO_FILE"
    exit 1
fi

FILE_SIZE=$(stat -c%s "$VIDEO_FILE")
if (( FILE_SIZE == 0 )); then
    log_error "Video file is empty"
    exit 1
fi

# Check title length (max 100 chars)
if (( ${#TITLE} > 100 )); then
    log_warn "Title truncated to 100 characters"
    TITLE="${TITLE:0:100}"
fi

# Validate privacy setting
case "$PRIVACY" in
    public|unlisted|private) ;;
    *)
        log_error "Invalid privacy setting: $PRIVACY"
        log_error "Must be: public, unlisted, or private"
        exit 1
        ;;
esac

#------------------------------------------------------------------------------
# Get access token
#------------------------------------------------------------------------------
log_step "Authenticating..."
ACCESS_TOKEN=$("$SCRIPT_DIR/yt-auth.sh")

if [[ -z "$ACCESS_TOKEN" ]]; then
    log_error "Failed to get access token"
    log_error "Run: $SCRIPT_DIR/yt-auth.sh --setup"
    exit 1
fi

#------------------------------------------------------------------------------
# Build metadata JSON
#------------------------------------------------------------------------------
log_step "Preparing metadata..."

# Build tags array
TAGS_JSON="[]"
if [[ -n "$TAGS" ]]; then
    # Convert comma-separated to JSON array
    TAGS_JSON=$(echo "$TAGS" | tr ',' '\n' | jq -R . | jq -s .)
fi

# Escape special characters in description
DESCRIPTION_ESCAPED=$(echo "$DESCRIPTION" | jq -Rs .)

METADATA=$(jq -n \
    --arg title "$TITLE" \
    --argjson description "$DESCRIPTION_ESCAPED" \
    --argjson tags "$TAGS_JSON" \
    --arg categoryId "$CATEGORY_ID" \
    --arg privacy "$PRIVACY" \
    '{
        snippet: {
            title: $title,
            description: ($description | fromjson),
            tags: $tags,
            categoryId: $categoryId
        },
        status: {
            privacyStatus: $privacy,
            selfDeclaredMadeForKids: false,
            embeddable: true,
            publicStatsViewable: true
        }
    }')

log_info "Title: $TITLE"
log_info "Category: $CATEGORY_ID"
log_info "Privacy: $PRIVACY"
log_info "File: $VIDEO_FILE ($(numfmt --to=iec $FILE_SIZE))"

#------------------------------------------------------------------------------
# Phase 1: Initialize resumable upload
#------------------------------------------------------------------------------
log_step "Phase 1: Requesting upload URL..."

# Detect mime type
MIME_TYPE=$(file -b --mime-type "$VIDEO_FILE")
case "$MIME_TYPE" in
    video/*) ;;
    application/octet-stream)
        # Try to determine from extension
        case "${VIDEO_FILE##*.}" in
            mp4|m4v)  MIME_TYPE="video/mp4" ;;
            mov)      MIME_TYPE="video/quicktime" ;;
            avi)      MIME_TYPE="video/x-msvideo" ;;
            mkv)      MIME_TYPE="video/x-matroska" ;;
            webm)     MIME_TYPE="video/webm" ;;
            *)        MIME_TYPE="video/mp4" ;;
        esac
        ;;
esac
log_info "MIME type: $MIME_TYPE"

# Request upload URL
HEADERS_FILE=$(mktemp)
trap "rm -f $HEADERS_FILE" EXIT

HTTP_CODE=$(curl -s -X POST \
    "https://www.googleapis.com/upload/youtube/v3/videos?part=snippet,status&uploadType=resumable&notifySubscribers=false" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json; charset=UTF-8" \
    -H "X-Upload-Content-Type: $MIME_TYPE" \
    -H "X-Upload-Content-Length: $FILE_SIZE" \
    -d "$METADATA" \
    -D "$HEADERS_FILE" \
    -o /dev/null \
    -w "%{http_code}")

if [[ "$HTTP_CODE" != "200" ]]; then
    log_error "Failed to initiate upload (HTTP $HTTP_CODE)"
    cat "$HEADERS_FILE" >&2
    exit 1
fi

# Extract upload URL from Location header
UPLOAD_URL=$(grep -i "^location:" "$HEADERS_FILE" | cut -d' ' -f2 | tr -d '\r\n')

if [[ -z "$UPLOAD_URL" ]]; then
    log_error "No upload URL in response"
    cat "$HEADERS_FILE" >&2
    exit 1
fi

log_info "Upload URL obtained"

#------------------------------------------------------------------------------
# Phase 2: Upload video binary with retry logic
#------------------------------------------------------------------------------
log_step "Phase 2: Uploading video..."

MAX_RETRIES=10
RETRY=0
BACKOFF=1

while (( RETRY < MAX_RETRIES )); do
    # Upload with progress
    RESPONSE=$(curl -X PUT "$UPLOAD_URL" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: $MIME_TYPE" \
        -H "Content-Length: $FILE_SIZE" \
        --data-binary "@$VIDEO_FILE" \
        --progress-bar \
        -w "\n%{http_code}" \
        2>&1)
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    
    case "$HTTP_CODE" in
        200|201)
            # Success!
            VIDEO_ID=$(echo "$BODY" | jq -r '.id // empty')
            if [[ -n "$VIDEO_ID" ]]; then
                echo ""
                log_info "Upload successful!"
                echo ""
                echo -e "${GREEN}Video ID:${NC} $VIDEO_ID"
                echo -e "${GREEN}URL:${NC} https://youtu.be/$VIDEO_ID"
                echo -e "${GREEN}Studio:${NC} https://studio.youtube.com/video/$VIDEO_ID/edit"
                echo ""
                
                # Notify dashboard if script exists
                local DASHBOARD_SCRIPT="$SCRIPT_DIR/dashboard.sh"
                if [[ -x "$DASHBOARD_SCRIPT" ]]; then
                    local DURATION=$(ffprobe -v error -show_entries format=duration \
                        -of default=noprint_wrappers=1:nokey=1 "$VIDEO_FILE" 2>/dev/null | cut -d. -f1 || echo "0")
                    "$DASHBOARD_SCRIPT" add-upload "$VIDEO_ID" "$TITLE" "Gaming" "$DURATION" 2>/dev/null || true
                fi
                
                # Output JSON for scripting
                echo "$BODY" | jq '{
                    id: .id,
                    title: .snippet.title,
                    url: ("https://youtu.be/" + .id),
                    privacy: .status.privacyStatus,
                    uploadStatus: .status.uploadStatus
                }'
                exit 0
            else
                log_error "Upload completed but no video ID in response"
                echo "$BODY" >&2
                exit 1
            fi
            ;;
        308)
            # Resume incomplete - not implemented in basic upload
            log_warn "Partial upload (308) - retrying full upload..."
            ;;
        400|401|403)
            # Client error - don't retry
            log_error "Upload failed (HTTP $HTTP_CODE)"
            echo "$BODY" | jq -r '.error.message // .' >&2
            exit 1
            ;;
        404)
            log_error "Upload URL expired or invalid (HTTP 404)"
            log_error "Please try again from the beginning"
            exit 1
            ;;
        5*)
            # Server error - retry with backoff
            RETRY=$((RETRY + 1))
            log_warn "Server error ($HTTP_CODE), retry $RETRY/$MAX_RETRIES in ${BACKOFF}s..."
            sleep "$BACKOFF"
            BACKOFF=$((BACKOFF * 2))
            if (( BACKOFF > 64 )); then BACKOFF=64; fi
            ;;
        *)
            log_error "Unexpected response (HTTP $HTTP_CODE)"
            echo "$BODY" >&2
            exit 1
            ;;
    esac
done

log_error "Max retries ($MAX_RETRIES) exceeded"
exit 1
