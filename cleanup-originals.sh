#!/bin/bash

# Helper script to move original video files (without transcoding markers) to trash
# Processes current directory and subdirectories one level deep
# Only moves files that don't have .fmpg., .orig., or .hbrk. markers

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

# Check if a file has any of the transcoding markers
# Returns 0 (true) if file has markers, 1 (false) if it's an original file
has_transcoding_marker() {
    local filename="$1"
    local basename=$(basename "$filename")
    
    # Check if filename contains any of the skip markers
    if [[ "$basename" == *".hbrk."* ]] || \
       [[ "$basename" == *".fmpg."* ]] || \
       [[ "$basename" == *".orig."* ]]; then
        return 0  # Has marker
    fi
    
    return 1  # No marker (is original file)
}

# Move file to macOS trash
# Uses native `trash` command on macOS 15+ (Sequoia), falls back to AppleScript on older versions
move_to_trash() {
    local file_path="$1"
    
    # Check if native `trash` command is available (macOS 15 Sequoia+)
    if command -v trash >/dev/null 2>&1; then
        # Use native trash command (simpler, faster)
        trash "$file_path" 2>/dev/null
    else
        # Fall back to AppleScript for older macOS versions
        local abs_path=$(cd "$(dirname "$file_path")" && pwd)/$(basename "$file_path")
        osascript -e "tell application \"Finder\" to move POSIX file \"$abs_path\" to trash" 2>/dev/null
    fi
}

# Video file extensions to process
video_extensions=("mp4" "mkv" "avi" "mov" "m4v" "webm" "flv" "wmv")

# Get list of directories to check (current directory and subdirectories one level deep)
directories=(".")
while IFS= read -r dir; do
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        directories+=("$dir")
    fi
done < <(find . -maxdepth 1 -type d ! -path . 2>/dev/null)

# Find all video files in current directory and subdirectories (one level deep)
original_files=()
directories_checked=0
directories_with_originals=0
directories_skipped=0

info "Scanning directories for original video files..."
echo ""

# Process each directory
for dir in "${directories[@]}"; do
    directories_checked=$((directories_checked + 1))
    local_original_files=()
    local_transcoded_files=0
    
    # Find video files in this directory
    for ext in "${video_extensions[@]}"; do
        while IFS= read -r found; do
            if [ -n "$found" ] && [ -f "$found" ]; then
                if has_transcoding_marker "$found"; then
                    local_transcoded_files=$((local_transcoded_files + 1))
                else
                    local_original_files+=("$found")
                fi
            fi
        done < <(find "$dir" -maxdepth 1 -type f -iname "*.${ext}" 2>/dev/null)
    done
    
    # Show directory status
    if [ ${#local_original_files[@]} -gt 0 ]; then
        directories_with_originals=$((directories_with_originals + 1))
        if [ "$dir" = "." ]; then
            info "Checking current directory: Found ${#local_original_files[@]} original file(s)"
        else
            info "Checking $dir: Found ${#local_original_files[@]} original file(s)"
        fi
        # Add to main list
        for file in "${local_original_files[@]}"; do
            original_files+=("$file")
        done
    else
        directories_skipped=$((directories_skipped + 1))
        if [ "$dir" = "." ]; then
            if [ $local_transcoded_files -gt 0 ]; then
                info "Checking current directory: Skipped (${local_transcoded_files} transcoded file(s), no originals)"
            else
                info "Checking current directory: Skipped (no video files)"
            fi
        else
            if [ $local_transcoded_files -gt 0 ]; then
                info "Checking $dir: Skipped (${local_transcoded_files} transcoded file(s), no originals)"
            else
                info "Checking $dir: Skipped (no video files)"
            fi
        fi
    fi
done

echo ""
info "Scan complete: Checked ${directories_checked} directory/directories, found originals in ${directories_with_originals}, skipped ${directories_skipped}"

# Check if any files found
if [ ${#original_files[@]} -eq 0 ]; then
    echo ""
    info "No original video files found (all files have transcoding markers)"
    exit 0
fi

echo ""

# Show files to be moved
warn "Found ${#original_files[@]} original video file(s) to move to trash:"
for file in "${original_files[@]}"; do
    echo "  - $file"
done

# Confirm before proceeding
echo ""
read -p "Move these files to trash? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Cancelled."
    exit 0
fi

# Move files to trash
moved_count=0
failed_count=0

for file in "${original_files[@]}"; do
    if move_to_trash "$file"; then
        info "Moved to trash: $file"
        moved_count=$((moved_count + 1))
    else
        error "Failed to move to trash: $file"
        failed_count=$((failed_count + 1))
    fi
done

# Summary
echo ""
if [ $failed_count -eq 0 ]; then
    info "Cleanup complete! Moved ${moved_count} file(s) to trash."
else
    warn "Cleanup complete with errors. Moved ${moved_count} file(s) to trash, ${failed_count} failed."
    exit 1
fi

