#!/usr/bin/env bats
# Tests for subtitle stream preservation in boiler.sh:
# - remux_to_mp4() maps only convertible streams and populates SUBTITLE_DROP_FILES for image-only
# - transcode_full_video() maps convertible streams and sets SUBTITLE_HAS_DROP_PENDING for image-only
# - main() prints a post-run summary listing files where all subtitle streams were dropped

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
# remux_to_mp4() subtitle mapping (boiler.sh)
# ============================================================================

@test "boiler remux_to_mp4: mixed subs - only convertible stream mapped by global index" {
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

@test "boiler remux_to_mp4: all-image subs - adds output file to SUBTITLE_DROP_FILES" {
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

@test "boiler remux_to_mp4: no subtitles - no subtitle args and SUBTITLE_DROP_FILES empty" {
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

# ============================================================================
# transcode_full_video() subtitle mapping (boiler.sh)
# ============================================================================

@test "boiler transcode_full_video: subrip stream - mapped by global index with mov_text" {
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

@test "boiler transcode_full_video: PGS-only - no subtitle args and sets SUBTITLE_HAS_DROP_PENDING" {
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

@test "boiler transcode_full_video: no subtitles - no subtitle args and SUBTITLE_HAS_DROP_PENDING unchanged" {
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

# ============================================================================
# main() post-run accumulator summary
# ============================================================================

@test "main: prints subtitle drop summary when transcode drops all subtitle streams" {
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

@test "main: no subtitle summary when no subtitle drops occurred" {
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
