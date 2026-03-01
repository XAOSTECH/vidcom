#!/bin/bash
# encode-short.sh - Encode video segment for YouTube Shorts (9:16 vertical)
# Uses FFmpeg with NVENC hardware acceleration
#
# Usage:
#   ./encode-short.sh <input> <output> <start> <duration> [options]
#
# Examples:
#   ./encode-short.sh stream.mp4 short_001.mp4 01:23:45 60
#   ./encode-short.sh stream.mp4 short_001.mp4 01:23:45 60 --quality 18 --focus top

set -euo pipefail

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Shorts specifications
SHORTS_WIDTH=1080
SHORTS_HEIGHT=1920
SHORTS_RATIO="0.5625"  # 9/16

# Defaults
CQ=20           # Quality (lower = better, 15-25 recommended)
PRESET="p4"     # NVENC preset (p1=fastest, p7=slowest/best)
FOCUS="center"  # Crop focus: center, top, bottom, left, right
MAX_BITRATE="12M"
BUF_SIZE="24M"

#------------------------------------------------------------------------------
# Parse arguments
#------------------------------------------------------------------------------
usage() {
    echo "Usage: $0 <input> <output> <start> <duration> [options]"
    echo ""
    echo "Required:"
    echo "  input       Input video file"
    echo "  output      Output file (will be 1080x1920 @ 9:16)"
    echo "  start       Start time (HH:MM:SS or seconds)"
    echo "  duration    Duration in seconds (max 60 for Shorts)"
    echo ""
    echo "Options:"
    echo "  --quality N    Constant quality (15-28, default: 20)"
    echo "  --preset P     NVENC preset p1-p7 (default: p4)"
    echo "  --focus F      Crop focus: centre|top|bottom (default: centre)"
    echo "  --no-audio     Strip audio"
    echo "  --cpu          Use CPU encoding (no GPU required)"
    echo "  --help         Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 stream.mp4 short.mp4 01:23:45 55"
    echo "  $0 stream.mp4 short.mp4 00:05:00 60 --quality 18 --focus top"
}

if [[ $# -lt 4 ]]; then
    usage
    exit 1
fi

INPUT="$1"
OUTPUT="$2"
START="$3"
DURATION="$4"
shift 4

NO_AUDIO=false
USE_CPU=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quality)
            CQ="$2"
            shift 2
            ;;
        --preset)
            PRESET="$2"
            shift 2
            ;;
        --focus)
            FOCUS="$2"
            shift 2
            ;;
        --no-audio)
            NO_AUDIO=true
            shift
            ;;
        --cpu)
            USE_CPU=true
            shift
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
# Validate inputs
#------------------------------------------------------------------------------
if [[ ! -f "$INPUT" ]]; then
    log_error "Input file not found: $INPUT"
    exit 1
fi

# Check duration for Shorts (max 60 seconds)
if (( DURATION > 60 )); then
    log_warn "YouTube Shorts max is 60 seconds, truncating from $DURATION"
    DURATION=60
fi

# Validate focus
case "$FOCUS" in
    centre|top|bottom|left|right) ;;
    *)
        log_error "Invalid focus: $FOCUS (use: centre, top, bottom, left, right)"
        exit 1
        ;;
esac

#------------------------------------------------------------------------------
# Detect input dimensions
#------------------------------------------------------------------------------
log_info "Analysing input video..."

PROBE=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,duration \
    -of json "$INPUT")

IN_W=$(echo "$PROBE" | jq -r '.streams[0].width')
IN_H=$(echo "$PROBE" | jq -r '.streams[0].height')
IN_DURATION=$(echo "$PROBE" | jq -r '.streams[0].duration // "unknown"')

if [[ -z "$IN_W" ]] || [[ "$IN_W" == "null" ]]; then
    log_error "Could not detect video dimensions"
    exit 1
fi

log_info "Input: ${IN_W}x${IN_H} (duration: ${IN_DURATION}s)"

#------------------------------------------------------------------------------
# Calculate crop parameters for 9:16
#------------------------------------------------------------------------------
log_info "Calculating crop for 9:16 aspect ratio..."

# Calculate input aspect ratio
IN_RATIO=$(echo "scale=6; $IN_W / $IN_H" | bc)

# Compare with target (9:16 = 0.5625)
# If input is wider (e.g., 16:9), crop left/right
# If input is taller, crop top/bottom

CROP_NEEDED=$(echo "$IN_RATIO > $SHORTS_RATIO" | bc)

if [[ "$CROP_NEEDED" == "1" ]]; then
    # Input is wider - need to crop horizontally
    CROP_W=$(echo "scale=0; $IN_H * $SHORTS_RATIO" | bc | cut -d. -f1)
    CROP_H=$IN_H
    
    case "$FOCUS" in
        left)
            CROP_X=0
            ;;
        right)
            CROP_X=$((IN_W - CROP_W))
            ;;
        *)  # centre
            CROP_X=$(( (IN_W - CROP_W) / 2 ))
            ;;
    esac
    CROP_Y=0
else
    # Input is taller or equal - need to crop vertically
    CROP_W=$IN_W
    CROP_H=$(echo "scale=0; $IN_W / $SHORTS_RATIO" | bc | cut -d. -f1)
    
    case "$FOCUS" in
        top)
            CROP_Y=0
            ;;
        bottom)
            CROP_Y=$((IN_H - CROP_H))
            ;;
        *)  # centre
            CROP_Y=$(( (IN_H - CROP_H) / 2 ))
            ;;
    esac
    CROP_X=0
fi

# Ensure even dimensions (required for most codecs)
CROP_W=$((CROP_W / 2 * 2))
CROP_H=$((CROP_H / 2 * 2))
CROP_X=$((CROP_X / 2 * 2))
CROP_Y=$((CROP_Y / 2 * 2))

log_info "Crop: ${CROP_W}x${CROP_H} at +${CROP_X}+${CROP_Y}"

#------------------------------------------------------------------------------
# Build FFmpeg command
#------------------------------------------------------------------------------
log_info "Encoding to ${SHORTS_WIDTH}x${SHORTS_HEIGHT}..."

# Video filter chain
VF="crop=${CROP_W}:${CROP_H}:${CROP_X}:${CROP_Y},scale=${SHORTS_WIDTH}:${SHORTS_HEIGHT}:flags=lanczos"

# Build ffmpeg args
FFMPEG_ARGS=(
    -hide_banner
    -loglevel warning
    -stats
)

# Input with hardware decode (if GPU)
if [[ "$USE_CPU" != "true" ]] && command -v nvidia-smi &>/dev/null; then
    FFMPEG_ARGS+=(
        -hwaccel cuda
        -hwaccel_output_format cuda
    )
fi

FFMPEG_ARGS+=(
    -ss "$START"
    -t "$DURATION"
    -i "$INPUT"
    -vf "$VF"
)

# Video encoder
if [[ "$USE_CPU" == "true" ]]; then
    # CPU encoding with libx264
    FFMPEG_ARGS+=(
        -c:v libx264
        -preset medium
        -crf "$CQ"
        -profile:v high
        -level:v 4.1
    )
else
    # GPU encoding with NVENC
    FFMPEG_ARGS+=(
        -c:v h264_nvenc
        -preset "$PRESET"
        -cq "$CQ"
        -maxrate "$MAX_BITRATE"
        -bufsize "$BUF_SIZE"
        -profile:v high
        -level:v 4.1
        -rc vbr
        -rc-lookahead 32
        -spatial-aq 1
        -temporal-aq 1
    )
fi

# Audio encoding
if [[ "$NO_AUDIO" == "true" ]]; then
    FFMPEG_ARGS+=(-an)
else
    FFMPEG_ARGS+=(
        -c:a aac
        -b:a 128k
        -ar 44100
        -ac 2
    )
fi

# Output options
FFMPEG_ARGS+=(
    -movflags +faststart
    -pix_fmt yuv420p
    -y
    "$OUTPUT"
)

# Execute
log_info "Running FFmpeg..."
if ! ffmpeg "${FFMPEG_ARGS[@]}"; then
    log_error "Encoding failed"
    rm -f "$OUTPUT"
    exit 1
fi

#------------------------------------------------------------------------------
# Verify output
#------------------------------------------------------------------------------
if [[ ! -f "$OUTPUT" ]]; then
    log_error "Output file not created"
    exit 1
fi

OUT_SIZE=$(stat -c%s "$OUTPUT")
OUT_DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null | cut -d. -f1)

log_info "Output: $OUTPUT"
log_info "Size: $(numfmt --to=iec $OUT_SIZE)"
log_info "Duration: ${OUT_DURATION}s"

# Verify dimensions
OUT_DIMS=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$OUTPUT")
log_info "Dimensions: $OUT_DIMS"

if [[ "$OUT_DIMS" != "${SHORTS_WIDTH}x${SHORTS_HEIGHT}" ]]; then
    log_warn "Output dimensions ($OUT_DIMS) differ from target (${SHORTS_WIDTH}x${SHORTS_HEIGHT})"
fi

echo ""
log_info "Done! Ready for YouTube Shorts upload."
