#!/usr/bin/env bats
# Tests for is_non_quicklook_format() and is_codec_mp4_compatible() functions
# Ported from test_boiler.sh

load 'helpers/setup'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# ============================================================================
# is_non_quicklook_format() tests
# Returns 0 (success) for non-QuickLook formats, 1 (failure) for compatible formats
# ============================================================================

@test "is_non_quicklook_format: mkv is non-QuickLook format" {
    run is_non_quicklook_format "video.mkv"
    assert_success
}

@test "is_non_quicklook_format: wmv is non-QuickLook format (case insensitive)" {
    run is_non_quicklook_format "video.WMV"
    assert_success
}

@test "is_non_quicklook_format: avi is non-QuickLook format" {
    run is_non_quicklook_format "video.avi"
    assert_success
}

@test "is_non_quicklook_format: webm is non-QuickLook format" {
    run is_non_quicklook_format "video.webm"
    assert_success
}

@test "is_non_quicklook_format: flv is non-QuickLook format" {
    run is_non_quicklook_format "video.flv"
    assert_success
}

@test "is_non_quicklook_format: mpg is non-QuickLook format" {
    run is_non_quicklook_format "video.mpg"
    assert_success
}

@test "is_non_quicklook_format: mpeg is non-QuickLook format" {
    run is_non_quicklook_format "video.mpeg"
    assert_success
}

@test "is_non_quicklook_format: ts is non-QuickLook format" {
    run is_non_quicklook_format "video.ts"
    assert_success
}

@test "is_non_quicklook_format: mp4 is QuickLook compatible" {
    run is_non_quicklook_format "video.mp4"
    assert_failure
}

@test "is_non_quicklook_format: mov is QuickLook compatible" {
    run is_non_quicklook_format "video.mov"
    assert_failure
}

@test "is_non_quicklook_format: m4v is QuickLook compatible" {
    run is_non_quicklook_format "video.m4v"
    assert_failure
}

# ============================================================================
# is_codec_mp4_compatible() tests
# Returns 0 (success) for compatible codecs, 1 (failure) for incompatible
# ============================================================================

@test "is_codec_mp4_compatible: h264 is compatible" {
    run is_codec_mp4_compatible "h264"
    assert_success
}

@test "is_codec_mp4_compatible: hevc is compatible (case insensitive)" {
    run is_codec_mp4_compatible "HEVC"
    assert_success
}

@test "is_codec_mp4_compatible: h265 is compatible" {
    run is_codec_mp4_compatible "h265"
    assert_success
}

@test "is_codec_mp4_compatible: mpeg4 is compatible" {
    run is_codec_mp4_compatible "mpeg4"
    assert_success
}

@test "is_codec_mp4_compatible: avc1 is compatible" {
    run is_codec_mp4_compatible "avc1"
    assert_success
}

@test "is_codec_mp4_compatible: wmv3 is incompatible" {
    run is_codec_mp4_compatible "wmv3"
    assert_failure
}

@test "is_codec_mp4_compatible: wmv1 is incompatible (case insensitive)" {
    run is_codec_mp4_compatible "WMV1"
    assert_failure
}

@test "is_codec_mp4_compatible: vc1 is incompatible" {
    run is_codec_mp4_compatible "vc1"
    assert_failure
}

@test "is_codec_mp4_compatible: rv40 is incompatible" {
    run is_codec_mp4_compatible "rv40"
    assert_failure
}

@test "is_codec_mp4_compatible: unknown codec assumes compatible" {
    run is_codec_mp4_compatible "unknown_codec"
    assert_success
}

# ============================================================================
# is_mkv_file() tests
# Returns 0 (success) for MKV files, 1 (failure) for non-MKV files
# ============================================================================

@test "is_mkv_file: detects lowercase .mkv" {
    run is_mkv_file "video.mkv"
    assert_success
}

@test "is_mkv_file: detects uppercase .MKV" {
    run is_mkv_file "video.MKV"
    assert_success
}

@test "is_mkv_file: detects mixed case .Mkv" {
    run is_mkv_file "video.Mkv"
    assert_success
}

@test "is_mkv_file: rejects .mp4" {
    run is_mkv_file "video.mp4"
    assert_failure
}

@test "is_mkv_file: rejects .avi" {
    run is_mkv_file "video.avi"
    assert_failure
}

@test "is_mkv_file: rejects .mov" {
    run is_mkv_file "video.mov"
    assert_failure
}
