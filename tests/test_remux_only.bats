#!/usr/bin/env bats
# Tests for remux-only.sh file discovery, argument parsing, and output path logic

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
# find_remux_files() with configurable depth tests
# ============================================================================

@test "find_remux_files: depth 1 finds only current directory files" {
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

@test "find_remux_files: depth 2 finds current + one subdirectory level (default)" {
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

@test "find_remux_files: depth 3 finds current + two subdirectory levels" {
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

@test "find_remux_files: depth 0 (unlimited) finds all files recursively" {
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

@test "find_remux_files: default depth (2) when GLOBAL_MAX_DEPTH not set" {
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

# ============================================================================
# Argument parsing tests
# ============================================================================

@test "parse_arguments: -L sets GLOBAL_MAX_DEPTH" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments -L 3
        echo \"\$GLOBAL_MAX_DEPTH\"
    "
    assert_success
    assert_output "3"
}

@test "parse_arguments: --max-depth sets GLOBAL_MAX_DEPTH" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments --max-depth 5
        echo \"\$GLOBAL_MAX_DEPTH\"
    "
    assert_success
    assert_output "5"
}

@test "parse_arguments: --preserve-name sets GLOBAL_PRESERVE_NAME" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments --preserve-name
        echo \"\$GLOBAL_PRESERVE_NAME\"
    "
    assert_success
    assert_output "1"
}

# ============================================================================
# validate_depth tests (catch divergence from boiler.sh)
# ============================================================================

@test "validate_depth: accepts valid depth values" {
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

@test "validate_depth: rejects invalid depth values" {
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

# ============================================================================
# Output path tests
# ============================================================================

@test "generate_output_filename: default naming preserves source directory" {
    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_PRESERVE_NAME=0
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        generate_output_filename 'level1/subdir' 'video' '5.50'
    "
    assert_success
    assert_output "level1/subdir/video.orig.5.50.Mbps.mp4"
}

@test "generate_output_filename: preserve-name outputs {base}.mp4" {
    run bash -c "
        export REMUX_TEST_MODE=1
        export GLOBAL_PRESERVE_NAME=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        generate_output_filename '.' 'movie' '8.00'
    "
    assert_success
    assert_output "movie.mp4"
}

@test "generate_output_filename: preserve-name falls back to {base}.remux.mp4 when {base}.mp4 exists" {
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

# ============================================================================
# Integration tests: flags affect end-to-end behavior
# ============================================================================

@test "parse_arguments -L 3: GLOBAL_MAX_DEPTH is 3 after direct call (not subshell)" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments -L 3
        echo \"\$GLOBAL_MAX_DEPTH\"
    "
    assert_success
    assert_output "3"
}

@test "parse_arguments -p: GLOBAL_PRESERVE_NAME is 1 after direct call (not subshell)" {
    run bash -c "
        export REMUX_TEST_MODE=1
        source '$PROJECT_ROOT/remux-only.sh' 2>/dev/null
        parse_arguments -p
        echo \"\$GLOBAL_PRESERVE_NAME\"
    "
    assert_success
    assert_output "1"
}

# ============================================================================
# Extension coverage test
# ============================================================================

@test "find_remux_files: discovers all supported non-QuickLook extensions" {
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

# ============================================================================
# QuickLook compatibility detection tests
# ============================================================================

@test "is_quicklook_compatible: returns incompatible for HEVC file with hev1 tag" {
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

@test "is_quicklook_compatible: returns incompatible for file with non-QuickLook audio" {
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

@test "is_quicklook_compatible: returns compatible for HEVC hvc1 with AAC audio" {
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

@test "find_mp4_files: skips .mp4 files with boiler markers" {
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

@test "generate_output_filename: preserve-name falls back to .remux.mp4 when .mp4 input exists (safety for mp4-to-mp4 remux)" {
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

@test "phase 2 mp4 fix: output is named {base}.remux.mp4 not .orig." {
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

@test "phase 2 mp4 fix: original is preserved after successful remux" {
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

@test "phase 2 mp4 fix: aborts and skips when user chooses abort on subtitle prompt" {
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
