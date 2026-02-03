#!/bin/bash

# run-bats-tests.sh - Run the bats test suite for boiler.sh
#
# Usage:
#   ./run-bats-tests.sh           # Run all tests
#   ./run-bats-tests.sh -p        # Run tests in parallel (faster)
#   ./run-bats-tests.sh -j 4      # Run tests with 4 parallel jobs
#   ./run-bats-tests.sh -f        # Run specific test file
#   ./run-bats-tests.sh -t "name" # Run tests matching pattern
#   ./run-bats-tests.sh -v        # Verbose output
#   ./run-bats-tests.sh -h        # Show help

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${SCRIPT_DIR}/tests"

# Default settings
PARALLEL=0
JOBS=""
VERBOSE=0
FILTER=""
TEST_FILE=""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [test_file.bats]

Run the bats test suite for boiler.sh

OPTIONS:
  -p, --parallel      Run tests in parallel (uses all available cores)
  -j, --jobs N        Run tests with N parallel jobs
  -t, --filter REGEX  Run only tests matching REGEX
  -v, --verbose       Show verbose output (print commands)
  -T, --tap           Output in TAP format (for CI systems)
  -h, --help          Show this help message

EXAMPLES:
  $(basename "$0")                          # Run all tests sequentially
  $(basename "$0") -p                       # Run all tests in parallel
  $(basename "$0") -j 4                     # Run with 4 parallel jobs
  $(basename "$0") tests/test_integration.bats  # Run specific test file
  $(basename "$0") -t "main"                # Run tests with "main" in name
  $(basename "$0") -v                       # Verbose output

TEST FILES:
  tests/test_sanitize_value.bats       - sanitize_value() tests
  tests/test_bps_to_mbps.bats          - bps_to_mbps() tests
  tests/test_parse_filename.bats       - parse_filename() tests
  tests/test_is_within_tolerance.bats  - is_within_tolerance() tests
  tests/test_format_codec_detection.bats - Format/codec detection tests
  tests/test_calculate_target_bitrate.bats - Target bitrate tests
  tests/test_calculate_sample_points.bats  - Sample points tests
  tests/test_validation.bats           - validate_bitrate()/validate_depth() tests
  tests/test_parse_arguments.bats      - Command-line argument tests
  tests/test_file_discovery.bats       - File discovery tests
  tests/test_filename_extraction.bats  - Filename extraction tests
  tests/test_quality_algorithms.bats   - Quality adjustment algorithm tests
  tests/test_mocked_functions.bats     - Mock function tests
  tests/test_integration.bats          - Integration tests (main() workflow)

EOF
}

# Check if bats is installed
check_bats() {
    if ! command -v bats &> /dev/null; then
        echo -e "${RED}Error: bats-core is not installed${NC}"
        echo ""
        echo "Install via Homebrew:"
        echo "  brew install bats-core"
        echo ""
        echo "Or see: https://github.com/bats-core/bats-core"
        exit 1
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--parallel)
            PARALLEL=1
            shift
            ;;
        -j|--jobs)
            JOBS="$2"
            PARALLEL=1
            shift 2
            ;;
        -t|--filter)
            FILTER="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -T|--tap)
            TAP=1
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *.bats)
            TEST_FILE="$1"
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            show_usage
            exit 1
            ;;
    esac
done

# Check bats installation
check_bats

# Build bats command
BATS_CMD="bats"

# Add parallel options (requires GNU parallel or rush)
if [ "$PARALLEL" -eq 1 ]; then
    # Check if parallel is available
    if ! command -v parallel &> /dev/null && ! command -v rush &> /dev/null; then
        echo -e "${YELLOW}Warning: Parallel execution requires GNU parallel or rush${NC}"
        echo -e "${YELLOW}Install via: brew install parallel${NC}"
        echo -e "${YELLOW}Running tests sequentially instead...${NC}"
        echo ""
        PARALLEL=0
    else
        if [ -n "$JOBS" ]; then
            BATS_CMD="$BATS_CMD --jobs $JOBS"
        else
            # Use all available cores
            BATS_CMD="$BATS_CMD --jobs $(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
        fi
    fi
fi

# Add filter option
if [ -n "$FILTER" ]; then
    BATS_CMD="$BATS_CMD --filter \"$FILTER\""
fi

# Add verbose option
if [ "$VERBOSE" -eq 1 ]; then
    BATS_CMD="$BATS_CMD --verbose-run"
fi

# Add TAP format option
if [ "${TAP:-0}" -eq 1 ]; then
    BATS_CMD="$BATS_CMD --formatter tap"
fi

# Determine what to run
if [ -n "$TEST_FILE" ]; then
    if [ ! -f "$TEST_FILE" ]; then
        echo -e "${RED}Error: Test file not found: $TEST_FILE${NC}"
        exit 1
    fi
    TARGET="$TEST_FILE"
else
    TARGET="${TESTS_DIR}/"
fi

# Show what we're running
echo -e "${GREEN}Running bats tests...${NC}"
if [ "$PARALLEL" -eq 1 ]; then
    echo -e "${YELLOW}Mode: Parallel${NC}"
fi
echo ""

# Run the tests
eval "$BATS_CMD $TARGET"
exit_code=$?

if [ $exit_code -eq 0 ]; then
    echo ""
    echo -e "${GREEN}All tests passed!${NC}"
else
    echo ""
    echo -e "${RED}Some tests failed!${NC}"
fi

exit $exit_code
