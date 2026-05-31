#!/bin/bash
# process-batch.sh - Batch process highlights to YouTube Shorts
# 
# Two modes:
#   1. Manual: Reads a manifest file with highlight timestamps
#   2. Auto: Uses vidcom highlight detection to find highlights
#
# Manifest format (JSON lines):
# {"input": "stream.mp4", "start": "01:23:45", "duration": 55, "title": "Epic Moment", "tags": "gaming,highlights"}

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VIDCOM="${PROJECT_DIR}/build/vidcom"

# Colours
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
AUTO_DETECT=false
GAME=""
CONFIDENCE=0.5
MAX_CLIPS=10

#------------------------------------------------------------------------------
# Parse arguments
#------------------------------------------------------------------------------
usage() {
    echo "Usage: $0 <manifest.jsonl|video.mp4> [options]"
    echo ""
    echo "Modes:"
    echo "  Manifest mode: Process predefined highlight timestamps from JSONL"
    echo "  Auto mode:     Use --auto to detect highlights automatically"
    echo ""
    echo "Options:"
    echo "  --auto           Auto-detect highlights using vidcom"
    echo "  --game NAME      Game type for detection (fortnite, valorant, etc.)"
    echo "  --confidence N   Detection threshold 0.0-1.0 (default: 0.5)"
    echo "  --max-clips N    Maximum clips to generate (default: 10)"
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
    echo "Examples:"
    echo "  $0 highlights.jsonl --upload --privacy public"
    echo "  $0 stream.mp4 --auto --game fortnite --max-clips 5"
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

MANIFEST="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)
            AUTO_DETECT=true
            shift
            ;;
        --game)
            GAME="$2"
            shift 2
            ;;
        --confidence)
            CONFIDENCE="$2"
            shift 2
            ;;
        --max-clips)
            MAX_CLIPS="$2"
            shift 2
            ;;
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
# Auto-detect highlights function
#------------------------------------------------------------------------------
detect_highlights() {
    local video="$1"
    local manifest="$2"
    
    log_step "Auto-detecting highlights in: $video"
    
    # Build vidcom command
    local cmd="$VIDCOM highlights \"$video\" --confidence $CONFIDENCE"
    [[ -n "$GAME" ]] && cmd+=" --game $GAME"
    
    log_info "Running: $cmd"
    
    # Run highlight detection
    if ! eval $cmd; then
        log_error "Highlight detection failed"
        return 1
    fi
    
    # Check for output JSON
    local json_file="${OUTPUT_DIR}/highlights.json"
    if [[ ! -f "$json_file" ]]; then
        log_error "No highlights.json generated"
        return 1
    fi
    
    # Convert highlights.json to manifest format
    log_info "Converting highlights to manifest..."
    
    local game_name="${GAME:-gaming}"
    local clip_num=0
    
    # Parse segments from JSON and create JSONL manifest
    jq -c '.segments[]' "$json_file" | while read -r segment; do
        ((clip_num++)) || true
        
        # Respect max clips limit
        if (( clip_num > MAX_CLIPS )); then
            break
        fi
        
        local type=$(echo "$segment" | jq -r '.type')
        local start=$(echo "$segment" | jq -r '.start')
        local end=$(echo "$segment" | jq -r '.end')
        local confidence=$(echo "$segment" | jq -r '.confidence')
        
        # Calculate duration
        local duration=$(echo "$end - $start" | bc)
        
        # Clamp duration to Shorts limits
        if (( $(echo "$duration < 10" | bc -l) )); then
            duration=10
            # Adjust start to include more context
            start=$(echo "$start - 5" | bc)
            if (( $(echo "$start < 0" | bc -l) )); then
                start=0
            fi
        elif (( $(echo "$duration > 55" | bc -l) )); then
            duration=55
        fi
        
        # Format timestamp as HH:MM:SS
        local start_ts=$(printf "%02d:%02d:%02d" $((${start%.*}/3600)) $(((${start%.*}%3600)/60)) $((${start%.*}%60)))
        
        # Generate title
        local title="${game_name^} ${type} #${clip_num}"
        
        # Output JSONL line
        echo "{\"input\": \"$video\", \"start\": \"$start_ts\", \"duration\": ${duration%.*}, \"title\": \"$title\", \"tags\": \"$game_name,shorts,gaming,$type\"}"
        
    done > "$manifest"
    
    local count=$(wc -l < "$manifest")
    log_info "Generated manifest with $count highlight(s)"
    
    return 0
}

#------------------------------------------------------------------------------
# Validate input and setup manifest
#------------------------------------------------------------------------------
if [[ ! -f "$MANIFEST" ]]; then
    log_error "Input file not found: $MANIFEST"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Determine mode based on file extension and --auto flag
if [[ "$AUTO_DETECT" == "true" ]]; then
    # Auto mode: detect highlights first
    VIDEO_INPUT="$MANIFEST"  # In auto mode, first arg is video
    MANIFEST="${OUTPUT_DIR}/auto_manifest.jsonl"
    
    if ! detect_highlights "$VIDEO_INPUT" "$MANIFEST"; then
        log_error "Failed to detect highlights"
        exit 1
    fi
elif [[ "$MANIFEST" == *.mp4 || "$MANIFEST" == *.mkv || "$MANIFEST" == *.avi || "$MANIFEST" == *.mov || "$MANIFEST" == *.webm ]]; then
    log_error "Video file provided but --auto not specified"
    log_info "Use: $0 $MANIFEST --auto --game <game>"
    exit 1
fi

TOTAL=$(wc -l < "$MANIFEST" | tr -d ' ')
log_info "Processing $TOTAL highlight(s) from $MANIFEST"

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
    FOCUS=$(echo "$line" | jq -r '.focus // "centre"')
    
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
