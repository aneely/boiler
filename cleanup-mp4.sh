#!/bin/bash

# Helper script to remove all .mp4 files from the project root directory

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

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get the script directory (project root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find all .mp4 files in the root directory (not recursive)
MP4_FILES=$(find "$SCRIPT_DIR" -maxdepth 1 -type f -name "*.mp4" 2>/dev/null)

if [ -z "$MP4_FILES" ]; then
    info "No .mp4 files found in project root directory"
    exit 0
fi

# Count files
FILE_COUNT=$(echo "$MP4_FILES" | grep -c . || echo "0")

if [ "$FILE_COUNT" -eq 0 ]; then
    info "No .mp4 files found in project root directory"
    exit 0
fi

# List files to be deleted
warn "Found $FILE_COUNT .mp4 file(s) to remove:"
echo "$MP4_FILES" | while read -r file; do
    if [ -n "$file" ]; then
        echo "  - $(basename "$file")"
    fi
done

# Remove files
echo "$MP4_FILES" | while read -r file; do
    if [ -n "$file" ]; then
        rm -f "$file"
        info "Removed: $(basename "$file")"
    fi
done

info "Cleanup complete!"

