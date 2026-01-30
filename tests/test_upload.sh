#!/bin/bash
# test_upload.sh - Test YouTube upload functionality (dry run)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== VIDCOM Upload Test ==="
echo ""

# Check authentication status
echo "1. Checking YouTube authentication..."
"$PROJECT_DIR/scripts/yt-auth.sh" --status || {
    echo ""
    echo "Not authenticated. To set up:"
    echo "  1. Create OAuth credentials at console.cloud.google.com"
    echo "  2. Save client_secrets.json to ~/.config/vidcom/"
    echo "  3. Run: ./scripts/yt-auth.sh --setup"
    exit 0
}

echo ""
echo "2. Testing upload script (syntax check)..."
bash -n "$PROJECT_DIR/scripts/yt-upload.sh"
echo "   Upload script syntax: OK"

echo ""
echo "3. Testing encode script (syntax check)..."
bash -n "$PROJECT_DIR/scripts/encode-short.sh"
echo "   Encode script syntax: OK"

echo ""
echo "4. Testing batch script (syntax check)..."
bash -n "$PROJECT_DIR/scripts/process-batch.sh"
echo "   Batch script syntax: OK"

echo ""
echo "=== All Tests Passed ==="
echo ""
echo "To test actual upload, create a short test video and run:"
echo "  ./scripts/yt-upload.sh test.mp4 \"Test Video\" \"Test description\" \"test\" 20 private"
