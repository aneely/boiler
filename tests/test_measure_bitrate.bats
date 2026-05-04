#!/usr/bin/env bats
# Tests for measure_bitrate() - verifies correct fallback behavior
# when stream-level bitrate is reported as "0" (e.g. WMV/ASF containers)

load 'helpers/setup'

setup() {
    common_setup
    TEST_DIR=$(mktemp -d)
}

teardown() {
    common_teardown
    if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}

# Run the real measure_bitrate (not the mock from mocks.bash) in an isolated
# subshell with controlled ffprobe behavior.
# $1 = stream bitrate value (what ffprobe returns for stream=bit_rate query)
# $2 = format bitrate value (what ffprobe returns for format=bit_rate query)
# remaining args = file_path and duration passed to measure_bitrate
run_real_measure_bitrate() {
    local stream_bitrate="$1"
    local format_bitrate="$2"
    shift 2
    PROJECT_ROOT="$PROJECT_ROOT" \
    MOCK_STREAM_BITRATE="$stream_bitrate" \
    MOCK_FORMAT_BITRATE="$format_bitrate" \
    bash -c '
        set +e
        export BOILER_TEST_MODE=1
        source "$PROJECT_ROOT/boiler.sh" 2>/dev/null
        ffprobe() {
            if [[ "$*" == *format=bit_rate* ]]; then
                echo "$MOCK_FORMAT_BITRATE"
            else
                echo "$MOCK_STREAM_BITRATE"
            fi
        }
        measure_bitrate "$1" "$2"
    ' -- "$@"
}

# ============================================================================
# measure_bitrate() fallback tests
# ============================================================================

@test "measure_bitrate: returns stream bitrate when ffprobe reports valid non-zero value" {
    local file="$TEST_DIR/test.mp4"
    touch "$file"
    run run_real_measure_bitrate "10000000" "" "$file" "60"
    assert_success
    assert_output "10000000"
}

@test "measure_bitrate: falls back to container bitrate when stream reports zero (WMV/ASF behavior)" {
    local file="$TEST_DIR/test.wmv"
    touch "$file"
    run run_real_measure_bitrate "0" "11976000" "$file" "60"
    assert_success
    assert_output "11976000"
}

@test "measure_bitrate: falls back to container bitrate when stream reports near-zero (WMV actual: 1 bps)" {
    local file="$TEST_DIR/test.wmv"
    touch "$file"
    run run_real_measure_bitrate "1" "11908002" "$file" "60"
    assert_success
    assert_output "11908002"
}

@test "measure_bitrate: falls back to file-size calculation when both stream and container report zero" {
    local file="$TEST_DIR/test.wmv"
    # 100 * 1024 = 102400 bytes = 819200 bits; at 10s = 81920 bps
    dd if=/dev/zero of="$file" bs=1024 count=100 2>/dev/null
    run run_real_measure_bitrate "0" "0" "$file" "10"
    assert_success
    assert_output "81920"
}
