#!/usr/bin/env bats
# Tests for sanitize_value() function
# Ported from test_boiler.sh

# Load test helpers
load 'helpers/setup'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# ============================================================================
# sanitize_value() tests
# ============================================================================

@test "sanitize_value: normal number passes through unchanged" {
    run sanitize_value "1000000"
    assert_success
    assert_output "1000000"
}

@test "sanitize_value: removes trailing newline" {
    local input
    input=$(printf "1000000\n")
    run sanitize_value "$input"
    assert_success
    assert_output "1000000"
}

@test "sanitize_value: removes carriage return" {
    local input
    input=$(printf "1000000\r")
    run sanitize_value "$input"
    assert_success
    assert_output "1000000"
}

@test "sanitize_value: trims leading and trailing whitespace" {
    run sanitize_value "  1000000  "
    assert_success
    assert_output "1000000"
}

@test "sanitize_value: removes all whitespace and newlines combined" {
    local input
    input=$(printf "1000000\n\r  ")
    run sanitize_value "$input"
    assert_success
    assert_output "1000000"
}
