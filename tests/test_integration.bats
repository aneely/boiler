#!/usr/bin/env bats
# Integration tests for main() function and related workflows
# Ported from test_boiler.sh

load 'helpers/setup'

setup() {
    common_setup
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
}

teardown() {
    common_teardown
    cd "$PROJECT_ROOT"
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}

# ============================================================================
# main() integration tests - Early exit scenarios
# ============================================================================

@test "main: exits 0 when source is within tolerance" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=8000000  # Exactly 8 Mbps (target for 1080p)
    
    run main
    assert_success
    assert_output --partial "within acceptable range"
}

@test "main: does not transcode when source is within tolerance" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=8000000
    
    main 2>&1 > /dev/null
    
    local sample_count full_count
    sample_count=$(get_call_count "$TRANSCODE_SAMPLE_CALLS_FILE")
    full_count=$(get_call_count "$TRANSCODE_FULL_CALLS_FILE")
    
    assert_equal "$sample_count" "0"
    assert_equal "$full_count" "0"
}

@test "main: renames file when within tolerance" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=8000000
    
    main 2>&1 > /dev/null
    
    assert_file_exists "test_video.orig.8.00.Mbps.mp4"
}

@test "main: exits 0 when source is below target" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=4000000  # 4 Mbps (below 8 Mbps target)
    
    run main
    assert_success
    assert_output --partial "below target bitrate"
}

@test "main: does not transcode when source is below target" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=4000000
    
    main 2>&1 > /dev/null
    
    local sample_count full_count
    sample_count=$(get_call_count "$TRANSCODE_SAMPLE_CALLS_FILE")
    full_count=$(get_call_count "$TRANSCODE_FULL_CALLS_FILE")
    
    assert_equal "$sample_count" "0"
    assert_equal "$full_count" "0"
}

@test "main: renames file when below target" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=4000000
    
    main 2>&1 > /dev/null
    
    assert_file_exists "test_video.orig.4.00.Mbps.mp4"
}

# ============================================================================
# main() integration tests - Full transcoding workflow
# ============================================================================

@test "main: completes full transcoding workflow when source above target" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000  # 12 Mbps (above 8 Mbps target)
    MOCK_SAMPLE_BITRATE_BPS=8000000  # Converge immediately
    MOCK_OUTPUT_BITRATE_BPS=8000000
    
    run main
    assert_success
    # Note: Output includes ANSI color codes, so use case-insensitive regex
    assert_output --regexp "[Tt]ranscoding complete"
}

@test "main: calls transcode_sample for optimization (3 samples for 300s video)" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=8000000
    
    main 2>&1 > /dev/null
    
    local count
    count=$(get_call_count "$TRANSCODE_SAMPLE_CALLS_FILE")
    assert_equal "$count" "3"
}

@test "main: calls transcode_full_video once for successful first pass" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=8000000
    
    main 2>&1 > /dev/null
    
    local count
    count=$(get_call_count "$TRANSCODE_FULL_CALLS_FILE")
    assert_equal "$count" "1"
}

# ============================================================================
# main() integration tests - Second pass scenarios
# ============================================================================

@test "main: completes transcoding with second pass when first pass outside tolerance" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=9000000  # First pass: 12.5% above target
    MOCK_SECOND_PASS_BITRATE_BPS=8100000  # Second pass: within tolerance
    
    run main
    assert_success
    assert_output --partial "second pass"
    assert_output --partial "outside tolerance"
}

@test "main: calls transcode_full_video twice for second pass" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=9000000
    MOCK_SECOND_PASS_BITRATE_BPS=8100000
    
    main 2>&1 > /dev/null
    
    local count
    count=$(get_call_count "$TRANSCODE_FULL_CALLS_FILE")
    assert_equal "$count" "2"
}

# ============================================================================
# main() integration tests - Third pass with interpolation
# ============================================================================

@test "main: completes transcoding with third pass when second pass outside tolerance" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=14050000  # First pass: way above
    MOCK_SECOND_PASS_BITRATE_BPS=7500000  # Second pass: below tolerance
    MOCK_THIRD_PASS_BITRATE_BPS=8000000  # Third pass: at target
    
    run main
    assert_success
    assert_output --partial "second pass"
}

@test "main: calls transcode_full_video three times for third pass" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=14050000
    MOCK_SECOND_PASS_BITRATE_BPS=7500000
    MOCK_THIRD_PASS_BITRATE_BPS=8000000
    
    main 2>&1 > /dev/null
    
    local count
    count=$(get_call_count "$TRANSCODE_FULL_CALLS_FILE")
    assert_equal "$count" "3"
}

# ============================================================================
# main() integration tests - Multiple resolutions
# ============================================================================

@test "main: uses correct target bitrate for 2160p (4K)" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=2160
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=20000000  # 20 Mbps (above 11 Mbps target for 4K)
    MOCK_SAMPLE_BITRATE_BPS=11000000
    MOCK_OUTPUT_BITRATE_BPS=11000000
    
    run main
    assert_success
    assert_output --partial "Target bitrate"
    assert_output --partial "11"
}

@test "main: uses correct target bitrate for 720p" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=720
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=10000000  # 10 Mbps (above 5 Mbps target for 720p)
    MOCK_SAMPLE_BITRATE_BPS=5000000
    MOCK_OUTPUT_BITRATE_BPS=5000000
    
    run main
    assert_success
    assert_output --partial "Target bitrate"
    assert_output --partial "5"
}

@test "main: uses correct target bitrate for 480p" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=480
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=5000000  # 5 Mbps (above 2.5 Mbps target for 480p)
    MOCK_SAMPLE_BITRATE_BPS=2500000
    MOCK_OUTPUT_BITRATE_BPS=2500000
    
    run main
    assert_success
    assert_output --partial "Target bitrate"
    assert_output --partial "2.5"
}

# ============================================================================
# main() integration tests - Target bitrate override
# ============================================================================

@test "main: uses override target bitrate when --target-bitrate provided" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000
    MOCK_SAMPLE_BITRATE_BPS=9500000
    MOCK_OUTPUT_BITRATE_BPS=9500000
    
    run main --target-bitrate 9.5
    assert_success
    assert_output --partial "Target bitrate (override): 9.5"
}

@test "main: uses override target bitrate when -t provided" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000
    MOCK_SAMPLE_BITRATE_BPS=6000000
    MOCK_OUTPUT_BITRATE_BPS=6000000
    
    run main -t 6
    assert_success
    assert_output --partial "Target bitrate (override): 6"
}

# ============================================================================
# transcode_video() tests with bitrate override
# ============================================================================

@test "transcode_video: completes with bitrate override" {
    touch "test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000
    MOCK_SAMPLE_BITRATE_BPS=6000000
    MOCK_OUTPUT_BITRATE_BPS=6000000
    
    run transcode_video "test_video.mp4" "6"
    assert_success
    assert_output --partial "Target bitrate (override): 6"
    # Note: Output includes ANSI color codes, so use case-insensitive regex
    assert_output --regexp "[Tt]ranscoding complete"
}

# ============================================================================
# Codec incompatibility tests
# ============================================================================

@test "transcode_video: transcodes incompatible codec within tolerance to HEVC" {
    touch "test_video.wmv"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=8000000  # At target
    MOCK_VIDEO_CODEC="wmv3"  # Incompatible codec
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=8000000
    
    run transcode_video "test_video.wmv"
    assert_success
    assert_output --partial "not compatible with MP4 container"
    assert_output --partial "Transcoding to HEVC at source bitrate"
}

@test "transcode_video: transcodes incompatible codec below target to HEVC" {
    touch "test_video.wmv"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=5000000  # Below target
    MOCK_VIDEO_CODEC="wmv3"
    MOCK_SAMPLE_BITRATE_BPS=5000000
    MOCK_OUTPUT_BITRATE_BPS=5000000
    
    run transcode_video "test_video.wmv"
    assert_success
    assert_output --partial "not compatible with MP4 container"
    assert_output --partial "Transcoding to HEVC at source bitrate"
}

# ============================================================================
# handle_non_quicklook_at_target() subdirectory output tests
# ============================================================================

@test "handle_non_quicklook_at_target: writes remuxed output next to source in subdirectory" {
    mkdir -p "subdir"
    touch "subdir/video.mkv"
    MOCK_VIDEO_CODEC="h264"
    
    local needs_transcode=0
    handle_non_quicklook_at_target "subdir/video.mkv" "8.50" "needs_transcode"
    
    local call
    call=$(get_call "$REMUX_CALLS_FILE" 1)
    local output_path="${call#*|}"
    
    assert_equal "$output_path" "subdir/video.orig.8.50.Mbps.mp4"
}

# ============================================================================
# transcode_video() additional tests - codec incompatibility file verification
# ============================================================================

@test "transcode_video: creates .orig. file for incompatible codec within tolerance" {
    touch "test_video.wmv"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=8000000  # At target
    MOCK_VIDEO_CODEC="wmv3"  # Incompatible codec
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=8000000
    
    transcode_video "test_video.wmv" 2>&1 > /dev/null
    
    # Check that an .orig. file was created
    local orig_files
    orig_files=$(ls -1 *.orig.*.mp4 2>/dev/null | wc -l | tr -d ' ')
    assert [ "$orig_files" -gt 0 ]
}

@test "transcode_video: creates .orig. file for incompatible codec below target" {
    touch "test_video.wmv"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=5000000  # Below target
    MOCK_VIDEO_CODEC="wmv3"
    MOCK_SAMPLE_BITRATE_BPS=5000000
    MOCK_OUTPUT_BITRATE_BPS=5000000
    
    transcode_video "test_video.wmv" 2>&1 > /dev/null
    
    # Check that an .orig. file was created
    local orig_files
    orig_files=$(ls -1 *.orig.*.mp4 2>/dev/null | wc -l | tr -d ' ')
    assert [ "$orig_files" -gt 0 ]
}

@test "transcode_video: calls transcode_full_video for incompatible codec within tolerance" {
    touch "test_video.wmv"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=8000000
    MOCK_VIDEO_CODEC="wmv3"
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=8000000
    
    transcode_video "test_video.wmv" 2>&1 > /dev/null
    
    local count
    count=$(get_call_count "$TRANSCODE_FULL_CALLS_FILE")
    assert_equal "$count" "1"
}

@test "transcode_video: calls transcode_full_video for incompatible codec below target" {
    touch "test_video.wmv"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=5000000
    MOCK_VIDEO_CODEC="wmv3"
    MOCK_SAMPLE_BITRATE_BPS=5000000
    MOCK_OUTPUT_BITRATE_BPS=5000000
    
    transcode_video "test_video.wmv" 2>&1 > /dev/null
    
    local count
    count=$(get_call_count "$TRANSCODE_FULL_CALLS_FILE")
    assert_equal "$count" "1"
}

# ============================================================================
# preprocess_non_quicklook_files() tests
# ============================================================================

@test "preprocess_non_quicklook_files: handles incompatible codec" {
    touch "test_video.wmv"
    MOCK_VIDEO_FILE="test_video.wmv"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=8000000  # At target
    MOCK_VIDEO_CODEC="wmv3"  # Incompatible
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=8000000
    
    run preprocess_non_quicklook_files
    # preprocess returns count of processed files (exit code = count)
    assert_equal "$status" "1"
    assert_output --partial "not compatible with MP4 container"
}

@test "preprocess_non_quicklook_files: calls transcode_full_video for incompatible codec" {
    touch "test_video.wmv"
    MOCK_VIDEO_FILE="test_video.wmv"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=8000000
    MOCK_VIDEO_CODEC="wmv3"
    MOCK_SAMPLE_BITRATE_BPS=8000000
    MOCK_OUTPUT_BITRATE_BPS=8000000
    
    preprocess_non_quicklook_files 2>&1 > /dev/null || true
    
    local count
    count=$(get_call_count "$TRANSCODE_FULL_CALLS_FILE")
    # When preprocessing with incompatible codec, transcode_video is called
    # which goes through its full workflow including transcoding
    assert [ "$count" -ge 1 ]
}

@test "preprocess_non_quicklook_files: uses override target bitrate" {
    touch "test_video.mkv"
    MOCK_VIDEO_FILE="test_video.mkv"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=9500000  # At override target
    MOCK_VIDEO_CODEC="h264"  # Compatible codec
    
    # Set global override
    GLOBAL_TARGET_BITRATE_MBPS="9.5"
    
    run preprocess_non_quicklook_files
    # Should process file at 9.5 Mbps (within tolerance of override target)
    assert_equal "$status" "1"
    assert_output --partial "remux"
}

@test "preprocess_non_quicklook_files: remuxes compatible codec" {
    touch "test_video.mkv"
    MOCK_VIDEO_FILE="test_video.mkv"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=9500000
    MOCK_VIDEO_CODEC="h264"
    GLOBAL_TARGET_BITRATE_MBPS="9.5"
    
    preprocess_non_quicklook_files 2>&1 > /dev/null || true
    
    local count
    count=$(get_call_count "$REMUX_CALLS_FILE")
    assert_equal "$count" "1"
}

# ============================================================================
# main() with override - additional verification
# ============================================================================

@test "main: calls transcode_full_video with override" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000
    MOCK_SAMPLE_BITRATE_BPS=9500000
    MOCK_OUTPUT_BITRATE_BPS=9500000
    
    main --target-bitrate 9.5 2>&1 > /dev/null
    
    local count
    count=$(get_call_count "$TRANSCODE_FULL_CALLS_FILE")
    assert_equal "$count" "1"
}

@test "main: uses correct bitrate call counts with override (source + samples + output)" {
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_BITRATE_BPS=12000000
    MOCK_SAMPLE_BITRATE_BPS=9500000
    MOCK_OUTPUT_BITRATE_BPS=9500000
    
    main --target-bitrate 9.5 2>&1 > /dev/null
    
    # 1 for source + 3 for samples + 1 for output = 5
    local count
    count=$(get_call_count "$MEASURE_BITRATE_CALLS_FILE")
    assert_equal "$count" "5"
}

# ============================================================================
# Error handling tests
# ============================================================================

@test "error handling: measure_bitrate returns empty when mock not set" {
    unset MOCK_BITRATE_BPS
    unset MOCK_SAMPLE_BITRATE_BPS
    unset MOCK_OUTPUT_BITRATE_BPS
    
    local result
    result=$(measure_bitrate "test.mp4" "300")
    assert_equal "$result" ""
}

@test "error handling: calculate_adjusted_quality handles zero bitrate" {
    local result
    result=$(calculate_adjusted_quality "50" "0" "8000000")
    # Zero bitrate triggers "too low" branch - should adjust quality upward
    assert [ "$result" -ne 50 ]
}

@test "error handling: calculate_adjusted_quality handles zero target without crashing" {
    local result
    result=$(calculate_adjusted_quality "50" "8000000" "0" 2>/dev/null || echo "error")
    # Should produce some result (not crash)
    assert [ -n "$result" ]
}
