#!/usr/bin/env bats
# Tests for validate_bitrate() and validate_depth() functions
# Ported from test_boiler.sh

load 'helpers/setup'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# ============================================================================
# validate_bitrate() tests
# Returns 0 (success) for valid bitrates, 1 (failure) for invalid
# ============================================================================

@test "validate_bitrate: accepts integer value (5)" {
    run validate_bitrate "5"
    assert_success
}

@test "validate_bitrate: accepts decimal value (9.5)" {
    run validate_bitrate "9.5"
    assert_success
}

@test "validate_bitrate: accepts minimum value (0.1)" {
    run validate_bitrate "0.1"
    assert_success
}

@test "validate_bitrate: accepts maximum value (100)" {
    run validate_bitrate "100"
    assert_success
}

@test "validate_bitrate: accepts decimal with two places (50.25)" {
    run validate_bitrate "50.25"
    assert_success
}

@test "validate_bitrate: rejects empty string" {
    run validate_bitrate ""
    assert_failure
}

@test "validate_bitrate: rejects zero" {
    run validate_bitrate "0"
    assert_failure
}

@test "validate_bitrate: rejects negative value" {
    run validate_bitrate "-5"
    assert_failure
}

@test "validate_bitrate: rejects value above 100" {
    run validate_bitrate "101"
    assert_failure
}

@test "validate_bitrate: rejects non-numeric value" {
    run validate_bitrate "abc"
    assert_failure
}

@test "validate_bitrate: rejects multiple decimal points" {
    run validate_bitrate "5.5.5"
    assert_failure
}

@test "validate_bitrate: rejects value with whitespace" {
    run validate_bitrate " 5 "
    assert_failure
}

# ============================================================================
# validate_depth() tests
# Returns 0 (success) for valid depths, 1 (failure) for invalid
# ============================================================================

@test "validate_depth: accepts 0 (unlimited)" {
    run validate_depth "0"
    assert_success
}

@test "validate_depth: accepts 1" {
    run validate_depth "1"
    assert_success
}

@test "validate_depth: accepts 2" {
    run validate_depth "2"
    assert_success
}

@test "validate_depth: accepts 3" {
    run validate_depth "3"
    assert_success
}

@test "validate_depth: accepts 10" {
    run validate_depth "10"
    assert_success
}

@test "validate_depth: accepts 100" {
    run validate_depth "100"
    assert_success
}

@test "validate_depth: rejects empty string" {
    run validate_depth ""
    assert_failure
}

@test "validate_depth: rejects negative value" {
    run validate_depth "-1"
    assert_failure
}

@test "validate_depth: rejects non-numeric value" {
    run validate_depth "abc"
    assert_failure
}

@test "validate_depth: rejects decimal value" {
    run validate_depth "5.5"
    assert_failure
}

@test "validate_depth: rejects value with whitespace" {
    run validate_depth " 5 "
    assert_failure
}
