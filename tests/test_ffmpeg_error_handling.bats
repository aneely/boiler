#!/usr/bin/env bats
# Tests for FFmpeg error handling: exit code and output file size checks
# transcode_sample(), transcode_full_video(), and remux_to_mp4() should
# return non-zero when ffmpeg fails or produces a zero-byte output.

load 'helpers/setup'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# Helper: run a boiler.sh function in isolation with a custom ffmpeg override
# $1 = ffmpeg function body (bash code)
# $2 = function to call
# remaining args passed to the function
run_with_ffmpeg_override() {
    local ffmpeg_body="$1"
    local func_name="$2"
    shift 2
    bash -c "
        set +e
        export BOILER_TEST_MODE=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        # Override ffmpeg
        ffmpeg() { $ffmpeg_body; }
        # Override ffprobe for codec detection
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
    " -- "$@"
}

# ============================================================================
# transcode_sample() error handling
# ============================================================================

@test "transcode_sample: returns non-zero when ffmpeg fails" {
    local output_file="$TEST_TMPDIR/sample_output.mp4"
    run run_with_ffmpeg_override \
        "return 1" \
        transcode_sample "$TEST_TMPDIR/input.mp4" "10" "5" "60" "$output_file"
    assert_failure
}

@test "transcode_sample: returns non-zero when output file is zero bytes" {
    local input_file="$TEST_TMPDIR/input.mp4"
    touch "$input_file"
    local output_file="$TEST_TMPDIR/sample_output.mp4"
    # ffmpeg creates the output file (via -y flag) but writes nothing
    run run_with_ffmpeg_override \
        "for a in \"\$@\"; do :; done; touch \"$output_file\"; return 0" \
        transcode_sample "$input_file" "10" "5" "60" "$output_file"
    assert_failure
}

@test "transcode_sample: returns non-zero when output file is missing" {
    local output_file="$TEST_TMPDIR/sample_output.mp4"
    run run_with_ffmpeg_override \
        "return 0" \
        transcode_sample "$TEST_TMPDIR/input.mp4" "10" "5" "60" "$output_file"
    assert_failure
}

@test "transcode_sample: outputs error message on ffmpeg failure" {
    local output_file="$TEST_TMPDIR/sample_output.mp4"
    run run_with_ffmpeg_override \
        "return 1" \
        transcode_sample "$TEST_TMPDIR/input.mp4" "10" "5" "60" "$output_file"
    assert_output --partial "FFmpeg"
}

# ============================================================================
# transcode_full_video() error handling
# ============================================================================

@test "transcode_full_video: returns non-zero when ffmpeg fails" {
    local output_file="$TEST_TMPDIR/full_output.mp4"
    run run_with_ffmpeg_override \
        "return 1" \
        transcode_full_video "$TEST_TMPDIR/input.mp4" "$output_file" "60"
    assert_failure
}

@test "transcode_full_video: returns non-zero when output file is zero bytes" {
    local input_file="$TEST_TMPDIR/input.mp4"
    touch "$input_file"
    local output_file="$TEST_TMPDIR/full_output.mp4"
    run run_with_ffmpeg_override \
        "touch \"$output_file\"; return 0" \
        transcode_full_video "$input_file" "$output_file" "60"
    assert_failure
}

@test "transcode_full_video: returns non-zero when output file is missing" {
    local output_file="$TEST_TMPDIR/full_output.mp4"
    run run_with_ffmpeg_override \
        "return 0" \
        transcode_full_video "$TEST_TMPDIR/input.mp4" "$output_file" "60"
    assert_failure
}

@test "transcode_full_video: outputs error message on failure" {
    local output_file="$TEST_TMPDIR/full_output.mp4"
    run run_with_ffmpeg_override \
        "return 1" \
        transcode_full_video "$TEST_TMPDIR/input.mp4" "$output_file" "60"
    assert_output --partial "FFmpeg"
}

# ============================================================================
# remux_to_mp4() error handling
# ============================================================================

@test "remux_to_mp4: returns non-zero when ffmpeg fails" {
    local output_file="$TEST_TMPDIR/remux_output.mp4"
    # ffmpeg override needs to handle both ffprobe codec checks and the actual ffmpeg call
    # The ffprobe override in run_with_ffmpeg_override handles codec detection;
    # the ffmpeg override only applies to the actual ffmpeg command
    run run_with_ffmpeg_override \
        "return 1" \
        remux_to_mp4 "$TEST_TMPDIR/input.mkv" "$output_file"
    assert_failure
}

@test "remux_to_mp4: returns non-zero when output file is zero bytes" {
    local input_file="$TEST_TMPDIR/input.mkv"
    touch "$input_file"
    local output_file="$TEST_TMPDIR/remux_output.mp4"
    run run_with_ffmpeg_override \
        "touch \"$output_file\"; return 0" \
        remux_to_mp4 "$input_file" "$output_file"
    assert_failure
}

@test "remux_to_mp4: returns non-zero when output file is missing" {
    local output_file="$TEST_TMPDIR/remux_output.mp4"
    run run_with_ffmpeg_override \
        "return 0" \
        remux_to_mp4 "$TEST_TMPDIR/input.mkv" "$output_file"
    assert_failure
}

@test "remux_to_mp4: outputs error message on ffmpeg failure" {
    local output_file="$TEST_TMPDIR/remux_output.mp4"
    run run_with_ffmpeg_override \
        "return 1" \
        remux_to_mp4 "$TEST_TMPDIR/input.mkv" "$output_file"
    assert_output --partial "FFmpeg"
}
