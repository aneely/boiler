#!/usr/bin/env bats
# Tests for calculate_adjusted_quality() and calculate_interpolated_quality() functions
# Ported from test_boiler.sh

load 'helpers/setup'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# ============================================================================
# calculate_adjusted_quality() tests
# ============================================================================

@test "calculate_adjusted_quality: increases quality when bitrate too low" {
    # Current quality: 50, actual: 4 Mbps, target: 8 Mbps (50% of target)
    run calculate_adjusted_quality "50" "4000000" "8000000"
    assert_success
    # Should increase quality (result > 50)
    [ "$output" -gt 50 ]
}

@test "calculate_adjusted_quality: increased quality is within valid range" {
    run calculate_adjusted_quality "50" "4000000" "8000000"
    assert_success
    [ "$output" -ge 50 ] && [ "$output" -le 100 ]
}

@test "calculate_adjusted_quality: increases quality slightly when close to target" {
    # Current quality: 50, actual: 7.2 Mbps, target: 8 Mbps (90% of target)
    run calculate_adjusted_quality "50" "7200000" "8000000"
    assert_success
    # Should increase slightly (result > 50 but not by much)
    [ "$output" -gt 50 ]
}

@test "calculate_adjusted_quality: decreases quality when bitrate too high" {
    # Current quality: 50, actual: 12 Mbps, target: 8 Mbps (150% of target)
    run calculate_adjusted_quality "50" "12000000" "8000000"
    assert_success
    # Should decrease quality (result < 50)
    [ "$output" -lt 50 ]
}

@test "calculate_adjusted_quality: decreased quality is within valid range" {
    run calculate_adjusted_quality "50" "12000000" "8000000"
    assert_success
    [ "$output" -ge 0 ] && [ "$output" -le 50 ]
}

@test "calculate_adjusted_quality: decreases quality slightly when close above target" {
    # Current quality: 50, actual: 8.8 Mbps, target: 8 Mbps (110% of target)
    run calculate_adjusted_quality "50" "8800000" "8000000"
    assert_success
    # Should decrease slightly (result < 50)
    [ "$output" -lt 50 ]
}

@test "calculate_adjusted_quality: caps quality at 100 when already at maximum" {
    run calculate_adjusted_quality "100" "4000000" "8000000"
    assert_success
    assert_output "100"
}

@test "calculate_adjusted_quality: caps quality at 0 when already at minimum" {
    run calculate_adjusted_quality "0" "12000000" "8000000"
    assert_success
    assert_output "0"
}

@test "calculate_adjusted_quality: handles extreme high bitrate ratio (capped distance)" {
    # Current quality: 50, actual: 24 Mbps, target: 8 Mbps (300% of target)
    run calculate_adjusted_quality "50" "24000000" "8000000"
    assert_success
    # Should decrease by max_step (10), so quality should be 40
    assert_output "40"
}

@test "calculate_adjusted_quality: handles extreme low bitrate ratio" {
    # Current quality: 50, actual: 1 Mbps, target: 8 Mbps (12.5% of target)
    run calculate_adjusted_quality "50" "1000000" "8000000"
    assert_success
    # Should increase significantly (result > 50)
    [ "$output" -gt 50 ]
}

@test "calculate_adjusted_quality: caps quality at 100 when adjustment would exceed" {
    run calculate_adjusted_quality "99" "4000000" "8000000"
    assert_success
    assert_output "100"
}

@test "calculate_adjusted_quality: caps quality at 0 when adjustment would go below" {
    run calculate_adjusted_quality "1" "24000000" "8000000"
    assert_success
    assert_output "0"
}

@test "calculate_adjusted_quality: decreases by min_step when exactly at target" {
    # When actual == target, goes to "too high" branch, decreases by min_step (1)
    run calculate_adjusted_quality "50" "8000000" "8000000"
    assert_success
    assert_output "49"
}

@test "calculate_adjusted_quality: decreases by min_step for very small difference above target" {
    run calculate_adjusted_quality "50" "8000001" "8000000"
    assert_success
    assert_output "49"
}

@test "calculate_adjusted_quality: increases by min_step for very small difference below target" {
    run calculate_adjusted_quality "50" "7999999" "8000000"
    assert_success
    assert_output "51"
}

# ============================================================================
# calculate_interpolated_quality() tests
# ============================================================================

@test "calculate_interpolated_quality: interpolated quality is between the two points" {
    # First pass: quality 79 -> 14.05 Mbps, Second pass: quality 73 -> 7.71 Mbps, Target: 9.00 Mbps
    run calculate_interpolated_quality "79" "14050000" "73" "7710000" "9000000"
    assert_success
    # Result should be between 73 and 79
    [ "$output" -ge 73 ] && [ "$output" -le 79 ]
}

@test "calculate_interpolated_quality: interpolated quality is closer to lower quality point" {
    # Target (9.00) is closer to second pass bitrate (7.71) than first pass (14.05)
    run calculate_interpolated_quality "79" "14050000" "73" "7710000" "9000000"
    assert_success
    # Should be closer to 73 than to 79 (less than 76)
    [ "$output" -lt 76 ]
}

@test "calculate_interpolated_quality: target at first pass bitrate returns first pass quality" {
    # First pass: quality 80 -> 10 Mbps, Second pass: quality 70 -> 8 Mbps, Target: 10 Mbps
    run calculate_interpolated_quality "80" "10000000" "70" "8000000" "10000000"
    assert_success
    assert_output "80"
}

@test "calculate_interpolated_quality: target at second pass bitrate returns second pass quality" {
    # First pass: quality 80 -> 10 Mbps, Second pass: quality 70 -> 8 Mbps, Target: 8 Mbps
    run calculate_interpolated_quality "80" "10000000" "70" "8000000" "8000000"
    assert_success
    assert_output "70"
}

@test "calculate_interpolated_quality: target at midpoint returns midpoint quality" {
    # First pass: quality 80 -> 10 Mbps, Second pass: quality 70 -> 8 Mbps, Target: 9 Mbps (midpoint)
    run calculate_interpolated_quality "80" "10000000" "70" "8000000" "9000000"
    assert_success
    assert_output "75"
}

@test "calculate_interpolated_quality: bitrates too close uses midpoint" {
    # First pass: quality 80 -> 9.01 Mbps, Second pass: quality 70 -> 9.00 Mbps
    # Bitrate difference (0.01 Mbps) is less than 1% of 9.00 Mbps
    run calculate_interpolated_quality "80" "9010000" "70" "9000000" "9000000"
    assert_success
    # Should use midpoint: (80 + 70) / 2 = 75
    assert_output "75"
}

@test "calculate_interpolated_quality: clamps result to minimum (0)" {
    # Extreme case where interpolation would go negative
    # This tests that the function properly clamps to 0
    run calculate_interpolated_quality "10" "20000000" "5" "10000000" "1000000"
    assert_success
    [ "$output" -ge 0 ]
}

@test "calculate_interpolated_quality: clamps result to maximum (100)" {
    # Extreme case where interpolation would exceed 100
    run calculate_interpolated_quality "90" "5000000" "95" "10000000" "20000000"
    assert_success
    [ "$output" -le 100 ]
}

@test "calculate_interpolated_quality: handles reversed bitrate order" {
    # First pass bitrate lower than second pass (unusual but possible)
    run calculate_interpolated_quality "70" "8000000" "80" "10000000" "9000000"
    assert_success
    # Should still produce a reasonable result between 70 and 80
    [ "$output" -ge 70 ] && [ "$output" -le 80 ]
}
