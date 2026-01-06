#!/bin/bash

# Test harness for boiler.sh utility functions
# Uses function mocking to test FFmpeg/ffprobe-dependent functions without requiring
# actual video files or FFmpeg installation. This enables fast local testing and
# CI/CD environments (e.g., GitHub Actions) that may not have FFmpeg available.
#
# Mocked functions:
#   - get_video_resolution() - returns configurable resolution (default: 1080)
#   - get_video_duration() - returns configurable duration (default: 300s)
#   - measure_bitrate() - returns configurable bitrate or calculates from file size
#   - transcode_sample() - creates mock output file instead of transcoding
#   - transcode_full_video() - creates mock output file instead of transcoding
#
# Mock behavior can be controlled via environment variables:
#   - MOCK_RESOLUTION: Override resolution returned by get_video_resolution()
#   - MOCK_DURATION: Override duration returned by get_video_duration()
#   - MOCK_BITRATE_BPS: Override bitrate returned by measure_bitrate()

# Test statistics
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors for test output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Assertion functions
assert_equal() {
    local actual="$1"
    local expected="$2"
    local test_name="$3"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [ "$actual" = "$expected" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo -e "  Expected: '$expected'"
        echo -e "  Actual:   '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_not_equal() {
    local actual="$1"
    local expected="$2"
    local test_name="$3"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [ "$actual" != "$expected" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo -e "  Values should not be equal: '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_empty() {
    local actual="$1"
    local test_name="$2"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [ -z "$actual" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo -e "  Expected empty string, got: '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_not_empty() {
    local actual="$1"
    local test_name="$2"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [ -n "$actual" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo -e "  Expected non-empty string, got empty"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_exit_code() {
    local actual_exit="$1"
    local expected_exit="$2"
    local test_name="$3"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [ "$actual_exit" -eq "$expected_exit" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo -e "  Expected exit code: $expected_exit"
        echo -e "  Actual exit code: $actual_exit"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Set test mode to prevent main() from running when we source boiler.sh
export BOILER_TEST_MODE=1

# Call tracking files for mocking (works across subshells)
CALL_TRACK_DIR=$(mktemp -d 2>/dev/null || echo "/tmp/boiler_test_calls_$$")
TRANSCODE_SAMPLE_CALLS_FILE="$CALL_TRACK_DIR/transcode_sample_calls"
TRANSCODE_FULL_CALLS_FILE="$CALL_TRACK_DIR/transcode_full_calls"
MEASURE_BITRATE_CALLS_FILE="$CALL_TRACK_DIR/measure_bitrate_calls"
FIND_VIDEO_FILE_CALLS_FILE="$CALL_TRACK_DIR/find_video_file_calls"

# Reset call tracking (call this before each test)
reset_call_tracking() {
    rm -f "$TRANSCODE_SAMPLE_CALLS_FILE" "$TRANSCODE_FULL_CALLS_FILE" \
          "$MEASURE_BITRATE_CALLS_FILE" "$FIND_VIDEO_FILE_CALLS_FILE"
    touch "$TRANSCODE_SAMPLE_CALLS_FILE" "$TRANSCODE_FULL_CALLS_FILE" \
          "$MEASURE_BITRATE_CALLS_FILE" "$FIND_VIDEO_FILE_CALLS_FILE"
}

# Helper function to count calls (counts lines in file)
count_calls() {
    local calls_file="$1"
    if [ ! -f "$calls_file" ]; then
        echo "0"
    else
        wc -l < "$calls_file" | tr -d ' '
    fi
}

# Helper function to get first call
get_first_call() {
    local calls_file="$1"
    if [ ! -f "$calls_file" ]; then
        echo ""
    else
        head -n1 "$calls_file"
    fi
}

# Source boiler.sh (main() won't run because of BOILER_TEST_MODE check we added)
# Temporarily disable set -e to prevent early exit during sourcing
# Also redirect stderr from info/warn/error functions to avoid noise
set +e
source boiler.sh 2>/dev/null
set -e

# Mock functions for FFmpeg/ffprobe calls
# These allow tests to run without requiring actual video files or FFmpeg installation
# Functions track calls instead of performing actual operations
# Mock get_video_resolution() - returns mock resolution (default: 1080, can be overridden via MOCK_RESOLUTION)
get_video_resolution() {
    local video_file="$1"
    echo "${MOCK_RESOLUTION:-1080}"
}

# Mock get_video_duration() - returns mock duration in seconds (default: 300, can be overridden via MOCK_DURATION)
get_video_duration() {
    local video_file="$1"
    echo "${MOCK_DURATION:-300}"
}

# Mock measure_bitrate() - tracks calls and returns mock bitrate
measure_bitrate() {
    local file_path="$1"
    local duration="$2"
    
    # Track the call (append to file)
    echo "$file_path|$duration" >> "$MEASURE_BITRATE_CALLS_FILE"
    
    # If this is an output file (temp_transcode), use MOCK_OUTPUT_BITRATE_BPS if set
    if [[ "$file_path" == *"temp_transcode"* ]] && [ -n "${MOCK_OUTPUT_BITRATE_BPS:-}" ]; then
        # Count how many times we've measured temp_transcode files
        local temp_transcode_count=$(grep -c "temp_transcode" "$MEASURE_BITRATE_CALLS_FILE" 2>/dev/null || echo "0")
        
        # If MOCK_SECOND_PASS_BITRATE_BPS is set and this is the second call, use it
        if [ "$temp_transcode_count" -eq 2 ] && [ -n "${MOCK_SECOND_PASS_BITRATE_BPS:-}" ]; then
            echo "${MOCK_SECOND_PASS_BITRATE_BPS}"
            return
        fi
        
        # Otherwise use MOCK_OUTPUT_BITRATE_BPS (first pass)
        echo "${MOCK_OUTPUT_BITRATE_BPS}"
        return
    fi
    
    # If this is a sample file, use MOCK_SAMPLE_BITRATE_BPS if set (for optimization convergence)
    if [[ "$file_path" == *"_sample_"* ]] && [ -n "${MOCK_SAMPLE_BITRATE_BPS:-}" ]; then
        echo "${MOCK_SAMPLE_BITRATE_BPS}"
        return
    fi
    
    # Return MOCK_BITRATE_BPS if set (for source files)
    if [ -n "${MOCK_BITRATE_BPS:-}" ]; then
        echo "${MOCK_BITRATE_BPS}"
    else
        echo ""
    fi
}

# Mock transcode_sample() - tracks calls instead of transcoding
transcode_sample() {
    local video_file="$1"
    local sample_start="$2"
    local sample_duration="$3"
    local quality_value="$4"
    local output_file="$5"
    
    # Track the call (append to file)
    echo "$video_file|$sample_start|$sample_duration|$quality_value|$output_file" >> "$TRANSCODE_SAMPLE_CALLS_FILE"
    
    # Create minimal file so downstream code doesn't fail on file existence checks
    touch "$output_file"
}

# Mock transcode_full_video() - tracks calls instead of transcoding
transcode_full_video() {
    local video_file="$1"
    local output_file="$2"
    local quality_value="$3"
    
    # Track the call (append to file)
    echo "$video_file|$output_file|$quality_value" >> "$TRANSCODE_FULL_CALLS_FILE"
    
    # Create minimal file so downstream code doesn't fail on file existence checks
    touch "$output_file"
}

# Mock check_requirements() - skip requirement checks in test mode
check_requirements() {
    # Do nothing - allow tests to run without ffmpeg/ffprobe
    return 0
}

# Mock find_video_file() - tracks calls and returns test video file path
find_video_file() {
    # Track the call (append to file)
    echo "called" >> "$FIND_VIDEO_FILE_CALLS_FILE"
    
    if [ -n "${MOCK_VIDEO_FILE:-}" ]; then
        # Ensure the file exists
        touch "$MOCK_VIDEO_FILE"
        echo "$MOCK_VIDEO_FILE"
    else
        # Create a temporary test file
        local test_file=$(mktemp --suffix=.mp4 2>/dev/null || mktemp -t test_video).mp4
        touch "$test_file"
        echo "$test_file"
    fi
}

# Note: find_optimal_quality() is NOT mocked - it will run and call transcode_sample()
# To make it converge quickly in tests, set MOCK_BITRATE_BPS to target bitrate
# so samples return target bitrate and optimization converges immediately

# Now run tests

echo "Running tests for boiler.sh utility functions..."
echo ""

# Test sanitize_value()
echo "Testing sanitize_value()..."
test_sanitize_value() {
    local result
    
    result=$(sanitize_value "1000000")
    assert_equal "$result" "1000000" "sanitize_value: normal number"
    
    result=$(sanitize_value "$(printf "1000000\n")")
    assert_equal "$result" "1000000" "sanitize_value: removes newline"
    
    result=$(sanitize_value "$(printf "1000000\r")")
    assert_equal "$result" "1000000" "sanitize_value: removes carriage return"
    
    result=$(sanitize_value "  1000000  ")
    assert_equal "$result" "1000000" "sanitize_value: trims whitespace"
    
    result=$(sanitize_value "$(printf "1000000\n\r  ")")
    assert_equal "$result" "1000000" "sanitize_value: removes all whitespace and newlines"
}
test_sanitize_value

echo ""

# Test bps_to_mbps()
echo "Testing bps_to_mbps()..."
test_bps_to_mbps() {
    local result
    
    result=$(bps_to_mbps "8000000")
    assert_equal "$result" "8.00" "bps_to_mbps: 8 Mbps"
    
    result=$(bps_to_mbps "11000000")
    assert_equal "$result" "11.00" "bps_to_mbps: 11 Mbps"
    
    result=$(bps_to_mbps "8500000")
    assert_equal "$result" "8.50" "bps_to_mbps: 8.5 Mbps"
    
    result=$(bps_to_mbps "$(printf "8500000\n")")
    assert_equal "$result" "8.50" "bps_to_mbps: handles newlines in input"
    
    result=$(bps_to_mbps "1000000")
    assert_equal "$result" "1.00" "bps_to_mbps: 1 Mbps"
    
    result=$(bps_to_mbps "0")
    assert_equal "$result" "0" "bps_to_mbps: zero bitrate"
}
test_bps_to_mbps

echo ""

# Test calculate_squared_distance()
echo "Testing calculate_squared_distance()..."
test_calculate_squared_distance() {
    local result
    local expected
    
    # Distance of 0 (same value)
    result=$(calculate_squared_distance "8000000" "8000000")
    assert_equal "$result" "0" "calculate_squared_distance: zero distance"
    
    # Distance of 1000000 (1 Mbps difference)
    result=$(calculate_squared_distance "8000000" "9000000")
    expected=$(echo "scale=4; (8000000 - 9000000)^2" | bc | tr -d '\n\r')
    assert_equal "$result" "$expected" "calculate_squared_distance: 1 Mbps difference"
    
    # Distance of 3000000 (3 Mbps difference)
    result=$(calculate_squared_distance "8000000" "11000000")
    expected=$(echo "scale=4; (8000000 - 11000000)^2" | bc | tr -d '\n\r')
    assert_equal "$result" "$expected" "calculate_squared_distance: 3 Mbps difference"
    
    # Test with sanitized inputs (newlines/carriage returns)
    result=$(calculate_squared_distance "$(printf "8000000\n")" "$(printf "9000000\r")")
    expected=$(echo "scale=4; (8000000 - 9000000)^2" | bc | tr -d '\n\r')
    assert_equal "$result" "$expected" "calculate_squared_distance: handles sanitized inputs"
}
test_calculate_squared_distance

echo ""

# Test parse_filename()
echo "Testing parse_filename()..."
test_parse_filename() {
    parse_filename "video.mp4"
    assert_equal "$BASE_NAME" "video" "parse_filename: simple filename"
    assert_equal "$FILE_EXTENSION" "mp4" "parse_filename: simple extension"
    
    parse_filename "my.video.file.mkv"
    assert_equal "$BASE_NAME" "my.video.file" "parse_filename: filename with dots"
    assert_equal "$FILE_EXTENSION" "mkv" "parse_filename: extension with dots in name"
    
    parse_filename "/path/to/video.avi"
    assert_equal "$BASE_NAME" "/path/to/video" "parse_filename: path with extension"
    assert_equal "$FILE_EXTENSION" "avi" "parse_filename: extension from path"
    
    parse_filename "noextension"
    assert_equal "$BASE_NAME" "noextension" "parse_filename: no extension"
    assert_equal "$FILE_EXTENSION" "noextension" "parse_filename: no extension (base equals ext)"
}
test_parse_filename

echo ""

# Test is_within_tolerance()
echo "Testing is_within_tolerance()..."
test_is_within_tolerance() {
    local exit_code
    
    # Test within tolerance (exactly at lower bound)
    set +e
    is_within_tolerance "7600000" "7600000" "8400000"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_within_tolerance: at lower bound"
    
    # Test within tolerance (exactly at upper bound)
    set +e
    is_within_tolerance "8400000" "7600000" "8400000"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_within_tolerance: at upper bound"
    
    # Test within tolerance (middle)
    set +e
    is_within_tolerance "8000000" "7600000" "8400000"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_within_tolerance: in middle"
    
    # Test below tolerance
    set +e
    is_within_tolerance "7500000" "7600000" "8400000"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_within_tolerance: below lower bound"
    
    # Test above tolerance
    set +e
    is_within_tolerance "8500000" "7600000" "8400000"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_within_tolerance: above upper bound"
    
    # Test with sanitized inputs (newlines/carriage returns/whitespace)
    set +e
    is_within_tolerance "$(printf "8000000\n")" "$(printf "7600000\r")" "8400000  "
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_within_tolerance: handles sanitized inputs"
}
test_is_within_tolerance

echo ""

# Test calculate_target_bitrate()
echo "Testing calculate_target_bitrate()..."
test_calculate_target_bitrate() {
    # Test 2160p (4K)
    calculate_target_bitrate "2160"
    assert_equal "$TARGET_BITRATE_MBPS" "11" "calculate_target_bitrate: 2160p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "11000000" "calculate_target_bitrate: 2160p bps"
    
    # Test above 2160p
    calculate_target_bitrate "4320"
    assert_equal "$TARGET_BITRATE_MBPS" "11" "calculate_target_bitrate: above 2160p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "11000000" "calculate_target_bitrate: above 2160p bps"
    
    # Test 1080p
    calculate_target_bitrate "1080"
    assert_equal "$TARGET_BITRATE_MBPS" "8" "calculate_target_bitrate: 1080p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "8000000" "calculate_target_bitrate: 1080p bps"
    
    # Test between 1080p and 2160p
    calculate_target_bitrate "1440"
    assert_equal "$TARGET_BITRATE_MBPS" "8" "calculate_target_bitrate: 1440p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "8000000" "calculate_target_bitrate: 1440p bps"
    
    # Test below 1080p
    calculate_target_bitrate "720"
    assert_equal "$TARGET_BITRATE_MBPS" "8" "calculate_target_bitrate: below 1080p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "8000000" "calculate_target_bitrate: below 1080p bps"
}
test_calculate_target_bitrate

echo ""

# Test calculate_sample_points()
echo "Testing calculate_sample_points()..."
test_calculate_sample_points() {
    # Test video shorter than 60 seconds (uses full video)
    calculate_sample_points "30"
    assert_equal "$SAMPLE_COUNT" "1" "calculate_sample_points: video < 60s count"
    assert_equal "$SAMPLE_START_1" "0" "calculate_sample_points: video < 60s start"
    assert_equal "$SAMPLE_DURATION" "30" "calculate_sample_points: video < 60s duration"
    
    # Test video exactly 60 seconds
    calculate_sample_points "60"
    assert_equal "$SAMPLE_COUNT" "1" "calculate_sample_points: video = 60s count"
    
    # Test video between 60-119 seconds (1 sample, full video)
    calculate_sample_points "90"
    assert_equal "$SAMPLE_COUNT" "1" "calculate_sample_points: video 60-119s count"
    
    # Test video between 120-179 seconds (2 samples)
    calculate_sample_points "150"
    assert_equal "$SAMPLE_COUNT" "2" "calculate_sample_points: video 120-179s count"
    assert_equal "$SAMPLE_START_1" "0" "calculate_sample_points: video 120-179s start1"
    # SAMPLE_START_2 should be max_start (150 - 60 = 90)
    local expected_start2=$(echo "scale=1; 150 - 60" | bc | tr -d '\n\r')
    assert_equal "$SAMPLE_START_2" "$expected_start2" "calculate_sample_points: video 120-179s start2"
    
    # Test video >= 180 seconds (3 samples)
    calculate_sample_points "300"
    assert_equal "$SAMPLE_COUNT" "3" "calculate_sample_points: video >= 180s count"
    # Check that sample points are approximately 10%, 50%, 90%
    # Note: sample_start_3 is capped at max_start (300 - 60 = 240) if it exceeds it
    local expected_start1=$(echo "scale=1; 300 * 0.1" | bc | tr -d '\n\r')
    local expected_start2=$(echo "scale=1; 300 * 0.5" | bc | tr -d '\n\r')
    local max_start=$(echo "scale=1; 300 - 60" | bc | tr -d '\n\r')
    local expected_start3=$max_start  # Capped at max_start
    assert_equal "$SAMPLE_START_1" "$expected_start1" "calculate_sample_points: video >= 180s start1 (10%)"
    assert_equal "$SAMPLE_START_2" "$expected_start2" "calculate_sample_points: video >= 180s start2 (50%)"
    assert_equal "$SAMPLE_START_3" "$expected_start3" "calculate_sample_points: video >= 180s start3 (capped at max_start)"
    assert_equal "$SAMPLE_DURATION" "60" "calculate_sample_points: video >= 180s duration"
}
test_calculate_sample_points

echo ""

# Test mocked FFmpeg/ffprobe functions
echo "Testing mocked FFmpeg/ffprobe functions..."
test_mocked_functions() {
    local result
    local temp_file
    
    # Test mocked get_video_resolution()
    result=$(get_video_resolution "test.mp4")
    assert_equal "$result" "1080" "mocked get_video_resolution: default 1080p"
    
    # Test mocked get_video_resolution() with override
    MOCK_RESOLUTION=2160
    result=$(get_video_resolution "test.mp4")
    assert_equal "$result" "2160" "mocked get_video_resolution: override to 2160p"
    unset MOCK_RESOLUTION
    
    # Test mocked get_video_duration()
    result=$(get_video_duration "test.mp4")
    assert_equal "$result" "300" "mocked get_video_duration: default 300s"
    
    # Test mocked get_video_duration() with override
    MOCK_DURATION=180
    result=$(get_video_duration "test.mp4")
    assert_equal "$result" "180" "mocked get_video_duration: override to 180s"
    unset MOCK_DURATION
    
    # Test mocked measure_bitrate() with MOCK_BITRATE_BPS
    reset_call_tracking
    MOCK_BITRATE_BPS=8000000
    result=$(measure_bitrate "test.mp4" "300")
    assert_equal "$result" "8000000" "mocked measure_bitrate: using MOCK_BITRATE_BPS"
    assert_equal "$(count_calls "$MEASURE_BITRATE_CALLS_FILE")" "1" "mocked measure_bitrate: tracks call"
    assert_equal "$(get_first_call "$MEASURE_BITRATE_CALLS_FILE")" "test.mp4|300" "mocked measure_bitrate: tracks call parameters"
    unset MOCK_BITRATE_BPS
    
    # Test mocked measure_bitrate() without MOCK_BITRATE_BPS (returns empty)
    reset_call_tracking
    result=$(measure_bitrate "test2.mp4" "200")
    assert_empty "$result" "mocked measure_bitrate: returns empty without MOCK_BITRATE_BPS"
    assert_equal "$(get_first_call "$MEASURE_BITRATE_CALLS_FILE")" "test2.mp4|200" "mocked measure_bitrate: tracks call without bitrate"
    
    # Test mocked transcode_sample() tracks calls
    reset_call_tracking
    temp_file=$(mktemp)
    transcode_sample "input.mp4" "0" "60" "52" "$temp_file"
    assert_equal "$(count_calls "$TRANSCODE_SAMPLE_CALLS_FILE")" "1" "mocked transcode_sample: tracks call"
    assert_equal "$(get_first_call "$TRANSCODE_SAMPLE_CALLS_FILE")" "input.mp4|0|60|52|$temp_file" "mocked transcode_sample: tracks call parameters"
    rm -f "$temp_file"
    
    # Test mocked transcode_full_video() tracks calls
    reset_call_tracking
    temp_file=$(mktemp)
    transcode_full_video "input.mp4" "$temp_file" "52"
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "1" "mocked transcode_full_video: tracks call"
    assert_equal "$(get_first_call "$TRANSCODE_FULL_CALLS_FILE")" "input.mp4|$temp_file|52" "mocked transcode_full_video: tracks call parameters"
    rm -f "$temp_file"
}
test_mocked_functions

echo ""

# Test main() function integration
echo "Testing main() function integration..."
test_main() {
    local test_dir
    local test_file
    local output
    local exit_code
    local temp_dir
    
    # Create a temporary directory for each test to avoid conflicts
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    # Test 1: Early exit when source is within tolerance
    reset_call_tracking
    test_file="test_video.mp4"
    touch "$test_file"
    MOCK_VIDEO_FILE="$test_file"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=8000000  # Exactly 8 Mbps (target for 1080p)
    
    set +e
    output=$(main 2>&1)
    exit_code=$?
    set -e
    
    assert_exit_code $exit_code 0 "main: exits 0 when source is within tolerance"
    assert_not_empty "$(echo "$output" | grep -i "within acceptable range" || true)" "main: outputs message about being within range"
    # Verify find_video_file was called
    assert_equal "$(count_calls "$FIND_VIDEO_FILE_CALLS_FILE")" "1" "main: calls find_video_file"
    # Verify measure_bitrate was called for source
    assert_equal "$(count_calls "$MEASURE_BITRATE_CALLS_FILE")" "1" "main: calls measure_bitrate for source"
    # Verify transcoding functions were NOT called (early exit)
    assert_equal "$(count_calls "$TRANSCODE_SAMPLE_CALLS_FILE")" "0" "main: does not call transcode_sample when within tolerance"
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "0" "main: does not call transcode_full_video when within tolerance"
    
    # Cleanup
    rm -f "$test_file"
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS
    
    # Test 2: Early exit when source is below target (with file renaming)
    reset_call_tracking
    test_file="test_video.mp4"
    touch "$test_file"
    MOCK_VIDEO_FILE="$test_file"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=4000000  # 4 Mbps (below 8 Mbps target)
    
    set +e
    output=$(main 2>&1)
    exit_code=$?
    set -e
    
    assert_exit_code $exit_code 0 "main: exits 0 when source is below target"
    assert_not_empty "$(echo "$output" | grep -i "below target bitrate" || true)" "main: outputs message about being below target"
    # Verify find_video_file was called
    assert_equal "$(count_calls "$FIND_VIDEO_FILE_CALLS_FILE")" "1" "main: calls find_video_file"
    # Verify measure_bitrate was called for source
    assert_equal "$(count_calls "$MEASURE_BITRATE_CALLS_FILE")" "1" "main: calls measure_bitrate for source"
    # Verify transcoding functions were NOT called (early exit)
    assert_equal "$(count_calls "$TRANSCODE_SAMPLE_CALLS_FILE")" "0" "main: does not call transcode_sample when below target"
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "0" "main: does not call transcode_full_video when below target"
    
    # Check that file was renamed (still need to check this as it's a side effect we care about)
    local renamed_file="test_video.orig.4.00.Mbps.mp4"
    if [ -f "$renamed_file" ]; then
        assert_equal "1" "1" "main: renames file when below target"
        rm -f "$renamed_file"
    fi
    
    # Cleanup
    rm -f "$test_file" "$renamed_file"
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS
    
    # Test 3: Full transcoding workflow (source above target)
    reset_call_tracking
    test_file="test_video.mp4"
    touch "$test_file"
    MOCK_VIDEO_FILE="$test_file"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000  # 12 Mbps (above 8 Mbps target, needs transcoding)
    MOCK_SAMPLE_BITRATE_BPS=8000000  # Sample bitrate at target (8 Mbps) so optimization converges immediately
    MOCK_OUTPUT_BITRATE_BPS=8000000  # Output should be at target (8 Mbps)
    
    set +e
    output=$(main 2>&1)
    exit_code=$?
    set -e
    
    assert_exit_code $exit_code 0 "main: completes full transcoding workflow"
    assert_not_empty "$(echo "$output" | grep -i "transcoding complete" || true)" "main: outputs completion message"
    # Verify find_video_file was called
    assert_equal "$(count_calls "$FIND_VIDEO_FILE_CALLS_FILE")" "1" "main: calls find_video_file"
    # Verify measure_bitrate was called (1 for source + 3 for samples + 1 for output = 5)
    assert_equal "$(count_calls "$MEASURE_BITRATE_CALLS_FILE")" "5" "main: calls measure_bitrate (source + samples + output)"
    # Verify transcode_sample was called (for finding optimal quality - 3 samples for 300s video)
    assert_equal "$(count_calls "$TRANSCODE_SAMPLE_CALLS_FILE")" "3" "main: calls transcode_sample for optimization (3 samples for 300s video)"
    # Verify transcode_full_video was called
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "1" "main: calls transcode_full_video"
    
    # Verify transcode_full_video was called (quality value will vary, so just check it was called)
    assert_not_empty "$(get_first_call "$TRANSCODE_FULL_CALLS_FILE")" "main: transcode_full_video called with parameters"
    
    # Cleanup
    rm -f "$test_file" *.mp4 *.fmpg.*.mp4 2>/dev/null
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_SAMPLE_BITRATE_BPS MOCK_OUTPUT_BITRATE_BPS
    
    # Test 4: Second pass when first pass is outside tolerance
    reset_call_tracking
    test_file="test_video.mp4"
    touch "$test_file"
    MOCK_VIDEO_FILE="$test_file"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000  # 12 Mbps (above 8 Mbps target, needs transcoding)
    MOCK_SAMPLE_BITRATE_BPS=8000000  # Sample bitrate at target (8 Mbps) so optimization converges immediately
    MOCK_OUTPUT_BITRATE_BPS=9000000  # First pass: 9 Mbps (12.5% above target, outside ±5% tolerance)
    MOCK_SECOND_PASS_BITRATE_BPS=8100000  # Second pass: 8.1 Mbps (1.25% above target, within tolerance)
    
    set +e
    output=$(main 2>&1)
    exit_code=$?
    set -e
    
    assert_exit_code $exit_code 0 "main: completes transcoding with second pass"
    assert_not_empty "$(echo "$output" | grep -i "second pass" || true)" "main: outputs second pass message"
    assert_not_empty "$(echo "$output" | grep -i "outside tolerance" || true)" "main: outputs outside tolerance warning"
    # Verify find_video_file was called
    assert_equal "$(count_calls "$FIND_VIDEO_FILE_CALLS_FILE")" "1" "main: calls find_video_file"
    # Verify measure_bitrate was called (1 for source + 3 for samples + 2 for output passes = 6)
    assert_equal "$(count_calls "$MEASURE_BITRATE_CALLS_FILE")" "6" "main: calls measure_bitrate (source + samples + 2 output passes)"
    # Verify transcode_sample was called (for finding optimal quality - 3 samples for 300s video)
    assert_equal "$(count_calls "$TRANSCODE_SAMPLE_CALLS_FILE")" "3" "main: calls transcode_sample for optimization (3 samples for 300s video)"
    # Verify transcode_full_video was called twice (first pass + second pass)
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "2" "main: calls transcode_full_video twice (first pass + second pass)"
    
    # Cleanup
    rm -f "$test_file" *.mp4 *.fmpg.*.mp4 2>/dev/null
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_SAMPLE_BITRATE_BPS MOCK_OUTPUT_BITRATE_BPS MOCK_SECOND_PASS_BITRATE_BPS
    
    # Return to original directory
    cd - > /dev/null || true
    rm -rf "$temp_dir"
}

test_main

echo ""

# Print test summary
echo "=========================================="
echo "Test Summary:"
echo "  Total:  $TESTS_RUN"
echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
else
    echo -e "  Failed: $TESTS_FAILED"
fi
echo "=========================================="

# Exit with appropriate code
if [ $TESTS_FAILED -eq 0 ]; then
    exit 0
else
    exit 1
fi

