#!/usr/bin/env bash
# Mock functions for FFmpeg/ffprobe calls
# These allow tests to run without requiring actual video files or FFmpeg installation
#
# Mock behavior can be controlled via environment variables:
#   - MOCK_RESOLUTION: Override resolution returned by get_video_resolution()
#   - MOCK_DURATION: Override duration returned by get_video_duration()
#   - MOCK_BITRATE_BPS: Override bitrate returned by measure_bitrate() for source files
#   - MOCK_SAMPLE_BITRATE_BPS: Override bitrate for sample files
#   - MOCK_OUTPUT_BITRATE_BPS: Override bitrate for output files (first pass)
#   - MOCK_SECOND_PASS_BITRATE_BPS: Override bitrate for second pass output
#   - MOCK_THIRD_PASS_BITRATE_BPS: Override bitrate for third pass output
#   - MOCK_VIDEO_CODEC: Override codec returned by ffprobe for codec detection
#   - MOCK_VIDEO_FILE: Override the video file path returned by find_video_file/find_all_video_files

# Directory for call tracking files (works across subshells)
MOCK_CALL_TRACK_DIR="${BATS_TEST_TMPDIR:-/tmp/bats_mock_$$}"

# Call tracking file paths
TRANSCODE_SAMPLE_CALLS_FILE="$MOCK_CALL_TRACK_DIR/transcode_sample_calls"
TRANSCODE_FULL_CALLS_FILE="$MOCK_CALL_TRACK_DIR/transcode_full_calls"
MEASURE_BITRATE_CALLS_FILE="$MOCK_CALL_TRACK_DIR/measure_bitrate_calls"
FIND_VIDEO_FILE_CALLS_FILE="$MOCK_CALL_TRACK_DIR/find_video_file_calls"
FIND_ALL_VIDEO_FILES_CALLS_FILE="$MOCK_CALL_TRACK_DIR/find_all_video_files_calls"
REMUX_CALLS_FILE="$MOCK_CALL_TRACK_DIR/remux_calls"

# Reset all mock state (call this before each test)
reset_mocks() {
    mkdir -p "$MOCK_CALL_TRACK_DIR"
    rm -f "$TRANSCODE_SAMPLE_CALLS_FILE" "$TRANSCODE_FULL_CALLS_FILE" \
          "$MEASURE_BITRATE_CALLS_FILE" "$FIND_VIDEO_FILE_CALLS_FILE" \
          "$FIND_ALL_VIDEO_FILES_CALLS_FILE" "$REMUX_CALLS_FILE"
    touch "$TRANSCODE_SAMPLE_CALLS_FILE" "$TRANSCODE_FULL_CALLS_FILE" \
          "$MEASURE_BITRATE_CALLS_FILE" "$FIND_VIDEO_FILE_CALLS_FILE" \
          "$FIND_ALL_VIDEO_FILES_CALLS_FILE" "$REMUX_CALLS_FILE"
}

# Helper function to count calls (counts lines in tracking file)
get_call_count() {
    local calls_file="$1"
    if [ ! -f "$calls_file" ]; then
        echo "0"
    else
        wc -l < "$calls_file" | tr -d ' '
    fi
}

# Helper function to get a specific call by index (1-based)
get_call() {
    local calls_file="$1"
    local index="${2:-1}"
    if [ ! -f "$calls_file" ]; then
        echo ""
    else
        sed -n "${index}p" "$calls_file"
    fi
}

# Helper function to get all calls
get_all_calls() {
    local calls_file="$1"
    if [ ! -f "$calls_file" ]; then
        echo ""
    else
        cat "$calls_file"
    fi
}

# ============================================================================
# Mock Functions - These override the real implementations from boiler.sh
# ============================================================================

# Mock get_video_resolution() - returns mock resolution (default: 1080)
get_video_resolution() {
    local video_file="$1"
    echo "${MOCK_RESOLUTION:-1080}"
}

# Mock get_video_duration() - returns mock duration in seconds (default: 300)
get_video_duration() {
    local video_file="$1"
    echo "${MOCK_DURATION:-300}"
}

# Mock ffprobe for codec detection
# Returns codec from MOCK_VIDEO_CODEC if set, otherwise returns h264
ffprobe() {
    # Check if this is a codec_name query (used by remux_to_mp4)
    if [[ "$*" == *"codec_name"* ]]; then
        echo "${MOCK_VIDEO_CODEC:-h264}"
    else
        # For other ffprobe calls, return empty
        echo ""
    fi
}

# Mock measure_bitrate() - tracks calls and returns mock bitrate
measure_bitrate() {
    local file_path="$1"
    local duration="$2"
    
    # Track the call
    echo "$file_path|$duration" >> "$MEASURE_BITRATE_CALLS_FILE"
    
    # If this is an output file (temp_transcode), use MOCK_OUTPUT_BITRATE_BPS if set
    if [[ "$file_path" == *"temp_transcode"* ]] && [ -n "${MOCK_OUTPUT_BITRATE_BPS:-}" ]; then
        # Count how many times we've measured temp_transcode files
        local temp_transcode_count
        temp_transcode_count=$(grep -c "temp_transcode" "$MEASURE_BITRATE_CALLS_FILE" 2>/dev/null || echo "0")
        
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
    
    # If this is a sample file, use MOCK_SAMPLE_BITRATE_BPS if set
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
    
    # Track the call
    echo "$video_file|$sample_start|$sample_duration|$quality_value|$output_file" >> "$TRANSCODE_SAMPLE_CALLS_FILE"
    
    # Create minimal file so downstream code doesn't fail on file existence checks
    touch "$output_file"
}

# Mock transcode_full_video() - tracks calls instead of transcoding
transcode_full_video() {
    local video_file="$1"
    local output_file="$2"
    local quality_value="$3"
    
    # Track the call
    echo "$video_file|$output_file|$quality_value" >> "$TRANSCODE_FULL_CALLS_FILE"
    
    # Create minimal file so downstream code doesn't fail on file existence checks
    touch "$output_file"
}

# Mock remux_to_mp4() - tracks calls and checks codec compatibility
remux_to_mp4() {
    local input_file="$1"
    local output_file="$2"
    
    # Track the call
    echo "$input_file|$output_file" >> "$REMUX_CALLS_FILE"
    
    # Detect video codec using mocked ffprobe
    local video_codec
    video_codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>/dev/null | head -1 | tr -d '\n\r')
    
    if [ -z "$video_codec" ]; then
        return 1
    fi
    
    # Check codec compatibility
    if ! is_codec_mp4_compatible "$video_codec"; then
        return 1
    fi
    
    # Create output file to simulate success
    touch "$output_file"
    return 0
}

# Mock check_requirements() - skip requirement checks in test mode
check_requirements() {
    return 0
}

# Mock find_video_file() - tracks calls and returns test video file path
find_video_file() {
    echo "called" >> "$FIND_VIDEO_FILE_CALLS_FILE"
    
    if [ -n "${MOCK_VIDEO_FILE:-}" ]; then
        touch "$MOCK_VIDEO_FILE"
        echo "$MOCK_VIDEO_FILE"
    else
        local test_file
        test_file=$(mktemp --suffix=.mp4 2>/dev/null || mktemp -t test_video).mp4
        touch "$test_file"
        echo "$test_file"
    fi
}

# Mock find_all_video_files() - tracks calls and returns test video file path(s)
find_all_video_files() {
    echo "called" >> "$FIND_ALL_VIDEO_FILES_CALLS_FILE"
    
    if [ -n "${MOCK_VIDEO_FILE:-}" ]; then
        touch "$MOCK_VIDEO_FILE"
        echo "$MOCK_VIDEO_FILE"
    else
        local test_file
        test_file=$(mktemp --suffix=.mp4 2>/dev/null || mktemp -t test_video).mp4
        touch "$test_file"
        echo "$test_file"
    fi
}

# ============================================================================
# Assertion Helpers for Mock Verification
# ============================================================================

# Assert that a function was called a specific number of times
assert_call_count() {
    local calls_file="$1"
    local expected_count="$2"
    local func_name="$3"
    
    local actual_count
    actual_count=$(get_call_count "$calls_file")
    
    if [ "$actual_count" -ne "$expected_count" ]; then
        echo "Expected $func_name to be called $expected_count times, but was called $actual_count times" >&2
        return 1
    fi
}

# Assert that a function was called with specific arguments
assert_called_with() {
    local calls_file="$1"
    local expected_args="$2"
    local call_index="${3:-1}"
    
    local actual_call
    actual_call=$(get_call "$calls_file" "$call_index")
    
    if [ "$actual_call" != "$expected_args" ]; then
        echo "Expected call $call_index to be '$expected_args', but was '$actual_call'" >&2
        return 1
    fi
}

# Assert that a function was never called
assert_not_called() {
    local calls_file="$1"
    local func_name="$2"
    
    local count
    count=$(get_call_count "$calls_file")
    
    if [ "$count" -ne 0 ]; then
        echo "Expected $func_name to not be called, but was called $count times" >&2
        return 1
    fi
}
