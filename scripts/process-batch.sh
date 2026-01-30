#!/bin/bash
# process-batch.sh - Batch process highlights to YouTube Shorts
# Reads a manifest file with highlight timestamps and metadata
#
# Manifest format (JSON lines):
# {"input": "stream.mp4", "start": "01:23:45", "duration": 55, "title": "Epic Moment", "tags": "gaming,highlights"}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

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

# Defaults
OUTPUT_DIR="${PROJECT_DIR}/output"
UPLOAD=false
DRY_RUN=false
CATEGORY_ID=20
PRIVACY="unlisted"

#------------------------------------------------------------------------------
# Parse arguments
#------------------------------------------------------------------------------
usage() {
    echo "Usage: $0 <manifest.jsonl> [options]"
    echo ""
    echo "Options:"
    echo "  --output DIR     Output directory (default: ./output)"
    echo "  --upload         Upload to YouTube after encoding"
    echo "  --dry-run        Show what would be done without executing"
    echo "  --category ID    YouTube category (default: 20=Gaming)"
    echo "  --privacy P      Privacy setting (default: unlisted)"
    echo "  --help           Show this help"
    echo ""
    echo "Manifest format (JSON Lines):"
    echo '  {"input": "stream.mp4", "start": "01:23:45", "duration": 55, "title": "Title", "description": "Desc", "tags": "tag1,tag2"}'
    echo ""
    echo "Example:"
    echo "  $0 highlights.jsonl --upload --privacy public"
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

MANIFEST="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --upload)
            UPLOAD=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --category)
            CATEGORY_ID="$2"
            shift 2
            ;;
        --privacy)
            PRIVACY="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

#------------------------------------------------------------------------------
# Validate manifest
#------------------------------------------------------------------------------
if [[ ! -f "$MANIFEST" ]]; then
    log_error "Manifest file not found: $MANIFEST"
    exit 1
fi

TOTAL=$(wc -l < "$MANIFEST")
log_info "Processing $TOTAL highlight(s) from $MANIFEST"

mkdir -p "$OUTPUT_DIR"

#------------------------------------------------------------------------------
# Process each highlight
#------------------------------------------------------------------------------
PROCESSED=0
FAILED=0
UPLOADED=0

while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip empty lines and comments
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue
    
    PROCESSED=$((PROCESSED + 1))
    
    # Parse JSON
    INPUT=$(echo "$line" | jq -r '.input')
    START=$(echo "$line" | jq -r '.start')
    DURATION=$(echo "$line" | jq -r '.duration // 60')
    TITLE=$(echo "$line" | jq -r '.title // "Untitled"')
    DESCRIPTION=$(echo "$line" | jq -r '.description // ""')
    TAGS=$(echo "$line" | jq -r '.tags // ""')
    FOCUS=$(echo "$line" | jq -r '.focus // "center"')
    
    # Generate output filename
    SAFE_TITLE=$(echo "$TITLE" | tr -cs '[:alnum:]' '_' | head -c 50)
    OUTPUT_FILE="${OUTPUT_DIR}/short_$(printf '%03d' $PROCESSED)_${SAFE_TITLE}.mp4"
    
    echo ""
    log_step "[$PROCESSED/$TOTAL] $TITLE"
    log_info "  Input: $INPUT"
    log_info "  Segment: $START for ${DURATION}s"
    log_info "  Output: $OUTPUT_FILE"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "  [DRY RUN] Would encode and upload"
        continue
    fi
    
    # Validate input exists
    if [[ ! -f "$INPUT" ]]; then
        log_error "  Input file not found: $INPUT"
        FAILED=$((FAILED + 1))
        continue
    fi
    
    # Encode
    if ! "$SCRIPT_DIR/encode-short.sh" "$INPUT" "$OUTPUT_FILE" "$START" "$DURATION" --focus "$FOCUS"; then
        log_error "  Encoding failed"
        FAILED=$((FAILED + 1))
        continue
    fi
    
    # Upload if requested
    if [[ "$UPLOAD" == "true" ]]; then
        log_info "  Uploading to YouTube..."
        
        if "$SCRIPT_DIR/yt-upload.sh" "$OUTPUT_FILE" "$TITLE" "$DESCRIPTION" "$TAGS" "$CATEGORY_ID" "$PRIVACY"; then
            UPLOADED=$((UPLOADED + 1))
            log_info "  Upload successful"
        else
            log_error "  Upload failed"
            # Don't count as failed encoding
        fi
        
        # Rate limit: wait between uploads
        if (( PROCESSED < TOTAL )); then
            log_info "  Waiting 30s before next upload..."
            sleep 30
        fi
    fi
    
done < "$MANIFEST"

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "Batch Processing Complete"
echo "=========================================="
echo "Total:    $TOTAL"
echo "Encoded:  $((PROCESSED - FAILED))"
echo "Failed:   $FAILED"
if [[ "$UPLOAD" == "true" ]]; then
    echo "Uploaded: $UPLOADED"
fi
echo ""
log_info "Output directory: $OUTPUT_DIR"

if (( FAILED > 0 )); then
    exit 1
fi
