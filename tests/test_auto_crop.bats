#!/usr/bin/env bats
# Tests for --auto-crop / --crop-detect-only: black bar detection and its integration
# with the transcoding flow. See plans/in-progress/AUTO-CROP-FEATURE-PLAN.md

bats_require_minimum_version 1.5.0
load 'helpers/setup'

# Small synthetic clips (generated once per file, no binaries in testdata/).
# All are 320x240; "content" is testsrc2 so the active picture is clearly non-black.
setup_file() {
    FIX="$BATS_FILE_TMPDIR/fixtures"
    mkdir -p "$FIX"
    local enc=(-c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 10)
    local common=(-v error -y -f lavfi)

    # Letterbox: 320x180 content, bars 30 lines top and bottom -> crop=320:180:0:30
    ffmpeg "${common[@]}" -i "testsrc2=s=320x180:r=5:d=40,pad=320:240:0:30:black" "${enc[@]}" "$FIX/letterbox.mp4"
    # Pillarbox: 240x240 content, bars 40 columns left and right -> crop=240:240:40:0
    ffmpeg "${common[@]}" -i "testsrc2=s=240x240:r=5:d=40,pad=320:240:40:0:black" "${enc[@]}" "$FIX/pillarbox.mp4"
    # Full frame: no bars
    ffmpeg "${common[@]}" -i "testsrc2=s=320x240:r=5:d=40" "${enc[@]}" "$FIX/full.mp4"
    # Tiny bars: 2 lines top and bottom (~1.7% of frame) -> below the 3% minimum
    ffmpeg "${common[@]}" -i "testsrc2=s=320x236:r=5:d=40,pad=320:240:0:2:black" "${enc[@]}" "$FIX/tinybars.mp4"
    # Dark first half (all black) then letterboxed content: union must recover the letterbox crop
    ffmpeg "${common[@]}" -i "color=c=black:s=320x240:r=5:d=20" \
        -f lavfi -i "testsrc2=s=320x180:r=5:d=20,pad=320:240:0:30:black" \
        -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0" "${enc[@]}" "$FIX/dark_then_letterbox.mp4"
    # Variable aspect: letterboxed first half, full frame second half -> union is the whole frame
    ffmpeg "${common[@]}" -i "testsrc2=s=320x180:r=5:d=20,pad=320:240:0:30:black" \
        -f lavfi -i "testsrc2=s=320x240:r=5:d=20" \
        -filter_complex "[0:v][1:v]concat=n=2:v=1:a=0" "${enc[@]}" "$FIX/variable_aspect.mp4"
    # Letterbox with bright "subtitle" in the top bar for the whole clip -> crop must not cut it
    ffmpeg "${common[@]}" -i "testsrc2=s=320x180:r=5:d=40,pad=320:240:0:30:black,drawbox=x=100:y=0:w=120:h=20:color=white:t=fill" \
        "${enc[@]}" "$FIX/burned_subs.mp4"
    # Short letterboxed clip (shorter than windows x seconds): whole-file single window
    ffmpeg "${common[@]}" -i "testsrc2=s=320x180:r=5:d=6,pad=320:240:0:30:black" "${enc[@]}" "$FIX/short_letterbox.mp4"
    # 10-bit letterbox: black is 64 here, so an unscaled integer cropdetect limit finds no bars
    ffmpeg "${common[@]}" -i "testsrc2=s=320x180:r=5:d=40,pad=320:240:0:30:black" \
        -c:v libx264 -preset ultrafast -pix_fmt yuv420p10le -g 10 "$FIX/letterbox_10bit.mp4"
}

setup() {
    common_setup
    FIX="$BATS_FILE_TMPDIR/fixtures"
}

teardown() {
    common_teardown
}

# Run a boiler.sh function against real ffmpeg (no mocks): sources boiler.sh in a fresh shell
real() {
    local func_name="$1"
    shift
    bash -c "
        export BOILER_TEST_MODE=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        $func_name \"\$@\"
    " -- "$@"
}

# Run the real get_video_dimensions() with ffprobe stubbed to print the given text
# (the shared mocks replace get_video_dimensions() itself, so source boiler.sh fresh)
real_with_ffprobe_output() {
    FAKE_FFPROBE_OUTPUT="$1" bash -c "
        export BOILER_TEST_MODE=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        ffprobe() { printf '%s' \"\$FAKE_FFPROBE_OUTPUT\"; }
        get_video_dimensions whatever.mp4
    "
}

# ============================================================================
# parse_cropdetect_output()
# ============================================================================

@test "parse_cropdetect_output: returns the last crop= value" {
    local out
    out=$'[Parsed_cropdetect_0 @ 0x1] x1:0 crop=1920:816:0:132\n[Parsed_cropdetect_0 @ 0x1] x1:0 crop=1920:800:0:140\nframe=1'
    run parse_cropdetect_output "$out"
    assert_success
    assert_output "1920:800:0:140"
}

@test "parse_cropdetect_output: empty when there is no crop line" {
    run parse_cropdetect_output "ffmpeg: Invalid data found when processing input"
    assert_success
    assert_output ""
}

@test "parse_cropdetect_output: ignores malformed crop= lines" {
    local out
    for out in "crop=1920:808:0:" "crop=::: " "crop=1920:808:0" "crop=abc:808:0:136" "crop=-8:808:0:136"; do
        run parse_cropdetect_output "[Parsed_cropdetect_0 @ 0x1] x1:0 $out"
        assert_success
        assert_output ""
    done
}

@test "parse_cropdetect_output: falls back to the last valid line when the final one is garbled" {
    local out
    out=$'[Parsed_cropdetect_0 @ 0x1] crop=1920:800:0:140\n[Parsed_cropdetect_0 @ 0x1] crop=1920:80'
    run parse_cropdetect_output "$out"
    assert_output "1920:800:0:140"
}

@test "parse_cropdetect_output: tolerates CRLF line endings" {
    run parse_cropdetect_output $'[Parsed_cropdetect_0 @ 0x1] crop=1920:800:0:140\r\n'
    assert_output "1920:800:0:140"
}

@test "crop_removed_pct: warns and reports 0.0 for non-numeric input instead of a bc error" {
    run --separate-stderr crop_removed_pct "1920::0:140" 1920 1080
    assert_success
    assert_output "0.0"
    [[ "$stderr" == *"Cannot compute removed area"* ]]
    [[ "$stderr" != *"Parse error"* ]]
    run --separate-stderr crop_removed_pct "1920:800:0:140" "" 1080
    assert_output "0.0"
    [[ "$stderr" == *"Cannot compute removed area"* ]]
    [[ "$stderr" != *"Parse error"* ]]
}

@test "detect_black_bars: non-numeric duration or frame size warns and does not crop" {
    run --separate-stderr detect_black_bars "$FIX/letterbox.mp4" "N/A" 320 240
    assert_success
    assert_output ""
    [[ "$stderr" == *"Unusable duration 'N/A'"* ]]
    [[ "$stderr" != *"Parse error"* ]]
    run --separate-stderr detect_black_bars "$FIX/letterbox.mp4" 40 "" 240
    assert_output ""
    [[ "$stderr" == *"Unusable frame size"* ]]
    [[ "$stderr" != *"Parse error"* ]]
}

@test "detect_black_bars: CROP_DEBUG=1 prints each window and the union" {
    CROP_DEBUG=1 CROP_SAMPLE_WINDOWS=3 run --separate-stderr real detect_black_bars "$FIX/letterbox.mp4" 40 320 240
    assert_output "320:180:0:30"
    [[ "$stderr" == *"[crop-debug] window 1/3"* ]]
    [[ "$stderr" == *"[crop-debug] union=320:180:0:30"* ]]
}

# ============================================================================
# get_video_dimensions()
# ============================================================================

@test "get_video_dimensions: returns 'WIDTH HEIGHT' for a real file" {
    run real get_video_dimensions "$FIX/letterbox.mp4"
    assert_success
    assert_output "320 240"
}

@test "get_video_dimensions: ignores extra output and CRLF (no stray separators)" {
    # Real-world regression: streams with side data (e.g. Dolby Vision) made the old CSV
    # parser return "3840 2160x", which bc rejected with "Parse error: bad expression".
    run real_with_ffprobe_output $'width=3840\r\nheight=2160\r\n[SIDE_DATA]\r\n'
    assert_output "3840 2160"
}

@test "get_video_dimensions: empty when ffprobe gives nothing usable" {
    run real_with_ffprobe_output $'width=N/A\nheight=\n'
    assert_success
    assert_output ""
}

# ============================================================================
# combine_crop_boxes()
# ============================================================================

@test "combine_crop_boxes: single box is returned unchanged" {
    run combine_crop_boxes "1920:800:0:140"
    assert_output "1920:800:0:140"
}

@test "combine_crop_boxes: union takes the widest extent in every direction" {
    # box A: x 0-1920, y 140-940   box B: x 100-1900, y 100-900
    run combine_crop_boxes "1920:800:0:140" "1800:800:100:100"
    assert_output "1920:840:0:100"
}

@test "combine_crop_boxes: a full-frame box makes the union full-frame" {
    run combine_crop_boxes "1920:800:0:140" "1920:1080:0:0"
    assert_output "1920:1080:0:0"
}

@test "combine_crop_boxes: no boxes gives empty output" {
    run combine_crop_boxes
    assert_output ""
}

# ============================================================================
# crop_removed_pct()
# ============================================================================

@test "crop_removed_pct: 1920x800 out of 1920x1080 removes 25.9%" {
    run crop_removed_pct "1920:800:0:140" 1920 1080
    assert_output "25.9"
}

@test "crop_removed_pct: full frame removes 0.0%" {
    run crop_removed_pct "1920:1080:0:0" 1920 1080
    assert_output "0.0"
}

# ============================================================================
# validate_crop_params()
# ============================================================================

@test "validate_crop_params: accepts a normal letterbox crop" {
    run validate_crop_params "1920:800:0:140" 1920 1080
    assert_success
}

@test "validate_crop_params: rejects odd values" {
    run validate_crop_params "1919:800:0:140" 1920 1080
    assert_failure
    assert_output --partial "even"
}

@test "validate_crop_params: rejects odd offsets" {
    run validate_crop_params "1920:800:0:141" 1920 1080
    assert_failure
}

@test "validate_crop_params: rejects results under 16 pixels" {
    run validate_crop_params "8:800:0:140" 1920 1080
    assert_failure
}

@test "validate_crop_params: rejects crops that remove more than half the frame" {
    run validate_crop_params "1920:400:0:340" 1920 1080
    assert_failure
    assert_output --partial "more than half"
}

@test "validate_crop_params: rejects crops outside the frame" {
    run validate_crop_params "1920:800:0:400" 1920 1080
    assert_failure
    assert_output --partial "outside"
}

@test "validate_crop_params: rejects malformed input" {
    run validate_crop_params "1920:800" 1920 1080
    assert_failure
}

# ============================================================================
# Argument parsing
# ============================================================================

@test "parse_arguments: --auto-crop enables auto-crop only" {
    parse_arguments --auto-crop
    assert_equal "$AUTO_CROP" "1"
    assert_equal "$CROP_DETECT_ONLY" "0"
}

@test "parse_arguments: --crop-detect-only implies auto-crop" {
    parse_arguments --crop-detect-only
    assert_equal "$AUTO_CROP" "1"
    assert_equal "$CROP_DETECT_ONLY" "1"
}

@test "parse_arguments: auto-crop is off by default" {
    parse_arguments -L 1
    assert_equal "$AUTO_CROP" "0"
    assert_equal "$CROP_DETECT_ONLY" "0"
}

@test "show_usage: documents the crop flags" {
    run show_usage
    assert_output --partial "--auto-crop"
    assert_output --partial "--crop-detect-only"
}

# ============================================================================
# detect_black_bars() against real ffmpeg and generated fixtures
# ============================================================================

@test "detect_black_bars: finds letterbox" {
    run real detect_black_bars "$FIX/letterbox.mp4" 40 320 240
    assert_success
    assert_output "320:180:0:30"
}

@test "detect_black_bars: finds pillarbox" {
    run real detect_black_bars "$FIX/pillarbox.mp4" 40 320 240
    assert_success
    assert_output "240:240:40:0"
}

@test "detect_black_bars: full-frame video has no crop" {
    run real detect_black_bars "$FIX/full.mp4" 40 320 240
    assert_success
    assert_output --partial "No significant black bars"
    refute_output --regexp '^[0-9]+:[0-9]+:[0-9]+:[0-9]+$'
}

@test "detect_black_bars: bars below the minimum are ignored" {
    run real detect_black_bars "$FIX/tinybars.mp4" 40 320 240
    assert_success
    assert_output --partial "No significant black bars"
}

@test "detect_black_bars: dark scenes do not cause over-cropping" {
    run real detect_black_bars "$FIX/dark_then_letterbox.mp4" 40 320 240
    assert_success
    assert_output --partial "320:180:0:30"
}

@test "detect_black_bars: variable aspect ratio uses the most conservative crop" {
    run real detect_black_bars "$FIX/variable_aspect.mp4" 40 320 240
    assert_success
    assert_output --partial "No significant black bars"
}

@test "detect_black_bars: burned-in text in a bar is not cropped away" {
    run real detect_black_bars "$FIX/burned_subs.mp4" 40 320 240
    assert_success
    # Top edge extends to the text (y=0); only the bottom bar is removed
    assert_output "320:210:0:0"
}

@test "detect_black_bars: short video is scanned as a single whole-file window" {
    run real detect_black_bars "$FIX/short_letterbox.mp4" 6 320 240
    assert_success
    assert_output "320:180:0:30"
}

@test "detect_black_bars: finds the same letterbox in 10-bit video (limit scales with bit depth)" {
    # Real-world regression: limit=24 is below 10-bit black (64), so a 10-bit letterboxed
    # source was reported as full frame and re-encoded with the bars still in.
    run real detect_black_bars "$FIX/letterbox_10bit.mp4" 40 320 240
    assert_success
    assert_output "320:180:0:30"
}

@test "detect_black_bars: non-numeric CROP_LIMIT warns and does not crop" {
    CROP_LIMIT=abc run --separate-stderr real detect_black_bars "$FIX/letterbox.mp4" 40 320 240
    assert_success
    assert_output ""
    [[ "$stderr" == *"Invalid CROP_LIMIT"* ]]
}

@test "detect_black_bars: stdout carries only the crop (diagnostics go to stderr)" {
    local out
    out=$(real detect_black_bars "$FIX/letterbox.mp4" 40 320 240 2>/dev/null)
    assert_equal "$out" "320:180:0:30"
}

@test "detect_black_bars: respects CROP_MIN_REMOVED_PCT" {
    CROP_MIN_REMOVED_PCT=30 run real detect_black_bars "$FIX/letterbox.mp4" 40 320 240
    assert_success
    assert_output --partial "No significant black bars"
}

# ============================================================================
# detect_crop_for_file() (mocked probes)
# ============================================================================

@test "detect_crop_for_file: sets CROP_PARAMS from detection" {
    detect_black_bars() { echo "1920:800:0:140"; }
    detect_crop_for_file "video.mp4" 300 2>/dev/null
    assert_equal "$CROP_PARAMS" "1920:800:0:140"
}

@test "detect_crop_for_file: leaves CROP_PARAMS empty when no crop applies" {
    detect_black_bars() { echo ""; }
    CROP_PARAMS="stale"
    detect_crop_for_file "video.mp4" 300 2>/dev/null
    assert_equal "$CROP_PARAMS" ""
}

@test "detect_crop_for_file: skips rotation-tagged files with a warning" {
    detect_black_bars() { echo "1920:800:0:140"; }
    MOCK_ROTATION=90
    run detect_crop_for_file "video.mp4" 300
    assert_success
    assert_output --partial "rotation"
    detect_crop_for_file "video.mp4" 300 2>/dev/null
    assert_equal "$CROP_PARAMS" ""
}

@test "get_video_rotation: real fixtures report 0" {
    run real get_video_rotation "$FIX/letterbox.mp4"
    assert_output "0"
}

# ============================================================================
# transcode_sample() / transcode_full_video() apply the crop filter
# ============================================================================

# Run a real encode function with ffmpeg stubbed to record its arguments
# $1 = CROP_PARAMS value, $2 = function name, remaining = function args
run_encode_with_stub() {
    local crop="$1" func_name="$2"
    shift 2
    ARGS_FILE="$TEST_TMPDIR/ffmpeg_args"
    bash -c "
        set +e
        export BOILER_TEST_MODE=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        CROP_PARAMS='$crop'
        ffmpeg() { printf '%s\n' \"\$*\" > '$ARGS_FILE'; echo data > '$TEST_TMPDIR/out.mp4'; }
        ffprobe() {
            if [[ \"\$*\" == *codec_name* ]] && [[ \"\$*\" == *select_streams\ a* ]]; then echo aac
            elif [[ \"\$*\" == *codec_name* ]]; then echo h264
            elif [[ \"\$*\" == *csv=p=0* ]]; then echo 1
            else echo ''; fi
        }
        $func_name \"\$@\"
    " -- "$@"
}

@test "transcode_sample: adds crop filter when CROP_PARAMS is set" {
    touch "$TEST_TMPDIR/in.mp4"
    run run_encode_with_stub "1920:800:0:140" transcode_sample "$TEST_TMPDIR/in.mp4" 10 5 60 "$TEST_TMPDIR/out.mp4"
    assert_success
    run cat "$TEST_TMPDIR/ffmpeg_args"
    assert_output --partial "-vf crop=1920:800:0:140"
}

@test "transcode_sample: no filter when CROP_PARAMS is empty" {
    touch "$TEST_TMPDIR/in.mp4"
    run run_encode_with_stub "" transcode_sample "$TEST_TMPDIR/in.mp4" 10 5 60 "$TEST_TMPDIR/out.mp4"
    assert_success
    run cat "$TEST_TMPDIR/ffmpeg_args"
    refute_output --partial "-vf"
}

@test "transcode_full_video: adds crop filter when CROP_PARAMS is set" {
    touch "$TEST_TMPDIR/in.mp4"
    run run_encode_with_stub "1920:800:0:140" transcode_full_video "$TEST_TMPDIR/in.mp4" "$TEST_TMPDIR/out.mp4" 60
    assert_success
    run cat "$TEST_TMPDIR/ffmpeg_args"
    assert_output --partial "-vf crop=1920:800:0:140"
}

@test "transcode_full_video: no filter when CROP_PARAMS is empty" {
    touch "$TEST_TMPDIR/in.mp4"
    run run_encode_with_stub "" transcode_full_video "$TEST_TMPDIR/in.mp4" "$TEST_TMPDIR/out.mp4" 60
    assert_success
    run cat "$TEST_TMPDIR/ffmpeg_args"
    refute_output --partial "-vf"
}

# ============================================================================
# verify_crop_output()
# ============================================================================

@test "verify_crop_output: passes when dimensions match the crop" {
    MOCK_OUTPUT_DIMS="1920 800"
    run verify_crop_output "x_temp_transcode.mp4" "1920:800:0:140"
    assert_success
}

@test "verify_crop_output: fails when dimensions differ" {
    MOCK_OUTPUT_DIMS="1920 1080"
    run verify_crop_output "x_temp_transcode.mp4" "1920:800:0:140"
    assert_failure
    assert_output --partial "expected 1920x800"
}

# ============================================================================
# transcode_video() integration with a detected crop (mocked encodes)
# ============================================================================

crop_test_setup() {
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"
    touch "test_video.mp4"
    MOCK_VIDEO_FILE="test_video.mp4"
    MOCK_RESOLUTION=1080
    MOCK_DURATION=300
    MOCK_OUTPUT_DIMS="1920 800"
    MOCK_OUTPUT_BITRATE_BPS=8000000
    MOCK_SAMPLE_BITRATE_BPS=8000000
    AUTO_CROP=1
    detect_black_bars() { echo "1920:800:0:140"; }
}

crop_test_teardown() {
    cd "$PROJECT_ROOT"
    [ -n "${TEST_DIR:-}" ] && rm -rf "$TEST_DIR"
}

@test "transcode_video: source within tolerance is still re-encoded when a crop is detected" {
    crop_test_setup
    MOCK_BITRATE_BPS=8000000
    run transcode_video "test_video.mp4"
    assert_success
    assert_output --partial "Re-encoding to apply crop"
    refute_output --partial "No transcoding needed"
    assert_file_exists "test_video.fmpg.8.00.Mbps.mp4"
    assert_file_not_exists "test_video.orig.8.00.Mbps.mp4"
    crop_test_teardown
}

@test "transcode_video: source below target is re-encoded with the source bitrate as target" {
    crop_test_setup
    MOCK_BITRATE_BPS=3000000
    MOCK_OUTPUT_BITRATE_BPS=3000000
    MOCK_SAMPLE_BITRATE_BPS=3000000
    run transcode_video "test_video.mp4"
    assert_success
    assert_output --partial "using source bitrate"
    assert_output --partial "Re-encoding to apply crop"
    assert_file_exists "test_video.fmpg.3.00.Mbps.mp4"
    crop_test_teardown
}

@test "transcode_video: explicit target bitrate is never replaced by the source bitrate" {
    crop_test_setup
    MOCK_BITRATE_BPS=3000000
    MOCK_OUTPUT_BITRATE_BPS=9500000
    MOCK_SAMPLE_BITRATE_BPS=9500000
    run transcode_video "test_video.mp4" "9.5"
    assert_success
    refute_output --partial "using source bitrate"
    assert_output --partial "Target bitrate (override): 9.5 Mbps"
    crop_test_teardown
}

@test "transcode_video: resolution tier comes from the pre-crop height" {
    crop_test_setup
    MOCK_BITRATE_BPS=20000000
    run transcode_video "test_video.mp4"
    assert_success
    # 1920x800 content would be the 720p tier (5 Mbps); the tier must stay 1080p (8 Mbps)
    assert_output --partial "Target bitrate: 8 Mbps (1080p)"
    refute_output --partial "(720p)"
    crop_test_teardown
}

@test "transcode_video: without a detected crop, within-tolerance source is still skipped" {
    crop_test_setup
    detect_black_bars() { echo ""; }
    MOCK_BITRATE_BPS=8000000
    run transcode_video "test_video.mp4"
    assert_success
    assert_output --partial "No transcoding needed"
    assert_equal "$(get_call_count "$TRANSCODE_FULL_CALLS_FILE")" "0"
    crop_test_teardown
}

@test "transcode_video: crop detection does not run without --auto-crop" {
    crop_test_setup
    AUTO_CROP=0
    detect_black_bars() { echo "detection ran" >> "$TEST_DIR/detect_called"; echo "1920:800:0:140"; }
    MOCK_BITRATE_BPS=8000000
    run transcode_video "test_video.mp4"
    assert_success
    assert_output --partial "No transcoding needed"
    assert_file_not_exists "$TEST_DIR/detect_called"
    crop_test_teardown
}

@test "transcode_video: fails and removes the temp file when output size is not the cropped size" {
    crop_test_setup
    MOCK_BITRATE_BPS=20000000
    MOCK_OUTPUT_DIMS="1920 1080"
    run transcode_video "test_video.mp4"
    assert_failure
    assert_output --partial "expected 1920x800"
    assert_file_not_exists "test_video_temp_transcode.mp4"
    crop_test_teardown
}

@test "transcode_video: crop from one file does not leak into the next" {
    crop_test_setup
    MOCK_BITRATE_BPS=20000000
    touch "second.mp4"
    detect_black_bars() { [[ "$1" == *second* ]] && echo "" || echo "1920:800:0:140"; }
    run transcode_video "test_video.mp4"
    assert_success
    # Same shell for the second call so a leaked CROP_PARAMS would be visible
    transcode_video "test_video.mp4" > /dev/null 2>&1
    assert_equal "$CROP_PARAMS" "1920:800:0:140"
    MOCK_BITRATE_BPS=8000000
    transcode_video "second.mp4" > /dev/null 2>&1
    assert_equal "$CROP_PARAMS" ""
    crop_test_teardown
}

# ============================================================================
# Pre-processing: files that need a crop are not remuxed
# ============================================================================

@test "preprocess: mkv within tolerance is remuxed when no crop is detected" {
    crop_test_setup
    rm -f test_video.mp4
    touch movie.mkv
    MOCK_BITRATE_BPS=8000000
    detect_black_bars() { echo ""; }
    preprocess_non_quicklook_files > /dev/null 2>&1 || true
    assert_equal "$(get_call_count "$REMUX_CALLS_FILE")" "1"
    crop_test_teardown
}

@test "preprocess: mkv within tolerance is left alone for re-encoding when a crop is detected" {
    crop_test_setup
    rm -f test_video.mp4
    touch movie.mkv
    MOCK_BITRATE_BPS=8000000
    run preprocess_non_quicklook_files
    assert_output --partial "skipping remux"
    assert_equal "$(get_call_count "$REMUX_CALLS_FILE")" "0"
    assert_file_exists "movie.mkv"
    crop_test_teardown
}

@test "detect_crop_for_file: says whole video for short files, window count for long ones" {
    run real detect_crop_for_file "$FIX/short_letterbox.mp4" 6
    assert_success
    assert_output --partial "scanning the whole video"
    refute_output --partial "12 windows"
    run real detect_crop_for_file "$FIX/letterbox.mp4" 40
    assert_success
    assert_output --partial "12 windows"
    refute_output --partial "whole video"
}

# ============================================================================
# --crop-detect-only
# ============================================================================

@test "main: --crop-detect-only reports crops and changes nothing" {
    crop_test_setup
    CROP_DETECT_ONLY=1
    MOCK_BITRATE_BPS=8000000
    run main
    assert_success
    assert_output --partial "Crop detected"
    assert_output --partial "crop=1920:800:0:140"
    assert_equal "$(get_call_count "$TRANSCODE_SAMPLE_CALLS_FILE")" "0"
    assert_equal "$(get_call_count "$TRANSCODE_FULL_CALLS_FILE")" "0"
    assert_equal "$(get_call_count "$REMUX_CALLS_FILE")" "0"
    assert_file_exists "test_video.mp4"
    crop_test_teardown
}
