#!/usr/bin/env bats
# Tests for calculate_target_bitrate() function
# Ported from test_boiler.sh

load 'helpers/setup'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# ============================================================================
# calculate_target_bitrate() tests
# Function sets global variables TARGET_BITRATE_MBPS and TARGET_BITRATE_BPS
# ============================================================================

@test "calculate_target_bitrate: 2160p (4K) targets 11 Mbps" {
    calculate_target_bitrate "2160"
    assert_equal "$TARGET_BITRATE_MBPS" "11"
    assert_equal "$TARGET_BITRATE_BPS" "11000000"
}

@test "calculate_target_bitrate: above 2160p targets 11 Mbps" {
    calculate_target_bitrate "4320"
    assert_equal "$TARGET_BITRATE_MBPS" "11"
    assert_equal "$TARGET_BITRATE_BPS" "11000000"
}

@test "calculate_target_bitrate: 1080p targets 8 Mbps" {
    calculate_target_bitrate "1080"
    assert_equal "$TARGET_BITRATE_MBPS" "8"
    assert_equal "$TARGET_BITRATE_BPS" "8000000"
}

@test "calculate_target_bitrate: 1440p (between 1080p and 2160p) targets 8 Mbps" {
    calculate_target_bitrate "1440"
    assert_equal "$TARGET_BITRATE_MBPS" "8"
    assert_equal "$TARGET_BITRATE_BPS" "8000000"
}

@test "calculate_target_bitrate: 720p targets 5 Mbps" {
    calculate_target_bitrate "720"
    assert_equal "$TARGET_BITRATE_MBPS" "5"
    assert_equal "$TARGET_BITRATE_BPS" "5000000"
}

@test "calculate_target_bitrate: 900p (between 720p and 1080p) targets 5 Mbps" {
    calculate_target_bitrate "900"
    assert_equal "$TARGET_BITRATE_MBPS" "5"
    assert_equal "$TARGET_BITRATE_BPS" "5000000"
}

@test "calculate_target_bitrate: 480p targets 2.5 Mbps" {
    calculate_target_bitrate "480"
    assert_equal "$TARGET_BITRATE_MBPS" "2.5"
    assert_equal "$TARGET_BITRATE_BPS" "2500000"
}

@test "calculate_target_bitrate: 600p (between 480p and 720p) targets 2.5 Mbps" {
    calculate_target_bitrate "600"
    assert_equal "$TARGET_BITRATE_MBPS" "2.5"
    assert_equal "$TARGET_BITRATE_BPS" "2500000"
}

@test "calculate_target_bitrate: below 480p targets 2.5 Mbps" {
    calculate_target_bitrate "360"
    assert_equal "$TARGET_BITRATE_MBPS" "2.5"
    assert_equal "$TARGET_BITRATE_BPS" "2500000"
}
