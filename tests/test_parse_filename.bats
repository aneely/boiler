#!/usr/bin/env bats
# Tests for parse_filename() function
# Ported from test_boiler.sh

load 'helpers/setup'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# ============================================================================
# parse_filename() tests
# Note: parse_filename sets global variables BASE_NAME and FILE_EXTENSION
# ============================================================================

@test "parse_filename: parses simple filename correctly" {
    parse_filename "video.mp4"
    assert_equal "$BASE_NAME" "video"
    assert_equal "$FILE_EXTENSION" "mp4"
}

@test "parse_filename: handles filename with multiple dots" {
    parse_filename "my.video.file.mkv"
    assert_equal "$BASE_NAME" "my.video.file"
    assert_equal "$FILE_EXTENSION" "mkv"
}

@test "parse_filename: handles path with extension" {
    parse_filename "/path/to/video.avi"
    assert_equal "$BASE_NAME" "/path/to/video"
    assert_equal "$FILE_EXTENSION" "avi"
}

@test "parse_filename: handles filename without extension" {
    parse_filename "noextension"
    assert_equal "$BASE_NAME" "noextension"
    assert_equal "$FILE_EXTENSION" "noextension"
}
