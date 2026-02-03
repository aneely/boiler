#!/usr/bin/env bats
# Tests for mocked FFmpeg/ffprobe functions
# Ported from test_boiler.sh

load 'helpers/setup'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# ============================================================================
# Mocked get_video_resolution() tests
# ============================================================================

@test "mocked get_video_resolution: returns default 1080p" {
    run get_video_resolution "test.mp4"
    assert_success
    assert_output "1080"
}

@test "mocked get_video_resolution: returns override value" {
    MOCK_RESOLUTION=2160
    run get_video_resolution "test.mp4"
    assert_success
    assert_output "2160"
}

# ============================================================================
# Mocked get_video_duration() tests
# ============================================================================

@test "mocked get_video_duration: returns default 300s" {
    run get_video_duration "test.mp4"
    assert_success
    assert_output "300"
}

@test "mocked get_video_duration: returns override value" {
    MOCK_DURATION=180
    run get_video_duration "test.mp4"
    assert_success
    assert_output "180"
}

# ============================================================================
# Mocked measure_bitrate() tests
# ============================================================================

@test "mocked measure_bitrate: returns MOCK_BITRATE_BPS when set" {
    MOCK_BITRATE_BPS=8000000
    run measure_bitrate "test.mp4" "300"
    assert_success
    assert_output "8000000"
}

@test "mocked measure_bitrate: tracks call" {
    MOCK_BITRATE_BPS=8000000
    measure_bitrate "test.mp4" "300" > /dev/null
    
    local count
    count=$(get_call_count "$MEASURE_BITRATE_CALLS_FILE")
    assert_equal "$count" "1"
}

@test "mocked measure_bitrate: tracks call parameters" {
    MOCK_BITRATE_BPS=8000000
    measure_bitrate "test.mp4" "300" > /dev/null
    
    local call
    call=$(get_call "$MEASURE_BITRATE_CALLS_FILE" 1)
    assert_equal "$call" "test.mp4|300"
}

@test "mocked measure_bitrate: returns empty without MOCK_BITRATE_BPS" {
    run measure_bitrate "test2.mp4" "200"
    assert_success
    assert_output ""
}

# ============================================================================
# Mocked transcode_sample() tests
# ============================================================================

@test "mocked transcode_sample: tracks call" {
    local temp_file
    temp_file=$(mktemp)
    
    transcode_sample "input.mp4" "0" "60" "52" "$temp_file"
    
    local count
    count=$(get_call_count "$TRANSCODE_SAMPLE_CALLS_FILE")
    assert_equal "$count" "1"
    
    rm -f "$temp_file"
}

@test "mocked transcode_sample: tracks call parameters" {
    local temp_file
    temp_file=$(mktemp)
    
    transcode_sample "input.mp4" "0" "60" "52" "$temp_file"
    
    local call
    call=$(get_call "$TRANSCODE_SAMPLE_CALLS_FILE" 1)
    assert_equal "$call" "input.mp4|0|60|52|$temp_file"
    
    rm -f "$temp_file"
}

@test "mocked transcode_sample: creates output file" {
    local temp_file
    temp_file=$(mktemp)
    rm -f "$temp_file"  # Remove so we can verify it gets created
    
    transcode_sample "input.mp4" "0" "60" "52" "$temp_file"
    
    assert_file_exists "$temp_file"
    
    rm -f "$temp_file"
}

# ============================================================================
# Mocked transcode_full_video() tests
# ============================================================================

@test "mocked transcode_full_video: tracks call" {
    local temp_file
    temp_file=$(mktemp)
    
    transcode_full_video "input.mp4" "$temp_file" "52"
    
    local count
    count=$(get_call_count "$TRANSCODE_FULL_CALLS_FILE")
    assert_equal "$count" "1"
    
    rm -f "$temp_file"
}

@test "mocked transcode_full_video: tracks call parameters" {
    local temp_file
    temp_file=$(mktemp)
    
    transcode_full_video "input.mp4" "$temp_file" "52"
    
    local call
    call=$(get_call "$TRANSCODE_FULL_CALLS_FILE" 1)
    assert_equal "$call" "input.mp4|$temp_file|52"
    
    rm -f "$temp_file"
}

@test "mocked transcode_full_video: creates output file" {
    local temp_file
    temp_file=$(mktemp)
    rm -f "$temp_file"  # Remove so we can verify it gets created
    
    transcode_full_video "input.mp4" "$temp_file" "52"
    
    assert_file_exists "$temp_file"
    
    rm -f "$temp_file"
}

# ============================================================================
# Mocked remux_to_mp4() tests
# ============================================================================

@test "mocked remux_to_mp4: succeeds with compatible codec (h264)" {
    local temp_file
    temp_file=$(mktemp --suffix=.mp4 2>/dev/null || mktemp).mp4
    MOCK_VIDEO_CODEC="h264"
    
    run remux_to_mp4 "input.mkv" "$temp_file"
    assert_success
    
    rm -f "$temp_file"
}

@test "mocked remux_to_mp4: tracks call" {
    local temp_file
    temp_file=$(mktemp --suffix=.mp4 2>/dev/null || mktemp).mp4
    MOCK_VIDEO_CODEC="h264"
    
    remux_to_mp4 "input.mkv" "$temp_file"
    
    local count
    count=$(get_call_count "$REMUX_CALLS_FILE")
    assert_equal "$count" "1"
    
    rm -f "$temp_file"
}

@test "mocked remux_to_mp4: tracks call parameters" {
    local temp_file
    temp_file=$(mktemp --suffix=.mp4 2>/dev/null || mktemp).mp4
    MOCK_VIDEO_CODEC="h264"
    
    remux_to_mp4 "input.mkv" "$temp_file"
    
    local call
    call=$(get_call "$REMUX_CALLS_FILE" 1)
    assert_equal "$call" "input.mkv|$temp_file"
    
    rm -f "$temp_file"
}

@test "mocked remux_to_mp4: creates output file on success" {
    local temp_file
    temp_file=$(mktemp --suffix=.mp4 2>/dev/null || mktemp).mp4
    rm -f "$temp_file"  # Remove so we can verify it gets created
    MOCK_VIDEO_CODEC="h264"
    
    remux_to_mp4 "input.mkv" "$temp_file"
    
    assert_file_exists "$temp_file"
    
    rm -f "$temp_file"
}

@test "mocked remux_to_mp4: fails with incompatible codec (wmv3)" {
    local temp_file
    temp_file=$(mktemp --suffix=.mp4 2>/dev/null || mktemp).mp4
    rm -f "$temp_file"
    MOCK_VIDEO_CODEC="wmv3"
    
    run remux_to_mp4 "input.wmv" "$temp_file"
    assert_failure
    
    # Should not create output file on failure
    assert_file_not_exists "$temp_file"
}

@test "mocked remux_to_mp4: tracks call even on failure" {
    local temp_file
    temp_file=$(mktemp --suffix=.mp4 2>/dev/null || mktemp).mp4
    rm -f "$temp_file"
    MOCK_VIDEO_CODEC="wmv3"
    
    run remux_to_mp4 "input.wmv" "$temp_file"
    
    local count
    count=$(get_call_count "$REMUX_CALLS_FILE")
    assert_equal "$count" "1"
}
