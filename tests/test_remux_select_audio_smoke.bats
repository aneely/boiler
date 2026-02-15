#!/usr/bin/env bats
# Smoke tests for remux-select-audio.sh (standalone helper script)

# BATS_TEST_FILENAME is the path to this test file (original path, not temp copy)
TESTS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PROJECT_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="${PROJECT_ROOT}/remux-select-audio.sh"

load "$TESTS_DIR/test_helper/bats-support/load"
load "$TESTS_DIR/test_helper/bats-assert/load"

@test "remux-select-audio.sh -h exits 0 and prints usage" {
    run "$SCRIPT" -h
    assert_success
    assert_output --partial "Usage:"
    assert_output --partial "video_file"
}

@test "remux-select-audio.sh with no args exits non-zero" {
    run "$SCRIPT"
    assert_failure
    assert_output --partial "No input file specified"
}

@test "remux-select-audio.sh with one audio track exits 0 and prints nothing-to-do" {
    if ! command -v ffmpeg &> /dev/null || ! command -v ffprobe &> /dev/null; then
        skip "ffmpeg/ffprobe not in PATH"
    fi
    local tmp
    tmp=$(mktemp -d)
    ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 1 -c:a aac -y "${tmp}/one_audio.mp4" 2>/dev/null
    run "$SCRIPT" "${tmp}/one_audio.mp4"
    assert_success
    assert_output --partial "Nothing to do"
    rm -rf "$tmp"
}

@test "remux-select-audio.sh with zero audio tracks exits 0 and prints nothing-to-do" {
    if ! command -v ffmpeg &> /dev/null || ! command -v ffprobe &> /dev/null; then
        skip "ffmpeg/ffprobe not in PATH"
    fi
    local tmp
    tmp=$(mktemp -d)
    ffmpeg -f lavfi -i color=c=black:s=320x240:d=1 -c:v libx264 -y "${tmp}/no_audio.mp4" 2>/dev/null
    run "$SCRIPT" "${tmp}/no_audio.mp4"
    assert_success
    assert_output --partial "Nothing to do"
    rm -rf "$tmp"
}

@test "remux-select-audio.sh keep-all (all selected) exits 0 and does not create remux file" {
    if ! command -v ffmpeg &> /dev/null || ! command -v ffprobe &> /dev/null; then
        skip "ffmpeg/ffprobe not in PATH"
    fi
    local tmp
    tmp=$(mktemp -d)
    # Create MP4 with two audio tracks: video + 2x aac
    ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 1 -c:a aac -y "${tmp}/a1.m4a" 2>/dev/null
    ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 1 -c:a aac -y "${tmp}/a2.m4a" 2>/dev/null
    ffmpeg -f lavfi -i color=c=black:s=320x240:d=1 -i "${tmp}/a1.m4a" -i "${tmp}/a2.m4a" -c:v libx264 -c:a copy -map 0:v -map 1:a -map 2:a -shortest -y "${tmp}/two_audio.mp4" 2>/dev/null
    run bash -c "echo 'all' | $SCRIPT ${tmp}/two_audio.mp4"
    assert_success
    assert_output --partial "Keeping all audio tracks"
    assert_output --partial "nothing to do"
    run test -f "${tmp}/two_audio.remux.mp4"
    assert_failure
    rm -rf "$tmp"
}
