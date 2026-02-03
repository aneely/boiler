#!/usr/bin/env bats
# Tests for calculate_sample_points() function
# Ported from test_boiler.sh

load 'helpers/setup'

setup() {
    common_setup
}

teardown() {
    common_teardown
}

# ============================================================================
# calculate_sample_points() tests
# Function sets global variables:
#   SAMPLE_COUNT, SAMPLE_DURATION
#   SAMPLE_START_1, SAMPLE_START_2, SAMPLE_START_3 (depending on count)
# ============================================================================

@test "calculate_sample_points: video < 60s uses 1 sample with full video duration" {
    calculate_sample_points "30"
    assert_equal "$SAMPLE_COUNT" "1"
    assert_equal "$SAMPLE_START_1" "0"
    assert_equal "$SAMPLE_DURATION" "30"
}

@test "calculate_sample_points: video exactly 60s uses 1 sample" {
    calculate_sample_points "60"
    assert_equal "$SAMPLE_COUNT" "1"
}

@test "calculate_sample_points: video 60-119s uses 1 sample (full video)" {
    calculate_sample_points "90"
    assert_equal "$SAMPLE_COUNT" "1"
}

@test "calculate_sample_points: video 120-179s uses 2 samples" {
    calculate_sample_points "150"
    assert_equal "$SAMPLE_COUNT" "2"
    assert_equal "$SAMPLE_START_1" "0"
    # SAMPLE_START_2 should be max_start (150 - 60 = 90)
    local expected_start2
    expected_start2=$(echo "scale=1; 150 - 60" | bc | tr -d '\n\r')
    assert_equal "$SAMPLE_START_2" "$expected_start2"
}

@test "calculate_sample_points: video >= 180s uses 3 samples at 10%, 50%, 90%" {
    calculate_sample_points "300"
    assert_equal "$SAMPLE_COUNT" "3"
    
    # Check sample points are approximately 10%, 50%, 90%
    local expected_start1 expected_start2 max_start expected_start3
    expected_start1=$(echo "scale=1; 300 * 0.1" | bc | tr -d '\n\r')
    expected_start2=$(echo "scale=1; 300 * 0.5" | bc | tr -d '\n\r')
    max_start=$(echo "scale=1; 300 - 60" | bc | tr -d '\n\r')
    expected_start3="$max_start"  # Capped at max_start
    
    assert_equal "$SAMPLE_START_1" "$expected_start1"
    assert_equal "$SAMPLE_START_2" "$expected_start2"
    assert_equal "$SAMPLE_START_3" "$expected_start3"
    assert_equal "$SAMPLE_DURATION" "60"
}

@test "calculate_sample_points: 3-sample video uses 60s sample duration" {
    calculate_sample_points "300"
    assert_equal "$SAMPLE_DURATION" "60"
}

@test "calculate_sample_points: start3 is capped at max_start for short-ish videos" {
    # For a 180s video, 90% would be 162, but max_start is 120 (180-60)
    calculate_sample_points "180"
    assert_equal "$SAMPLE_COUNT" "3"
    
    local max_start
    max_start=$(echo "scale=1; 180 - 60" | bc | tr -d '\n\r')
    # The function should cap SAMPLE_START_3 at max_start
    # 90% of 180 = 162, but max_start = 120, so it should be 120
    assert_equal "$SAMPLE_START_3" "$max_start"
}
