#!/bin/bash

# Helper script to move original video files (without transcoding markers) to trash
# Processes current directory and subdirectories (default: one level deep, configurable via -L/--max-depth)
# Only moves files that don't have .fmpg., .orig., or .hbrk. markers

set -e

# Global max depth for directory traversal (default: 2 = current directory + one subdirectory level)
# Set to 0 for unlimited depth (full recursive search)
# Only set default if not already set (allows environment variable override for testing)
GLOBAL_MAX_DEPTH="${GLOBAL_MAX_DEPTH:-2}"

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

# Sanitize value (remove newlines, carriage returns, and trim whitespace)
sanitize_value() {
    echo "$1" | tr -d '\n\r' | xargs
}

# Validate depth value
# Arguments: depth_value (integer as string)
# Returns: 0 if valid, 1 if invalid
validate_depth() {
    local depth="$1"
    
    # Check if empty
    if [ -z "$depth" ]; then
        return 1
    fi
    
    # Check if it's a non-negative integer (0 for unlimited, or positive integer)
    if ! echo "$depth" | grep -qE '^[0-9]+$'; then
        return 1
    fi
    
    return 0
}

# Show usage information
show_usage() {
    cat >&2 <<EOF
Usage: $0 [OPTIONS]

Move original video files (without transcoding markers) to trash.

OPTIONS:
    -L, --max-depth DEPTH        Maximum directory depth to traverse
                                 Example: --max-depth 3
                                 Default: 2 (current directory + one subdirectory level)
                                 Use 0 for unlimited depth (full recursive search)

    -h, --help                   Show this help message and exit

EXAMPLES:
    # Default behavior (2 levels deep)
    $0

    # Process only current directory (no subdirectories)
    $0 -L 1

    # Process three levels deep
    $0 -L 3

    # Process all subdirectories recursively (unlimited depth)
    $0 -L 0

The script scans for video files that don't have transcoding markers
(.fmpg., .orig., or .hbrk.) and moves them to trash after confirmation.
EOF
}

# Parse command-line arguments
# Sets global variable GLOBAL_MAX_DEPTH if -L or --max-depth is provided
parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -L|--max-depth)
                if [ $# -lt 2 ]; then
                    error "Error: --max-depth requires a value"
                    error "Example: --max-depth 3"
                    error "Use 0 for unlimited depth (full recursive search)"
                    exit 1
                fi
                local depth_value="$2"
                
                if ! validate_depth "$depth_value"; then
                    error "Error: Invalid depth value '$depth_value'"
                    error "Depth must be a non-negative integer (0 for unlimited, or positive integer)"
                    exit 1
                fi
                
                GLOBAL_MAX_DEPTH=$(sanitize_value "$depth_value")
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                error "Error: Unknown option '$1'"
                error "Use --help for usage information"
                exit 1
                ;;
        esac
    done
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

# Parse command-line arguments
parse_arguments "$@"

# Video file extensions to process
video_extensions=("mp4" "mkv" "avi" "mov" "m4v" "webm" "flv" "wmv")

# Get list of directories to check (uses GLOBAL_MAX_DEPTH for configurable depth)
directories=(".")
max_depth="${GLOBAL_MAX_DEPTH:-2}"

# Find subdirectories based on configured depth
# If depth is 0 (unlimited), find all directories recursively
# Otherwise, find directories up to the specified depth (maxdepth includes current dir, so we use maxdepth-1 for subdirs)
if [ "$max_depth" -eq 0 ]; then
    while IFS= read -r dir; do
        if [ -n "$dir" ] && [ -d "$dir" ]; then
            directories+=("$dir")
        fi
    done < <(find . -type d ! -path . 2>/dev/null)
else
    # For depth > 0, find all directories up to maxdepth (excluding current directory)
    # maxdepth 2 = current dir (.) + one level of subdirectories
    # So we find directories at depth 1 through (maxdepth-1)
    subdir_depth=$((max_depth - 1))
    if [ "$subdir_depth" -gt 0 ]; then
        while IFS= read -r dir; do
            if [ -n "$dir" ] && [ -d "$dir" ]; then
                directories+=("$dir")
            fi
        done < <(find . -mindepth 1 -maxdepth "$subdir_depth" -type d 2>/dev/null)
    fi
fi

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

