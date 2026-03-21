#!/usr/bin/env bats
# Tests for audio codec MP4 compatibility checking
# is_audio_codec_mp4_compatible() and get_audio_codec_arg()

load 'helpers/setup'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# ============================================================================
# is_audio_codec_mp4_compatible() tests
# Returns 0 (success) for compatible codecs, 1 (failure) for incompatible
# ============================================================================

@test "is_audio_codec_mp4_compatible: aac is compatible" {
    run is_audio_codec_mp4_compatible "aac"
    assert_success
}

@test "is_audio_codec_mp4_compatible: ac3 is compatible" {
    run is_audio_codec_mp4_compatible "ac3"
    assert_success
}

@test "is_audio_codec_mp4_compatible: eac3 is compatible" {
    run is_audio_codec_mp4_compatible "eac3"
    assert_success
}

@test "is_audio_codec_mp4_compatible: mp3 is compatible" {
    run is_audio_codec_mp4_compatible "mp3"
    assert_success
}

@test "is_audio_codec_mp4_compatible: mp2 is compatible" {
    run is_audio_codec_mp4_compatible "mp2"
    assert_success
}

@test "is_audio_codec_mp4_compatible: alac is compatible" {
    run is_audio_codec_mp4_compatible "alac"
    assert_success
}

@test "is_audio_codec_mp4_compatible: flac is compatible" {
    run is_audio_codec_mp4_compatible "flac"
    assert_success
}

@test "is_audio_codec_mp4_compatible: opus is compatible" {
    run is_audio_codec_mp4_compatible "opus"
    assert_success
}

@test "is_audio_codec_mp4_compatible: AAC is compatible (case insensitive)" {
    run is_audio_codec_mp4_compatible "AAC"
    assert_success
}

@test "is_audio_codec_mp4_compatible: wmav2 is incompatible" {
    run is_audio_codec_mp4_compatible "wmav2"
    assert_failure
}

@test "is_audio_codec_mp4_compatible: wmav1 is incompatible" {
    run is_audio_codec_mp4_compatible "wmav1"
    assert_failure
}

@test "is_audio_codec_mp4_compatible: WMAV2 is incompatible (case insensitive)" {
    run is_audio_codec_mp4_compatible "WMAV2"
    assert_failure
}

@test "is_audio_codec_mp4_compatible: vorbis is incompatible" {
    run is_audio_codec_mp4_compatible "vorbis"
    assert_failure
}

@test "is_audio_codec_mp4_compatible: wmalossless is incompatible" {
    run is_audio_codec_mp4_compatible "wmalossless"
    assert_failure
}

@test "is_audio_codec_mp4_compatible: wmapro is incompatible" {
    run is_audio_codec_mp4_compatible "wmapro"
    assert_failure
}

@test "is_audio_codec_mp4_compatible: adpcm_ms is incompatible" {
    run is_audio_codec_mp4_compatible "adpcm_ms"
    assert_failure
}

@test "is_audio_codec_mp4_compatible: unknown codec assumes compatible" {
    run is_audio_codec_mp4_compatible "some_future_codec"
    assert_success
}

# ============================================================================
# get_audio_codec_arg() tests
# Returns "copy" for compatible audio, "aac" for incompatible
# ============================================================================

@test "get_audio_codec_arg: returns copy for aac audio" {
    MOCK_AUDIO_CODEC="aac"
    run get_audio_codec_arg "test.mp4"
    assert_output "copy"
}

@test "get_audio_codec_arg: returns copy for ac3 audio" {
    MOCK_AUDIO_CODEC="ac3"
    run get_audio_codec_arg "test.mp4"
    assert_output "copy"
}

@test "get_audio_codec_arg: returns aac for wmav2 audio" {
    MOCK_AUDIO_CODEC="wmav2"
    run get_audio_codec_arg "test.wmv"
    assert_line "aac"
}

@test "get_audio_codec_arg: returns aac for vorbis audio" {
    MOCK_AUDIO_CODEC="vorbis"
    run get_audio_codec_arg "test.webm"
    assert_line "aac"
}

@test "get_audio_codec_arg: returns aac for wmapro audio" {
    MOCK_AUDIO_CODEC="wmapro"
    run get_audio_codec_arg "test.wmv"
    assert_line "aac"
}

@test "get_audio_codec_arg: returns copy for unknown codec (assumes compatible)" {
    MOCK_AUDIO_CODEC="some_future_codec"
    run get_audio_codec_arg "test.mp4"
    assert_output "copy"
}

@test "get_audio_codec_arg: returns copy when no audio codec detected (empty)" {
    MOCK_AUDIO_CODEC=""
    run get_audio_codec_arg "test.mp4"
    assert_output "copy"
}

@test "get_audio_codec_arg: logs warning when re-encoding" {
    MOCK_AUDIO_CODEC="wmav2"
    run get_audio_codec_arg "test.wmv"
    assert_output --partial "aac"
}
