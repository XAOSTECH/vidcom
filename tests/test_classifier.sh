#!/bin/bash
# test_classifier.sh - Test the ONNX classifier

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

echo "=== VIDCOM Classifier Test ==="
echo ""

# Check if vidcom is built
if [[ ! -f "$BUILD_DIR/vidcom" ]]; then
    echo "ERROR: vidcom not built. Run 'make' first."
    exit 1
fi

# Check if model exists
MODEL_PATH="$PROJECT_DIR/models/resnet50.onnx"
if [[ ! -f "$MODEL_PATH" ]]; then
    echo "WARNING: Model not found at $MODEL_PATH"
    echo "Run 'make models' to download."
    echo ""
    echo "Skipping classifier test."
    exit 0
fi

# Test with a sample video if available
SAMPLE_VIDEO="${1:-}"
if [[ -z "$SAMPLE_VIDEO" ]]; then
    echo "Usage: $0 <sample_video.mp4>"
    echo ""
    echo "To run test, provide a sample video file."
    exit 0
fi

if [[ ! -f "$SAMPLE_VIDEO" ]]; then
    echo "ERROR: Video not found: $SAMPLE_VIDEO"
    exit 1
fi

echo "Testing with: $SAMPLE_VIDEO"
echo ""

# Run analysis
"$BUILD_DIR/vidcom" --verbose analyse "$SAMPLE_VIDEO"

echo ""
echo "=== Test Complete ==="
