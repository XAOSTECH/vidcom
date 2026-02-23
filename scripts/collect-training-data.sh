#!/bin/bash
#
# collect-training-data.sh - Extract frames from gaming videos for labeling
#
# This script extracts frames from gaming videos, organising them by game
# and timestamp for manual labelling with tools like LabelImg or CVAT.
#
# Usage:
#   ./scripts/collect-training-data.sh [options] <video_file|video_dir>
#
# Options:
#   --game <name>       Game type (fortnite, valorant, csgo2, overwatch, apex)
#   --output <dir>      Output directory (default: datasets/highlight_detection)
#   --fps <n>           Frames per second to extract (default: 2)
#   --format <fmt>      Output format: jpg, png (default: jpg)
#   --quality <n>       JPEG quality 1-100 (default: 95)
#   --resize <WxH>      Resize frames (default: original)
#   --crop-roi          Crop to game-specific kill feed region
#   --timestamps <file> File with timestamps to extract (start,end per line)
#   --skip-existing     Skip videos already processed
#

set -e

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

# Project directory
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Default configuration
GAME=""
OUTPUT_DIR="${PROJECT_DIR}/datasets/highlight_detection"
FPS=2
FORMAT="jpg"
QUALITY=95
RESIZE=""
CROP_ROI=0
TIMESTAMPS_FILE=""
SKIP_EXISTING=0
INPUT_PATH=""

# Game-specific ROI regions (x:y:w:h as fractions)
# These crop to the kill feed/notification areas
declare -A GAME_ROI
GAME_ROI[fortnite]="0.7:0.0:0.3:0.35"      # Top-right
GAME_ROI[valorant]="0.35:0.4:0.3:0.2"      # Centre
GAME_ROI[csgo2]="0.6:0.0:0.4:0.3"          # Top-right
GAME_ROI[overwatch]="0.35:0.35:0.3:0.3"    # Centre
GAME_ROI[apex]="0.6:0.0:0.4:0.35"          # Top-right

usage() {
    head -25 "$0" | tail -22
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --game)
            GAME="$2"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --fps)
            FPS="$2"
            shift 2
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --quality)
            QUALITY="$2"
            shift 2
            ;;
        --resize)
            RESIZE="$2"
            shift 2
            ;;
        --crop-roi)
            CROP_ROI=1
            shift
            ;;
        --timestamps)
            TIMESTAMPS_FILE="$2"
            shift 2
            ;;
        --skip-existing)
            SKIP_EXISTING=1
            shift
            ;;
        --help|-h)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            INPUT_PATH="$1"
            shift
            ;;
    esac
done

# Validate input
if [[ -z "$INPUT_PATH" ]]; then
    log_error "No input video or directory specified"
    usage
fi

# Check ffmpeg
if ! command -v ffmpeg &>/dev/null; then
    log_error "ffmpeg not found. Please install ffmpeg."
    exit 1
fi

# Get video info
get_video_info() {
    local video="$1"
    ffprobe -v quiet -select_streams v:0 \
        -show_entries stream=width,height,duration,r_frame_rate \
        -of csv=p=0 "$video" 2>/dev/null
}

# Build FFmpeg filter chain
build_filter() {
    local width="$1"
    local height="$2"
    local filters=""
    
    # Apply ROI crop if requested
    if [[ $CROP_ROI -eq 1 && -n "$GAME" && -n "${GAME_ROI[$GAME]}" ]]; then
        IFS=':' read -r rx ry rw rh <<< "${GAME_ROI[$GAME]}"
        local cx=$(echo "$rx * $width" | bc | cut -d. -f1)
        local cy=$(echo "$ry * $height" | bc | cut -d. -f1)
        local cw=$(echo "$rw * $width" | bc | cut -d. -f1)
        local ch=$(echo "$rh * $height" | bc | cut -d. -f1)
        filters="crop=${cw}:${ch}:${cx}:${cy}"
    fi
    
    # Apply resize
    if [[ -n "$RESIZE" ]]; then
        if [[ -n "$filters" ]]; then
            filters+=","
        fi
        filters+="scale=${RESIZE}:force_original_aspect_ratio=decrease"
    fi
    
    echo "$filters"
}

# Extract frames from a single video
extract_video() {
    local video="$1"
    local video_name=$(basename "${video%.*}")
    local game_dir="${GAME:-unknown}"
    local out_dir="${OUTPUT_DIR}/images/train/${game_dir}/${video_name}"
    
    # Check if already processed
    if [[ $SKIP_EXISTING -eq 1 && -d "$out_dir" ]]; then
        local existing_count=$(find "$out_dir" -name "*.${FORMAT}" 2>/dev/null | wc -l)
        if [[ $existing_count -gt 0 ]]; then
            log_info "Skipping (already has ${existing_count} frames): $video"
            return 0
        fi
    fi
    
    mkdir -p "$out_dir"
    
    # Get video dimensions
    local info=$(get_video_info "$video")
    local width=$(echo "$info" | cut -d',' -f1)
    local height=$(echo "$info" | cut -d',' -f2)
    local duration=$(echo "$info" | cut -d',' -f3)
    
    log_step "Processing: $video"
    log_info "  Resolution: ${width}x${height}"
    log_info "  Duration: ${duration}s"
    log_info "  Output: $out_dir"
    
    # Build FFmpeg command
    local filter=$(build_filter "$width" "$height")
    local ffmpeg_args="-i \"$video\" -vf \"fps=${FPS}"
    
    if [[ -n "$filter" ]]; then
        ffmpeg_args+=",${filter}"
    fi
    
    ffmpeg_args+="\" -qscale:v 2"
    
    if [[ "$FORMAT" == "jpg" ]]; then
        ffmpeg_args+=" -q:v $((100-QUALITY))"
    fi
    
    # Handle timestamps file
    if [[ -n "$TIMESTAMPS_FILE" && -f "$TIMESTAMPS_FILE" ]]; then
        local segment=1
        while IFS=',' read -r start_time end_time || [[ -n "$start_time" ]]; do
            # Skip comments and empty lines
            [[ "$start_time" =~ ^#.*$ || -z "$start_time" ]] && continue
            
            local seg_out="${out_dir}/seg${segment}_%06d.${FORMAT}"
            local seg_args="-ss $start_time -to $end_time $ffmpeg_args"
            
            log_info "  Segment $segment: ${start_time}s - ${end_time}s"
            eval "ffmpeg -y -loglevel warning $seg_args \"$seg_out\""
            
            ((segment++))
        done < "$TIMESTAMPS_FILE"
    else
        # Extract all frames
        local out_pattern="${out_dir}/frame_%06d.${FORMAT}"
        eval "ffmpeg -y -loglevel warning $ffmpeg_args \"$out_pattern\""
    fi
    
    # Count extracted frames
    local count=$(find "$out_dir" -name "*.${FORMAT}" | wc -l)
    log_info "  Extracted: $count frames"
    
    # Create labels directory structure
    local labels_dir="${OUTPUT_DIR}/labels/train/${game_dir}/${video_name}"
    mkdir -p "$labels_dir"
}

# Process input (file or directory)
process_input() {
    if [[ -f "$INPUT_PATH" ]]; then
        extract_video "$INPUT_PATH"
    elif [[ -d "$INPUT_PATH" ]]; then
        log_info "Processing directory: $INPUT_PATH"
        
        local count=0
        while IFS= read -r -d '' video; do
            extract_video "$video"
            ((count++))
        done < <(find "$INPUT_PATH" -type f \( -name "*.mp4" -o -name "*.mkv" -o -name "*.avi" -o -name "*.mov" -o -name "*.webm" \) -print0 | sort -z)
        
        log_info "Processed $count videos"
    else
        log_error "Input not found: $INPUT_PATH"
        exit 1
    fi
}

# Create data.yaml for training
create_data_yaml() {
    local yaml_path="${OUTPUT_DIR}/data.yaml"
    
    log_step "Creating data.yaml..."
    
    cat > "$yaml_path" << EOF
# VIDCOM Highlight Detection Dataset
# Generated by collect-training-data.sh
# $(date)

path: ${OUTPUT_DIR}
train: images/train
val: images/val  # Create by moving ~20% of train images

# Highlight classes
names:
  0: kill
  1: headshot
  2: assist
  3: down
  4: multi_kill
  5: clutch
  6: action

# Class notes:
# kill       - Standard elimination confirmed
# headshot   - Headshot indicator/icon
# assist     - Assist notification
# down       - Enemy knocked/downed (BR games)
# multi_kill - Double/triple/quad/etc kills
# clutch     - 1vX clutch situation indicator
# action     - General high-action moment
EOF
    
    log_info "Created: $yaml_path"
}

# Print labelling instructions
print_instructions() {
    echo
    log_info "====================================="
    log_info "Dataset Collection Complete"
    log_info "====================================="
    echo
    log_info "Next steps:"
    echo "  1. Label frames using LabelImg, CVAT, or Label Studio"
    echo "     - LabelImg: pip install labelImg && labelImg"
    echo "     - CVAT: https://cvat.ai"
    echo ""
    echo "  2. Save annotations in YOLO format (.txt files)"
    echo "     - One .txt per image in labels/ directory"
    echo "     - Format: <class> <x_center> <y_center> <width> <height>"
    echo "     - All values normalised 0-1"
    echo ""
    echo "  3. Create validation split:"
    echo "     mkdir -p ${OUTPUT_DIR}/images/val"
    echo "     mkdir -p ${OUTPUT_DIR}/labels/val"
    echo "     # Move ~20% of images+labels to val/"
    echo ""
    echo "  4. Train the model:"
    echo "     ./scripts/train-highlight-model.sh --data ${OUTPUT_DIR}/data.yaml"
    echo ""
    log_info "Dataset structure:"
    echo "  ${OUTPUT_DIR}/"
    echo "  ├── data.yaml"
    echo "  ├── images/"
    echo "  │   ├── train/"
    echo "  │   │   └── <game>/<video>/*.jpg"
    echo "  │   └── val/"
    echo "  └── labels/"
    echo "      ├── train/"
    echo "      │   └── <game>/<video>/*.txt"
    echo "      └── val/"
    echo
}

# Count total frames
count_frames() {
    local total=$(find "${OUTPUT_DIR}/images" -name "*.${FORMAT}" 2>/dev/null | wc -l)
    log_info "Total frames in dataset: $total"
}

# Main
main() {
    log_info "====================================="
    log_info "VIDCOM Training Data Collection"
    log_info "====================================="
    
    if [[ -n "$GAME" ]]; then
        log_info "Game: $GAME"
        if [[ $CROP_ROI -eq 1 ]]; then
            log_info "ROI: ${GAME_ROI[$GAME]:-full frame}"
        fi
    fi
    log_info "Output: $OUTPUT_DIR"
    log_info "FPS: $FPS"
    log_info "Format: $FORMAT (quality: $QUALITY)"
    echo
    
    mkdir -p "$OUTPUT_DIR"
    
    process_input
    create_data_yaml
    count_frames
    print_instructions
}

main "$@"
