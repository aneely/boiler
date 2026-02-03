#!/usr/bin/env bats
# Tests for bps_to_mbps() function
# Ported from test_boiler.sh

load 'helpers/setup'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# ============================================================================
# bps_to_mbps() tests
# ============================================================================

@test "bps_to_mbps: converts 8 Mbps correctly" {
    run bps_to_mbps "8000000"
    assert_success
    assert_output "8.00"
}

@test "bps_to_mbps: converts 11 Mbps correctly" {
    run bps_to_mbps "11000000"
    assert_success
    assert_output "11.00"
}

@test "bps_to_mbps: converts 8.5 Mbps correctly" {
    run bps_to_mbps "8500000"
    assert_success
    assert_output "8.50"
}

@test "bps_to_mbps: handles newlines in input" {
    local input
    input=$(printf "8500000\n")
    run bps_to_mbps "$input"
    assert_success
    assert_output "8.50"
}

@test "bps_to_mbps: converts 1 Mbps correctly" {
    run bps_to_mbps "1000000"
    assert_success
    assert_output "1.00"
}

@test "bps_to_mbps: handles zero bitrate" {
    run bps_to_mbps "0"
    assert_success
    assert_output "0"
}
