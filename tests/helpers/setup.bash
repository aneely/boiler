#!/usr/bin/env bash
# Common setup for bats tests
# This file is loaded by each test file to provide common functionality

# Get the directory where this script is located
HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(cd "$HELPERS_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

# Load bats helper libraries
load "$TESTS_DIR/test_helper/bats-support/load"
load "$TESTS_DIR/test_helper/bats-assert/load"
load "$TESTS_DIR/test_helper/bats-file/load"

# Set test mode to prevent main() from running when we source boiler.sh
export BOILER_TEST_MODE=1

# Source boiler.sh (this provides all the functions we want to test)
# We do this once when the helper is loaded
source "$PROJECT_ROOT/boiler.sh" 2>/dev/null

# Load mock functions (these override the real FFmpeg/ffprobe-dependent functions)
load "$HELPERS_DIR/mocks"

# Global temporary directory for test files (created fresh for each test)
# bats provides BATS_TEST_TMPDIR for this purpose
export TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"

# Common setup function - called before each test
# Tests can override this by defining their own setup() function
common_setup() {
    # Reset all mock state
    reset_mocks
    
    # Clear any mock overrides
    unset MOCK_RESOLUTION
    unset MOCK_DURATION
    unset MOCK_BITRATE_BPS
    unset MOCK_SAMPLE_BITRATE_BPS
    unset MOCK_OUTPUT_BITRATE_BPS
    unset MOCK_SECOND_PASS_BITRATE_BPS
    unset MOCK_THIRD_PASS_BITRATE_BPS
    unset MOCK_VIDEO_CODEC
    unset MOCK_VIDEO_FILE
    
    # Reset global variables that might be set by tests
    unset GLOBAL_TARGET_BITRATE_MBPS
    unset GLOBAL_MAX_DEPTH
}

# Common teardown function - called after each test
common_teardown() {
    # Clean up any temporary files created during the test
    # BATS_TEST_TMPDIR is automatically cleaned up by bats
    :
}

# Helper to create a temporary video file (just touches a file with video extension)
create_temp_video() {
    local name="${1:-test_video.mp4}"
    local path="$TEST_TMPDIR/$name"
    touch "$path"
    echo "$path"
}

# Helper to create a directory structure for testing
create_test_dir_structure() {
    local base_dir="$TEST_TMPDIR"
    mkdir -p "$base_dir"
    echo "$base_dir"
}

# Helper to run boiler.sh functions in isolation (fresh subshell)
# This is useful when you need to test functions that modify global state
run_in_isolation() {
    local func_name="$1"
    shift
    bash -c "
        export BOILER_TEST_MODE=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        $func_name \"\$@\"
    " -- "$@"
}
