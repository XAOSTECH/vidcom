#!/bin/bash
#
# train-highlight-model.sh - Train YOLOv11 model for gaming highlight detection
#
# This script trains a YOLOv11n (nano) model on labeled gaming highlight data
# and exports it to ONNX format for use with vidcom.
#
# Prerequisites:
#   - Python 3.10+ with pip
#   - CUDA 11.8+ (for GPU training)
#   - At least 8GB GPU VRAM (recommended: 16GB+)
#   - Labeled dataset in YOLO format
#
# Usage:
#   ./scripts/train-highlight-model.sh [options]
#
# Options:
#   --data <path>       Path to data.yaml (required)
#   --epochs <n>        Training epochs (default: 100)
#   --batch <n>         Batch size (default: 16)
#   --imgsz <n>         Image size (default: 640)
#   --device <id>       GPU device (default: 0)
#   --resume            Resume from last checkpoint
#   --export-only       Skip training, just export existing model
#   --model <path>      Base model or checkpoint (default: yolo11n.pt)
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Default configuration
DATA_YAML=""
EPOCHS=100
BATCH_SIZE=16
IMG_SIZE=640
DEVICE=0
RESUME=0
EXPORT_ONLY=0
BASE_MODEL="yolo11n.pt"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/models/training"
FINAL_MODEL="${PROJECT_DIR}/models/highlight_yolov8n.onnx"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --data)
            DATA_YAML="$2"
            shift 2
            ;;
        --epochs)
            EPOCHS="$2"
            shift 2
            ;;
        --batch)
            BATCH_SIZE="$2"
            shift 2
            ;;
        --imgsz)
            IMG_SIZE="$2"
            shift 2
            ;;
        --device)
            DEVICE="$2"
            shift 2
            ;;
        --resume)
            RESUME=1
            shift
            ;;
        --export-only)
            EXPORT_ONLY=1
            shift
            ;;
        --model)
            BASE_MODEL="$2"
            shift 2
            ;;
        --help|-h)
            head -40 "$0" | tail -30
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate data.yaml unless export-only
if [[ $EXPORT_ONLY -eq 0 && -z "$DATA_YAML" ]]; then
    log_error "Missing --data <path/to/data.yaml>"
    log_info "Data YAML format:"
    cat << 'EOF'
    # data.yaml example
    path: /path/to/dataset
    train: images/train
    val: images/val
    
    names:
      0: kill
      1: headshot
      2: assist
      3: down
      4: multi_kill
      5: clutch
      6: action
EOF
    exit 1
fi

# Check Python environment
check_python() {
    if ! command -v python3 &>/dev/null; then
        log_error "Python 3 not found. Please install Python 3.10+"
        exit 1
    fi
    
    PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    log_info "Python version: $PYTHON_VERSION"
}

# Install/update ultralytics
setup_ultralytics() {
    log_info "Setting up Ultralytics..."
    
    # Create virtual environment if needed
    if [[ ! -d "${PROJECT_DIR}/.venv" ]]; then
        log_info "Creating Python virtual environment..."
        python3 -m venv "${PROJECT_DIR}/.venv"
    fi
    
    # Activate venv
    source "${PROJECT_DIR}/.venv/bin/activate"
    
    # Install/upgrade ultralytics
    pip install -q --upgrade pip
    pip install -q ultralytics>=8.3.0 onnx onnxruntime-gpu
    
    log_info "Ultralytics installed: $(yolo version 2>/dev/null || echo 'checking...')"
}

# Train the model
train_model() {
    log_info "Starting YOLOv11 training..."
    log_info "  Base model:  $BASE_MODEL"
    log_info "  Data:        $DATA_YAML"
    log_info "  Epochs:      $EPOCHS"
    log_info "  Batch size:  $BATCH_SIZE"
    log_info "  Image size:  $IMG_SIZE"
    log_info "  Device:      cuda:$DEVICE"
    
    mkdir -p "$OUTPUT_DIR"
    
    # Build training command
    TRAIN_CMD="yolo detect train"
    TRAIN_CMD+=" model=$BASE_MODEL"
    TRAIN_CMD+=" data=$DATA_YAML"
    TRAIN_CMD+=" epochs=$EPOCHS"
    TRAIN_CMD+=" imgsz=$IMG_SIZE"
    TRAIN_CMD+=" batch=$BATCH_SIZE"
    TRAIN_CMD+=" device=$DEVICE"
    TRAIN_CMD+=" project=$OUTPUT_DIR"
    TRAIN_CMD+=" name=highlight_detector"
    TRAIN_CMD+=" exist_ok=True"
    TRAIN_CMD+=" patience=20"
    TRAIN_CMD+=" save_period=10"
    TRAIN_CMD+=" cache=ram"
    TRAIN_CMD+=" workers=4"
    TRAIN_CMD+=" verbose=True"
    
    if [[ $RESUME -eq 1 ]]; then
        TRAIN_CMD+=" resume=True"
    fi
    
    log_info "Running: $TRAIN_CMD"
    echo
    
    eval $TRAIN_CMD
    
    log_info "Training complete!"
}

# Export to ONNX
export_model() {
    log_info "Exporting model to ONNX..."
    
    # Find best.pt
    BEST_PT="${OUTPUT_DIR}/highlight_detector/weights/best.pt"
    if [[ ! -f "$BEST_PT" ]]; then
        # Check if BASE_MODEL is a checkpoint
        if [[ -f "$BASE_MODEL" && "$BASE_MODEL" == *.pt ]]; then
            BEST_PT="$BASE_MODEL"
            log_warn "Using specified model: $BEST_PT"
        else
            log_error "No trained model found at: $BEST_PT"
            exit 1
        fi
    fi
    
    log_info "Exporting: $BEST_PT"
    
    # Export to ONNX with optimizations
    EXPORT_CMD="yolo export"
    EXPORT_CMD+=" model=$BEST_PT"
    EXPORT_CMD+=" format=onnx"
    EXPORT_CMD+=" imgsz=$IMG_SIZE"
    EXPORT_CMD+=" simplify=True"
    EXPORT_CMD+=" opset=17"
    EXPORT_CMD+=" dynamic=False"
    EXPORT_CMD+=" half=False"  # Keep FP32 for wider compatibility
    
    log_info "Running: $EXPORT_CMD"
    eval $EXPORT_CMD
    
    # Find and copy ONNX file
    EXPORTED_ONNX="${BEST_PT%.pt}.onnx"
    if [[ -f "$EXPORTED_ONNX" ]]; then
        cp "$EXPORTED_ONNX" "$FINAL_MODEL"
        log_info "Model exported to: $FINAL_MODEL"
        
        # Show model info
        MODEL_SIZE=$(du -h "$FINAL_MODEL" | cut -f1)
        log_info "Model size: $MODEL_SIZE"
    else
        log_error "ONNX export failed - file not found: $EXPORTED_ONNX"
        exit 1
    fi
}

# Validate exported model
validate_model() {
    log_info "Validating ONNX model..."
    
    python3 << EOF
import onnxruntime as ort
import numpy as np

model_path = "$FINAL_MODEL"
session = ort.InferenceSession(model_path)

# Get input/output info
inputs = session.get_inputs()
outputs = session.get_outputs()

print(f"  Input: {inputs[0].name}")
print(f"    Shape: {inputs[0].shape}")
print(f"    Type:  {inputs[0].type}")

print(f"  Output: {outputs[0].name}")
print(f"    Shape: {outputs[0].shape}")
print(f"    Type:  {outputs[0].type}")

# Test inference
batch_size = 1
channels = 3
height = ${IMG_SIZE}
width = ${IMG_SIZE}

dummy_input = np.random.randn(batch_size, channels, height, width).astype(np.float32)
output = session.run(None, {inputs[0].name: dummy_input})

print(f"  Test inference output shape: {output[0].shape}")
print("  Model validation: PASSED")
EOF
}

# Print class mapping
print_classes() {
    log_info "Highlight class mapping:"
    echo "  0: NONE (background)"
    echo "  1: KILL"
    echo "  2: HEADSHOT"
    echo "  3: ASSIST"
    echo "  4: DOWN"
    echo "  5: MULTI_KILL"
    echo "  6: CLUTCH"
    echo "  7: ACTION"
}

# Main execution
main() {
    log_info "====================================="
    log_info "VIDCOM Highlight Model Training"
    log_info "====================================="
    
    check_python
    setup_ultralytics
    
    if [[ $EXPORT_ONLY -eq 0 ]]; then
        train_model
    fi
    
    export_model
    validate_model
    print_classes
    
    log_info "====================================="
    log_info "Training pipeline complete!"
    log_info "Model ready at: $FINAL_MODEL"
    log_info ""
    log_info "Usage:"
    log_info "  ./build/vidcom highlights video.mp4 --game fortnite"
    log_info "====================================="
}

main "$@"
