#!/usr/bin/env bats
# Tests for calculate_squared_distance() function
# Ported from test_boiler.sh

load 'helpers/setup'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# ============================================================================
# calculate_squared_distance() tests
# ============================================================================

@test "calculate_squared_distance: zero distance when values are equal" {
    run calculate_squared_distance "8000000" "8000000"
    assert_success
    assert_output "0"
}

@test "calculate_squared_distance: correct distance for 1 Mbps difference" {
    run calculate_squared_distance "8000000" "9000000"
    assert_success
    # (8000000 - 9000000)^2 = 1000000000000
    local expected
    expected=$(echo "scale=4; (8000000 - 9000000)^2" | bc | tr -d '\n\r')
    assert_output "$expected"
}

@test "calculate_squared_distance: correct distance for 3 Mbps difference" {
    run calculate_squared_distance "8000000" "11000000"
    assert_success
    local expected
    expected=$(echo "scale=4; (8000000 - 11000000)^2" | bc | tr -d '\n\r')
    assert_output "$expected"
}

@test "calculate_squared_distance: handles sanitized inputs with newlines/carriage returns" {
    local val1 val2 expected
    val1=$(printf "8000000\n")
    val2=$(printf "9000000\r")
    expected=$(echo "scale=4; (8000000 - 9000000)^2" | bc | tr -d '\n\r')
    
    run calculate_squared_distance "$val1" "$val2"
    assert_success
    assert_output "$expected"
}
