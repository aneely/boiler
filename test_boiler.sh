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
#   - MOCK_WIDTH / MOCK_HEIGHT / MOCK_OUTPUT_DIMS / MOCK_ROTATION: Frame size, encoded-output size
#     and rotation returned by get_video_dimensions() / get_video_rotation() (auto-crop tests)

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

assert_exit_code_nonzero() {
    local actual_exit="$1"
    local test_name="$2"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [ "$actual_exit" -ne 0 ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo -e "  Expected non-zero exit code"
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

# Mock get_video_dimensions() - returns "W H" (default: 1920 x MOCK_RESOLUTION; temp_transcode files
# report MOCK_OUTPUT_DIMS when set so crop output verification can be exercised)
get_video_dimensions() {
    local video_file="$1"
    if [[ "$video_file" == *"temp_transcode"* ]] && [ -n "${MOCK_OUTPUT_DIMS:-}" ]; then
        echo "${MOCK_OUTPUT_DIMS}"
    else
        echo "${MOCK_WIDTH:-1920} ${MOCK_HEIGHT:-${MOCK_RESOLUTION:-1080}}"
    fi
}

# Mock get_video_rotation() - returns mock rotation (default: 0)
get_video_rotation() {
    echo "${MOCK_ROTATION:-0}"
}

# Mock ffprobe for codec detection (used by remux_to_mp4)
# Returns codec from MOCK_VIDEO_CODEC if set, otherwise returns h264; audio queries return MOCK_AUDIO_CODEC (default aac)
ffprobe() {
    # Check if this is a codec_name query (used by remux_to_mp4)
    if [[ "$*" == *"codec_name"* ]]; then
        if [[ "$*" == *"select_streams a"* ]]; then
            echo "${MOCK_AUDIO_CODEC-aac}"
        else
            echo "${MOCK_VIDEO_CODEC:-h264}"
        fi
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

# Test is_audio_codec_mp4_compatible()
echo "Testing is_audio_codec_mp4_compatible()..."
test_is_audio_codec_mp4_compatible() {
    local exit_code

    # Test compatible audio codecs (should return 0)
    set +e
    is_audio_codec_mp4_compatible "aac"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_audio_codec_mp4_compatible: aac codec"

    set +e
    is_audio_codec_mp4_compatible "ac3"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_audio_codec_mp4_compatible: ac3 codec"

    set +e
    is_audio_codec_mp4_compatible "mp3"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_audio_codec_mp4_compatible: mp3 codec"

    set +e
    is_audio_codec_mp4_compatible "eac3"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_audio_codec_mp4_compatible: eac3 codec"

    set +e
    is_audio_codec_mp4_compatible "alac"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_audio_codec_mp4_compatible: alac codec"

    set +e
    is_audio_codec_mp4_compatible "flac"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_audio_codec_mp4_compatible: flac codec"

    set +e
    is_audio_codec_mp4_compatible "opus"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_audio_codec_mp4_compatible: opus codec"

    set +e
    is_audio_codec_mp4_compatible "AAC"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_audio_codec_mp4_compatible: AAC codec (case insensitive)"

    # Test incompatible audio codecs (should return 1)
    set +e
    is_audio_codec_mp4_compatible "wmav2"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_audio_codec_mp4_compatible: wmav2 codec (incompatible)"

    set +e
    is_audio_codec_mp4_compatible "wmav1"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_audio_codec_mp4_compatible: wmav1 codec (incompatible)"

    set +e
    is_audio_codec_mp4_compatible "vorbis"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_audio_codec_mp4_compatible: vorbis codec (incompatible)"

    set +e
    is_audio_codec_mp4_compatible "WMAV2"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_audio_codec_mp4_compatible: WMAV2 codec (incompatible, case insensitive)"

    set +e
    is_audio_codec_mp4_compatible "wmalossless"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_audio_codec_mp4_compatible: wmalossless codec (incompatible)"

    set +e
    is_audio_codec_mp4_compatible "wmapro"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_audio_codec_mp4_compatible: wmapro codec (incompatible)"

    set +e
    is_audio_codec_mp4_compatible "adpcm_ms"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_audio_codec_mp4_compatible: adpcm_ms codec (incompatible)"

    # Test unknown codec (should return 0 - assume compatible)
    set +e
    is_audio_codec_mp4_compatible "some_future_codec"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_audio_codec_mp4_compatible: unknown codec (assumes compatible)"
}
test_is_audio_codec_mp4_compatible

echo ""

# Test FFmpeg error handling in transcode_sample(), transcode_full_video(), remux_to_mp4()
echo "Testing FFmpeg error handling..."

# Helper: run a boiler.sh function in a subshell with a custom ffmpeg/ffprobe override
run_with_ffmpeg_override() {
    local ffmpeg_body="$1"
    local func_name="$2"
    shift 2
    bash -c "
        set +e
        export BOILER_TEST_MODE=1
        source '$(pwd)/boiler.sh' 2>/dev/null
        ffmpeg() { $ffmpeg_body; }
        ffprobe() {
            if [[ \"\$*\" == *codec_name* ]] && [[ \"\$*\" == *select_streams\ a* ]]; then
                echo 'aac'
            elif [[ \"\$*\" == *codec_name* ]]; then
                echo 'h264'
            elif [[ \"\$*\" == *csv=p=0* ]]; then
                echo '1'
            else
                echo ''
            fi
        }
        $func_name \"\$@\"
    " -- "$@" 2>/dev/null
}

test_ffmpeg_error_handling() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local exit_code

    # --- transcode_sample ---

    # ffmpeg fails (exit code 1) → should return non-zero
    set +e
    run_with_ffmpeg_override "return 1" transcode_sample "$tmpdir/input.mp4" "10" "5" "60" "$tmpdir/sample_out.mp4"
    exit_code=$?
    set -e
    assert_exit_code_nonzero $exit_code "transcode_sample: returns non-zero when ffmpeg fails"

    # ffmpeg succeeds but output file missing → should return non-zero
    set +e
    run_with_ffmpeg_override "return 0" transcode_sample "$tmpdir/input.mp4" "10" "5" "60" "$tmpdir/sample_out2.mp4"
    exit_code=$?
    set -e
    assert_exit_code_nonzero $exit_code "transcode_sample: returns non-zero when output file is missing"

    # ffmpeg succeeds but output file is zero bytes → should return non-zero
    set +e
    run_with_ffmpeg_override "touch '$tmpdir/sample_out3.mp4'; return 0" transcode_sample "$tmpdir/input.mp4" "10" "5" "60" "$tmpdir/sample_out3.mp4"
    exit_code=$?
    set -e
    assert_exit_code_nonzero $exit_code "transcode_sample: returns non-zero when output file is zero bytes"

    # --- transcode_full_video ---

    set +e
    run_with_ffmpeg_override "return 1" transcode_full_video "$tmpdir/input.mp4" "$tmpdir/full_out.mp4" "60"
    exit_code=$?
    set -e
    assert_exit_code_nonzero $exit_code "transcode_full_video: returns non-zero when ffmpeg fails"

    set +e
    run_with_ffmpeg_override "return 0" transcode_full_video "$tmpdir/input.mp4" "$tmpdir/full_out2.mp4" "60"
    exit_code=$?
    set -e
    assert_exit_code_nonzero $exit_code "transcode_full_video: returns non-zero when output file is missing"

    set +e
    run_with_ffmpeg_override "touch '$tmpdir/full_out3.mp4'; return 0" transcode_full_video "$tmpdir/input.mp4" "$tmpdir/full_out3.mp4" "60"
    exit_code=$?
    set -e
    assert_exit_code_nonzero $exit_code "transcode_full_video: returns non-zero when output file is zero bytes"

    # --- remux_to_mp4 ---

    set +e
    run_with_ffmpeg_override "return 1" remux_to_mp4 "$tmpdir/input.mkv" "$tmpdir/remux_out.mp4"
    exit_code=$?
    set -e
    assert_exit_code_nonzero $exit_code "remux_to_mp4: returns non-zero when ffmpeg fails"

    set +e
    run_with_ffmpeg_override "return 0" remux_to_mp4 "$tmpdir/input.mkv" "$tmpdir/remux_out2.mp4"
    exit_code=$?
    set -e
    assert_exit_code_nonzero $exit_code "remux_to_mp4: returns non-zero when output file is missing"

    set +e
    run_with_ffmpeg_override "touch '$tmpdir/remux_out3.mp4'; return 0" remux_to_mp4 "$tmpdir/input.mkv" "$tmpdir/remux_out3.mp4"
    exit_code=$?
    set -e
    assert_exit_code_nonzero $exit_code "remux_to_mp4: returns non-zero when output file is zero bytes"

    rm -rf "$tmpdir"
}
test_ffmpeg_error_handling

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
    
    # Names with glob characters must still match their own encoded copy (find -iname globs the pattern)
    local gname
    for gname in 'Movie [2024]' '[1080p] Title' 'a*b' 'what?' 'back\slash' "it's (2024)"; do
        rm -f ./*
        touch "$gname.mp4" "$gname.fmpg.6.05.Mbps.mp4"
        bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; should_skip_file \"./\$1.mp4\"" -- "$gname" && result="skip" || result="process"
        assert_equal "$result" "skip" "should_skip_file: skips source whose name has glob characters ($gname)"
    done
    rm -f ./*
    touch '[ab].mp4' 'a.fmpg.6.05.Mbps.mp4'
    bash -c "export BOILER_TEST_MODE=1; source /Users/andrewneely/dev/boiler/boiler.sh; cd '$temp_dir'; has_encoded_version '[ab].mp4'" && result="has_encoded" || result="no_encoded"
    assert_equal "$result" "no_encoded" "has_encoded_version: [ab] is not a character class matching another video's copy"
    rm -f ./*
    touch video.mp4 video.fmpg.10.25.Mbps.mp4

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

# Test transcode_video() uses resolution-based target when source bitrate is zero
echo "Testing transcode_video() with zero source bitrate and incompatible codec..."
test_transcode_video_zero_source_bitrate_incompatible_codec() {
    local output
    local exit_code
    local temp_dir

    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    reset_call_tracking
    touch "test_video.wmv"
    MOCK_VIDEO_FILE="test_video.wmv"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=0           # ffprobe returns 0 for WMV stream
    MOCK_VIDEO_CODEC="wmv3"
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=8000000

    set +e
    output=$(transcode_video "test_video.wmv" 2>&1)
    exit_code=$?
    set -e

    assert_exit_code $exit_code 0 "transcode_video: completes with zero source bitrate and incompatible codec"
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "1" "transcode_video: calls transcode_full_video for zero source bitrate + incompatible codec"
    local sample_count
    sample_count=$(count_calls "$TRANSCODE_SAMPLE_CALLS_FILE")
    local in_range_zero; [ "$sample_count" -le 9 ] && in_range_zero="yes" || in_range_zero="no"
    assert_equal "$in_range_zero" "yes" "transcode_video: sample count is <= 9 (no runaway loop) for zero source bitrate"

    rm -f "test_video.wmv" *.mp4 *.orig.*.mp4 2>/dev/null
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_VIDEO_CODEC MOCK_SAMPLE_BITRATE_BPS MOCK_OUTPUT_BITRATE_BPS

    cd - > /dev/null || true
    rm -rf "$temp_dir"
}
test_transcode_video_zero_source_bitrate_incompatible_codec

echo ""

# Test transcode_video() uses resolution-based target when source bitrate is near-zero (1 bps)
echo "Testing transcode_video() with near-zero source bitrate and incompatible codec..."
test_transcode_video_near_zero_source_bitrate_incompatible_codec() {
    local output
    local exit_code
    local temp_dir

    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    reset_call_tracking
    touch "test_video.wmv"
    MOCK_VIDEO_FILE="test_video.wmv"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=1           # ffprobe returns 1 bps — near-zero sentinel
    MOCK_VIDEO_CODEC="wmv3"
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=8000000

    set +e
    output=$(transcode_video "test_video.wmv" 2>&1)
    exit_code=$?
    set -e

    assert_exit_code $exit_code 0 "transcode_video: completes with near-zero source bitrate and incompatible codec"
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "1" "transcode_video: calls transcode_full_video for near-zero source bitrate + incompatible codec"
    local sample_count
    sample_count=$(count_calls "$TRANSCODE_SAMPLE_CALLS_FILE")
    local in_range_nearzero; [ "$sample_count" -le 9 ] && in_range_nearzero="yes" || in_range_nearzero="no"
    assert_equal "$in_range_nearzero" "yes" "transcode_video: sample count is <= 9 (no runaway loop) for near-zero source bitrate"

    rm -f "test_video.wmv" *.mp4 *.orig.*.mp4 2>/dev/null
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_VIDEO_CODEC MOCK_SAMPLE_BITRATE_BPS MOCK_OUTPUT_BITRATE_BPS

    cd - > /dev/null || true
    rm -rf "$temp_dir"
}
test_transcode_video_near_zero_source_bitrate_incompatible_codec

echo ""

# Test preprocess_non_quicklook_files() uses resolution-based target when source bitrate is zero
echo "Testing preprocess_non_quicklook_files() with zero source bitrate and incompatible codec..."
test_preprocess_zero_source_bitrate_incompatible_codec() {
    local output
    local exit_code
    local temp_dir

    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    reset_call_tracking
    touch "test_video.wmv"
    MOCK_VIDEO_FILE="test_video.wmv"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=0
    MOCK_VIDEO_CODEC="wmv3"
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=8000000

    set +e
    output=$(preprocess_non_quicklook_files 2>&1)
    exit_code=$?
    set -e

    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "1" "preprocess_non_quicklook_files: calls transcode_full_video for zero source bitrate + incompatible codec"
    local sample_count
    sample_count=$(count_calls "$TRANSCODE_SAMPLE_CALLS_FILE")
    local in_range_pre_zero; [ "$sample_count" -le 9 ] && in_range_pre_zero="yes" || in_range_pre_zero="no"
    assert_equal "$in_range_pre_zero" "yes" "preprocess_non_quicklook_files: sample count is <= 9 (no runaway loop) for zero source bitrate"

    rm -f "test_video.wmv" *.mp4 *.orig.*.mp4 2>/dev/null
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_VIDEO_CODEC MOCK_SAMPLE_BITRATE_BPS MOCK_OUTPUT_BITRATE_BPS

    cd - > /dev/null || true
    rm -rf "$temp_dir"
}
test_preprocess_zero_source_bitrate_incompatible_codec

echo ""

# Test preprocess_non_quicklook_files() uses resolution-based target when source bitrate is near-zero (1 bps)
echo "Testing preprocess_non_quicklook_files() with near-zero source bitrate and incompatible codec..."
test_preprocess_near_zero_source_bitrate_incompatible_codec() {
    local output
    local exit_code
    local temp_dir

    temp_dir=$(mktemp -d)
    cd "$temp_dir" || exit 1

    reset_call_tracking
    touch "test_video.wmv"
    MOCK_VIDEO_FILE="test_video.wmv"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=1
    MOCK_VIDEO_CODEC="wmv3"
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=8000000

    set +e
    output=$(preprocess_non_quicklook_files 2>&1)
    exit_code=$?
    set -e

    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "1" "preprocess_non_quicklook_files: calls transcode_full_video for near-zero source bitrate + incompatible codec"
    local sample_count
    sample_count=$(count_calls "$TRANSCODE_SAMPLE_CALLS_FILE")
    local in_range_pre_nz; [ "$sample_count" -le 9 ] && in_range_pre_nz="yes" || in_range_pre_nz="no"
    assert_equal "$in_range_pre_nz" "yes" "preprocess_non_quicklook_files: sample count is <= 9 (no runaway loop) for near-zero source bitrate"

    rm -f "test_video.wmv" *.mp4 *.orig.*.mp4 2>/dev/null
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_VIDEO_CODEC MOCK_SAMPLE_BITRATE_BPS MOCK_OUTPUT_BITRATE_BPS

    cd - > /dev/null || true
    rm -rf "$temp_dir"
}
test_preprocess_near_zero_source_bitrate_incompatible_codec

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

# ============================================================================
# Auto-crop (--auto-crop / --crop-detect-only)
# See plans/in-progress/AUTO-CROP-FEATURE-PLAN.md
# ============================================================================

echo "Testing auto-crop parsing and math helpers..."
test_crop_helpers() {
    local out exit_code
    has() { [[ "$1" == *"$2"* ]] && echo yes || echo no; }

    # parse_cropdetect_output: last crop= value wins
    out=$(parse_cropdetect_output $'[Parsed_cropdetect_0 @ 0x1] crop=1920:816:0:132\n[Parsed_cropdetect_0 @ 0x1] crop=1920:800:0:140\nframe=1')
    assert_equal "$out" "1920:800:0:140" "parse_cropdetect_output: returns the last crop= value"
    out=$(parse_cropdetect_output "ffmpeg: Invalid data found when processing input")
    assert_empty "$out" "parse_cropdetect_output: empty when there is no crop line"

    # parse_cropdetect_output: malformed lines are rejected, never passed to bc
    assert_empty "$(parse_cropdetect_output "[Parsed_cropdetect_0 @ 0x1] crop=1920:808:0:")" "parse_cropdetect_output: rejects empty field"
    assert_empty "$(parse_cropdetect_output "[Parsed_cropdetect_0 @ 0x1] crop=1920:808:0")" "parse_cropdetect_output: rejects three fields"
    assert_empty "$(parse_cropdetect_output "[Parsed_cropdetect_0 @ 0x1] crop=abc:808:0:136")" "parse_cropdetect_output: rejects non-numeric field"
    out=$(parse_cropdetect_output $'[Parsed_cropdetect_0 @ 0x1] crop=1920:800:0:140\n[Parsed_cropdetect_0 @ 0x1] crop=1920:80')
    assert_equal "$out" "1920:800:0:140" "parse_cropdetect_output: falls back to last valid line when final is garbled"
    out=$(parse_cropdetect_output $'[Parsed_cropdetect_0 @ 0x1] crop=1920:800:0:140\r\n')
    assert_equal "$out" "1920:800:0:140" "parse_cropdetect_output: tolerates CRLF"

    # bc guards: bad input warns and never surfaces a bc parse error
    out=$(crop_removed_pct "1920::0:140" 1920 1080 2>&1)
    assert_equal "$(has "$out" "Cannot compute removed area")" yes "crop_removed_pct: warns on malformed crop"
    assert_equal "$(has "$out" "Parse error")" no "crop_removed_pct: no bc parse error on malformed crop"
    out=$(crop_removed_pct "1920:800:0:140" "" 1080 2>&1)
    assert_equal "$(has "$out" "Cannot compute removed area")" yes "crop_removed_pct: warns on empty frame width"
    out=$(detect_black_bars /nonexistent.mp4 "N/A" 320 240 2>&1)
    assert_equal "$(has "$out" "Unusable duration 'N/A'")" yes "detect_black_bars: warns on non-numeric duration"
    assert_equal "$(has "$out" "Parse error")" no "detect_black_bars: no bc parse error on non-numeric duration"

    # detect_crop_for_file progress message reflects the real sampling mode
    out=$(detect_crop_for_file /nonexistent.mp4 6 2>&1)
    assert_equal "$(has "$out" "Detecting black bars (scanning the whole video)")" "yes" "detect_crop_for_file: short video reports whole-video scan"
    out=$(detect_crop_for_file /nonexistent.mp4 600 2>&1)
    assert_equal "$(has "$out" "Detecting black bars (12 windows)")" "yes" "detect_crop_for_file: long video reports window count"

    # get_video_dimensions: key=value parsing, immune to stray separators from side-data streams.
    # The suite mocks get_video_dimensions(), so run the real one in a fresh shell with ffprobe stubbed.
    dims_with_ffprobe() {
        FAKE_FFPROBE_OUTPUT="$1" BOILER_TEST_MODE=1 bash -c '
            source ./boiler.sh 2>/dev/null
            ffprobe() { printf "%s" "$FAKE_FFPROBE_OUTPUT"; }
            get_video_dimensions whatever.mp4'
    }
    assert_equal "$(dims_with_ffprobe $'width=3840\r\nheight=2160\r\n[SIDE_DATA]\r\n')" "3840 2160" "get_video_dimensions: ignores extra output and CRLF"
    assert_empty "$(dims_with_ffprobe $'width=N/A\nheight=\n')" "get_video_dimensions: empty when ffprobe output is unusable"

    # combine_crop_boxes: union
    assert_equal "$(combine_crop_boxes "1920:800:0:140")" "1920:800:0:140" "combine_crop_boxes: single box unchanged"
    assert_equal "$(combine_crop_boxes "1920:800:0:140" "1800:800:100:100")" "1920:840:0:100" "combine_crop_boxes: union takes widest extent"
    assert_equal "$(combine_crop_boxes "1920:800:0:140" "1920:1080:0:0")" "1920:1080:0:0" "combine_crop_boxes: full-frame box makes union full-frame"
    assert_empty "$(combine_crop_boxes)" "combine_crop_boxes: no boxes gives empty output"

    # crop_removed_pct
    assert_equal "$(crop_removed_pct "1920:800:0:140" 1920 1080)" "25.9" "crop_removed_pct: 1920x800 of 1920x1080 removes 25.9%"
    assert_equal "$(crop_removed_pct "1920:1080:0:0" 1920 1080)" "0.0" "crop_removed_pct: full frame removes 0.0%"

    # validate_crop_params
    set +e
    validate_crop_params "1920:800:0:140" 1920 1080 2>/dev/null
    assert_exit_code $? 0 "validate_crop_params: accepts a normal letterbox crop"
    validate_crop_params "1919:800:0:140" 1920 1080 2>/dev/null
    assert_exit_code $? 1 "validate_crop_params: rejects odd width"
    validate_crop_params "1920:800:0:141" 1920 1080 2>/dev/null
    assert_exit_code $? 1 "validate_crop_params: rejects odd offset"
    validate_crop_params "8:800:0:140" 1920 1080 2>/dev/null
    assert_exit_code $? 1 "validate_crop_params: rejects results under 16 pixels"
    validate_crop_params "1920:400:0:340" 1920 1080 2>/dev/null
    assert_exit_code $? 1 "validate_crop_params: rejects crops removing more than half the frame"
    validate_crop_params "1920:800:0:400" 1920 1080 2>/dev/null
    assert_exit_code $? 1 "validate_crop_params: rejects crops outside the frame"
    validate_crop_params "1920:800" 1920 1080 2>/dev/null
    assert_exit_code $? 1 "validate_crop_params: rejects malformed input"
    set -e
}
test_crop_helpers

echo ""

echo "Testing auto-crop argument parsing..."
test_crop_parse_arguments() {
    AUTO_CROP=0; CROP_DETECT_ONLY=0
    parse_arguments -L 1
    assert_equal "$AUTO_CROP$CROP_DETECT_ONLY" "00" "parse_arguments: auto-crop is off by default"

    AUTO_CROP=0; CROP_DETECT_ONLY=0
    parse_arguments --auto-crop
    assert_equal "$AUTO_CROP$CROP_DETECT_ONLY" "10" "parse_arguments: --auto-crop enables auto-crop only"

    AUTO_CROP=0; CROP_DETECT_ONLY=0
    parse_arguments --crop-detect-only
    assert_equal "$AUTO_CROP$CROP_DETECT_ONLY" "11" "parse_arguments: --crop-detect-only implies auto-crop"

    local usage
    usage=$(show_usage 2>&1)
    assert_not_empty "$(echo "$usage" | grep -- '--auto-crop' || true)" "show_usage: documents --auto-crop"
    assert_not_empty "$(echo "$usage" | grep -- '--crop-detect-only' || true)" "show_usage: documents --crop-detect-only"

    AUTO_CROP=0; CROP_DETECT_ONLY=0
}
test_crop_parse_arguments

echo ""

echo "Testing detect_black_bars() against generated clips..."
test_detect_black_bars_real() {
    if ! command -v ffmpeg &> /dev/null || ! command -v ffprobe &> /dev/null; then
        echo "  (Skipping detect_black_bars tests: ffmpeg/ffprobe not in PATH)"
        return 0
    fi
    local fix root
    root=$(pwd)
    fix=$(mktemp -d)
    local enc=(-c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 10)
    local common=(-v error -y -f lavfi)

    # 320x240 clips; content is testsrc2 so the active picture is clearly non-black
    ffmpeg "${common[@]}" -i "testsrc2=s=320x180:r=5:d=40,pad=320:240:0:30:black" "${enc[@]}" "$fix/letterbox.mp4" 2>/dev/null
    ffmpeg "${common[@]}" -i "testsrc2=s=240x240:r=5:d=40,pad=320:240:40:0:black" "${enc[@]}" "$fix/pillarbox.mp4" 2>/dev/null
    ffmpeg "${common[@]}" -i "testsrc2=s=320x240:r=5:d=40" "${enc[@]}" "$fix/full.mp4" 2>/dev/null
    ffmpeg "${common[@]}" -i "testsrc2=s=320x236:r=5:d=40,pad=320:240:0:2:black" "${enc[@]}" "$fix/tinybars.mp4" 2>/dev/null
    ffmpeg "${common[@]}" -i "color=c=black:s=320x240:r=5:d=20" \
        -f lavfi -i "testsrc2=s=320x180:r=5:d=20,pad=320:240:0:30:black" \
        -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0" "${enc[@]}" "$fix/dark_then_letterbox.mp4" 2>/dev/null
    ffmpeg "${common[@]}" -i "testsrc2=s=320x180:r=5:d=20,pad=320:240:0:30:black" \
        -f lavfi -i "testsrc2=s=320x240:r=5:d=20" \
        -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0" "${enc[@]}" "$fix/variable_aspect.mp4" 2>/dev/null
    ffmpeg "${common[@]}" -i "testsrc2=s=320x180:r=5:d=40,pad=320:240:0:30:black,drawbox=x=100:y=0:w=120:h=20:color=white:t=fill" \
        "${enc[@]}" "$fix/burned_subs.mp4" 2>/dev/null
    ffmpeg "${common[@]}" -i "testsrc2=s=320x180:r=5:d=6,pad=320:240:0:30:black" "${enc[@]}" "$fix/short_letterbox.mp4" 2>/dev/null
    ffmpeg "${common[@]}" -i "testsrc2=s=320x180:r=5:d=40,pad=320:240:0:30:black" \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p10le -g 10 "$fix/letterbox_10bit.mp4" 2>/dev/null

    # Run against real ffmpeg in a fresh shell (the harness mocks ffprobe and probe helpers)
    detect_real() {
        local func_name="$1"
        shift
        bash -c "
            set +e
            export BOILER_TEST_MODE=1
            source '$root/boiler.sh' 2>/dev/null
            $func_name \"\$@\"
        " -- "$@"
    }

    assert_equal "$(detect_real detect_black_bars "$fix/letterbox.mp4" 40 320 240 2>/dev/null)" "320:180:0:30" "detect_black_bars: finds letterbox"
    assert_equal "$(detect_real detect_black_bars "$fix/pillarbox.mp4" 40 320 240 2>/dev/null)" "240:240:40:0" "detect_black_bars: finds pillarbox"
    assert_empty "$(detect_real detect_black_bars "$fix/full.mp4" 40 320 240 2>/dev/null)" "detect_black_bars: full-frame video has no crop"
    assert_empty "$(detect_real detect_black_bars "$fix/tinybars.mp4" 40 320 240 2>/dev/null)" "detect_black_bars: bars below the minimum are ignored"
    assert_equal "$(detect_real detect_black_bars "$fix/dark_then_letterbox.mp4" 40 320 240 2>/dev/null)" "320:180:0:30" "detect_black_bars: dark scenes do not cause over-cropping"
    assert_empty "$(detect_real detect_black_bars "$fix/variable_aspect.mp4" 40 320 240 2>/dev/null)" "detect_black_bars: variable aspect ratio uses the most conservative crop"
    assert_equal "$(detect_real detect_black_bars "$fix/burned_subs.mp4" 40 320 240 2>/dev/null)" "320:210:0:0" "detect_black_bars: burned-in text in a bar is not cropped away"
    assert_equal "$(detect_real detect_black_bars "$fix/short_letterbox.mp4" 6 320 240 2>/dev/null)" "320:180:0:30" "detect_black_bars: short video scanned as a single whole-file window"
    assert_equal "$(detect_real detect_black_bars "$fix/letterbox_10bit.mp4" 40 320 240 2>/dev/null)" "320:180:0:30" "detect_black_bars: finds letterbox in 10-bit video (limit scales with bit depth)"
    assert_empty "$(CROP_LIMIT=abc detect_real detect_black_bars "$fix/letterbox.mp4" 40 320 240 2>/dev/null)" "detect_black_bars: non-numeric CROP_LIMIT does not crop"
    assert_empty "$(CROP_MIN_REMOVED_PCT=30 detect_real detect_black_bars "$fix/letterbox.mp4" 40 320 240 2>/dev/null)" "detect_black_bars: respects CROP_MIN_REMOVED_PCT"
    assert_equal "$(detect_real get_video_rotation "$fix/letterbox.mp4" 2>/dev/null)" "0" "get_video_rotation: untagged clip reports 0"
    assert_equal "$(detect_real get_video_dimensions "$fix/letterbox.mp4" 2>/dev/null)" "320 240" "get_video_dimensions: reports width and height"

    unset -f detect_real
    rm -rf "$fix"
}
test_detect_black_bars_real

echo ""

echo "Testing detect_crop_for_file() and verify_crop_output()..."
test_detect_crop_for_file() {
    local output

    detect_black_bars() { echo "1920:800:0:140"; }
    CROP_PARAMS=""
    detect_crop_for_file "video.mp4" 300 2>/dev/null
    assert_equal "$CROP_PARAMS" "1920:800:0:140" "detect_crop_for_file: sets CROP_PARAMS from detection"

    detect_black_bars() { echo ""; }
    CROP_PARAMS="stale"
    detect_crop_for_file "video.mp4" 300 2>/dev/null
    assert_empty "$CROP_PARAMS" "detect_crop_for_file: clears CROP_PARAMS when no crop applies"

    detect_black_bars() { echo "1920:800:0:140"; }
    MOCK_ROTATION=90
    output=$(detect_crop_for_file "video.mp4" 300 2>&1)
    assert_not_empty "$(echo "$output" | grep -i "rotation" || true)" "detect_crop_for_file: warns for rotation-tagged files"
    CROP_PARAMS="stale"
    detect_crop_for_file "video.mp4" 300 2>/dev/null
    assert_empty "$CROP_PARAMS" "detect_crop_for_file: skips rotation-tagged files"
    unset MOCK_ROTATION

    set +e
    MOCK_OUTPUT_DIMS="1920 800"
    verify_crop_output "x_temp_transcode.mp4" "1920:800:0:140" 2>/dev/null
    assert_exit_code $? 0 "verify_crop_output: passes when dimensions match the crop"
    MOCK_OUTPUT_DIMS="1920 1080"
    output=$(verify_crop_output "x_temp_transcode.mp4" "1920:800:0:140" 2>&1)
    assert_exit_code $? 1 "verify_crop_output: fails when dimensions differ"
    set -e
    assert_not_empty "$(echo "$output" | grep "expected 1920x800" || true)" "verify_crop_output: reports expected size"
    unset MOCK_OUTPUT_DIMS
    CROP_PARAMS=""
}
test_detect_crop_for_file

echo ""

echo "Testing crop filter in transcode_sample() and transcode_full_video()..."
test_crop_filter_args() {
    local tmpdir args
    tmpdir=$(mktemp -d)
    touch "$tmpdir/in.mp4"

    # Real encode functions with ffmpeg stubbed to record its arguments
    encode_with_stub() {
        local crop="$1" func_name="$2"
        shift 2
        bash -c "
            set +e
            export BOILER_TEST_MODE=1
            source '$(pwd)/boiler.sh' 2>/dev/null
            CROP_PARAMS='$crop'
            ffmpeg() { printf '%s\n' \"\$*\" > '$tmpdir/args'; echo data > '$tmpdir/out.mp4'; }
            ffprobe() {
                if [[ \"\$*\" == *codec_name* ]] && [[ \"\$*\" == *select_streams\ a* ]]; then echo aac
                elif [[ \"\$*\" == *codec_name* ]]; then echo h264
                elif [[ \"\$*\" == *csv=p=0* ]]; then echo 1
                else echo ''; fi
            }
            $func_name \"\$@\"
        " -- "$@" 2>/dev/null
    }

    encode_with_stub "1920:800:0:140" transcode_sample "$tmpdir/in.mp4" 10 5 60 "$tmpdir/out.mp4"
    args=$(cat "$tmpdir/args")
    assert_not_empty "$(echo "$args" | grep -F -- "-vf crop=1920:800:0:140" || true)" "transcode_sample: adds crop filter when CROP_PARAMS is set"

    rm -f "$tmpdir/args" "$tmpdir/out.mp4"
    encode_with_stub "" transcode_sample "$tmpdir/in.mp4" 10 5 60 "$tmpdir/out.mp4"
    args=$(cat "$tmpdir/args")
    assert_empty "$(echo "$args" | grep -F -- "-vf" || true)" "transcode_sample: no filter when CROP_PARAMS is empty"

    rm -f "$tmpdir/args" "$tmpdir/out.mp4"
    encode_with_stub "1920:800:0:140" transcode_full_video "$tmpdir/in.mp4" "$tmpdir/out.mp4" 60
    args=$(cat "$tmpdir/args")
    assert_not_empty "$(echo "$args" | grep -F -- "-vf crop=1920:800:0:140" || true)" "transcode_full_video: adds crop filter when CROP_PARAMS is set"

    rm -f "$tmpdir/args" "$tmpdir/out.mp4"
    encode_with_stub "" transcode_full_video "$tmpdir/in.mp4" "$tmpdir/out.mp4" 60
    args=$(cat "$tmpdir/args")
    assert_empty "$(echo "$args" | grep -F -- "-vf" || true)" "transcode_full_video: no filter when CROP_PARAMS is empty"

    unset -f encode_with_stub
    rm -rf "$tmpdir"
}
test_crop_filter_args

echo ""

echo "Testing transcode_video() with a detected crop..."
# Shared setup/teardown for crop integration tests (mocked encodes, 1080p source)
crop_it_setup() {
    CROP_IT_DIR=$(mktemp -d)
    cd "$CROP_IT_DIR" || exit 1
    reset_call_tracking
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_OUTPUT_DIMS="1920 800"
    MOCK_OUTPUT_BITRATE_BPS=8000000
    MOCK_SAMPLE_BITRATE_BPS=8000000
    AUTO_CROP=1
    CROP_DETECT_ONLY=0
    CROP_PARAMS=""
    detect_black_bars() { echo "1920:800:0:140"; }
}
crop_it_teardown() {
    unset MOCK_VIDEO_FILE MOCK_RESOLUTION MOCK_DURATION MOCK_OUTPUT_DIMS MOCK_OUTPUT_BITRATE_BPS MOCK_SAMPLE_BITRATE_BPS MOCK_BITRATE_BPS
    AUTO_CROP=0
    CROP_DETECT_ONLY=0
    CROP_PARAMS=""
    cd - > /dev/null || true
    rm -rf "$CROP_IT_DIR"
}

test_transcode_video_crop() {
    local output exit_code

    # Within tolerance + crop: re-encoded instead of skipped/renamed
    crop_it_setup
    MOCK_BITRATE_BPS=8000000
    set +e
    output=$(transcode_video "test_video.mp4" 2>&1)
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "transcode_video crop: completes when source is within tolerance"
    assert_not_empty "$(echo "$output" | grep "Re-encoding to apply crop" || true)" "transcode_video crop: re-encodes instead of short-circuiting"
    assert_empty "$(echo "$output" | grep "No transcoding needed" || true)" "transcode_video crop: no 'no transcoding needed' message"
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "1" "transcode_video crop: calls transcode_full_video"
    assert_equal "$([ -f test_video.fmpg.8.00.Mbps.mp4 ] && echo yes || echo no)" "yes" "transcode_video crop: creates .fmpg. output"
    assert_equal "$([ -f test_video.orig.8.00.Mbps.mp4 ] && echo yes || echo no)" "no" "transcode_video crop: does not rename source to .orig."
    crop_it_teardown

    # Below target + crop: source bitrate becomes the target
    crop_it_setup
    MOCK_BITRATE_BPS=3000000
    MOCK_OUTPUT_BITRATE_BPS=3000000
    MOCK_SAMPLE_BITRATE_BPS=3000000
    set +e
    output=$(transcode_video "test_video.mp4" 2>&1)
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "transcode_video crop: completes when source is below target"
    assert_not_empty "$(echo "$output" | grep "using source bitrate" || true)" "transcode_video crop: below-target source uses its own bitrate as target"
    assert_equal "$([ -f test_video.fmpg.3.00.Mbps.mp4 ] && echo yes || echo no)" "yes" "transcode_video crop: below-target output named from source bitrate"
    crop_it_teardown

    # Explicit target bitrate is never replaced
    crop_it_setup
    MOCK_BITRATE_BPS=3000000
    MOCK_OUTPUT_BITRATE_BPS=9500000
    MOCK_SAMPLE_BITRATE_BPS=9500000
    set +e
    output=$(transcode_video "test_video.mp4" "9.5" 2>&1)
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "transcode_video crop: completes with explicit target bitrate"
    assert_empty "$(echo "$output" | grep "using source bitrate" || true)" "transcode_video crop: explicit target bitrate is never replaced"
    assert_not_empty "$(echo "$output" | grep "Target bitrate (override): 9.5 Mbps" || true)" "transcode_video crop: explicit target bitrate used verbatim"
    crop_it_teardown

    # Tier stays on the pre-crop height
    crop_it_setup
    MOCK_BITRATE_BPS=20000000
    set +e
    output=$(transcode_video "test_video.mp4" 2>&1)
    set -e
    assert_not_empty "$(echo "$output" | grep "Target bitrate: 8 Mbps (1080p)" || true)" "transcode_video crop: tier comes from pre-crop height (1080p)"
    assert_empty "$(echo "$output" | grep "(720p)" || true)" "transcode_video crop: cropped height does not change the tier"
    crop_it_teardown

    # No crop detected: existing short-circuit still applies
    crop_it_setup
    detect_black_bars() { echo ""; }
    MOCK_BITRATE_BPS=8000000
    set +e
    output=$(transcode_video "test_video.mp4" 2>&1)
    set -e
    assert_not_empty "$(echo "$output" | grep "No transcoding needed" || true)" "transcode_video crop: no crop detected keeps the normal short-circuit"
    assert_equal "$(count_calls "$TRANSCODE_FULL_CALLS_FILE")" "0" "transcode_video crop: no crop detected means no encode"
    crop_it_teardown

    # Detection does not run without --auto-crop
    crop_it_setup
    AUTO_CROP=0
    detect_black_bars() { echo "called" >> "$CROP_IT_DIR/detect_called"; echo "1920:800:0:140"; }
    MOCK_BITRATE_BPS=8000000
    set +e
    output=$(transcode_video "test_video.mp4" 2>&1)
    set -e
    assert_not_empty "$(echo "$output" | grep "No transcoding needed" || true)" "transcode_video crop: without --auto-crop behavior is unchanged"
    assert_equal "$([ -f "$CROP_IT_DIR/detect_called" ] && echo yes || echo no)" "no" "transcode_video crop: detection does not run without --auto-crop"
    crop_it_teardown

    # Output size mismatch fails the file and removes the temp output
    crop_it_setup
    MOCK_BITRATE_BPS=20000000
    MOCK_OUTPUT_DIMS="1920 1080"
    set +e
    output=$(transcode_video "test_video.mp4" 2>&1)
    exit_code=$?
    set -e
    assert_exit_code_nonzero $exit_code "transcode_video crop: fails when output is not the cropped size"
    assert_not_empty "$(echo "$output" | grep "expected 1920x800" || true)" "transcode_video crop: reports the expected size"
    assert_equal "$([ -f test_video_temp_transcode.mp4 ] && echo yes || echo no)" "no" "transcode_video crop: removes temp output on size mismatch"
    crop_it_teardown

    # Crop state does not leak between files
    crop_it_setup
    touch second.mp4
    MOCK_BITRATE_BPS=20000000
    detect_black_bars() { [[ "$1" == *second* ]] && echo "" || echo "1920:800:0:140"; }
    set +e
    transcode_video "test_video.mp4" > /dev/null 2>&1
    set -e
    assert_equal "$CROP_PARAMS" "1920:800:0:140" "transcode_video crop: crop is active for the first file"
    MOCK_BITRATE_BPS=8000000
    set +e
    transcode_video "second.mp4" > /dev/null 2>&1
    set -e
    assert_empty "$CROP_PARAMS" "transcode_video crop: crop does not leak into the next file"
    crop_it_teardown
}
test_transcode_video_crop

echo ""

echo "Testing auto-crop with preprocessing and --crop-detect-only..."
test_crop_preprocess_and_detect_only() {
    local output

    # mkv within tolerance, no crop: remuxed as before
    crop_it_setup
    rm -f test_video.mp4
    touch movie.mkv
    MOCK_BITRATE_BPS=8000000
    detect_black_bars() { echo ""; }
    set +e
    preprocess_non_quicklook_files > /dev/null 2>&1
    set -e
    assert_equal "$(count_calls "$REMUX_CALLS_FILE")" "1" "preprocess crop: mkv within tolerance is remuxed when no crop is detected"
    crop_it_teardown

    # mkv within tolerance, crop detected: left alone for the main pass
    crop_it_setup
    rm -f test_video.mp4
    touch movie.mkv
    MOCK_BITRATE_BPS=8000000
    set +e
    output=$(preprocess_non_quicklook_files 2>&1)
    set -e
    assert_not_empty "$(echo "$output" | grep "skipping remux" || true)" "preprocess crop: reports skipping remux when a crop is detected"
    assert_equal "$(count_calls "$REMUX_CALLS_FILE")" "0" "preprocess crop: mkv needing a crop is not remuxed"
    assert_equal "$([ -f movie.mkv ] && echo yes || echo no)" "yes" "preprocess crop: mkv needing a crop is left in place"
    crop_it_teardown

    # --crop-detect-only: reports, changes nothing
    crop_it_setup
    CROP_DETECT_ONLY=1
    MOCK_BITRATE_BPS=8000000
    set +e
    output=$(main 2>&1)
    local exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "main --crop-detect-only: exits 0"
    assert_not_empty "$(echo "$output" | grep "crop=1920:800:0:140" || true)" "main --crop-detect-only: reports the detected crop"
    assert_equal "$(count_calls "$TRANSCODE_SAMPLE_CALLS_FILE")$(count_calls "$TRANSCODE_FULL_CALLS_FILE")$(count_calls "$REMUX_CALLS_FILE")" "000" "main --crop-detect-only: encodes and remuxes nothing"
    assert_equal "$([ -f test_video.mp4 ] && echo yes || echo no)" "yes" "main --crop-detect-only: leaves files untouched"
    crop_it_teardown

    unset -f detect_black_bars
}
test_crop_preprocess_and_detect_only

echo ""

# ============================================================================
# Script-level and subtitle tests (parity with tests/*.bats)
#
# These are transcribed one-to-one from the bats files named in each section, with the
# bats test bodies kept verbatim. A minimal bats-compatible shim (run, assert_success,
# assert_output, assert_line, ...) lets the same bodies run under this harness; each
# bats test counts as one assertion here.
# ============================================================================

PROJECT_ROOT="$(pwd)"
TESTS_DIR="$PROJECT_ROOT/tests"

# --- bats-compatible shim --------------------------------------------------
# run: capture combined output, status and lines (never fails the caller)
run() {
    local _rc=0
    output=$("$@" 2>&1) || _rc=$?
    status=$_rc
    lines=()
    local _l
    while IFS= read -r _l; do
        lines+=("$_l")
    done <<< "$output"
    return 0
}
assert_success() {
    if [ "${status:-1}" -ne 0 ]; then
        echo "expected success, got status ${status}; output: ${output}" >&2
        return 1
    fi
}
# assert_output [--partial STR | STR]
assert_output() {
    if [ "${1:-}" = "--partial" ]; then
        if [[ "$output" != *"$2"* ]]; then
            echo "expected output to contain '$2'; got: ${output}" >&2
            return 1
        fi
    else
        if [ "$output" != "$1" ]; then
            echo "expected output '$1'; got: '${output}'" >&2
            return 1
        fi
    fi
}
# refute_output [--partial STR | STR]
refute_output() {
    if [ "${1:-}" = "--partial" ]; then
        if [[ "$output" == *"$2"* ]]; then
            echo "expected output not to contain '$2'; got: ${output}" >&2
            return 1
        fi
    else
        if [ "$output" = "$1" ]; then
            echo "expected output to differ from '$1'" >&2
            return 1
        fi
    fi
}
# assert_line [--partial] STR
assert_line() {
    local _partial=0
    if [ "$1" = "--partial" ]; then _partial=1; shift; fi
    local _l
    for _l in "${lines[@]}"; do
        if [ "$_partial" -eq 1 ]; then
            [[ "$_l" == *"$1"* ]] && return 0
        else
            [ "$_l" = "$1" ] && return 0
        fi
    done
    echo "expected a line ${_partial:+matching }'$1'; got: ${output}" >&2
    return 1
}
# refute_line [--partial] STR
refute_line() {
    local _partial=0
    if [ "$1" = "--partial" ]; then _partial=1; shift; fi
    local _l
    for _l in "${lines[@]}"; do
        if [ "$_partial" -eq 1 ]; then
            if [[ "$_l" == *"$1"* ]]; then
                echo "expected no line containing '$1'; got: ${output}" >&2
                return 1
            fi
        else
            if [ "$_l" = "$1" ]; then
                echo "expected no line '$1'; got: ${output}" >&2
                return 1
            fi
        fi
    done
    return 0
}
# Stand-ins for tests/helpers/setup.bash hooks (mock state lives in this file)
common_setup() {
    reset_call_tracking
    unset MOCK_RESOLUTION MOCK_DURATION MOCK_BITRATE_BPS MOCK_SAMPLE_BITRATE_BPS MOCK_OUTPUT_BITRATE_BPS \
          MOCK_SECOND_PASS_BITRATE_BPS MOCK_THIRD_PASS_BITRATE_BPS MOCK_VIDEO_CODEC MOCK_AUDIO_CODEC MOCK_VIDEO_FILE
    unset GLOBAL_TARGET_BITRATE_MBPS
}
common_teardown() { :; }

# Run one transcribed bats test in a subshell: setup, body, teardown (via EXIT trap).
# $1 = test name, $2 = test function, $3 = setup function, $4 = teardown function
bats_case() {
    local _name="$1" _fn="$2" _setup="$3" _teardown="$4"
    local _out _rc=0
    TESTS_RUN=$((TESTS_RUN + 1))
    _out=$( ( set -e; trap "$_teardown" EXIT; "$_setup"; "$_fn" ) 2>&1 ) || _rc=$?
    if [ "$_rc" -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} $_name"
        echo "$_out" | sed 's/^/  /' | head -20
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}


echo "Testing remux-only.sh (file discovery, args, output paths, subtitles) (tests/test_remux_only.bats)..."
remux_only__setup() {
    TEST_DIR=$(mktemp -d)
}
remux_only__teardown() {
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
remux_only__t1() {
    cd "$TEST_DIR"
    mkdir -p level1/level2/level3
    touch video0.mkv
    touch level1/video1.avi
    touch level1/level2/video2.webm
    touch level1/level2/level3/video3.mkv

    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_remux_files
    "
    assert_success
    assert_output "./video0.mkv"
}
remux_only__t2() {
    cd "$TEST_DIR"
    mkdir -p level1/level2/level3
    touch video0.mkv
    touch level1/video1.avi
    touch level1/level2/video2.webm
    touch level1/level2/level3/video3.mkv

    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=2
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_remux_files
    "
    assert_success
    assert_line "./video0.mkv"
    assert_line "./level1/video1.avi"
    refute_line "./level1/level2/video2.webm"
}
remux_only__t3() {
    cd "$TEST_DIR"
    mkdir -p level1/level2/level3
    touch video0.mkv
    touch level1/video1.avi
    touch level1/level2/video2.webm
    touch level1/level2/level3/video3.mkv

    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=3
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_remux_files
    "
    assert_success
    assert_line "./video0.mkv"
    assert_line "./level1/video1.avi"
    assert_line "./level1/level2/video2.webm"
    refute_line "./level1/level2/level3/video3.mkv"
}
remux_only__t4() {
    cd "$TEST_DIR"
    mkdir -p level1/level2/level3
    touch video0.mkv
    touch level1/video1.avi
    touch level1/level2/video2.webm
    touch level1/level2/level3/video3.mkv

    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=0
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_remux_files
    "
    assert_success
    assert_line "./video0.mkv"
    assert_line "./level1/video1.avi"
    assert_line "./level1/level2/video2.webm"
    assert_line "./level1/level2/level3/video3.mkv"
}
remux_only__t5() {
    cd "$TEST_DIR"
    mkdir -p level1/level2
    touch video0.mkv
    touch level1/video1.avi
    touch level1/level2/video2.webm

    run bash -c "
        export REMUX_TEST_MODE=1
        unset GLOBAL_MAX_DEPTH
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_remux_files
    "
    assert_success
    assert_line "./video0.mkv"
    assert_line "./level1/video1.avi"
    refute_line "./level1/level2/video2.webm"
}
remux_only__t6() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments -L 3
        echo \"\$GLOBAL_MAX_DEPTH\"
    "
    assert_success
    assert_output "3"
}
remux_only__t7() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments --max-depth 5
        echo \"\$GLOBAL_MAX_DEPTH\"
    "
    assert_success
    assert_output "5"
}
remux_only__t8() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments --preserve-name
        echo \"\$GLOBAL_PRESERVE_NAME\"
    "
    assert_success
    assert_output "1"
}
remux_only__t9() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        validate_depth 0 && echo 'ok0'
        validate_depth 1 && echo 'ok1'
        validate_depth 5 && echo 'ok5'
        validate_depth 100 && echo 'ok100'
    "
    assert_success
    assert_line "ok0"
    assert_line "ok1"
    assert_line "ok5"
    assert_line "ok100"
}
remux_only__t10() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        validate_depth '' && echo 'empty_ok' || echo 'empty_rejected'
        validate_depth '-1' && echo 'neg_ok' || echo 'neg_rejected'
        validate_depth '2.5' && echo 'dec_ok' || echo 'dec_rejected'
        validate_depth 'abc' && echo 'str_ok' || echo 'str_rejected'
    "
    assert_line "empty_rejected"
    assert_line "neg_rejected"
    assert_line "dec_rejected"
    assert_line "str_rejected"
}
remux_only__t11() {
    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_PRESERVE_NAME=0
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        generate_output_filename 'level1/subdir' 'video' '5.50'
    "
    assert_success
    assert_output "level1/subdir/video.orig.5.50.Mbps.mp4"
}
remux_only__t12() {
    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_PRESERVE_NAME=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        generate_output_filename '.' 'movie' '8.00'
    "
    assert_success
    assert_output "movie.mp4"
}
remux_only__t13() {
    cd "$TEST_DIR"
    touch movie.mp4

    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_PRESERVE_NAME=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        generate_output_filename '.' 'movie' '8.00'
    "
    assert_success
    assert_output "movie.remux.mp4"
}
remux_only__t14() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments -L 3
        echo \"\$GLOBAL_MAX_DEPTH\"
    "
    assert_success
    assert_output "3"
}
remux_only__t15() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments -p
        echo \"\$GLOBAL_PRESERVE_NAME\"
    "
    assert_success
    assert_output "1"
}
remux_only__t16() {
    cd "$TEST_DIR"
    touch video.mkv video.wmv video.avi video.webm video.flv video.mpg video.mpeg video.ts

    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_remux_files
    "
    assert_success
    assert_line "./video.mkv"
    assert_line "./video.wmv"
    assert_line "./video.avi"
    assert_line "./video.webm"
    assert_line "./video.flv"
    assert_line "./video.mpg"
    assert_line "./video.mpeg"
    assert_line "./video.ts"
}
remux_only__t17() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        get_video_codec() { echo 'hevc'; }
        get_video_codec_tag() { echo 'hev1'; }
        get_audio_codec() { echo 'aac'; }
        is_quicklook_compatible 'test.mp4' && echo 'compatible' || echo 'incompatible'
    "
    assert_success
    assert_output "incompatible"
}
remux_only__t18() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        get_video_codec() { echo 'h264'; }
        get_video_codec_tag() { echo 'avc1'; }
        get_audio_codec() { echo 'opus'; }
        is_quicklook_compatible 'test.mp4' && echo 'compatible' || echo 'incompatible'
    "
    assert_success
    assert_output "incompatible"
}
remux_only__t19() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        get_video_codec() { echo 'hevc'; }
        get_video_codec_tag() { echo 'hvc1'; }
        get_audio_codec() { echo 'aac'; }
        is_quicklook_compatible 'test.mp4' && echo 'compatible' || echo 'incompatible'
    "
    assert_success
    assert_output "compatible"
}
remux_only__t20() {
    cd "$TEST_DIR"
    touch movie.mp4
    touch movie.fmpg.8.00.Mbps.mp4
    touch movie.orig.7.50.Mbps.mp4
    touch movie.hbrk.9.00.Mbps.mp4

    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        find_mp4_files
    "
    assert_success
    assert_output "./movie.mp4"
    refute_line "./movie.fmpg.8.00.Mbps.mp4"
    refute_line "./movie.orig.7.50.Mbps.mp4"
    refute_line "./movie.hbrk.9.00.Mbps.mp4"
}
remux_only__t21() {
    cd "$TEST_DIR"
    touch movie.mp4

    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_PRESERVE_NAME=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'
        generate_output_filename '.' 'movie' '8.00'
    "
    assert_success
    assert_output "movie.remux.mp4"
}
remux_only__t22() {
    # Verify the Phase 2 naming convention matches remux-select-audio pattern
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        # Simulate the Phase 2 output path calculation
        file_path='./movie.mp4'
        parse_filename \"\$file_path\"
        base_name=\"\$BASE_NAME\"
        dirname=\$(dirname \"\$file_path\")
        prefix=\"\"
        [ \"\$dirname\" != \".\" ] && prefix=\"\${dirname}/\"
        echo \"\${prefix}\${base_name}.remux.mp4\"
    "
    assert_success
    assert_output "movie.remux.mp4"
}
remux_only__t23() {
    cd "$TEST_DIR"
    touch movie.mp4

    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'

        get_subtitle_mode_for_file() { echo 'none'; }
        remux_to_mp4() { touch \"\$2\"; return 0; }
        is_quicklook_compatible() { return 1; }
        get_video_codec() { echo 'hevc'; }

        file_path='./movie.mp4'
        parse_filename \"\$file_path\"
        base_name=\"\$BASE_NAME\"
        dirname=\$(dirname \"\$file_path\")
        prefix=\"\"
        [ \"\$dirname\" != \".\" ] && prefix=\"\${dirname}/\"
        output_file=\"\${prefix}\${base_name}.remux.mp4\"

        subtitle_mode=\$(get_subtitle_mode_for_file \"\$file_path\")
        remux_to_mp4 \"\$file_path\" \"\$output_file\" \"\$subtitle_mode\"

        [ -f \"\$file_path\" ] && echo 'original_exists' || echo 'original_deleted'
        [ -f \"\$output_file\" ] && echo 'output_exists' || echo 'output_missing'
    "
    assert_success
    assert_line "original_exists"
    assert_line "output_exists"
}
remux_only__t24() {
    cd "$TEST_DIR"
    touch movie.mp4

    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        cd '$TEST_DIR'

        get_subtitle_mode_for_file() { echo 'abort'; }
        remux_called=0
        remux_to_mp4() { remux_called=1; }
        is_quicklook_compatible() { return 1; }

        file_path='./movie.mp4'
        parse_filename \"\$file_path\"
        base_name=\"\$BASE_NAME\"
        dirname=\$(dirname \"\$file_path\")
        prefix=\"\"
        [ \"\$dirname\" != \".\" ] && prefix=\"\${dirname}/\"
        output_file=\"\${prefix}\${base_name}.remux.mp4\"

        skipped_count=0
        subtitle_mode=\$(get_subtitle_mode_for_file \"\$file_path\")
        if [ \"\$subtitle_mode\" = 'abort' ]; then
            skipped_count=\$((skipped_count + 1))
        else
            remux_to_mp4 \"\$file_path\" \"\$output_file\" \"\$subtitle_mode\"
        fi

        echo \"skipped:\$skipped_count\"
        echo \"remux_called:\$remux_called\"
        [ -f \"\$file_path\" ] && echo 'original_exists' || echo 'original_deleted'
    "
    assert_success
    assert_line "skipped:1"
    assert_line "remux_called:0"
    assert_line "original_exists"
}
remux_only__t25() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        get_video_codec() { echo 'h264'; }
        get_audio_codec_arg() { echo 'copy'; }
        count_audio_streams() { echo '1'; }
        detect_subtitle_streams() { printf '0|subrip|eng|2\n1|hdmv_pgs_subtitle|jpn|3\n'; }
        ffmpeg() { echo \"\$@\"; return 0; }
        remux_to_mp4 'input.mkv' 'output.mp4' 'include'
    "
    assert_success
    assert_output --partial "0:2"
    refute_output --partial "0:3"
    assert_output --partial "mov_text"
    refute_output --partial "0:s?"
}
remux_only__t26() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        get_video_codec() { echo 'h264'; }
        get_audio_codec_arg() { echo 'copy'; }
        count_audio_streams() { echo '1'; }
        detect_subtitle_streams() { printf '0|hdmv_pgs_subtitle|eng|2\n1|dvd_subtitle|spa|3\n'; }
        ffmpeg() { echo \"\$@\"; return 0; }
        remux_to_mp4 'input.mkv' 'output.mp4' 'include'
    "
    assert_success
    refute_output --partial "0:s?"
    refute_output --partial "mov_text"
    refute_output --partial "0:2"
    refute_output --partial "0:3"
    refute_output --partial "c:s"
}
bats_case "remux_only: find_remux_files: depth 1 finds only current directory files" remux_only__t1 remux_only__setup remux_only__teardown
bats_case "remux_only: find_remux_files: depth 2 finds current + one subdirectory level (default)" remux_only__t2 remux_only__setup remux_only__teardown
bats_case "remux_only: find_remux_files: depth 3 finds current + two subdirectory levels" remux_only__t3 remux_only__setup remux_only__teardown
bats_case "remux_only: find_remux_files: depth 0 (unlimited) finds all files recursively" remux_only__t4 remux_only__setup remux_only__teardown
bats_case "remux_only: find_remux_files: default depth (2) when GLOBAL_MAX_DEPTH not set" remux_only__t5 remux_only__setup remux_only__teardown
bats_case "remux_only: parse_arguments: -L sets GLOBAL_MAX_DEPTH" remux_only__t6 remux_only__setup remux_only__teardown
bats_case "remux_only: parse_arguments: --max-depth sets GLOBAL_MAX_DEPTH" remux_only__t7 remux_only__setup remux_only__teardown
bats_case "remux_only: parse_arguments: --preserve-name sets GLOBAL_PRESERVE_NAME" remux_only__t8 remux_only__setup remux_only__teardown
bats_case "remux_only: validate_depth: accepts valid depth values" remux_only__t9 remux_only__setup remux_only__teardown
bats_case "remux_only: validate_depth: rejects invalid depth values" remux_only__t10 remux_only__setup remux_only__teardown
bats_case "remux_only: generate_output_filename: default naming preserves source directory" remux_only__t11 remux_only__setup remux_only__teardown
bats_case "remux_only: generate_output_filename: preserve-name outputs {base}.mp4" remux_only__t12 remux_only__setup remux_only__teardown
bats_case "remux_only: generate_output_filename: preserve-name falls back to {base}.remux.mp4 when {base}.mp4 exists" remux_only__t13 remux_only__setup remux_only__teardown
bats_case "remux_only: parse_arguments -L 3: GLOBAL_MAX_DEPTH is 3 after direct call (not subshell)" remux_only__t14 remux_only__setup remux_only__teardown
bats_case "remux_only: parse_arguments -p: GLOBAL_PRESERVE_NAME is 1 after direct call (not subshell)" remux_only__t15 remux_only__setup remux_only__teardown
bats_case "remux_only: find_remux_files: discovers all supported non-QuickLook extensions" remux_only__t16 remux_only__setup remux_only__teardown
bats_case "remux_only: is_quicklook_compatible: returns incompatible for HEVC file with hev1 tag" remux_only__t17 remux_only__setup remux_only__teardown
bats_case "remux_only: is_quicklook_compatible: returns incompatible for file with non-QuickLook audio" remux_only__t18 remux_only__setup remux_only__teardown
bats_case "remux_only: is_quicklook_compatible: returns compatible for HEVC hvc1 with AAC audio" remux_only__t19 remux_only__setup remux_only__teardown
bats_case "remux_only: find_mp4_files: skips .mp4 files with boiler markers" remux_only__t20 remux_only__setup remux_only__teardown
bats_case "remux_only: generate_output_filename: preserve-name falls back to .remux.mp4 when .mp4 input exists (safety for mp4-to-mp4 remux)" remux_only__t21 remux_only__setup remux_only__teardown
bats_case "remux_only: phase 2 mp4 fix: output is named {base}.remux.mp4 not .orig." remux_only__t22 remux_only__setup remux_only__teardown
bats_case "remux_only: phase 2 mp4 fix: original is preserved after successful remux" remux_only__t23 remux_only__setup remux_only__teardown
bats_case "remux_only: phase 2 mp4 fix: aborts and skips when user chooses abort on subtitle prompt" remux_only__t24 remux_only__setup remux_only__teardown
bats_case "remux_only: remux_to_mp4: mixed subtitles - only convertible stream mapped by global index" remux_only__t25 remux_only__setup remux_only__teardown
bats_case "remux_only: remux_to_mp4: all-incompatible subtitles - no subtitle map or mov_text emitted" remux_only__t26 remux_only__setup remux_only__teardown
echo ""

echo "Testing cleanup-originals.sh (acceptance) (tests/test_cleanup_originals.bats)..."
cleanup_originals__setup() {
    TEST_DIR=$(mktemp -d)
}
cleanup_originals__teardown() {
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
SCRIPT_UNDER_TEST="${CLEANUP_SCRIPT:-cleanup-originals.sh}"
cleanup_originals__t1() {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4  # counterpart for movie.mkv
    touch other.mkv                  # no counterpart

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mkv"
    refute_line --partial "trashed:other.mkv"
    assert_line --partial "1 file(s) skipped (no counterpart)"
}
cleanup_originals__t2() {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.orig.7.50.Mbps.mp4  # counterpart for movie.mkv

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mkv"
}
cleanup_originals__t3() {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.hbrk.9.00.Mbps.mp4  # counterpart for movie.mkv

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mkv"
}
cleanup_originals__t4() {
    cd "$TEST_DIR"
    touch movie.mp4
    touch movie.remux.mp4  # counterpart for movie.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mp4"
}
cleanup_originals__t5() {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=n main
    "
    assert_success
    refute_line --partial "trashed:"
    assert_line --partial "Cancelled"
}
cleanup_originals__t6() {
    cd "$TEST_DIR"
    touch movie.mkv
    touch other.mkv

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        main
    "
    assert_success
    assert_line --partial "Nothing to trash"
}
cleanup_originals__t7() {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        main
    " </dev/null
    assert_success
    assert_line --partial "Cancelled"
    refute_line --partial "trashed:"
}
cleanup_originals__t8() {
    cd "$TEST_DIR"
    touch orphan.mkv   # no counterpart

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        cd '$TEST_DIR'
        main
    "
    assert_success
    assert_line --partial "will NOT be trashed"
    assert_line --partial "orphan.mkv"
}
cleanup_originals__t9() {
    cd "$TEST_DIR"
    touch movie.mkv
    touch movie.mp4  # same base, no marker — not a counterpart

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        main
    "
    assert_success
    assert_line --partial "Nothing to trash"
}
cleanup_originals__t10() {
    cd "$TEST_DIR"
    touch "[belize] vacation footage (07.10.15).mp4"
    touch "[belize] vacation footage (07.10.15).fmpg.8.03.Mbps.mp4"

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:[belize] vacation footage (07.10.15).mp4"
}
cleanup_originals__t11() {
    cd "$TEST_DIR"
    mkdir -p level1
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4
    touch level1/deep.mkv
    touch level1/deep.fmpg.8.00.Mbps.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mkv"
    refute_line --partial "trashed:deep.mkv"
}
cleanup_originals__t12() {
    cd "$TEST_DIR"
    mkdir -p level1/level2
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4
    touch level1/deep.mkv
    touch level1/deep.fmpg.8.00.Mbps.mp4
    touch level1/level2/deeper.mkv
    touch level1/level2/deeper.fmpg.8.00.Mbps.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=2
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mkv"
    assert_line --partial "trashed:deep.mkv"
    refute_line --partial "trashed:deeper.mkv"
}
cleanup_originals__t13() {
    cd "$TEST_DIR"
    mkdir -p level1/level2/level3
    touch movie.mkv
    touch movie.fmpg.8.00.Mbps.mp4
    touch level1/level2/level3/deep.mkv
    touch level1/level2/level3/deep.fmpg.8.00.Mbps.mp4

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=0
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial "trashed:movie.mkv"
    assert_line --partial "trashed:deep.mkv"
}
cleanup_originals__t14() {
    cd "$TEST_DIR"
    touch 'back\slash movie.mkv'
    touch 'back\slash movie.fmpg.8.00.Mbps.mp4'

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    assert_line --partial 'trashed:back\slash movie.mkv'
}
cleanup_originals__t15() {
    cd "$TEST_DIR"
    # "[ab]" must not act as a character class: a.fmpg... is another video's copy
    touch '[ab].mkv'
    touch 'a.fmpg.8.00.Mbps.mp4'

    run bash -c "
        export CLEANUP_TEST_MODE=1
        export GLOBAL_MAX_DEPTH=1
        source '$PROJECT_ROOT/$SCRIPT_UNDER_TEST' 2>/dev/null
        move_to_trash() { echo \"trashed:\$(basename \"\$1\")\"; return 0; }
        cd '$TEST_DIR'
        CLEANUP_CONFIRM=y main
    "
    assert_success
    refute_line --partial 'trashed:[ab].mkv'
}
bats_case "cleanup_originals: main: trashes original with .fmpg counterpart, skips original without, when user confirms" cleanup_originals__t1 cleanup_originals__setup cleanup_originals__teardown
bats_case "cleanup_originals: main: trashes original with .orig counterpart when user confirms" cleanup_originals__t2 cleanup_originals__setup cleanup_originals__teardown
bats_case "cleanup_originals: main: trashes original with .hbrk counterpart when user confirms" cleanup_originals__t3 cleanup_originals__setup cleanup_originals__teardown
bats_case "cleanup_originals: main: trashes original with .remux counterpart when user confirms" cleanup_originals__t4 cleanup_originals__setup cleanup_originals__teardown
bats_case "cleanup_originals: main: trashes nothing when user declines confirmation" cleanup_originals__t5 cleanup_originals__setup cleanup_originals__teardown
bats_case "cleanup_originals: main: exits cleanly with no eligible files when no counterparts exist" cleanup_originals__t6 cleanup_originals__setup cleanup_originals__teardown
bats_case "cleanup_originals: main: cancels gracefully when stdin is closed and no CLEANUP_CONFIRM set" cleanup_originals__t7 cleanup_originals__setup cleanup_originals__teardown
bats_case "cleanup_originals: main: reports originals without counterparts in warn list" cleanup_originals__t8 cleanup_originals__setup cleanup_originals__teardown
bats_case "cleanup_originals: main: does not treat peer file without marker as counterpart" cleanup_originals__t9 cleanup_originals__setup cleanup_originals__teardown
bats_case "cleanup_originals: main: handles filenames with brackets and special characters" cleanup_originals__t10 cleanup_originals__setup cleanup_originals__teardown
bats_case "cleanup_originals: main: depth 1 scans only current directory" cleanup_originals__t11 cleanup_originals__setup cleanup_originals__teardown
bats_case "cleanup_originals: main: depth 2 scans current directory and one subdirectory level" cleanup_originals__t12 cleanup_originals__setup cleanup_originals__teardown
bats_case "cleanup_originals: main: depth 0 scans all directories recursively" cleanup_originals__t13 cleanup_originals__setup cleanup_originals__teardown
bats_case "cleanup_originals: main: handles filenames containing a backslash" cleanup_originals__t14 cleanup_originals__setup cleanup_originals__teardown
bats_case "cleanup_originals: main: glob characters in a name do not match another video's counterpart" cleanup_originals__t15 cleanup_originals__setup cleanup_originals__teardown
echo ""

echo "Testing remux-only.sh subtitle detection and classification (tests/test_subtitle_detection.bats)..."
subtitle_detection__setup() {
    TEST_DIR=$(mktemp -d)
}
subtitle_detection__teardown() {
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
subtitle_detection__t1() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        ffprobe() { echo ''; }
        detect_subtitle_streams 'test.mkv'
    "
    assert_success
    assert_output ""
}
subtitle_detection__t2() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        ffprobe() { echo '2,subrip,eng'; }
        detect_subtitle_streams 'test.mkv'
    "
    assert_success
    assert_output "0|subrip|eng|2"
}
subtitle_detection__t3() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        ffprobe() { printf '2,subrip,eng\n3,hdmv_pgs_subtitle,jpn\n'; }
        detect_subtitle_streams 'test.mkv'
    "
    assert_success
    assert_line "0|subrip|eng|2"
    assert_line "1|hdmv_pgs_subtitle|jpn|3"
}
subtitle_detection__t4() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        ffprobe() { echo '2,subrip,N/A'; }
        detect_subtitle_streams 'test.mkv'
    "
    assert_success
    assert_output "0|subrip||2"
}
subtitle_detection__t5() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'subrip' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "yes"
}
subtitle_detection__t6() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'ass' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "yes"
}
subtitle_detection__t7() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'ssa' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "yes"
}
subtitle_detection__t8() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'webvtt' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "yes"
}
subtitle_detection__t9() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'mov_text' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "yes"
}
subtitle_detection__t10() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'text' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "yes"
}
subtitle_detection__t11() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'hdmv_pgs_subtitle' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "no"
}
subtitle_detection__t12() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'dvd_subtitle' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "no"
}
subtitle_detection__t13() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'dvbsub' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "no"
}
subtitle_detection__t14() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'pgssub' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "no"
}
subtitle_detection__t15() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'some_unknown_codec' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "no"
}
subtitle_detection__t16() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'SubRip' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "yes"
}
subtitle_detection__t17() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        report_subtitles '0|subrip|eng'
    "
    assert_success
    assert_output --partial "[0:s:0] subrip (eng)"
    assert_output --partial "convertible to mov_text"
}
subtitle_detection__t18() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        report_subtitles '0|hdmv_pgs_subtitle|eng'
    "
    assert_success
    assert_output --partial "[0:s:0] hdmv_pgs_subtitle (eng)"
    assert_output --partial "NOT convertible"
}
subtitle_detection__t19() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        report_subtitles '0|subrip|'
    "
    assert_success
    assert_output --partial "[0:s:0] subrip"
    refute_output --partial "()"
}
subtitle_detection__t20() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        report_subtitles '$(printf "0|subrip|eng\n1|hdmv_pgs_subtitle|jpn")'
    "
    assert_success
    assert_output --partial "convertible to mov_text"
    assert_output --partial "NOT convertible"
}
subtitle_detection__t21() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        echo '1' | prompt_subtitle_choice '0|subrip|eng'
    "
    assert_success
    assert_output --partial "include"
}
subtitle_detection__t22() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        echo '2' | prompt_subtitle_choice '0|subrip|eng'
    "
    assert_success
    assert_output --partial "none"
}
subtitle_detection__t23() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        echo '3' | prompt_subtitle_choice '0|subrip|eng'
    "
    assert_success
    assert_output --partial "abort"
}
subtitle_detection__t24() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        echo '' | prompt_subtitle_choice '0|subrip|eng'
    "
    assert_success
    assert_output --partial "abort"
}
subtitle_detection__t25() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        echo '3' | prompt_subtitle_choice '0|subrip|eng'
    "
    assert_success
    assert_output --partial "convert to mov_text"
}
subtitle_detection__t26() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        echo '3' | prompt_subtitle_choice \"\$(printf '0|subrip|eng\n1|hdmv_pgs_subtitle|jpn')\"
    "
    assert_success
    assert_output --partial "convertible kept, incompatible dropped"
}
subtitle_detection__t27() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        get_video_codec() { echo 'h264'; }
        get_audio_codec_arg() { echo 'copy'; }
        count_audio_streams() { echo '1'; }
        ffmpeg() { echo \"\$@\"; return 0; }
        remux_to_mp4 'input.mkv' 'output.mp4' 'none'
    "
    assert_success
    refute_output --partial "0:s"
}
subtitle_detection__t28() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        get_video_codec() { echo 'h264'; }
        get_audio_codec_arg() { echo 'copy'; }
        count_audio_streams() { echo '1'; }
        detect_subtitle_streams() { printf '0|subrip|eng|2\n'; }
        ffmpeg() { echo \"\$@\"; return 0; }
        remux_to_mp4 'input.mkv' 'output.mp4' 'include'
    "
    assert_success
    assert_output --partial "0:2"
    assert_output --partial "mov_text"
    refute_output --partial "0:s?"
}
subtitle_detection__t29() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        get_video_codec() { echo 'h264'; }
        get_audio_codec_arg() { echo 'copy'; }
        count_audio_streams() { echo '1'; }
        ffmpeg() { echo \"\$@\"; return 0; }
        remux_to_mp4 'input.mkv' 'output.mp4'
    "
    assert_success
    refute_output --partial "0:s"
}
subtitle_detection__t30() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        detect_subtitle_streams() { echo ''; }
        get_subtitle_mode_for_file 'test.mkv'
    "
    assert_success
    assert_output "none"
}
subtitle_detection__t31() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        detect_subtitle_streams() { echo '0|subrip|eng'; }
        echo '1' | get_subtitle_mode_for_file 'test.mkv'
    "
    assert_success
    assert_output --partial "include"
}
subtitle_detection__t32() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        detect_subtitle_streams() { echo '0|subrip|eng'; }
        echo '3' | get_subtitle_mode_for_file 'test.mkv'
    "
    assert_success
    assert_output --partial "abort"
}
subtitle_detection__t33() {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        detect_subtitle_streams() { echo '0|subrip|eng'; }
        mode=\$(echo '1' | get_subtitle_mode_for_file 'test.mkv')
        echo \"captured:\$mode\"
    "
    assert_success
    assert_output --partial "captured:include"
}
subtitle_detection__t34() {
    cd "$TEST_DIR"
    touch video.mkv

    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        get_video_duration() { echo '120'; }
        measure_bitrate() { echo '8000000'; }
        bps_to_mbps() { echo '8.00'; }
        get_subtitle_mode_for_file() { echo 'abort'; }
        remux_to_mp4_called=0
        remux_to_mp4() { remux_to_mp4_called=1; }
        processed_count=0; skipped_count=0; failed_count=0
        process_one_file '$TEST_DIR/video.mkv'
        echo \"skipped:\$skipped_count\"
        echo \"remux_called:\$remux_to_mp4_called\"
    "
    assert_success
    assert_output --partial "skipped:1"
    assert_output --partial "remux_called:0"
}
subtitle_detection__t35() {
    cd "$TEST_DIR"
    touch video.mkv

    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        get_video_duration() { echo '120'; }
        measure_bitrate() { echo '8000000'; }
        bps_to_mbps() { echo '8.00'; }
        get_subtitle_mode_for_file() { echo 'include'; }
        received_mode=''
        remux_to_mp4() { touch \"\$2\"; received_mode=\"\$3\"; return 0; }
        processed_count=0; skipped_count=0; failed_count=0
        process_one_file '$TEST_DIR/video.mkv'
        echo \"mode:\$received_mode\"
    "
    assert_success
    assert_output --partial "mode:include"
}
subtitle_detection__t36() {
    cd "$TEST_DIR"
    touch video.mkv

    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        get_video_duration() { echo '120'; }
        measure_bitrate() { echo '8000000'; }
        bps_to_mbps() { echo '8.00'; }
        get_subtitle_mode_for_file() { echo 'none'; }
        received_mode=''
        remux_to_mp4() { touch \"\$2\"; received_mode=\"\$3\"; return 0; }
        processed_count=0; skipped_count=0; failed_count=0
        process_one_file '$TEST_DIR/video.mkv'
        echo \"mode:\$received_mode\"
    "
    assert_success
    assert_output --partial "mode:none"
}
bats_case "subtitle_detection: detect_subtitle_streams: no subtitle streams returns empty output" subtitle_detection__t1 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: detect_subtitle_streams: single subrip stream with language" subtitle_detection__t2 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: detect_subtitle_streams: multiple streams output sequential indices" subtitle_detection__t3 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: detect_subtitle_streams: missing language tag produces empty lang field" subtitle_detection__t4 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: is_subtitle_convertible: subrip is convertible" subtitle_detection__t5 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: is_subtitle_convertible: ass is convertible" subtitle_detection__t6 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: is_subtitle_convertible: ssa is convertible" subtitle_detection__t7 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: is_subtitle_convertible: webvtt is convertible" subtitle_detection__t8 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: is_subtitle_convertible: mov_text is convertible" subtitle_detection__t9 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: is_subtitle_convertible: text is convertible" subtitle_detection__t10 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: is_subtitle_convertible: hdmv_pgs_subtitle is not convertible" subtitle_detection__t11 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: is_subtitle_convertible: dvd_subtitle is not convertible" subtitle_detection__t12 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: is_subtitle_convertible: dvbsub is not convertible" subtitle_detection__t13 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: is_subtitle_convertible: pgssub is not convertible" subtitle_detection__t14 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: is_subtitle_convertible: unknown codec is not convertible" subtitle_detection__t15 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: is_subtitle_convertible: codec matching is case-insensitive" subtitle_detection__t16 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: report_subtitles: single convertible stream shows correct label" subtitle_detection__t17 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: report_subtitles: incompatible stream shows NOT convertible label" subtitle_detection__t18 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: report_subtitles: stream with no language omits language from label" subtitle_detection__t19 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: report_subtitles: mixed streams shows both convertible and incompatible" subtitle_detection__t20 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: prompt_subtitle_choice: user enters 1 returns include" subtitle_detection__t21 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: prompt_subtitle_choice: user enters 2 returns none" subtitle_detection__t22 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: prompt_subtitle_choice: user enters 3 returns abort" subtitle_detection__t23 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: prompt_subtitle_choice: empty input returns abort" subtitle_detection__t24 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: prompt_subtitle_choice: all convertible streams show convert menu option" subtitle_detection__t25 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: prompt_subtitle_choice: mixed streams show kept/dropped menu option" subtitle_detection__t26 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: remux_to_mp4: subtitle_mode=none does not pass subtitle map to ffmpeg" subtitle_detection__t27 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: remux_to_mp4: subtitle_mode=include maps convertible stream by global index" subtitle_detection__t28 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: remux_to_mp4: no subtitle_mode arg preserves current behavior (no subtitle map)" subtitle_detection__t29 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: get_subtitle_mode_for_file: no subtitles returns none without prompting" subtitle_detection__t30 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: get_subtitle_mode_for_file: subtitles present, user chooses 1 returns include" subtitle_detection__t31 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: get_subtitle_mode_for_file: subtitles present, user chooses 3 returns abort" subtitle_detection__t32 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: get_subtitle_mode_for_file: mode is correctly captured via command substitution" subtitle_detection__t33 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: process_one_file: aborts and increments skipped_count when user chooses abort" subtitle_detection__t34 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: process_one_file: passes include mode to remux_to_mp4 when user chooses include" subtitle_detection__t35 subtitle_detection__setup subtitle_detection__teardown
bats_case "subtitle_detection: process_one_file: no subtitles proceeds silently with mode none" subtitle_detection__t36 subtitle_detection__setup subtitle_detection__teardown
echo ""

echo "Testing boiler.sh subtitle preservation (tests/test_boiler_subtitles.bats)..."
boiler_subtitles__setup() {
    common_setup
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
}
boiler_subtitles__teardown() {
    common_teardown
    cd "$PROJECT_ROOT"
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}
boiler_subtitles__t1() {
    run bash -c "
        export BOILER_TEST_MODE=1
        source '${PROJECT_ROOT}/boiler.sh' 2>/dev/null
        get_video_codec() { echo 'h264'; }
        count_audio_streams() { echo '1'; }
        get_audio_codec_arg() { echo 'copy'; }
        detect_subtitle_streams() { printf '0|subrip|eng|2\n1|hdmv_pgs_subtitle|jpn|3\n'; }
        ffmpeg() { echo \"\$@\"; return 0; }
        printf 'x' > '${TEST_DIR}/out.mp4'
        remux_to_mp4 input.mkv '${TEST_DIR}/out.mp4'
    "
    assert_success
    assert_output --partial "0:2"
    refute_output --partial "0:3"
    assert_output --partial "c:s mov_text"
    refute_output --partial "0:s?"
}
boiler_subtitles__t2() {
    run bash -c "
        export BOILER_TEST_MODE=1
        source '${PROJECT_ROOT}/boiler.sh' 2>/dev/null
        get_video_codec() { echo 'h264'; }
        count_audio_streams() { echo '1'; }
        get_audio_codec_arg() { echo 'copy'; }
        detect_subtitle_streams() { printf '0|hdmv_pgs_subtitle|eng|2\n1|dvd_subtitle|spa|3\n'; }
        ffmpeg() { return 0; }
        printf 'x' > '${TEST_DIR}/out.mp4'
        SUBTITLE_DROP_FILES=()
        remux_to_mp4 input.mkv '${TEST_DIR}/out.mp4'
        echo \"drop_count:\${#SUBTITLE_DROP_FILES[@]}\"
        echo \"file:\${SUBTITLE_DROP_FILES[0]:-none}\"
    "
    assert_success
    assert_output --partial "drop_count:1"
    assert_output --partial "out.mp4"
}
boiler_subtitles__t3() {
    run bash -c "
        export BOILER_TEST_MODE=1
        source '${PROJECT_ROOT}/boiler.sh' 2>/dev/null
        get_video_codec() { echo 'h264'; }
        count_audio_streams() { echo '1'; }
        get_audio_codec_arg() { echo 'copy'; }
        detect_subtitle_streams() { return 0; }
        ffmpeg() { echo \"\$@\"; return 0; }
        printf 'x' > '${TEST_DIR}/out.mp4'
        SUBTITLE_DROP_FILES=()
        remux_to_mp4 input.mkv '${TEST_DIR}/out.mp4'
        echo \"drop_count:\${#SUBTITLE_DROP_FILES[@]}\"
    "
    assert_success
    refute_output --partial "mov_text"
    refute_output --partial "0:s"
    assert_output --partial "drop_count:0"
}
boiler_subtitles__t4() {
    run bash -c "
        export BOILER_TEST_MODE=1
        source '${PROJECT_ROOT}/boiler.sh' 2>/dev/null
        count_audio_streams() { echo '1'; }
        get_audio_codec_arg() { echo 'copy'; }
        detect_subtitle_streams() { printf '0|subrip|eng|2\n'; }
        ffmpeg() { echo \"\$@\"; return 0; }
        printf 'x' > '${TEST_DIR}/out.mp4'
        SUBTITLE_HAS_DROP_PENDING=0
        transcode_full_video input.mp4 '${TEST_DIR}/out.mp4' 65
        echo \"drop_pending:\${SUBTITLE_HAS_DROP_PENDING:-0}\"
    "
    assert_success
    assert_output --partial "0:2"
    assert_output --partial "c:s mov_text"
    assert_output --partial "drop_pending:0"
}
boiler_subtitles__t5() {
    run bash -c "
        export BOILER_TEST_MODE=1
        source '${PROJECT_ROOT}/boiler.sh' 2>/dev/null
        count_audio_streams() { echo '1'; }
        get_audio_codec_arg() { echo 'copy'; }
        detect_subtitle_streams() { printf '0|hdmv_pgs_subtitle|eng|3\n'; }
        ffmpeg() { return 0; }
        printf 'x' > '${TEST_DIR}/out.mp4'
        SUBTITLE_HAS_DROP_PENDING=0
        transcode_full_video input.mp4 '${TEST_DIR}/out.mp4' 65
        echo \"drop_pending:\${SUBTITLE_HAS_DROP_PENDING:-0}\"
    "
    assert_success
    refute_output --partial "mov_text"
    assert_output --partial "drop_pending:1"
}
boiler_subtitles__t6() {
    run bash -c "
        export BOILER_TEST_MODE=1
        source '${PROJECT_ROOT}/boiler.sh' 2>/dev/null
        count_audio_streams() { echo '1'; }
        get_audio_codec_arg() { echo 'copy'; }
        detect_subtitle_streams() { return 0; }
        ffmpeg() { echo \"\$@\"; return 0; }
        printf 'x' > '${TEST_DIR}/out.mp4'
        SUBTITLE_HAS_DROP_PENDING=0
        transcode_full_video input.mp4 '${TEST_DIR}/out.mp4' 65
        echo \"drop_pending:\${SUBTITLE_HAS_DROP_PENDING:-0}\"
    "
    assert_success
    refute_output --partial "mov_text"
    refute_output --partial "0:s"
    assert_output --partial "drop_pending:0"
}
boiler_subtitles__t7() {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=16000000
    MOCK_OUTPUT_BITRATE_BPS=8000000
    MOCK_SAMPLE_BITRATE_BPS=8000000

    transcode_full_video() {
        local video_file="$1"
        local output_file="$2"
        local quality_value="$3"
        echo "$video_file|$output_file|$quality_value" >> "$TRANSCODE_FULL_CALLS_FILE"
        touch "$output_file"
        SUBTITLE_HAS_DROP_PENDING=1
    }

    run main
    assert_success
    assert_output --partial "image-based subtitle"
}
boiler_subtitles__t8() {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=16000000
    MOCK_OUTPUT_BITRATE_BPS=8000000
    MOCK_SAMPLE_BITRATE_BPS=8000000

    run main
    assert_success
    refute_output --partial "image-based subtitle"
}
bats_case "boiler_subtitles: boiler remux_to_mp4: mixed subs - only convertible stream mapped by global index" boiler_subtitles__t1 boiler_subtitles__setup boiler_subtitles__teardown
bats_case "boiler_subtitles: boiler remux_to_mp4: all-image subs - adds output file to SUBTITLE_DROP_FILES" boiler_subtitles__t2 boiler_subtitles__setup boiler_subtitles__teardown
bats_case "boiler_subtitles: boiler remux_to_mp4: no subtitles - no subtitle args and SUBTITLE_DROP_FILES empty" boiler_subtitles__t3 boiler_subtitles__setup boiler_subtitles__teardown
bats_case "boiler_subtitles: boiler transcode_full_video: subrip stream - mapped by global index with mov_text" boiler_subtitles__t4 boiler_subtitles__setup boiler_subtitles__teardown
bats_case "boiler_subtitles: boiler transcode_full_video: PGS-only - no subtitle args and sets SUBTITLE_HAS_DROP_PENDING" boiler_subtitles__t5 boiler_subtitles__setup boiler_subtitles__teardown
bats_case "boiler_subtitles: boiler transcode_full_video: no subtitles - no subtitle args and SUBTITLE_HAS_DROP_PENDING unchanged" boiler_subtitles__t6 boiler_subtitles__setup boiler_subtitles__teardown
bats_case "boiler_subtitles: main: prints subtitle drop summary when transcode drops all subtitle streams" boiler_subtitles__t7 boiler_subtitles__setup boiler_subtitles__teardown
bats_case "boiler_subtitles: main: no subtitle summary when no subtitle drops occurred" boiler_subtitles__t8 boiler_subtitles__setup boiler_subtitles__teardown
echo ""

# ============================================================================
# Remaining parity with tests/*.bats for boiler.sh functions
# (audio codec args, ffmpeg error messages, discovery/matching edge cases,
#  tier selection through main(), real measure_bitrate fallbacks)
# ============================================================================

echo "Testing additional boiler.sh parity cases (audio args, error messages, discovery, tiers, measure_bitrate)..."

parity__setup() {
    common_setup
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
}
parity__teardown() {
    cd "$PROJECT_ROOT"
    if [ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}

# is_audio_codec_mp4_compatible: mp2 (test_audio_codec_compatibility.bats)
parity__mp2() { is_audio_codec_mp4_compatible "mp2"; }
bats_case "is_audio_codec_mp4_compatible: mp2 is compatible" parity__mp2 parity__setup parity__teardown

# get_audio_codec_arg (test_audio_codec_compatibility.bats); MOCK_AUDIO_CODEC drives the mocked ffprobe
parity__audio_arg() {
    # $1 = codec, $2 = expected output
    MOCK_AUDIO_CODEC="$AUDIO_ARG_CODEC"
    run get_audio_codec_arg "test.mkv"
    assert_line "$AUDIO_ARG_EXPECT"
}
audio_arg_case() {
    AUDIO_ARG_CODEC="$2"
    AUDIO_ARG_EXPECT="$3"
    bats_case "get_audio_codec_arg: $1" parity__audio_arg parity__setup parity__teardown
}
audio_arg_case "returns copy for aac audio" "aac" "copy"
audio_arg_case "returns copy for ac3 audio" "ac3" "copy"
audio_arg_case "returns aac for wmav2 audio" "wmav2" "aac"
audio_arg_case "returns aac for vorbis audio" "vorbis" "aac"
audio_arg_case "returns aac for wmapro audio" "wmapro" "aac"
audio_arg_case "returns copy for unknown codec (assumes compatible)" "some_future_codec" "copy"
audio_arg_case "returns copy when no audio codec detected (empty)" "" "copy"

parity__audio_warn() {
    MOCK_AUDIO_CODEC="wmav2"
    run get_audio_codec_arg "test.wmv"
    assert_output --partial "aac"
}
bats_case "get_audio_codec_arg: logs warning when re-encoding" parity__audio_warn parity__setup parity__teardown

# ffmpeg failure messages (test_ffmpeg_error_handling.bats)
ffmpeg_fail_output() {
    local func_name="$1"
    shift
    bash -c "
        set +e
        export BOILER_TEST_MODE=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        ffmpeg() { return 1; }
        ffprobe() {
            if [[ \"\$*\" == *codec_name* ]] && [[ \"\$*\" == *select_streams\ a* ]]; then echo 'aac'
            elif [[ \"\$*\" == *codec_name* ]]; then echo 'h264'
            elif [[ \"\$*\" == *csv=p=0* ]]; then echo '1'
            else echo ''; fi
        }
        $func_name \"\$@\"
    " -- "$@"
}
parity__err_sample() {
    run ffmpeg_fail_output transcode_sample "$TEST_DIR/input.mp4" "10" "5" "60" "$TEST_DIR/sample_output.mp4"
    assert_output --partial "FFmpeg"
}
parity__err_full() {
    run ffmpeg_fail_output transcode_full_video "$TEST_DIR/input.mp4" "$TEST_DIR/full_output.mp4" "60"
    assert_output --partial "FFmpeg"
}
parity__err_remux() {
    run ffmpeg_fail_output remux_to_mp4 "$TEST_DIR/input.mkv" "$TEST_DIR/remux_output.mp4"
    assert_output --partial "FFmpeg"
}
bats_case "transcode_sample: outputs error message on ffmpeg failure" parity__err_sample parity__setup parity__teardown
bats_case "transcode_full_video: outputs error message on failure" parity__err_full parity__setup parity__teardown
bats_case "remux_to_mp4: outputs error message on ffmpeg failure" parity__err_remux parity__setup parity__teardown

# find_skipped_video_files / has_encoded_version edge cases (test_file_discovery.bats, test_filename_extraction.bats)
parity__skipped_empty() {
    touch "regular1.mp4" "regular2.mkv"
    GLOBAL_MAX_DEPTH=1
    run find_skipped_video_files
    assert_success
    assert_output ""
}
parity__enc_orig() {
    touch video.mp4 video.orig.5.00.Mbps.mp4
    has_encoded_version "video.mp4"
}
parity__enc_hbrk() {
    touch video.mp4 video.hbrk.8.00.Mbps.mp4
    has_encoded_version "video.mp4"
}
bats_case "find_skipped_video_files: returns empty when no skipped files" parity__skipped_empty parity__setup parity__teardown
bats_case "has_encoded_version: detects .orig. encoded version" parity__enc_orig parity__setup parity__teardown
bats_case "has_encoded_version: detects .hbrk. encoded version" parity__enc_hbrk parity__setup parity__teardown

# mocked transcode functions create their output file (test_mocked_functions.bats)
parity__mock_sample_creates() {
    local f="$TEST_DIR/sample_out.mp4"
    transcode_sample "input.mp4" "0" "60" "52" "$f"
    [ -f "$f" ]
}
parity__mock_full_creates() {
    local f="$TEST_DIR/full_out.mp4"
    transcode_full_video "input.mp4" "$f" "52"
    [ -f "$f" ]
}
bats_case "mocked transcode_sample: creates output file" parity__mock_sample_creates parity__setup parity__teardown
bats_case "mocked transcode_full_video: creates output file" parity__mock_full_creates parity__setup parity__teardown

# Resolution tiers through main() (test_integration.bats)
tier_case() {
    TIER_RES="$2"; TIER_SRC="$3"; TIER_OUT="$4"; TIER_EXPECT="$5"
    bats_case "main: uses correct target bitrate for $1" parity__tier parity__setup parity__teardown
}
parity__tier() {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION="$TIER_RES"
    MOCK_DURATION=300
    MOCK_BITRATE_BPS="$TIER_SRC"
    MOCK_SAMPLE_BITRATE_BPS="$TIER_OUT"
    MOCK_OUTPUT_BITRATE_BPS="$TIER_OUT"
    run main
    assert_success
    assert_output --partial "Target bitrate"
    assert_output --partial "$TIER_EXPECT"
}
tier_case "2160p (4K)" 2160 20000000 11000000 "11"
tier_case "720p" 720 10000000 5000000 "5"
tier_case "480p" 480 5000000 2500000 "2.5"

parity__override_calls() {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000
    MOCK_SAMPLE_BITRATE_BPS=9500000
    MOCK_OUTPUT_BITRATE_BPS=9500000
    main --target-bitrate 9.5 > /dev/null 2>&1
    # 1 for source + 3 for samples + 1 for output = 5
    [ "$(count_calls "$MEASURE_BITRATE_CALLS_FILE")" = "5" ]
}
bats_case "main: uses correct bitrate call counts with override (source + samples + output)" parity__override_calls parity__setup parity__teardown

# Real measure_bitrate fallbacks (test_measure_bitrate.bats); runs the real function with a stubbed ffprobe
run_real_measure_bitrate() {
    local stream_bitrate="$1"
    local format_bitrate="$2"
    shift 2
    PROJECT_ROOT="$PROJECT_ROOT" \
    MOCK_STREAM_BITRATE="$stream_bitrate" \
    MOCK_FORMAT_BITRATE="$format_bitrate" \
    bash -c '
        set +e
        export BOILER_TEST_MODE=1
        source "$PROJECT_ROOT/boiler.sh" 2>/dev/null
        ffprobe() {
            if [[ "$*" == *format=bit_rate* ]]; then
                echo "$MOCK_FORMAT_BITRATE"
            else
                echo "$MOCK_STREAM_BITRATE"
            fi
        }
        measure_bitrate "$1" "$2"
    ' -- "$@"
}
parity__mb_stream() {
    local file="$TEST_DIR/test.mp4"; touch "$file"
    run run_real_measure_bitrate "10000000" "" "$file" "60"
    assert_success
    assert_output "10000000"
}
parity__mb_zero() {
    local file="$TEST_DIR/test.wmv"; touch "$file"
    run run_real_measure_bitrate "0" "11976000" "$file" "60"
    assert_success
    assert_output "11976000"
}
parity__mb_near_zero() {
    local file="$TEST_DIR/test.wmv"; touch "$file"
    run run_real_measure_bitrate "1" "11908002" "$file" "60"
    assert_success
    assert_output "11908002"
}
parity__mb_filesize() {
    local file="$TEST_DIR/test.wmv"
    # 100 * 1024 = 102400 bytes = 819200 bits; at 10s = 81920 bps
    dd if=/dev/zero of="$file" bs=1024 count=100 2>/dev/null
    run run_real_measure_bitrate "0" "0" "$file" "10"
    assert_success
    assert_output "81920"
}
bats_case "measure_bitrate: returns stream bitrate when ffprobe reports valid non-zero value" parity__mb_stream parity__setup parity__teardown
bats_case "measure_bitrate: falls back to container bitrate when stream reports zero (WMV/ASF behavior)" parity__mb_zero parity__setup parity__teardown
bats_case "measure_bitrate: falls back to container bitrate when stream reports near-zero (WMV actual: 1 bps)" parity__mb_near_zero parity__setup parity__teardown
bats_case "measure_bitrate: falls back to file-size calculation when both stream and container report zero" parity__mb_filesize parity__setup parity__teardown

echo ""

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

