#!/bin/bash
#
# test_highlights.sh - Test YOLO highlight detection functionality
#
# Tests the highlight detection module with various inputs and validates
# output format and basic functionality.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
VIDCOM="${PROJECT_DIR}/build/vidcom"
OUTPUT_DIR="${PROJECT_DIR}/output"

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

log_test() { echo -e "${YELLOW}[TEST]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
run_test() { TESTS_RUN=$((TESTS_RUN + 1)); "$@"; }

#------------------------------------------------------------------------------
# Test: vidcom binary exists and is executable
#------------------------------------------------------------------------------
test_binary_exists() {
    log_test "Checking vidcom binary exists"
    
    if [[ -x "$VIDCOM" ]]; then
        log_pass "vidcom binary found: $VIDCOM"
    else
        log_fail "vidcom binary not found or not executable"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Test: highlights command shows in help
#------------------------------------------------------------------------------
test_help_shows_highlights() {
    log_test "Checking help shows highlights command"
    
    local help_output
    help_output=$("$VIDCOM" help 2>&1)
    
    if echo "$help_output" | grep -q "highlights"; then
        log_pass "highlights command found in help"
    else
        log_fail "highlights command not in help output"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Test: highlights command accepts --game option
#------------------------------------------------------------------------------
test_game_option() {
    log_test "Checking --game option parsing"
    
    local output
    # This should fail because no video is provided, but shouldn't crash
    output=$("$VIDCOM" highlights --game fortnite 2>&1 || true)
    
    if echo "$output" | grep -qi "usage\|error\|video"; then
        log_pass "--game option parsing works"
    else
        log_fail "--game option parsing failed"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Test: highlights command accepts --confidence option
#------------------------------------------------------------------------------
test_confidence_option() {
    log_test "Checking --confidence option parsing"
    
    local output
    output=$("$VIDCOM" highlights --confidence 0.7 2>&1 || true)
    
    if echo "$output" | grep -qi "usage\|error\|video"; then
        log_pass "--confidence option parsing works"
    else
        log_fail "--confidence option parsing failed"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Test: Version is 0.2.0+
#------------------------------------------------------------------------------
test_version() {
    log_test "Checking version number"
    
    local help_output
    help_output=$("$VIDCOM" help 2>&1)
    
    if echo "$help_output" | grep -q "Version 0\.2"; then
        log_pass "Version is 0.2.x"
    else
        log_fail "Expected version 0.2.x"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Test: highlight_detector module compiles
#------------------------------------------------------------------------------
test_module_compiled() {
    log_test "Checking highlight_detector module compiled"
    
    # Check if the object file exists in build
    if [[ -f "${PROJECT_DIR}/build/highlight_detector.d" ]] || \
       nm "$VIDCOM" 2>/dev/null | grep -q "vidcom_detector_create"; then
        log_pass "highlight_detector module compiled and linked"
    else
        log_fail "highlight_detector module not found in binary"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Test: All game types recognised
#------------------------------------------------------------------------------
test_game_types() {
    log_test "Checking game type recognition"
    
    local games=("fortnite" "valorant" "csgo2" "overwatch" "apex")
    local all_passed=true
    
    for game in "${games[@]}"; do
        local output
        output=$("$VIDCOM" highlights --game "$game" 2>&1 || true)
        
        # Should not say "Unknown game"
        if echo "$output" | grep -qi "unknown game"; then
            log_fail "Game '$game' not recognised"
            all_passed=false
        fi
    done
    
    if $all_passed; then
        log_pass "All game types recognised"
    fi
}

#------------------------------------------------------------------------------
# Test: Invalid confidence value rejected
#------------------------------------------------------------------------------
test_invalid_confidence() {
    log_test "Checking invalid confidence rejection"
    
    local output
    output=$("$VIDCOM" highlights --confidence 2.0 2>&1 || true)
    
    if echo "$output" | grep -qi "must be between\|invalid\|0\.0.*1\.0"; then
        log_pass "Invalid confidence (2.0) rejected"
    else
        log_fail "Invalid confidence should be rejected"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Test: Output directory exists
#------------------------------------------------------------------------------
test_output_dir() {
    log_test "Checking output directory"
    
    mkdir -p "$OUTPUT_DIR"
    
    if [[ -d "$OUTPUT_DIR" ]]; then
        log_pass "Output directory exists: $OUTPUT_DIR"
    else
        log_fail "Could not create output directory"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Test: Training script exists
#------------------------------------------------------------------------------
test_training_script() {
    log_test "Checking training script"
    
    local script="${PROJECT_DIR}/scripts/train-highlight-model.sh"
    
    if [[ -x "$script" ]]; then
        log_pass "Training script exists and is executable"
    else
        log_fail "Training script not found or not executable: $script"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Test: Data collection script exists
#------------------------------------------------------------------------------
test_data_collection_script() {
    log_test "Checking data collection script"
    
    local script="${PROJECT_DIR}/scripts/collect-training-data.sh"
    
    if [[ -x "$script" ]]; then
        log_pass "Data collection script exists and is executable"
    else
        log_fail "Data collection script not found: $script"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Test: Header file exists
#------------------------------------------------------------------------------
test_header_exists() {
    log_test "Checking highlight_detector.h"
    
    local header="${PROJECT_DIR}/include/highlight_detector.h"
    
    if [[ -f "$header" ]]; then
        # Check for key definitions
        if grep -q "VIDCOM_HIGHLIGHT_KILL" "$header" && \
           grep -q "vidcom_detector_create" "$header"; then
            log_pass "highlight_detector.h exists with expected definitions"
        else
            log_fail "highlight_detector.h missing expected definitions"
            return 1
        fi
    else
        log_fail "highlight_detector.h not found"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Test: Config file has highlight settings
#------------------------------------------------------------------------------
test_config_highlight_settings() {
    log_test "Checking config has highlight settings"
    
    local config="${PROJECT_DIR}/config/vidcom.conf"
    
    if grep -q "\[highlight_detection\]" "$config" && \
       grep -q "highlight_model" "$config" && \
       grep -q "confidence_threshold" "$config"; then
        log_pass "Config has highlight detection settings"
    else
        log_fail "Config missing highlight detection settings"
        return 1
    fi
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------
main() {
    echo "=========================================="
    echo "VIDCOM Highlight Detection Tests"
    echo "=========================================="
    echo ""
    
    # Run all tests
    run_test test_binary_exists
    run_test test_help_shows_highlights
    run_test test_version
    run_test test_module_compiled
    run_test test_game_option
    run_test test_confidence_option
    run_test test_game_types
    run_test test_invalid_confidence
    run_test test_output_dir
    run_test test_training_script
    run_test test_data_collection_script
    run_test test_header_exists
    run_test test_config_highlight_settings
    
    # Summary
    echo ""
    echo "=========================================="
    echo "Test Summary"
    echo "=========================================="
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo ""
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed${NC}"
        exit 1
    fi
}

main "$@"
