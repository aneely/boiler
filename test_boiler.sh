#!/bin/bash

# Simple test harness for boiler.sh utility functions
# Tests functions that don't require actual video files or ffmpeg calls

# Test statistics
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors for test output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Assertion functions
assert_equal() {
    local actual="$1"
    local expected="$2"
    local test_name="$3"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [ "$actual" = "$expected" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo -e "  Expected: '$expected'"
        echo -e "  Actual:   '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_not_equal() {
    local actual="$1"
    local expected="$2"
    local test_name="$3"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [ "$actual" != "$expected" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo -e "  Values should not be equal: '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_empty() {
    local actual="$1"
    local test_name="$2"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [ -z "$actual" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo -e "  Expected empty string, got: '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_not_empty() {
    local actual="$1"
    local test_name="$2"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [ -n "$actual" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo -e "  Expected non-empty string, got empty"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_exit_code() {
    local actual_exit="$1"
    local expected_exit="$2"
    local test_name="$3"
    
    TESTS_RUN=$((TESTS_RUN + 1))
    
    if [ "$actual_exit" -eq "$expected_exit" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $test_name"
        echo -e "  Expected exit code: $expected_exit"
        echo -e "  Actual exit code: $actual_exit"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# Set test mode to prevent main() from running when we source boiler.sh
export BOILER_TEST_MODE=1

# Source boiler.sh (main() won't run because of BOILER_TEST_MODE check we added)
# Temporarily disable set -e to prevent early exit during sourcing
# Also redirect stderr from info/warn/error functions to avoid noise
set +e
source boiler.sh 2>/dev/null
set -e

# Now run tests

echo "Running tests for boiler.sh utility functions..."
echo ""

# Test sanitize_value()
echo "Testing sanitize_value()..."
test_sanitize_value() {
    local result
    
    result=$(sanitize_value "1000000")
    assert_equal "$result" "1000000" "sanitize_value: normal number"
    
    result=$(sanitize_value "$(printf "1000000\n")")
    assert_equal "$result" "1000000" "sanitize_value: removes newline"
    
    result=$(sanitize_value "$(printf "1000000\r")")
    assert_equal "$result" "1000000" "sanitize_value: removes carriage return"
    
    result=$(sanitize_value "  1000000  ")
    assert_equal "$result" "1000000" "sanitize_value: trims whitespace"
    
    result=$(sanitize_value "$(printf "1000000\n\r  ")")
    assert_equal "$result" "1000000" "sanitize_value: removes all whitespace and newlines"
}
test_sanitize_value

echo ""

# Test bps_to_mbps()
echo "Testing bps_to_mbps()..."
test_bps_to_mbps() {
    local result
    
    result=$(bps_to_mbps "8000000")
    assert_equal "$result" "8.00" "bps_to_mbps: 8 Mbps"
    
    result=$(bps_to_mbps "11000000")
    assert_equal "$result" "11.00" "bps_to_mbps: 11 Mbps"
    
    result=$(bps_to_mbps "8500000")
    assert_equal "$result" "8.50" "bps_to_mbps: 8.5 Mbps"
    
    result=$(bps_to_mbps "$(printf "8500000\n")")
    assert_equal "$result" "8.50" "bps_to_mbps: handles newlines in input"
    
    result=$(bps_to_mbps "1000000")
    assert_equal "$result" "1.00" "bps_to_mbps: 1 Mbps"
    
    result=$(bps_to_mbps "0")
    assert_equal "$result" "0" "bps_to_mbps: zero bitrate"
}
test_bps_to_mbps

echo ""

# Test calculate_squared_distance()
echo "Testing calculate_squared_distance()..."
test_calculate_squared_distance() {
    local result
    local expected
    
    # Distance of 0 (same value)
    result=$(calculate_squared_distance "8000000" "8000000")
    assert_equal "$result" "0" "calculate_squared_distance: zero distance"
    
    # Distance of 1000000 (1 Mbps difference)
    result=$(calculate_squared_distance "8000000" "9000000")
    expected=$(echo "scale=4; (8000000 - 9000000)^2" | bc | tr -d '\n\r')
    assert_equal "$result" "$expected" "calculate_squared_distance: 1 Mbps difference"
    
    # Distance of 3000000 (3 Mbps difference)
    result=$(calculate_squared_distance "8000000" "11000000")
    expected=$(echo "scale=4; (8000000 - 11000000)^2" | bc | tr -d '\n\r')
    assert_equal "$result" "$expected" "calculate_squared_distance: 3 Mbps difference"
    
    # Test with sanitized inputs (newlines/carriage returns)
    result=$(calculate_squared_distance "$(printf "8000000\n")" "$(printf "9000000\r")")
    expected=$(echo "scale=4; (8000000 - 9000000)^2" | bc | tr -d '\n\r')
    assert_equal "$result" "$expected" "calculate_squared_distance: handles sanitized inputs"
}
test_calculate_squared_distance

echo ""

# Test parse_filename()
echo "Testing parse_filename()..."
test_parse_filename() {
    parse_filename "video.mp4"
    assert_equal "$BASE_NAME" "video" "parse_filename: simple filename"
    assert_equal "$FILE_EXTENSION" "mp4" "parse_filename: simple extension"
    
    parse_filename "my.video.file.mkv"
    assert_equal "$BASE_NAME" "my.video.file" "parse_filename: filename with dots"
    assert_equal "$FILE_EXTENSION" "mkv" "parse_filename: extension with dots in name"
    
    parse_filename "/path/to/video.avi"
    assert_equal "$BASE_NAME" "/path/to/video" "parse_filename: path with extension"
    assert_equal "$FILE_EXTENSION" "avi" "parse_filename: extension from path"
    
    parse_filename "noextension"
    assert_equal "$BASE_NAME" "noextension" "parse_filename: no extension"
    assert_equal "$FILE_EXTENSION" "noextension" "parse_filename: no extension (base equals ext)"
}
test_parse_filename

echo ""

# Test is_within_tolerance()
echo "Testing is_within_tolerance()..."
test_is_within_tolerance() {
    local exit_code
    
    # Test within tolerance (exactly at lower bound)
    set +e
    is_within_tolerance "7600000" "7600000" "8400000"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_within_tolerance: at lower bound"
    
    # Test within tolerance (exactly at upper bound)
    set +e
    is_within_tolerance "8400000" "7600000" "8400000"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_within_tolerance: at upper bound"
    
    # Test within tolerance (middle)
    set +e
    is_within_tolerance "8000000" "7600000" "8400000"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_within_tolerance: in middle"
    
    # Test below tolerance
    set +e
    is_within_tolerance "7500000" "7600000" "8400000"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_within_tolerance: below lower bound"
    
    # Test above tolerance
    set +e
    is_within_tolerance "8500000" "7600000" "8400000"
    exit_code=$?
    set -e
    assert_exit_code $exit_code 1 "is_within_tolerance: above upper bound"
    
    # Test with sanitized inputs (newlines/carriage returns/whitespace)
    set +e
    is_within_tolerance "$(printf "8000000\n")" "$(printf "7600000\r")" "8400000  "
    exit_code=$?
    set -e
    assert_exit_code $exit_code 0 "is_within_tolerance: handles sanitized inputs"
}
test_is_within_tolerance

echo ""

# Test calculate_target_bitrate()
echo "Testing calculate_target_bitrate()..."
test_calculate_target_bitrate() {
    # Test 2160p (4K)
    calculate_target_bitrate "2160"
    assert_equal "$TARGET_BITRATE_MBPS" "11" "calculate_target_bitrate: 2160p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "11000000" "calculate_target_bitrate: 2160p bps"
    
    # Test above 2160p
    calculate_target_bitrate "4320"
    assert_equal "$TARGET_BITRATE_MBPS" "11" "calculate_target_bitrate: above 2160p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "11000000" "calculate_target_bitrate: above 2160p bps"
    
    # Test 1080p
    calculate_target_bitrate "1080"
    assert_equal "$TARGET_BITRATE_MBPS" "8" "calculate_target_bitrate: 1080p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "8000000" "calculate_target_bitrate: 1080p bps"
    
    # Test between 1080p and 2160p
    calculate_target_bitrate "1440"
    assert_equal "$TARGET_BITRATE_MBPS" "8" "calculate_target_bitrate: 1440p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "8000000" "calculate_target_bitrate: 1440p bps"
    
    # Test below 1080p
    calculate_target_bitrate "720"
    assert_equal "$TARGET_BITRATE_MBPS" "8" "calculate_target_bitrate: below 1080p Mbps"
    assert_equal "$TARGET_BITRATE_BPS" "8000000" "calculate_target_bitrate: below 1080p bps"
}
test_calculate_target_bitrate

echo ""

# Test calculate_sample_points()
echo "Testing calculate_sample_points()..."
test_calculate_sample_points() {
    # Test video shorter than 60 seconds (uses full video)
    calculate_sample_points "30"
    assert_equal "$SAMPLE_COUNT" "1" "calculate_sample_points: video < 60s count"
    assert_equal "$SAMPLE_START_1" "0" "calculate_sample_points: video < 60s start"
    assert_equal "$SAMPLE_DURATION" "30" "calculate_sample_points: video < 60s duration"
    
    # Test video exactly 60 seconds
    calculate_sample_points "60"
    assert_equal "$SAMPLE_COUNT" "1" "calculate_sample_points: video = 60s count"
    
    # Test video between 60-119 seconds (1 sample, full video)
    calculate_sample_points "90"
    assert_equal "$SAMPLE_COUNT" "1" "calculate_sample_points: video 60-119s count"
    
    # Test video between 120-179 seconds (2 samples)
    calculate_sample_points "150"
    assert_equal "$SAMPLE_COUNT" "2" "calculate_sample_points: video 120-179s count"
    assert_equal "$SAMPLE_START_1" "0" "calculate_sample_points: video 120-179s start1"
    # SAMPLE_START_2 should be max_start (150 - 60 = 90)
    local expected_start2=$(echo "scale=1; 150 - 60" | bc | tr -d '\n\r')
    assert_equal "$SAMPLE_START_2" "$expected_start2" "calculate_sample_points: video 120-179s start2"
    
    # Test video >= 180 seconds (3 samples)
    calculate_sample_points "300"
    assert_equal "$SAMPLE_COUNT" "3" "calculate_sample_points: video >= 180s count"
    # Check that sample points are approximately 10%, 50%, 90%
    # Note: sample_start_3 is capped at max_start (300 - 60 = 240) if it exceeds it
    local expected_start1=$(echo "scale=1; 300 * 0.1" | bc | tr -d '\n\r')
    local expected_start2=$(echo "scale=1; 300 * 0.5" | bc | tr -d '\n\r')
    local max_start=$(echo "scale=1; 300 - 60" | bc | tr -d '\n\r')
    local expected_start3=$max_start  # Capped at max_start
    assert_equal "$SAMPLE_START_1" "$expected_start1" "calculate_sample_points: video >= 180s start1 (10%)"
    assert_equal "$SAMPLE_START_2" "$expected_start2" "calculate_sample_points: video >= 180s start2 (50%)"
    assert_equal "$SAMPLE_START_3" "$expected_start3" "calculate_sample_points: video >= 180s start3 (capped at max_start)"
    assert_equal "$SAMPLE_DURATION" "60" "calculate_sample_points: video >= 180s duration"
}
test_calculate_sample_points

echo ""

# Print test summary
echo "=========================================="
echo "Test Summary:"
echo "  Total:  $TESTS_RUN"
echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"
if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
else
    echo -e "  Failed: $TESTS_FAILED"
fi
echo "=========================================="

# Exit with appropriate code
if [ $TESTS_FAILED -eq 0 ]; then
    exit 0
else
    exit 1
fi

