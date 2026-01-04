#!/bin/bash

# Helper script to copy 4K test video to current directory

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get the script directory (project root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_VIDEO="$SCRIPT_DIR/testdata/videos/4k/first_2_min_keyframe.2160p.mp4"
DEST_FILE="first_2_min_keyframe.2160p.mp4"

# Check if source file exists
if [ ! -f "$TEST_VIDEO" ]; then
    error "Test video not found: $TEST_VIDEO"
    exit 1
fi

# Copy the file
cp "$TEST_VIDEO" "$DEST_FILE"

info "Copied 4K test video to: $DEST_FILE"

