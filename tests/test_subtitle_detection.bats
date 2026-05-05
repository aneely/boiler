#!/usr/bin/env bats
# Tests for subtitle detection and classification in remux-only.sh

TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

load "$TESTS_DIR/test_helper/bats-support/load"
load "$TESTS_DIR/test_helper/bats-assert/load"

setup() {
    TEST_DIR=$(mktemp -d)
}

teardown() {
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}

# ============================================================================
# detect_subtitle_streams()
# ============================================================================

@test "detect_subtitle_streams: no subtitle streams returns empty output" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        ffprobe() { echo ''; }
        detect_subtitle_streams 'test.mkv'
    "
    assert_success
    assert_output ""
}

@test "detect_subtitle_streams: single subrip stream with language" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        ffprobe() { echo 'subrip,eng'; }
        detect_subtitle_streams 'test.mkv'
    "
    assert_success
    assert_output "0|subrip|eng"
}

@test "detect_subtitle_streams: multiple streams output sequential indices" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        ffprobe() { printf 'subrip,eng\nhdmv_pgs_subtitle,jpn\n'; }
        detect_subtitle_streams 'test.mkv'
    "
    assert_success
    assert_line "0|subrip|eng"
    assert_line "1|hdmv_pgs_subtitle|jpn"
}

@test "detect_subtitle_streams: missing language tag produces empty lang field" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        ffprobe() { echo 'subrip,N/A'; }
        detect_subtitle_streams 'test.mkv'
    "
    assert_success
    assert_output "0|subrip|"
}

# ============================================================================
# is_subtitle_convertible()
# ============================================================================

@test "is_subtitle_convertible: subrip is convertible" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'subrip' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "yes"
}

@test "is_subtitle_convertible: ass is convertible" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'ass' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "yes"
}

@test "is_subtitle_convertible: ssa is convertible" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'ssa' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "yes"
}

@test "is_subtitle_convertible: webvtt is convertible" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'webvtt' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "yes"
}

@test "is_subtitle_convertible: mov_text is convertible" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'mov_text' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "yes"
}

@test "is_subtitle_convertible: text is convertible" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'text' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "yes"
}

@test "is_subtitle_convertible: hdmv_pgs_subtitle is not convertible" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'hdmv_pgs_subtitle' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "no"
}

@test "is_subtitle_convertible: dvd_subtitle is not convertible" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'dvd_subtitle' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "no"
}

@test "is_subtitle_convertible: dvbsub is not convertible" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'dvbsub' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "no"
}

@test "is_subtitle_convertible: pgssub is not convertible" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'pgssub' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "no"
}

@test "is_subtitle_convertible: unknown codec is not convertible" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'some_unknown_codec' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "no"
}

@test "is_subtitle_convertible: codec matching is case-insensitive" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        is_subtitle_convertible 'SubRip' && echo 'yes' || echo 'no'
    "
    assert_success
    assert_output "yes"
}

# ============================================================================
# report_subtitles()
# ============================================================================

@test "report_subtitles: single convertible stream shows correct label" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        report_subtitles '0|subrip|eng'
    "
    assert_success
    assert_output --partial "[0:s:0] subrip (eng)"
    assert_output --partial "convertible to mov_text"
}

@test "report_subtitles: incompatible stream shows NOT convertible label" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        report_subtitles '0|hdmv_pgs_subtitle|eng'
    "
    assert_success
    assert_output --partial "[0:s:0] hdmv_pgs_subtitle (eng)"
    assert_output --partial "NOT convertible"
}

@test "report_subtitles: stream with no language omits language from label" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        report_subtitles '0|subrip|'
    "
    assert_success
    assert_output --partial "[0:s:0] subrip"
    refute_output --partial "()"
}

@test "report_subtitles: mixed streams shows both convertible and incompatible" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        report_subtitles '$(printf "0|subrip|eng\n1|hdmv_pgs_subtitle|jpn")'
    "
    assert_success
    assert_output --partial "convertible to mov_text"
    assert_output --partial "NOT convertible"
}

# ============================================================================
# prompt_subtitle_choice()
# ============================================================================

@test "prompt_subtitle_choice: user enters 1 returns include" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        echo '1' | prompt_subtitle_choice '0|subrip|eng'
    "
    assert_success
    assert_output --partial "include"
}

@test "prompt_subtitle_choice: user enters 2 returns none" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        echo '2' | prompt_subtitle_choice '0|subrip|eng'
    "
    assert_success
    assert_output --partial "none"
}

@test "prompt_subtitle_choice: user enters 3 returns abort" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        echo '3' | prompt_subtitle_choice '0|subrip|eng'
    "
    assert_success
    assert_output --partial "abort"
}

@test "prompt_subtitle_choice: empty input returns abort" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        echo '' | prompt_subtitle_choice '0|subrip|eng'
    "
    assert_success
    assert_output --partial "abort"
}

@test "prompt_subtitle_choice: all convertible streams show convert menu option" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        echo '3' | prompt_subtitle_choice '0|subrip|eng'
    "
    assert_success
    assert_output --partial "convert to mov_text"
}

@test "prompt_subtitle_choice: mixed streams show kept/dropped menu option" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        echo '3' | prompt_subtitle_choice \"\$(printf '0|subrip|eng\n1|hdmv_pgs_subtitle|jpn')\"
    "
    assert_success
    assert_output --partial "convertible kept, incompatible dropped"
}

# ============================================================================
# remux_to_mp4(): subtitle_mode argument
# ============================================================================

@test "remux_to_mp4: subtitle_mode=none does not pass subtitle map to ffmpeg" {
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

@test "remux_to_mp4: subtitle_mode=include passes subtitle map and codec to ffmpeg" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        get_video_codec() { echo 'h264'; }
        get_audio_codec_arg() { echo 'copy'; }
        count_audio_streams() { echo '1'; }
        ffmpeg() { echo \"\$@\"; return 0; }
        remux_to_mp4 'input.mkv' 'output.mp4' 'include'
    "
    assert_success
    assert_output --partial "0:s?"
    assert_output --partial "mov_text"
}

@test "remux_to_mp4: no subtitle_mode arg preserves current behavior (no subtitle map)" {
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

# ============================================================================
# get_subtitle_mode_for_file()
# ============================================================================

@test "get_subtitle_mode_for_file: no subtitles returns none without prompting" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        detect_subtitle_streams() { echo ''; }
        get_subtitle_mode_for_file 'test.mkv'
    "
    assert_success
    assert_output "none"
}

@test "get_subtitle_mode_for_file: subtitles present, user chooses 1 returns include" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        detect_subtitle_streams() { echo '0|subrip|eng'; }
        echo '1' | get_subtitle_mode_for_file 'test.mkv'
    "
    assert_success
    assert_output --partial "include"
}

@test "get_subtitle_mode_for_file: subtitles present, user chooses 3 returns abort" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        detect_subtitle_streams() { echo '0|subrip|eng'; }
        echo '3' | get_subtitle_mode_for_file 'test.mkv'
    "
    assert_success
    assert_output --partial "abort"
}

# Regression test: report/menu must go to stderr so the mode word is the only
# stdout output — otherwise $() command substitution swallows the display and
# read blocks on stdin with nothing visible (the stall bug).
@test "get_subtitle_mode_for_file: mode is correctly captured via command substitution" {
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

# ============================================================================
# process_one_file(): subtitle integration
# ============================================================================

@test "process_one_file: aborts and increments skipped_count when user chooses abort" {
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

@test "process_one_file: passes include mode to remux_to_mp4 when user chooses include" {
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

@test "process_one_file: no subtitles proceeds silently with mode none" {
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
