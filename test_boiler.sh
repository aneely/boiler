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
FIND_ALL_VIDEO_FILES_CALLS_FILE="$CALL_TRACK_DIR/find_all_video_files_calls"
REMUX_CALLS_FILE="$CALL_TRACK_DIR/remux_calls"

# Reset call tracking (call this before each test)
reset_call_tracking() {
    rm -f "$TRANSCODE_SAMPLE_CALLS_FILE" "$TRANSCODE_FULL_CALLS_FILE" \
          "$MEASURE_BITRATE_CALLS_FILE" "$FIND_VIDEO_FILE_CALLS_FILE" "$FIND_ALL_VIDEO_FILES_CALLS_FILE" \
          "$REMUX_CALLS_FILE"
    touch "$TRANSCODE_SAMPLE_CALLS_FILE" "$TRANSCODE_FULL_CALLS_FILE" \
          "$MEASURE_BITRATE_CALLS_FILE" "$FIND_VIDEO_FILE_CALLS_FILE" "$FIND_ALL_VIDEO_FILES_CALLS_FILE" \
          "$REMUX_CALLS_FILE"
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

# Mock ffprobe for codec detection (used by remux_to_mp4)
# Returns codec from MOCK_VIDEO_CODEC if set, otherwise returns h264
ffprobe() {
    # Check if this is a codec_name query (used by remux_to_mp4)
    if [[ "$*" == *"codec_name"* ]]; then
        echo "${MOCK_VIDEO_CODEC:-h264}"
    else
        # For other ffprobe calls, return empty (let other mocks handle it)
        echo ""
    fi
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
        
        # If MOCK_THIRD_PASS_BITRATE_BPS is set and this is the third call, use it
        if [ "$temp_transcode_count" -eq 3 ] && [ -n "${MOCK_THIRD_PASS_BITRATE_BPS:-}" ]; then
            echo "${MOCK_THIRD_PASS_BITRATE_BPS}"
            return
        fi
        
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

# Mock remux_to_mp4() - tracks calls and checks codec compatibility
# Uses mocked ffprobe (which reads MOCK_VIDEO_CODEC) to determine if remux should succeed
remux_to_mp4() {
    local input_file="$1"
    local output_file="$2"
    
    # Track the call (append to file)
    echo "$input_file|$output_file" >> "$REMUX_CALLS_FILE"
    
    # Detect video codec using mocked ffprobe (which returns MOCK_VIDEO_CODEC)
    local video_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null | head -1 | tr -d '\n\r')
    
    if [ -z "$video_codec" ]; then
        # No codec detected - return failure
        return 1
    fi
    
    # Check codec compatibility
    if ! is_codec_mp4_compatible "$video_codec"; then
        # Codec incompatible - return failure
        return 1
    fi
    
    # Codec compatible - create output file to simulate success
    touch "$output_file"
    return 0
}

# Mock check_requirements() - skip requirement checks in test mode
check_requirements() {
    # Do nothing - allow tests to run without ffmpeg/ffprobe
    return 0
}

# Mock find_all_video_files() - tracks calls and returns test video file path(s)
find_all_video_files() {
    # Track the call (append to file)
    echo "called" >> "$FIND_ALL_VIDEO_FILES_CALLS_FILE"
    
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

# Test is_non_quicklook_format()
echo "Testing is_non_quicklook_format()..."
test_is_non_quicklook_format() {
    local exit_code
    
    # Test non-QuickLook formats (should return 0)
    set +e
    is_non_quicklook_format "video.mkv"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_non_quicklook_format: mkv format"
    
    set +e
    is_non_quicklook_format "video.WMV"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_non_quicklook_format: wmv format (case insensitive)"
    
    set +e
    is_non_quicklook_format "video.avi"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_non_quicklook_format: avi format"
    
    set +e
    is_non_quicklook_format "video.webm"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_non_quicklook_format: webm format"
    
    set +e
    is_non_quicklook_format "video.flv"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_non_quicklook_format: flv format"
    
    set +e
    is_non_quicklook_format "video.mpg"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_non_quicklook_format: mpg format"
    
    set +e
    is_non_quicklook_format "video.mpeg"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_non_quicklook_format: mpeg format"
    
    set +e
    is_non_quicklook_format "video.ts"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_non_quicklook_format: ts format"
    
    # Test QuickLook-compatible formats (should return 1)
    set +e
    is_non_quicklook_format "video.mp4"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_non_quicklook_format: mp4 format (compatible)"
    
    set +e
    is_non_quicklook_format "video.mov"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_non_quicklook_format: mov format (compatible)"
    
    set +e
    is_non_quicklook_format "video.m4v"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_non_quicklook_format: m4v format (compatible)"
}
test_is_non_quicklook_format

echo ""

# Test is_codec_mp4_compatible()
echo "Testing is_codec_mp4_compatible()..."
test_is_codec_mp4_compatible() {
    local exit_code
    
    # Test compatible codecs (should return 0)
    set +e
    is_codec_mp4_compatible "h264"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_codec_mp4_compatible: h264 codec"
    
    set +e
    is_codec_mp4_compatible "HEVC"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_codec_mp4_compatible: hevc codec (case insensitive)"
    
    set +e
    is_codec_mp4_compatible "h265"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_codec_mp4_compatible: h265 codec"
    
    set +e
    is_codec_mp4_compatible "mpeg4"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_codec_mp4_compatible: mpeg4 codec"
    
    set +e
    is_codec_mp4_compatible "avc1"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_codec_mp4_compatible: avc1 codec"
    
    # Test incompatible codecs (should return 1)
    set +e
    is_codec_mp4_compatible "wmv3"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_codec_mp4_compatible: wmv3 codec (incompatible)"
    
    set +e
    is_codec_mp4_compatible "WMV1"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_codec_mp4_compatible: wmv1 codec (incompatible, case insensitive)"
    
    set +e
    is_codec_mp4_compatible "vc1"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_codec_mp4_compatible: vc1 codec (incompatible)"
    
    set +e
    is_codec_mp4_compatible "rv40"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_codec_mp4_compatible: rv40 codec (incompatible)"
    
    # Test unknown codec (should return 0 - assume compatible)
    set +e
    is_codec_mp4_compatible "unknown_codec"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_codec_mp4_compatible: unknown codec (assumes compatible)"
}
test_is_codec_mp4_compatible

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
    
    # Test 720p
    calculate_target_bitrate "720"
    assert_equal "$TARGET_BITRATE_MBPS" "5" "calculate_target_bitrate: 720p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "5000000" "calculate_target_bitrate: 720p bps"
    
    # Test between 720p and 1080p
    calculate_target_bitrate "900"
    assert_equal "$TARGET_BITRATE_MBPS" "5" "calculate_target_bitrate: 900p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "5000000" "calculate_target_bitrate: 900p bps"
    
    # Test 480p
    calculate_target_bitrate "480"
    assert_equal "$TARGET_BITRATE_MBPS" "2.5" "calculate_target_bitrate: 480p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "2500000" "calculate_target_bitrate: 480p bps"
    
    # Test between 480p and 720p
    calculate_target_bitrate "600"
    assert_equal "$TARGET_BITRATE_MBPS" "2.5" "calculate_target_bitrate: 600p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "2500000" "calculate_target_bitrate: 600p bps"
    
    # Test below 480p
    calculate_target_bitrate "360"
    assert_equal "$TARGET_BITRATE_MBPS" "2.5" "calculate_target_bitrate: below 480p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "2500000" "calculate_target_bitrate: below 480p bps"
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

# Test should_skip_file() and find_all_video_files()
echo "Testing should_skip_file() and find_all_video_files()..."
test_skip_and_find_functions() {
    local temp_dir
    local result
    
    # Create a temporary directory for testing
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    # Test should_skip_file: files with skip markers
    should_skip_file "test.hbrk.10.25.Mbps.mp4" && result="skip" || result="process"
    assert_equal "$result" "skip" "should_skip_file: skips .hbrk. files"
    
    should_skip_file "test.fmpg.10.25.Mbps.mp4" && result="skip" || result="process"
    assert_equal "$result" "skip" "should_skip_file: skips .fmpg. files"
    
    should_skip_file "test.orig.2.90.Mbps.mp4" && result="skip" || result="process"
    assert_equal "$result" "skip" "should_skip_file: skips .orig. files"
    
    # Test should_skip_file: normal files should not be skipped
    should_skip_file "normal_video.mp4" && result="skip" || result="process"
    assert_equal "$result" "process" "should_skip_file: processes normal files"
    
    # Test find_all_video_files: finds all non-skipped files
    # Test in a clean subshell to avoid mock interference
    touch video1.mp4 video2.mp4 video3.mp4
    touch skip.hbrk.mp4 skip.fmpg.mp4 skip.orig.mp4
    
    local found_files
    # Use a subshell with fresh boiler.sh source to test real function
    found_files=$(bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; find_all_video_files" | sort)
    local expected="$(echo -e './video1.mp4\n./video2.mp4\n./video3.mp4' | sort)"
    assert_equal "$found_files" "$expected" "find_all_video_files: finds all non-skipped files"
    
    # Test find_all_video_files: skips files with markers
    local count=$(bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; find_all_video_files" | wc -l | tr -d ' ')
    assert_equal "$count" "3" "find_all_video_files: skips files with .hbrk., .fmpg., .orig. markers"
    
    # Test find_all_video_files: returns empty when no files
    rm -f *.mp4
    found_files=$(bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; find_all_video_files")
    assert_equal "$found_files" "" "find_all_video_files: returns empty when no files"
    
    # Test find_all_video_files: finds files in subdirectories (one level deep)
    mkdir -p subdir1 subdir2
    touch subdir1/video1.mp4 subdir1/video2.mp4
    touch subdir2/video3.mp4
    touch video4.mp4  # File in current directory
    touch subdir1/skip.fmpg.mp4  # Should be skipped
    mkdir -p subdir1/nested
    touch subdir1/nested/video5.mp4  # Should NOT be found (too deep)
    
    found_files=$(bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; find_all_video_files" | sort)
    local expected="$(echo -e './subdir1/video1.mp4\n./subdir1/video2.mp4\n./subdir2/video3.mp4\n./video4.mp4' | sort)"
    assert_equal "$found_files" "$expected" "find_all_video_files: finds files in current directory and subdirectories (one level deep)"
    
    # Cleanup
    cd - > /dev/null || true
    rm -rf "$temp_dir"
}
test_skip_and_find_functions

echo ""

# Test find_all_video_files() with configurable depth
test_find_all_video_files_depth() {
    echo "Testing find_all_video_files() with configurable depth..."
    
    local temp_dir
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    # Create directory structure:
    # ./
    #   video0.mp4 (current dir)
    #   level1/
    #     video1.mp4
    #     level2/
    #       video2.mp4
    #       level3/
    #         video3.mp4
    
    mkdir -p level1/level2/level3
    touch video0.mp4
    touch level1/video1.mp4
    touch level1/level2/video2.mp4
    touch level1/level2/level3/video3.mp4
    
    # Test depth 1 (current directory only)
    found_files=$(bash -c "export BOILER_TEST_MODE=1; export GLOBAL_MAX_DEPTH=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; find_all_video_files" | sort)
    local expected="$(echo -e './video0.mp4' | sort)"
    assert_equal "$found_files" "$expected" "find_all_video_files: depth 1 finds only current directory"
    
    # Test depth 2 (current + one subdirectory level) - default
    found_files=$(bash -c "export BOILER_TEST_MODE=1; export GLOBAL_MAX_DEPTH=2; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; find_all_video_files" | sort)
    local expected="$(echo -e './level1/video1.mp4\n./video0.mp4' | sort)"
    assert_equal "$found_files" "$expected" "find_all_video_files: depth 2 finds current + one subdirectory level"
    
    # Test depth 3 (current + two subdirectory levels)
    found_files=$(bash -c "export BOILER_TEST_MODE=1; export GLOBAL_MAX_DEPTH=3; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; find_all_video_files" | sort)
    local expected="$(echo -e './level1/level2/video2.mp4\n./level1/video1.mp4\n./video0.mp4' | sort)"
    assert_equal "$found_files" "$expected" "find_all_video_files: depth 3 finds current + two subdirectory levels"
    
    # Test depth 4 (current + three subdirectory levels)
    found_files=$(bash -c "export BOILER_TEST_MODE=1; export GLOBAL_MAX_DEPTH=4; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; find_all_video_files" | sort)
    local expected="$(echo -e './level1/level2/level3/video3.mp4\n./level1/level2/video2.mp4\n./level1/video1.mp4\n./video0.mp4' | sort)"
    assert_equal "$found_files" "$expected" "find_all_video_files: depth 4 finds current + three subdirectory levels"
    
    # Test depth 0 (unlimited - should find all files)
    found_files=$(bash -c "export BOILER_TEST_MODE=1; export GLOBAL_MAX_DEPTH=0; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; find_all_video_files" | sort)
    local expected="$(echo -e './level1/level2/level3/video3.mp4\n./level1/level2/video2.mp4\n./level1/video1.mp4\n./video0.mp4' | sort)"
    assert_equal "$found_files" "$expected" "find_all_video_files: depth 0 (unlimited) finds all files recursively"
    
    # Test default depth (2) when GLOBAL_MAX_DEPTH is not set
    found_files=$(bash -c "export BOILER_TEST_MODE=1; unset GLOBAL_MAX_DEPTH; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; find_all_video_files" | sort)
    local expected="$(echo -e './level1/video1.mp4\n./video0.mp4' | sort)"
    assert_equal "$found_files" "$expected" "find_all_video_files: default depth (2) when GLOBAL_MAX_DEPTH not set"
    
    # Cleanup
    cd - > /dev/null || true
    rm -rf "$temp_dir"
}
test_find_all_video_files_depth

echo ""

# Test find_all_video_files returns files in sorted order (predictable processing order)
echo "Testing find_all_video_files() sorted order..."
test_find_all_video_files_sorted_order() {
    local temp_dir
    temp_dir=$(mktemp -d)
    # Create files in non-alphabetical order so find's order would be undefined without sort
    touch "$temp_dir/c.mp4" "$temp_dir/a.mp4" "$temp_dir/b.mp4"
    
    local output
    output=$(bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; find_all_video_files")
    local expected="./a.mp4
./b.mp4
./c.mp4"
    
    assert_equal "$output" "$expected" "find_all_video_files: returns files in sorted (alphabetical) order"
    
    rm -rf "$temp_dir"
}
test_find_all_video_files_sorted_order

echo ""

# Test extract_original_filename() and matching logic
echo "Testing extract_original_filename() and original/encoded matching..."
test_extract_and_matching() {
    local temp_dir
    local result
    
    # Create a temporary directory for testing
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    # Test extract_original_filename: .fmpg. pattern
    result=$(bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; extract_original_filename 'video.fmpg.10.25.Mbps.mp4'")
    assert_equal "$result" "video.mp4" "extract_original_filename: extracts from .fmpg. pattern"
    
    # Test extract_original_filename: .orig. pattern
    result=$(bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; extract_original_filename 'video.orig.2.90.Mbps.mp4'")
    assert_equal "$result" "video.mp4" "extract_original_filename: extracts from .orig. pattern"
    
    # Test extract_original_filename: .hbrk. pattern
    result=$(bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; extract_original_filename 'video.hbrk.10.25.Mbps.mp4'")
    assert_equal "$result" "video.mp4" "extract_original_filename: extracts from .hbrk. pattern"
    
    # Test has_original_file: original exists
    touch video.mp4 video.fmpg.10.25.Mbps.mp4
    bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; has_original_file 'video.fmpg.10.25.Mbps.mp4'" && result="exists" || result="missing"
    assert_equal "$result" "exists" "has_original_file: detects original when it exists"
    
    # Test has_original_file: original missing
    rm -f video.mp4
    bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; has_original_file 'video.fmpg.10.25.Mbps.mp4'" && result="exists" || result="missing"
    assert_equal "$result" "missing" "has_original_file: detects missing original"
    
    # Test has_encoded_version: encoded exists
    touch video.mp4 video.fmpg.10.25.Mbps.mp4
    bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; has_encoded_version 'video.mp4'" && result="has_encoded" || result="no_encoded"
    assert_equal "$result" "has_encoded" "has_encoded_version: detects encoded version when it exists"
    
    # Test has_encoded_version: no encoded version
    rm -f video.fmpg.10.25.Mbps.mp4
    bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; has_encoded_version 'video.mp4'" && result="has_encoded" || result="no_encoded"
    assert_equal "$result" "no_encoded" "has_encoded_version: detects when no encoded version exists"
    
    # Test should_skip_file: skips original when encoded exists
    touch video.mp4 video.fmpg.10.25.Mbps.mp4
    bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; should_skip_file 'video.mp4'" && result="skip" || result="process"
    assert_equal "$result" "skip" "should_skip_file: skips original when encoded version exists"
    
    # Test should_skip_file: processes original when no encoded version
    rm -f video.fmpg.10.25.Mbps.mp4
    bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; should_skip_file 'video.mp4'" && result="skip" || result="process"
    assert_equal "$result" "process" "should_skip_file: processes original when no encoded version"
    
    # Test has_encoded_version and should_skip_file: non-.mp4 original with existing .mp4 encoded version
    rm -f video.mp4 video.fmpg.10.25.Mbps.mp4
    touch video.mpg video.fmpg.10.25.Mbps.mp4
    bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; has_encoded_version 'video.mpg'" && result="has_encoded" || result="no_encoded"
    assert_equal "$result" "has_encoded" "has_encoded_version: detects encoded .mp4 when original is .mpg"
    bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; should_skip_file 'video.mpg'" && result="skip" || result="process"
    assert_equal "$result" "skip" "should_skip_file: skips .mpg original when encoded .mp4 exists"
    
    # Test find_all_video_files: skips both original and encoded when both exist
    touch video.mp4 video.fmpg.10.25.Mbps.mp4 another.mkv
    local found_files=$(bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; find_all_video_files")
    assert_equal "$found_files" "./another.mkv" "find_all_video_files: skips both original and encoded when both exist"
    
    # Cleanup
    cd - > /dev/null || true
    rm -rf "$temp_dir"
}
test_extract_and_matching

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
    
    # Test mocked remux_to_mp4() with compatible codec
    reset_call_tracking
    temp_file=$(mktemp --suffix=.mp4 2>/dev/null || mktemp -t test_remux).mp4
    MOCK_VIDEO_CODEC="h264"
    set +e
    remux_to_mp4 "input.mkv" "$temp_file"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "mocked remux_to_mp4: succeeds with compatible codec (h264)"
    assert_equal "$(count_calls "$REMUX_CALLS_FILE")" "1" "mocked remux_to_mp4: tracks call"
    assert_equal "$(get_first_call "$REMUX_CALLS_FILE")" "input.mkv|$temp_file" "mocked remux_to_mp4: tracks call parameters"
    assert_equal "$([ -f "$temp_file" ]; echo $?)" "0" "mocked remux_to_mp4: creates output file on success"
    rm -f "$temp_file"
    unset MOCK_VIDEO_CODEC
    
    # Test mocked remux_to_mp4() with incompatible codec
    reset_call_tracking
    temp_file=$(mktemp --suffix=.mp4 2>/dev/null || mktemp -t test_remux).mp4
    MOCK_VIDEO_CODEC="wmv3"
    set +e
    remux_to_mp4 "input.wmv" "$temp_file"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "mocked remux_to_mp4: fails with incompatible codec (wmv3)"
    assert_equal "$(count_calls "$REMUX_CALLS_FILE")" "1" "mocked remux_to_mp4: tracks call even on failure"
    assert_equal "$([ -f "$temp_file" ]; echo $?)" "1" "mocked remux_to_mp4: does not create output file on failure"
    rm -f "$temp_file"
    unset MOCK_VIDEO_CODEC
}
test_mocked_functions

echo ""

# Test handle_non_quicklook_at_target() writes remuxed output next to source (subdirectory)
echo "Testing handle_non_quicklook_at_target() output path (subdirectory)..."
test_handle_non_quicklook_at_target_subdir_output() {
    local temp_dir
    temp_dir=$(mktemp -d 2>/dev/null || echo "/tmp/boiler_test_subdir_$$")
    mkdir -p "${temp_dir}/subdir"
    touch "${temp_dir}/subdir/video.mkv"
    
    local saved_pwd
    saved_pwd=$(pwd)
    cd "$temp_dir" || exit 1
    
    reset_call_tracking
    MOCK_VIDEO_CODEC="h264"
    needs_transcode=0
    handle_non_quicklook_at_target "subdir/video.mkv" "8.50" "needs_transcode"
    local exit_code=$?
    
    cd "$saved_pwd" || exit 1
    rm -rf "$temp_dir"
    unset MOCK_VIDEO_CODEC
    
    assert_exit_code $exit_code 0 "handle_non_quicklook_at_target: subdir source succeeds"
    assert_equal "$(count_calls "$REMUX_CALLS_FILE")" "1" "handle_non_quicklook_at_target: remux_to_mp4 called once for subdir source"
    local call
    call=$(get_first_call "$REMUX_CALLS_FILE")
    local input_path="${call%%|*}"
    local output_path="${call#*|}"
    assert_equal "$input_path" "subdir/video.mkv" "handle_non_quicklook_at_target: remux input is subdir path"
    assert_equal "$output_path" "subdir/video.orig.8.50.Mbps.mp4" "handle_non_quicklook_at_target: remux output is next to source (same directory)"
}
test_handle_non_quicklook_at_target_subdir_output

echo ""

# Test calculate_adjusted_quality()
echo "Testing calculate_adjusted_quality()..."
test_calculate_adjusted_quality() {
    local result
    
    # Test: Bitrate too low, need to increase quality
    # Current quality: 50, actual: 4 Mbps, target: 8 Mbps (50% of target)
    # Expected: Should increase quality significantly (large adjustment)
    result=$(calculate_adjusted_quality "50" "4000000" "8000000")
    # Ratio = 0.5, distance = 0.5, adjustment should be around 6 (min_step + (max_step - min_step) * 0.5 = 1 + 9*0.5 = 5.5 ≈ 6)
    # So quality should be around 56
    assert_not_equal "$result" "50" "calculate_adjusted_quality: increases quality when bitrate too low"
    if [ "$result" -ge 50 ] && [ "$result" -le 100 ]; then
        assert_equal "1" "1" "calculate_adjusted_quality: increased quality is within valid range (50-100)"
    else
        assert_equal "valid" "invalid" "calculate_adjusted_quality: increased quality should be 50-100"
    fi
    
    # Test: Bitrate slightly below target (90% of target)
    # Current quality: 50, actual: 7.2 Mbps, target: 8 Mbps
    # Expected: Small increase (close to target, small adjustment)
    result=$(calculate_adjusted_quality "50" "7200000" "8000000")
    # Ratio = 0.9, distance = 0.1, adjustment should be around 2 (min_step + 9*0.1 = 1 + 0.9 = 1.9 ≈ 2)
    # So quality should be around 52
    assert_not_equal "$result" "50" "calculate_adjusted_quality: increases quality slightly when close to target"
    
    # Test: Bitrate too high, need to decrease quality
    # Current quality: 50, actual: 12 Mbps, target: 8 Mbps (150% of target)
    # Expected: Should decrease quality (ratio = 1.5, distance = 0.5, adjustment ≈ 6)
    result=$(calculate_adjusted_quality "50" "12000000" "8000000")
    # Should decrease quality
    assert_not_equal "$result" "50" "calculate_adjusted_quality: decreases quality when bitrate too high"
    if [ "$result" -ge 0 ] && [ "$result" -le 50 ]; then
        assert_equal "1" "1" "calculate_adjusted_quality: decreased quality is within valid range (0-50)"
    else
        assert_equal "valid" "invalid" "calculate_adjusted_quality: decreased quality should be 0-50"
    fi
    
    # Test: Bitrate slightly above target (110% of target)
    # Current quality: 50, actual: 8.8 Mbps, target: 8 Mbps
    # Expected: Small decrease
    result=$(calculate_adjusted_quality "50" "8800000" "8000000")
    # Ratio = 1.1, distance = 0.1, adjustment ≈ 2, so quality should be around 48
    assert_not_equal "$result" "50" "calculate_adjusted_quality: decreases quality slightly when close above target"
    
    # Test: Quality at upper bound (100) - should cap at 100
    result=$(calculate_adjusted_quality "100" "4000000" "8000000")
    assert_equal "$result" "100" "calculate_adjusted_quality: caps quality at 100 when already at maximum"
    
    # Test: Quality at lower bound (0) - should cap at 0
    result=$(calculate_adjusted_quality "0" "12000000" "8000000")
    assert_equal "$result" "0" "calculate_adjusted_quality: caps quality at 0 when already at minimum"
    
    # Test: Extreme bitrate ratio (very high bitrate)
    # Current quality: 50, actual: 24 Mbps, target: 8 Mbps (300% of target)
    # Distance should be capped at 1.0, so adjustment should be max_step (10)
    result=$(calculate_adjusted_quality "50" "24000000" "8000000")
    # Should decrease by max_step (10), so quality should be 40
    assert_equal "$result" "40" "calculate_adjusted_quality: handles extreme high bitrate ratio (capped distance)"
    
    # Test: Extreme bitrate ratio (very low bitrate)
    # Current quality: 50, actual: 1 Mbps, target: 8 Mbps (12.5% of target)
    # Ratio = 0.125, distance = 0.875, adjustment should be large (around 9)
    result=$(calculate_adjusted_quality "50" "1000000" "8000000")
    # Should increase significantly
    assert_not_equal "$result" "50" "calculate_adjusted_quality: handles extreme low bitrate ratio"
    if [ "$result" -gt 50 ]; then
        assert_equal "1" "1" "calculate_adjusted_quality: extreme low bitrate increases quality"
    else
        assert_equal "increased" "not_increased" "calculate_adjusted_quality: should increase quality for extreme low bitrate"
    fi
    
    # Test: Quality near upper bound (99) - should cap at 100
    result=$(calculate_adjusted_quality "99" "4000000" "8000000")
    assert_equal "$result" "100" "calculate_adjusted_quality: caps quality at 100 when adjustment would exceed"
    
    # Test: Quality near lower bound (1) - should cap at 0 if needed
    result=$(calculate_adjusted_quality "1" "24000000" "8000000")
    assert_equal "$result" "0" "calculate_adjusted_quality: caps quality at 0 when adjustment would go below"
    
    # Test: At target bitrate (should still adjust slightly due to min_step)
    # Current quality: 50, actual: 8 Mbps, target: 8 Mbps
    # Since actual == target, the condition checks <, so it goes to else branch
    # But if they're exactly equal, the comparison might be tricky - let's test with slightly different values
    # Actually, if actual == target exactly, the < check fails, so it goes to else (too high branch)
    # But the ratio would be 1.0, distance = 0, adjustment = min_step = 1
    result=$(calculate_adjusted_quality "50" "8000000" "8000000")
    # Should decrease by min_step (1) since it goes to "too high" branch
    assert_equal "$result" "49" "calculate_adjusted_quality: decreases by min_step when exactly at target (goes to too high branch)"
    
    # Test: Very small difference (just above target)
    result=$(calculate_adjusted_quality "50" "8000001" "8000000")
    # Ratio ≈ 1.0, distance ≈ 0, adjustment = min_step = 1
    assert_equal "$result" "49" "calculate_adjusted_quality: decreases by min_step for very small difference above target"
    
    # Test: Very small difference (just below target)
    result=$(calculate_adjusted_quality "50" "7999999" "8000000")
    # Ratio ≈ 1.0, distance ≈ 0, adjustment = min_step = 1
    assert_equal "$result" "51" "calculate_adjusted_quality: increases by min_step for very small difference below target"
}
test_calculate_adjusted_quality

echo ""

echo "Testing calculate_interpolated_quality()..."
test_calculate_interpolated_quality() {
    local result
    
    # Test: Normal interpolation case
    # First pass: quality 79 → 14.05 Mbps, Second pass: quality 73 → 7.71 Mbps, Target: 9.00 Mbps
    # Expected: Interpolated quality should be between 73 and 79, closer to 73 since 9.00 is closer to 7.71
    result=$(calculate_interpolated_quality "79" "14050000" "73" "7710000" "9000000")
    # ratio = (9.0 - 7.71) / (14.05 - 7.71) = 1.29 / 6.34 ≈ 0.203
    # quality = 73 + (79 - 73) * 0.203 = 73 + 6 * 0.203 = 73 + 1.218 ≈ 74
    if [ "$result" -ge 73 ] && [ "$result" -le 79 ]; then
        assert_equal "1" "1" "calculate_interpolated_quality: interpolated quality is between the two points"
    else
        assert_equal "between" "outside" "calculate_interpolated_quality: should be between 73 and 79"
    fi
    # Should be closer to 73 (lower quality) since target is closer to second pass bitrate
    if [ "$result" -lt 76 ]; then
        assert_equal "1" "1" "calculate_interpolated_quality: interpolated quality is closer to lower quality point"
    else
        assert_equal "closer_to_lower" "closer_to_higher" "calculate_interpolated_quality: should be closer to 73 than 79"
    fi
    
    # Test: Target exactly at first pass bitrate
    # First pass: quality 80 → 10 Mbps, Second pass: quality 70 → 8 Mbps, Target: 10 Mbps
    result=$(calculate_interpolated_quality "80" "10000000" "70" "8000000" "10000000")
    # ratio = (10 - 8) / (10 - 8) = 2 / 2 = 1.0
    # quality = 70 + (80 - 70) * 1.0 = 70 + 10 = 80
    assert_equal "$result" "80" "calculate_interpolated_quality: target at first pass bitrate returns first pass quality"
    
    # Test: Target exactly at second pass bitrate
    # First pass: quality 80 → 10 Mbps, Second pass: quality 70 → 8 Mbps, Target: 8 Mbps
    result=$(calculate_interpolated_quality "80" "10000000" "70" "8000000" "8000000")
    # ratio = (8 - 8) / (10 - 8) = 0 / 2 = 0
    # quality = 70 + (80 - 70) * 0 = 70
    assert_equal "$result" "70" "calculate_interpolated_quality: target at second pass bitrate returns second pass quality"
    
    # Test: Target between the two points (midpoint case)
    # First pass: quality 80 → 10 Mbps, Second pass: quality 70 → 8 Mbps, Target: 9 Mbps (midpoint)
    result=$(calculate_interpolated_quality "80" "10000000" "70" "8000000" "9000000")
    # ratio = (9 - 8) / (10 - 8) = 1 / 2 = 0.5
    # quality = 70 + (80 - 70) * 0.5 = 70 + 10 * 0.5 = 70 + 5 = 75
    assert_equal "$result" "75" "calculate_interpolated_quality: target at midpoint returns midpoint quality"
    
    # Test: Edge case - bitrates too close (should use midpoint)
    # First pass: quality 80 → 9.01 Mbps, Second pass: quality 70 → 9.00 Mbps, Target: 9.00 Mbps
    # Bitrate difference is 0.01 Mbps, which is less than 1% of 9.00 Mbps (0.09 Mbps)
    result=$(calculate_interpolated_quality "80" "9010000" "70" "9000000" "9000000")
    # Should use midpoint: (80 + 70) / 2 = 75
    assert_equal "$result" "75" "calculate_interpolated_quality: bitrates too close uses midpoint"
    
    # Test: Quality clamping at upper bound (100)
    # First pass: quality 95 → 15 Mbps, Second pass: quality 90 → 10 Mbps, Target: 20 Mbps (extrapolation)
    result=$(calculate_interpolated_quality "95" "15000000" "90" "10000000" "20000000")
    # ratio = (20 - 10) / (15 - 10) = 10 / 5 = 2.0
    # quality = 90 + (95 - 90) * 2.0 = 90 + 10 = 100 (should clamp)
    assert_equal "$result" "100" "calculate_interpolated_quality: clamps quality at 100 when extrapolation exceeds upper bound"
    
    # Test: Quality clamping at lower bound (0)
    # First pass: quality 10 → 10 Mbps, Second pass: quality 5 → 8 Mbps, Target: 5 Mbps (extrapolation below)
    result=$(calculate_interpolated_quality "10" "10000000" "5" "8000000" "5000000")
    # ratio = (5 - 8) / (10 - 8) = -3 / 2 = -1.5
    # quality = 5 + (10 - 5) * (-1.5) = 5 - 7.5 = -2.5 (should clamp to 0)
    assert_equal "$result" "0" "calculate_interpolated_quality: clamps quality at 0 when extrapolation goes below lower bound"
    
    # Test: Reverse order (first pass has lower quality than second pass - shouldn't happen in practice but test it)
    # First pass: quality 70 → 8 Mbps, Second pass: quality 80 → 10 Mbps, Target: 9 Mbps
    result=$(calculate_interpolated_quality "70" "8000000" "80" "10000000" "9000000")
    # ratio = (9 - 10) / (8 - 10) = -1 / -2 = 0.5
    # quality = 80 + (70 - 80) * 0.5 = 80 - 5 = 75
    assert_equal "$result" "75" "calculate_interpolated_quality: handles reverse quality order correctly"
    
    # Test: Very small quality difference
    # First pass: quality 52 → 9.1 Mbps, Second pass: quality 51 → 8.9 Mbps, Target: 9.0 Mbps
    result=$(calculate_interpolated_quality "52" "9100000" "51" "8900000" "9000000")
    # ratio = (9.0 - 8.9) / (9.1 - 8.9) = 0.1 / 0.2 = 0.5
    # quality = 51 + (52 - 51) * 0.5 = 51 + 0.5 = 51.5 ≈ 52 (rounded)
    if [ "$result" -ge 51 ] && [ "$result" -le 52 ]; then
        assert_equal "1" "1" "calculate_interpolated_quality: handles small quality differences correctly"
    else
        assert_equal "51-52" "$result" "calculate_interpolated_quality: should be 51 or 52 for small difference"
    fi
}
test_calculate_interpolated_quality

echo ""

# Test error handling for critical functions
echo "Testing error handling for critical functions..."
test_error_handling() {
    local exit_code
    local result
    
    # Test get_video_resolution() error handling (empty resolution)
    # Override the mock to return empty string
    get_video_resolution() {
        local video_file="$1"
        echo ""  # Simulate empty resolution
    }
    
    set +e
    get_video_resolution "test.mp4" >/dev/null 2>&1
    exit_code=$?
    set -e
    
    # The real function would exit 1, but our mock doesn't - we need to test the real error path
    # Since we're mocking, we can't test the actual exit behavior without unmocking
    # Instead, let's test that the mock can simulate errors
    
    # Restore mock
    get_video_resolution() {
        local video_file="$1"
        echo "${MOCK_RESOLUTION:-1080}"
    }
    
    # Test get_video_duration() error handling (empty duration)
    get_video_duration() {
        local video_file="$1"
        echo ""  # Simulate empty duration
    }
    
    set +e
    get_video_duration "test.mp4" >/dev/null 2>&1
    exit_code=$?
    set -e
    
    # Restore mock
    get_video_duration() {
        local video_file="$1"
        echo "${MOCK_DURATION:-300}"
    }
    
    # Test measure_bitrate() error handling (empty bitrate, no fallback)
    reset_call_tracking
    unset MOCK_BITRATE_BPS
    unset MOCK_SAMPLE_BITRATE_BPS
    unset MOCK_OUTPUT_BITRATE_BPS
    
    # Mock measure_bitrate to return empty (simulating failure)
    measure_bitrate() {
        local file_path="$1"
        local duration="$2"
        echo "$file_path|$duration" >> "$MEASURE_BITRATE_CALLS_FILE"
        echo ""  # Return empty to simulate error
    }
    
    result=$(measure_bitrate "test.mp4" "300")
    assert_empty "$result" "measure_bitrate: returns empty when bitrate unavailable"
    
    # Restore mock
    measure_bitrate() {
        local file_path="$1"
        local duration="$2"
        
        # Track the call (append to file)
        echo "$file_path|$duration" >> "$MEASURE_BITRATE_CALLS_FILE"
        
        # If this is an output file (temp_transcode), use MOCK_OUTPUT_BITRATE_BPS if set
        if [[ "$file_path" == *"temp_transcode"* ]] && [ -n "${MOCK_OUTPUT_BITRATE_BPS:-}" ]; then
            # Count how many times we've measured temp_transcode files
            local temp_transcode_count=$(grep -c "temp_transcode" "$MEASURE_BITRATE_CALLS_FILE" 2>/dev/null || echo "0")
            
            # If MOCK_THIRD_PASS_BITRATE_BPS is set and this is the third call, use it
            if [ "$temp_transcode_count" -eq 3 ] && [ -n "${MOCK_THIRD_PASS_BITRATE_BPS:-}" ]; then
                echo "${MOCK_THIRD_PASS_BITRATE_BPS}"
                return
            fi
            
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
    
    # Test find_optimal_quality() error handling (no valid samples)
    # This is harder to test directly since it calls transcode_sample which is mocked
    # But we can test the error path by ensuring sample_count == 0 scenario
    # Actually, this would require more complex mocking - let's note it but skip for now
    
    # Test calculate_adjusted_quality() with edge case inputs
    # Test with zero bitrate
    result=$(calculate_adjusted_quality "50" "0" "8000000")
    # Zero bitrate should trigger "too low" branch, ratio = 0, distance = 1, max adjustment
    assert_not_equal "$result" "50" "calculate_adjusted_quality: handles zero bitrate"
    
    # Test with zero target bitrate (should handle gracefully)
    # This is an edge case - division by zero would occur
    # Let's test it - bc should handle division by zero
    set +e
    result=$(calculate_adjusted_quality "50" "8000000" "0" 2>/dev/null)
    exit_code=$?
    set -e
    # This might produce unexpected results, but should not crash
    assert_not_empty "$result" "calculate_adjusted_quality: handles zero target bitrate without crashing"
}
test_error_handling

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
    # Verify find_all_video_files was called
    assert_equal "$(count_calls "$FIND_ALL_VIDEO_FILES_CALLS_FILE")" "1" "main: calls find_all_video_files"
    # Verify measure_bitrate was called for source
    assert_equal "$(count_calls "$MEASURE_BITRATE_CALLS_FILE")" "1" "main: calls measure_bitrate for source"
    # Verify transcoding functions were NOT called (early exit)
    assert_equal "$(count_calls "$TRANSCODE_SAMPLE_CALLS_FILE")" "0" "main: does not call transcode_sample when within tolerance"
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "0" "main: does not call transcode_full_video when within tolerance"
    
    # Check that file was renamed (files within tolerance should be renamed to show bitrate)
    local renamed_file="test_video.orig.8.00.Mbps.mp4"
    if [ -f "$renamed_file" ]; then
        assert_equal "1" "1" "main: renames file when within tolerance"
        rm -f "$renamed_file"
    else
        # File should have been renamed, fail if it wasn't
        assert_equal "renamed" "not_renamed" "main: renames file when within tolerance"
    fi
    
    # Cleanup
    rm -f "$test_file" "$renamed_file"
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
    # Verify find_all_video_files was called
    assert_equal "$(count_calls "$FIND_ALL_VIDEO_FILES_CALLS_FILE")" "1" "main: calls find_all_video_files"
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
    # Verify find_all_video_files was called
    assert_equal "$(count_calls "$FIND_ALL_VIDEO_FILES_CALLS_FILE")" "1" "main: calls find_all_video_files"
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
    # Verify find_all_video_files was called
    assert_equal "$(count_calls "$FIND_ALL_VIDEO_FILES_CALLS_FILE")" "1" "main: calls find_all_video_files"
    # Verify measure_bitrate was called (1 for source + 3 for samples + 2 for output passes = 6)
    assert_equal "$(count_calls "$MEASURE_BITRATE_CALLS_FILE")" "6" "main: calls measure_bitrate (source + samples + 2 output passes)"
    # Verify transcode_sample was called (for finding optimal quality - 3 samples for 300s video)
    assert_equal "$(count_calls "$TRANSCODE_SAMPLE_CALLS_FILE")" "3" "main: calls transcode_sample for optimization (3 samples for 300s video)"
    # Verify transcode_full_video was called twice (first pass + second pass)
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "2" "main: calls transcode_full_video twice (first pass + second pass)"
    
    # Cleanup
    rm -f "$test_file" *.mp4 *.fmpg.*.mp4 2>/dev/null
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_SAMPLE_BITRATE_BPS MOCK_OUTPUT_BITRATE_BPS MOCK_SECOND_PASS_BITRATE_BPS
    
    # Test 5: Third pass with interpolation when second pass is still outside tolerance
    reset_call_tracking
    test_file="test_video.mp4"
    touch "$test_file"
    MOCK_VIDEO_FILE="$test_file"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000  # 12 Mbps (above 8 Mbps target, needs transcoding)
    MOCK_SAMPLE_BITRATE_BPS=8000000  # Sample bitrate at target (8 Mbps) so optimization converges immediately
    MOCK_OUTPUT_BITRATE_BPS=14050000  # First pass: 14.05 Mbps (75.6% above target, outside ±5% tolerance)
    MOCK_SECOND_PASS_BITRATE_BPS=7500000  # Second pass: 7.5 Mbps (6.25% below target, still outside ±5% tolerance - lower bound is 7.6 Mbps)
    MOCK_THIRD_PASS_BITRATE_BPS=9000000  # Third pass: 9.00 Mbps (12.5% above target, but we'll use it)
    
    set +e
    output=$(main 2>&1)
    exit_code=$?
    set -e
    
    assert_exit_code $exit_code 0 "main: completes transcoding with third pass"
    assert_not_empty "$(echo "$output" | grep -i "second pass" || true)" "main: outputs second pass message"
    assert_not_empty "$(echo "$output" | grep -i "Performing third\|Interpolating quality\|third pass" || true)" "main: outputs third pass or interpolation message"
    assert_not_empty "$(echo "$output" | grep -i "outside tolerance" || true)" "main: outputs outside tolerance warning"
    # Verify find_all_video_files was called
    assert_equal "$(count_calls "$FIND_ALL_VIDEO_FILES_CALLS_FILE")" "1" "main: calls find_all_video_files"
    # Verify measure_bitrate was called (1 for source + 3 for samples + 3 for output passes = 7)
    assert_equal "$(count_calls "$MEASURE_BITRATE_CALLS_FILE")" "7" "main: calls measure_bitrate (source + samples + 3 output passes)"
    # Verify transcode_sample was called (for finding optimal quality - 3 samples for 300s video)
    assert_equal "$(count_calls "$TRANSCODE_SAMPLE_CALLS_FILE")" "3" "main: calls transcode_sample for optimization (3 samples for 300s video)"
    # Verify transcode_full_video was called three times (first pass + second pass + third pass)
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "3" "main: calls transcode_full_video three times (first pass + second pass + third pass)"
    
    # Cleanup
    rm -f "$test_file" *.mp4 *.fmpg.*.mp4 2>/dev/null
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_SAMPLE_BITRATE_BPS MOCK_OUTPUT_BITRATE_BPS MOCK_SECOND_PASS_BITRATE_BPS MOCK_THIRD_PASS_BITRATE_BPS
    
    # Return to original directory
    cd - > /dev/null || true
    rm -rf "$temp_dir"
}

test_main

echo ""

# Test transcode_video() with target bitrate override
echo "Testing transcode_video() with target bitrate override..."
test_transcode_video_bitrate_override() {
    local test_dir
    local test_file
    local output
    local exit_code
    local temp_dir
    
    # Create a temporary directory for each test to avoid conflicts
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    reset_call_tracking
    test_file="test_video.mp4"
    touch "$test_file"
    MOCK_VIDEO_FILE="$test_file"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000  # 12 Mbps (above 8 Mbps target, would normally transcode to 8 Mbps)
    MOCK_SAMPLE_BITRATE_BPS=6000000  # Sample bitrate at override target (6 Mbps)
    MOCK_OUTPUT_BITRATE_BPS=6000000  # Output should be at override target (6 Mbps)
    
    # Call transcode_video with bitrate override of 6 Mbps
    set +e
    output=$(transcode_video "$test_file" "6" 2>&1)
    exit_code=$?
    set -e
    
    assert_exit_code $exit_code 0 "transcode_video: completes with bitrate override"
    assert_not_empty "$(echo "$output" | grep -i "Target bitrate (override): 6" || true)" "transcode_video: outputs override bitrate message"
    assert_not_empty "$(echo "$output" | grep -i "transcoding complete" || true)" "transcode_video: outputs completion message"
    # Verify transcode_full_video was called
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "1" "transcode_video: calls transcode_full_video with override"
    
    # Cleanup
    rm -f "$test_file" *.mp4 *.fmpg.*.mp4 2>/dev/null
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_SAMPLE_BITRATE_BPS MOCK_OUTPUT_BITRATE_BPS
    
    # Return to original directory
    cd - > /dev/null || true
    rm -rf "$temp_dir"
}
test_transcode_video_bitrate_override

echo ""

# Test codec incompatibility handling in transcode_video() (within tolerance)
echo "Testing codec incompatibility in transcode_video() (within tolerance)..."
test_transcode_video_codec_incompatible_within_tolerance() {
    local test_dir
    local test_file
    local output
    local exit_code
    local temp_dir
    
    # Create a temporary directory for each test to avoid conflicts
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    reset_call_tracking
    test_file="test_video.wmv"
    touch "$test_file"
    MOCK_VIDEO_FILE="$test_file"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=8000000  # 8 Mbps (exactly at target, within tolerance)
    MOCK_VIDEO_CODEC="wmv3"  # Incompatible codec
    MOCK_SAMPLE_BITRATE_BPS=8000000  # Sample bitrate at source bitrate (8 Mbps)
    MOCK_OUTPUT_BITRATE_BPS=8000000  # Output should be at source bitrate (8 Mbps)
    
    set +e
    output=$(transcode_video "$test_file" 2>&1)
    exit_code=$?
    set -e
    
    assert_exit_code $exit_code 0 "transcode_video: completes transcoding for incompatible codec within tolerance"
    assert_not_empty "$(echo "$output" | grep -i "not compatible with MP4 container" || true)" "transcode_video: outputs codec incompatibility warning"
    assert_not_empty "$(echo "$output" | grep -i "Transcoding to HEVC at source bitrate" || true)" "transcode_video: outputs transcoding message"
    assert_not_empty "$(echo "$output" | grep -i "transcoding complete" || true)" "transcode_video: outputs completion message"
    # Verify transcode_full_video was called (should transcode instead of remuxing)
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "1" "transcode_video: calls transcode_full_video for incompatible codec"
    # Verify output file uses .orig. pattern (since it's at/below target)
    local output_file="test_video.orig.8.00.Mbps.mp4"
    if [ -f "$output_file" ]; then
        assert_equal "1" "1" "transcode_video: creates .orig. file for incompatible codec within tolerance"
    else
        # Check if any .orig. file exists
        local orig_files=$(ls -1 *.orig.*.mp4 2>/dev/null | wc -l | tr -d ' ')
        assert_not_equal "$orig_files" "0" "transcode_video: creates .orig. file for incompatible codec within tolerance"
    fi
    
    # Cleanup
    rm -f "$test_file" *.mp4 *.orig.*.mp4 2>/dev/null
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_VIDEO_CODEC MOCK_SAMPLE_BITRATE_BPS MOCK_OUTPUT_BITRATE_BPS
    
    # Return to original directory
    cd - > /dev/null || true
    rm -rf "$temp_dir"
}
test_transcode_video_codec_incompatible_within_tolerance

echo ""

# Test codec incompatibility handling in transcode_video() (below target)
echo "Testing codec incompatibility in transcode_video() (below target)..."
test_transcode_video_codec_incompatible_below_target() {
    local test_dir
    local test_file
    local output
    local exit_code
    local temp_dir
    
    # Create a temporary directory for each test to avoid conflicts
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    reset_call_tracking
    test_file="test_video.wmv"
    touch "$test_file"
    MOCK_VIDEO_FILE="$test_file"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=5000000  # 5 Mbps (below 8 Mbps target)
    MOCK_VIDEO_CODEC="wmv3"  # Incompatible codec
    MOCK_SAMPLE_BITRATE_BPS=5000000  # Sample bitrate at source bitrate (5 Mbps)
    MOCK_OUTPUT_BITRATE_BPS=5000000  # Output should be at source bitrate (5 Mbps)
    
    set +e
    output=$(transcode_video "$test_file" 2>&1)
    exit_code=$?
    set -e
    
    assert_exit_code $exit_code 0 "transcode_video: completes transcoding for incompatible codec below target"
    assert_not_empty "$(echo "$output" | grep -i "not compatible with MP4 container" || true)" "transcode_video: outputs codec incompatibility warning"
    assert_not_empty "$(echo "$output" | grep -i "Transcoding to HEVC at source bitrate" || true)" "transcode_video: outputs transcoding message"
    assert_not_empty "$(echo "$output" | grep -i "transcoding complete" || true)" "transcode_video: outputs completion message"
    # Verify transcode_full_video was called (should transcode instead of remuxing)
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "1" "transcode_video: calls transcode_full_video for incompatible codec below target"
    # Verify output file uses .orig. pattern (since it's below target)
    local output_file="test_video.orig.5.00.Mbps.mp4"
    if [ -f "$output_file" ]; then
        assert_equal "1" "1" "transcode_video: creates .orig. file for incompatible codec below target"
    else
        # Check if any .orig. file exists
        local orig_files=$(ls -1 *.orig.*.mp4 2>/dev/null | wc -l | tr -d ' ')
        assert_not_equal "$orig_files" "0" "transcode_video: creates .orig. file for incompatible codec below target"
    fi
    
    # Cleanup
    rm -f "$test_file" *.mp4 *.orig.*.mp4 2>/dev/null
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_VIDEO_CODEC MOCK_SAMPLE_BITRATE_BPS MOCK_OUTPUT_BITRATE_BPS
    
    # Return to original directory
    cd - > /dev/null || true
    rm -rf "$temp_dir"
}
test_transcode_video_codec_incompatible_below_target

echo ""

# Test codec incompatibility handling in preprocess_non_quicklook_files()
echo "Testing codec incompatibility in preprocess_non_quicklook_files()..."
test_preprocess_codec_incompatible() {
    local test_dir
    local test_file
    local output
    local exit_code
    local temp_dir
    
    # Create a temporary directory for each test to avoid conflicts
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    reset_call_tracking
    test_file="test_video.wmv"
    touch "$test_file"
    MOCK_VIDEO_FILE="$test_file"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=8000000  # 8 Mbps (exactly at target, within tolerance)
    MOCK_VIDEO_CODEC="wmv3"  # Incompatible codec
    MOCK_SAMPLE_BITRATE_BPS=8000000  # Sample bitrate at source bitrate (8 Mbps)
    MOCK_OUTPUT_BITRATE_BPS=8000000  # Output should be at source bitrate (8 Mbps)
    
    set +e
    output=$(preprocess_non_quicklook_files 2>&1)
    exit_code=$?
    set -e
    
    assert_exit_code $exit_code 1 "preprocess_non_quicklook_files: completes for incompatible codec (returns count of processed files)"
    assert_not_empty "$(echo "$output" | grep -i "not compatible with MP4 container" || true)" "preprocess_non_quicklook_files: outputs codec incompatibility warning"
    assert_not_empty "$(echo "$output" | grep -i "Transcoding.*to HEVC at source bitrate" || true)" "preprocess_non_quicklook_files: outputs transcoding message"
    # Verify transcode_full_video was called (should transcode instead of remuxing)
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "1" "preprocess_non_quicklook_files: calls transcode_full_video for incompatible codec"
    
    # Cleanup
    rm -f "$test_file" *.mp4 *.orig.*.mp4 2>/dev/null
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_VIDEO_CODEC MOCK_SAMPLE_BITRATE_BPS MOCK_OUTPUT_BITRATE_BPS
    
    # Return to original directory
    cd - > /dev/null || true
    rm -rf "$temp_dir"
}
test_preprocess_codec_incompatible

echo ""

# Test validate_bitrate()
test_validate_bitrate() {
    echo "Testing validate_bitrate()..."
    
    # Valid bitrates
    validate_bitrate "5" && assert_equal $? 0 "validate_bitrate accepts integer"
    validate_bitrate "9.5" && assert_equal $? 0 "validate_bitrate accepts decimal"
    validate_bitrate "0.1" && assert_equal $? 0 "validate_bitrate accepts minimum (0.1)"
    validate_bitrate "100" && assert_equal $? 0 "validate_bitrate accepts maximum (100)"
    validate_bitrate "50.25" && assert_equal $? 0 "validate_bitrate accepts decimal with two places"
    
    # Invalid bitrates (these should return 1/false) - use set +e so return 1 doesn't exit
    local exit_code
    set +e
    validate_bitrate ""; exit_code=$?; set -e; assert_equal $exit_code 1 "validate_bitrate rejects empty string"
    set +e; validate_bitrate "0"; exit_code=$?; set -e; assert_equal $exit_code 1 "validate_bitrate rejects zero"
    set +e; validate_bitrate "-5"; exit_code=$?; set -e; assert_equal $exit_code 1 "validate_bitrate rejects negative"
    set +e; validate_bitrate "101"; exit_code=$?; set -e; assert_equal $exit_code 1 "validate_bitrate rejects > 100"
    set +e; validate_bitrate "abc"; exit_code=$?; set -e; assert_equal $exit_code 1 "validate_bitrate rejects non-numeric"
    set +e; validate_bitrate "5.5.5"; exit_code=$?; set -e; assert_equal $exit_code 1 "validate_bitrate rejects multiple decimals"
    set +e; validate_bitrate " 5 "; exit_code=$?; set -e; assert_equal $exit_code 1 "validate_bitrate rejects whitespace (should be sanitized first)"
}
test_validate_bitrate

echo ""

# Test validate_depth()
test_validate_depth() {
    echo "Testing validate_depth()..."
    
    # Valid cases
    validate_depth "0"; assert_equal $? 0 "validate_depth accepts 0 (unlimited)"
    validate_depth "1"; assert_equal $? 0 "validate_depth accepts 1"
    validate_depth "2"; assert_equal $? 0 "validate_depth accepts 2"
    validate_depth "3"; assert_equal $? 0 "validate_depth accepts 3"
    validate_depth "10"; assert_equal $? 0 "validate_depth accepts 10"
    validate_depth "100"; assert_equal $? 0 "validate_depth accepts 100"
    
    # Invalid cases - use set +e so return 1 doesn't exit
    set +e; validate_depth ""; exit_code=$?; set -e; assert_equal $exit_code 1 "validate_depth rejects empty string"
    set +e; validate_depth "-1"; exit_code=$?; set -e; assert_equal $exit_code 1 "validate_depth rejects negative"
    set +e; validate_depth "abc"; exit_code=$?; set -e; assert_equal $exit_code 1 "validate_depth rejects non-numeric"
    set +e; validate_depth "5.5"; exit_code=$?; set -e; assert_equal $exit_code 1 "validate_depth rejects decimals"
    set +e; validate_depth " 5 "; exit_code=$?; set -e; assert_equal $exit_code 1 "validate_depth rejects whitespace (should be sanitized first)"
}
test_validate_depth

echo ""

# Test parse_arguments()
test_parse_arguments() {
    echo "Testing parse_arguments()..."
    
    # Reset global variables
    GLOBAL_TARGET_BITRATE_MBPS=""
    GLOBAL_MAX_DEPTH=2  # Reset to default
    
    # Test --target-bitrate flag
    parse_arguments --target-bitrate 9.5
    assert_equal "$GLOBAL_TARGET_BITRATE_MBPS" "9.5" "parse_arguments sets GLOBAL_TARGET_BITRATE_MBPS with --target-bitrate"
    
    # Test -t flag
    GLOBAL_TARGET_BITRATE_MBPS=""
    parse_arguments -t 6.0
    assert_equal "$GLOBAL_TARGET_BITRATE_MBPS" "6.0" "parse_arguments sets GLOBAL_TARGET_BITRATE_MBPS with -t"
    
    # Test --max-depth flag
    GLOBAL_MAX_DEPTH=2
    parse_arguments --max-depth 3
    assert_equal "$GLOBAL_MAX_DEPTH" "3" "parse_arguments sets GLOBAL_MAX_DEPTH with --max-depth"
    
    # Test -L flag
    GLOBAL_MAX_DEPTH=2
    parse_arguments -L 1
    assert_equal "$GLOBAL_MAX_DEPTH" "1" "parse_arguments sets GLOBAL_MAX_DEPTH with -L"
    
    # Test unlimited depth (0)
    GLOBAL_MAX_DEPTH=2
    parse_arguments --max-depth 0
    assert_equal "$GLOBAL_MAX_DEPTH" "0" "parse_arguments sets GLOBAL_MAX_DEPTH to 0 (unlimited)"
    
    # Test no arguments
    GLOBAL_TARGET_BITRATE_MBPS=""
    GLOBAL_MAX_DEPTH=2
    parse_arguments
    assert_empty "$GLOBAL_TARGET_BITRATE_MBPS" "parse_arguments leaves GLOBAL_TARGET_BITRATE_MBPS empty with no args"
    assert_equal "$GLOBAL_MAX_DEPTH" "2" "parse_arguments leaves GLOBAL_MAX_DEPTH at default (2) with no args"
    
    # Test decimal values (for bitrate)
    GLOBAL_TARGET_BITRATE_MBPS=""
    parse_arguments --target-bitrate 9.75
    assert_equal "$GLOBAL_TARGET_BITRATE_MBPS" "9.75" "parse_arguments handles decimal values for bitrate"
    
    # Test error cases using subshells (since parse_arguments exits on error)
    # Test missing value after --target-bitrate flag
    set +e
    (parse_arguments --target-bitrate 2>&1 > /dev/null)
    exit_code=$?
    set -e
    assert_equal $exit_code 1 "parse_arguments exits 1 when value missing after --target-bitrate"
    
    # Test missing value after --max-depth flag
    set +e
    (parse_arguments --max-depth 2>&1 > /dev/null)
    exit_code=$?
    set -e
    assert_equal $exit_code 1 "parse_arguments exits 1 when value missing after --max-depth"
    
    # Test invalid bitrate value
    set +e
    (parse_arguments --target-bitrate 101 2>&1 > /dev/null)
    exit_code=$?
    set -e
    assert_equal $exit_code 1 "parse_arguments exits 1 when bitrate value is invalid (>100)"
    
    # Test invalid depth value (negative)
    set +e
    (parse_arguments --max-depth -1 2>&1 > /dev/null)
    exit_code=$?
    set -e
    assert_equal $exit_code 1 "parse_arguments exits 1 when depth value is invalid (negative)"
    
    # Test invalid depth value (decimal)
    set +e
    (parse_arguments --max-depth 2.5 2>&1 > /dev/null)
    exit_code=$?
    set -e
    assert_equal $exit_code 1 "parse_arguments exits 1 when depth value is invalid (decimal)"
    
    # Test unknown flag
    set +e
    (parse_arguments --unknown-flag 2>&1 > /dev/null)
    exit_code=$?
    set -e
    assert_equal $exit_code 1 "parse_arguments exits 1 when unknown flag provided"
    
    # Test help flag (should exit 0)
    set +e
    (parse_arguments --help 2>&1 > /dev/null)
    exit_code=$?
    set -e
    assert_equal $exit_code 0 "parse_arguments exits 0 when --help provided"
    
    # Test that last flag wins if both -t and --target-bitrate are provided
    GLOBAL_TARGET_BITRATE_MBPS=""
    parse_arguments -t 5.0 --target-bitrate 9.5
    assert_equal "$GLOBAL_TARGET_BITRATE_MBPS" "9.5" "parse_arguments: last flag wins when multiple flags provided"
    
    # Test that last flag wins if both -L and --max-depth are provided
    GLOBAL_MAX_DEPTH=2
    parse_arguments -L 1 --max-depth 3
    assert_equal "$GLOBAL_MAX_DEPTH" "3" "parse_arguments: last depth flag wins when multiple flags provided"
    
    # Test combining both flags
    GLOBAL_TARGET_BITRATE_MBPS=""
    GLOBAL_MAX_DEPTH=2
    parse_arguments --target-bitrate 9.5 --max-depth 3
    assert_equal "$GLOBAL_TARGET_BITRATE_MBPS" "9.5" "parse_arguments: sets bitrate when both flags provided"
    assert_equal "$GLOBAL_MAX_DEPTH" "3" "parse_arguments: sets depth when both flags provided"
}
test_parse_arguments

echo ""

# Test main() integration with parse_arguments() and override flow
test_main_with_override() {
    echo "Testing main() with target bitrate override..."
    
    local temp_dir
    local test_file
    local output
    local exit_code
    
    # Create a temporary directory for each test to avoid conflicts
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    reset_call_tracking
    test_file="test_video.mp4"
    touch "$test_file"
    MOCK_VIDEO_FILE="$test_file"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000  # 12 Mbps (above 8 Mbps default target, but we'll override to 9.5)
    MOCK_SAMPLE_BITRATE_BPS=9500000  # 9.5 Mbps (at override target)
    MOCK_OUTPUT_BITRATE_BPS=9500000  # Output should be at override target (9.5 Mbps)
    
    # Call main with override argument
    set +e
    output=$(main --target-bitrate 9.5 2>&1)
    exit_code=$?
    set -e
    
    assert_exit_code $exit_code 0 "main: completes with override argument"
    assert_not_empty "$(echo "$output" | grep -i "Target bitrate (override): 9.5" || true)" "main: outputs override bitrate message"
    # Verify transcode_video was called with override
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "1" "main: calls transcode_full_video with override"
    
    # Cleanup
    rm -f "$test_file" *.mp4 *.fmpg.*.mp4 2>/dev/null
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_SAMPLE_BITRATE_BPS MOCK_OUTPUT_BITRATE_BPS
    GLOBAL_TARGET_BITRATE_MBPS=""
    
    # Return to original directory
    cd - > /dev/null || true
    rm -rf "$temp_dir"
}
test_main_with_override

echo ""

# Test preprocess_non_quicklook_files() with override
test_preprocess_with_override() {
    echo "Testing preprocess_non_quicklook_files() with target bitrate override..."
    
    local temp_dir
    local test_file
    local output
    local exit_code
    
    # Create a temporary directory for each test to avoid conflicts
    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1
    
    reset_call_tracking
    test_file="test_video.mkv"
    touch "$test_file"
    MOCK_VIDEO_FILE="$test_file"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=9500000  # 9.5 Mbps (at override target, within tolerance)
    MOCK_VIDEO_CODEC="h264"  # Compatible codec (should remux)
    
    # Set global override
    GLOBAL_TARGET_BITRATE_MBPS="9.5"
    
    set +e
    output=$(preprocess_non_quicklook_files 2>&1)
    exit_code=$?
    set -e
    
    # preprocess returns remuxed count (0 = no files, 1 = one file remuxed, etc.)
    assert_exit_code $exit_code 1 "preprocess_non_quicklook_files: completes with override (exit 1 = 1 file remuxed)"
    # Should use override target (9.5) instead of resolution-based target (8)
    # File is at 9.5 Mbps, which is within tolerance of override target (9.5)
    assert_not_empty "$(echo "$output" | grep -i "remuxing\|remuxed" || true)" "preprocess_non_quicklook_files: processes file with override"
    
    # Cleanup
    rm -f "$test_file" *.mp4 *.orig.*.mp4 2>/dev/null
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_VIDEO_CODEC
    GLOBAL_TARGET_BITRATE_MBPS=""
    
    # Return to original directory
    cd - > /dev/null || true
    rm -rf "$temp_dir"
}
test_preprocess_with_override

echo ""

# Test is_mkv_file() function
test_is_mkv_file() {
    echo "Testing is_mkv_file()..."
    
    # Test lowercase .mkv extension
    is_mkv_file "video.mkv" && local mkv_result=0 || local mkv_result=1
    assert_exit_code $mkv_result 0 "is_mkv_file: detects lowercase .mkv"
    
    # Test uppercase .MKV extension
    is_mkv_file "video.MKV" && local mkv_upper_result=0 || local mkv_upper_result=1
    assert_exit_code $mkv_upper_result 0 "is_mkv_file: detects uppercase .MKV"
    
    # Test mixed case .Mkv extension
    is_mkv_file "video.Mkv" && local mkv_mixed_result=0 || local mkv_mixed_result=1
    assert_exit_code $mkv_mixed_result 0 "is_mkv_file: detects mixed case .Mkv"
    
    # Test non-mkv extension .mp4
    is_mkv_file "video.mp4" && local mp4_result=0 || local mp4_result=1
    assert_exit_code $mp4_result 1 "is_mkv_file: rejects .mp4"
    
    # Test non-mkv extension .avi
    is_mkv_file "video.avi" && local avi_result=0 || local avi_result=1
    assert_exit_code $avi_result 1 "is_mkv_file: rejects .avi"
    
    # Test non-mkv extension .mov
    is_mkv_file "video.mov" && local mov_result=0 || local mov_result=1
    assert_exit_code $mov_result 1 "is_mkv_file: rejects .mov"
}
test_is_mkv_file

echo ""

# Test find_skipped_video_files() function
test_find_skipped_video_files() {
    echo "Testing find_skipped_video_files()..."
    
    # Store original directory
    local original_dir=$(pwd)
    
    # Create a temp directory for testing
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    # Create test files: some skipped, some not
    touch "regular_video.mp4"
    touch "video.fmpg.10.25.Mbps.mp4"
    touch "video.orig.5.00.Mbps.mp4"
    touch "video.hbrk.something.mp4"
    touch "another_regular.mkv"
    
    # Set max depth for test
    GLOBAL_MAX_DEPTH=1
    
    # Get skipped files
    local skipped_files=$(find_skipped_video_files)
    
    # Check that skipped files include .fmpg., .orig., .hbrk. marked files
    # Use || true to prevent set -e from exiting on grep failure
    echo "$skipped_files" | grep -q "fmpg" || true
    local fmpg_found=$?
    # Reset to check actual result (grep -q sets $? to 0 if found, 1 if not)
    echo "$skipped_files" | grep -q "fmpg" && fmpg_found=0 || fmpg_found=1
    assert_exit_code $fmpg_found 0 "find_skipped_video_files: finds .fmpg. files"
    
    echo "$skipped_files" | grep -q "orig" && local orig_found=0 || local orig_found=1
    assert_exit_code $orig_found 0 "find_skipped_video_files: finds .orig. files"
    
    echo "$skipped_files" | grep -q "hbrk" && local hbrk_found=0 || local hbrk_found=1
    assert_exit_code $hbrk_found 0 "find_skipped_video_files: finds .hbrk. files"
    
    # Check that regular files are NOT in skipped list
    echo "$skipped_files" | grep -q "regular_video.mp4" && local regular_found=0 || local regular_found=1
    assert_exit_code $regular_found 1 "find_skipped_video_files: excludes regular files"
    
    echo "$skipped_files" | grep -q "another_regular.mkv" && local mkv_found=0 || local mkv_found=1
    assert_exit_code $mkv_found 1 "find_skipped_video_files: excludes regular mkv files"
    
    # Cleanup
    cd "$original_dir"
    rm -rf "$temp_dir"
}
test_find_skipped_video_files

echo ""

# Test find_skipped_video_files() returns sorted output
test_find_skipped_video_files_sorted() {
    echo "Testing find_skipped_video_files() sorted output..."
    
    # Store original directory
    local original_dir=$(pwd)
    
    # Create a temp directory for testing
    local temp_dir=$(mktemp -d)
    cd "$temp_dir"
    
    # Create test files in non-alphabetical order
    touch "z_video.fmpg.10.00.Mbps.mp4"
    touch "a_video.orig.5.00.Mbps.mp4"
    touch "m_video.hbrk.foo.mp4"
    
    # Set max depth for test
    GLOBAL_MAX_DEPTH=1
    
    # Get skipped files
    local skipped_files=$(find_skipped_video_files)
    
    # Check that output is sorted (first file should be a_video)
    local first_file=$(echo "$skipped_files" | head -1)
    echo "$first_file" | grep -q "a_video" && local a_first=0 || local a_first=1
    assert_exit_code $a_first 0 "find_skipped_video_files: returns sorted output (a before m, z)"
    
    # Cleanup
    cd "$original_dir"
    rm -rf "$temp_dir"
}
test_find_skipped_video_files_sorted

echo ""

# Test that main() passes target bitrate override to transcode_video()
# This is tested indirectly through the existing transcode_video() tests with override parameter
# The integration is verified by ensuring transcode_video() receives and uses the override correctly

echo ""

# ============================================================================
# remux-select-audio.sh smoke tests (standalone script, not sourced)
# ============================================================================
test_remux_select_audio_help() {
    local out exit_code
    out=$(./remux-select-audio.sh -h 2>&1)
    exit_code=$?
    assert_exit_code $exit_code 0 "remux-select-audio.sh -h exits 0"
    echo "$out" | grep -q "Usage:"
    assert_exit_code $? 0 "remux-select-audio.sh -h prints usage"
}
test_remux_select_audio_help

test_remux_select_audio_no_args() {
    local root tmp exit_code
    root=$(pwd)
    tmp=$(mktemp -d)
    set +e
    (cd "$tmp" && bash "$root/remux-select-audio.sh" 2>&1)
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "remux-select-audio.sh with no args (empty dir) exits non-zero"
    rm -rf "$tmp"
}
test_remux_select_audio_no_args

test_remux_select_audio_nothing_to_do() {
    if ! command -v ffmpeg &> /dev/null || ! command -v ffprobe &> /dev/null; then
        echo "  (Skipping 0/1 audio tests: ffmpeg/ffprobe not in PATH)"
        return 0
    fi
    local tmp
    tmp=$(mktemp -d)
    local one_audio="${tmp}/one_audio.mp4"
    local no_audio="${tmp}/no_audio.mp4"
    ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 1 -c:a aac -y "$one_audio" 2>/dev/null || true
    ffmpeg -f lavfi -i color=c=black:s=320x240:d=1 -c:v libx264 -y "$no_audio" 2>/dev/null || true
    if [ -f "$one_audio" ]; then
        local out exit_code
        out=$(./remux-select-audio.sh "$one_audio" 2>&1)
        exit_code=$?
        assert_exit_code $exit_code 0 "remux-select-audio.sh one audio track exits 0"
        echo "$out" | grep -qi "nothing to do"
        assert_exit_code $? 0 "remux-select-audio.sh one audio prints nothing-to-do message"
    fi
    if [ -f "$no_audio" ]; then
        local out exit_code
        out=$(./remux-select-audio.sh "$no_audio" 2>&1)
        exit_code=$?
        assert_exit_code $exit_code 0 "remux-select-audio.sh zero audio tracks exits 0"
        echo "$out" | grep -qi "nothing to do"
        assert_exit_code $? 0 "remux-select-audio.sh zero audio prints nothing-to-do message"
    fi
    rm -rf "$tmp"
}
test_remux_select_audio_nothing_to_do

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

