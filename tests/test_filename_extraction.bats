#!/usr/bin/env bats
# Tests for extract_original_filename() and related matching functions
# Ported from test_boiler.sh

load 'helpers/setup'

setup() {
    common_setup
    TEST_DIR=$(mktemp -d)
}

teardown() {
    common_teardown
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}

# Helper to run boiler.sh functions in isolation
run_boiler_func() {
    local func_name="$1"
    shift
    bash -c "
        export BOILER_TEST_MODE=1
        source '$PROJECT_ROOT/boiler.sh' 2>/dev/null
        $func_name \"\$@\"
    " -- "$@"
}

# ============================================================================
# extract_original_filename() tests
# ============================================================================

@test "extract_original_filename: extracts from .fmpg. pattern" {
    run run_boiler_func extract_original_filename "video.fmpg.10.25.Mbps.mp4"
    assert_success
    assert_output "video.mp4"
}

@test "extract_original_filename: extracts from .orig. pattern" {
    run run_boiler_func extract_original_filename "video.orig.2.90.Mbps.mp4"
    assert_success
    assert_output "video.mp4"
}

@test "extract_original_filename: extracts from .hbrk. pattern" {
    run run_boiler_func extract_original_filename "video.hbrk.10.25.Mbps.mp4"
    assert_success
    assert_output "video.mp4"
}

# ============================================================================
# has_original_file() tests
# ============================================================================

@test "has_original_file: detects original when it exists" {
    cd "$TEST_DIR"
    touch video.mp4 video.fmpg.10.25.Mbps.mp4
    
    run run_boiler_func has_original_file "video.fmpg.10.25.Mbps.mp4"
    assert_success
}

@test "has_original_file: detects missing original" {
    cd "$TEST_DIR"
    touch video.fmpg.10.25.Mbps.mp4
    # No video.mp4 exists
    
    run run_boiler_func has_original_file "video.fmpg.10.25.Mbps.mp4"
    assert_failure
}

# ============================================================================
# has_encoded_version() tests
# ============================================================================

@test "has_encoded_version: detects encoded version when it exists" {
    cd "$TEST_DIR"
    touch video.mp4 video.fmpg.10.25.Mbps.mp4
    
    run run_boiler_func has_encoded_version "video.mp4"
    assert_success
}

@test "has_encoded_version: detects when no encoded version exists" {
    cd "$TEST_DIR"
    touch video.mp4
    # No encoded version exists
    
    run run_boiler_func has_encoded_version "video.mp4"
    assert_failure
}

# Names with glob characters: find -iname treats the pattern as a glob, so unescaped
# brackets/backslashes made these files never match their own encoded copy.
@test "has_encoded_version: detects encoded copy for names with glob characters" {
    cd "$TEST_DIR"
    local name
    for name in 'Movie [2024]' '[1080p] Title' 'a*b' 'what?' 'back\slash' 'mix [a]*?\z' 'with space' "it's (2024)"; do
        rm -f ./*
        touch "$name.mp4" "$name.fmpg.6.05.Mbps.mp4"
        run run_boiler_func has_encoded_version "$name.mp4"
        [ "$status" -eq 0 ] || { echo "not detected: $name"; return 1; }
        run run_boiler_func should_skip_file "./$name.mp4"
        [ "$status" -eq 0 ] || { echo "not skipped: $name"; return 1; }
    done
}

@test "has_encoded_version: glob characters in a name do not match unrelated files" {
    cd "$TEST_DIR"
    # "[ab]" must not act as a character class that matches the file "a.fmpg..." of another video
    touch "[ab].mp4" "a.fmpg.6.05.Mbps.mp4"
    run run_boiler_func has_encoded_version "[ab].mp4"
    assert_failure
    touch "a*.mp4" "abc.fmpg.6.05.Mbps.mp4"
    run run_boiler_func has_encoded_version "a*.mp4"
    assert_failure
}

# End to end with the real script: a source next to its finished output must not be
# encoded again, with or without --auto-crop, and nothing on disk may change.
@test "boiler.sh: source with an existing encoded copy is left alone (plain and --auto-crop)" {
    cd "$TEST_DIR"
    local name flags before after out
    for name in 'plain' 'Movie [2024]' 'back\slash'; do
        for flags in "" "--auto-crop"; do
            rm -f ./*
            ffmpeg -v error -y -f lavfi -i "testsrc2=s=320x180:r=5:d=2" -c:v libx264 -pix_fmt yuv420p "$name.mp4"
            cp "$name.mp4" "$name.fmpg.6.05.Mbps.mp4"
            before=$(ls -la | sed 1d | sort)
            out=$(env -u BOILER_TEST_MODE bash "$PROJECT_ROOT/boiler.sh" $flags 2>&1) || true
            after=$(ls -la | sed 1d | sort)
            [[ "$out" == *"No video files to encode"* ]] || { echo "name='$name' flags='$flags': $out"; return 1; }
            [ "$before" = "$after" ] || { echo "files changed for name='$name' flags='$flags'"; return 1; }
        done
    done
}

@test "has_encoded_version: detects .orig. encoded version" {
    cd "$TEST_DIR"
    touch video.mp4 video.orig.5.00.Mbps.mp4
    
    run run_boiler_func has_encoded_version "video.mp4"
    assert_success
}

@test "has_encoded_version: detects .hbrk. encoded version" {
    cd "$TEST_DIR"
    touch video.mp4 video.hbrk.8.00.Mbps.mp4
    
    run run_boiler_func has_encoded_version "video.mp4"
    assert_success
}

@test "has_encoded_version: detects encoded .mp4 when original has non-.mp4 extension" {
    cd "$TEST_DIR"
    touch video.mpg video.fmpg.10.25.Mbps.mp4
    
    run run_boiler_func has_encoded_version "video.mpg"
    assert_success
}
