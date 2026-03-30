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
(.fmpg., .orig., or .hbrk.) and identifies which ones have a processed
counterpart in the same directory. Only files WITH a counterpart are
offered for trashing. Files without a counterpart are reported but left
alone.

A "processed counterpart" is any file in the same directory whose name
matches one of these patterns (where BASE is the original's name without
its extension):
  BASE.fmpg.*.mp4   — transcoded by boiler.sh
  BASE.orig.*.mp4   — remuxed or within-tolerance by boiler.sh
  BASE.hbrk.*.mp4   — hardbreak variant
  BASE.remux.*      — QuickLook-fixed or audio-selected remux
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

# Check if an original file has a processed counterpart in the same directory.
# A counterpart is any file whose name starts with {base}. and contains a boiler
# marker (.fmpg., .orig., .hbrk.) as an .mp4, OR starts with {base}.remux. with
# any extension.
# Arguments: original_file_path
# Returns: 0 (true) if counterpart exists, 1 (false) if not
has_processed_counterpart() {
    local original_file="$1"
    local basename
    basename=$(basename "$original_file")
    local dir
    dir=$(dirname "$original_file")
    local base_part="${basename%.*}"

    # Escape glob metacharacters in base_part so find -iname treats them literally.
    # Brackets in particular are common in video filenames (e.g. "[belize] footage.mp4")
    # and would otherwise be interpreted as character classes by find's glob engine.
    local escaped_base
    escaped_base=$(printf '%s' "$base_part" | sed 's/[][*?]/\\&/g')

    # Boiler-marker counterparts always output .mp4
    local markers=("fmpg" "orig" "hbrk")
    for marker in "${markers[@]}"; do
        local found
        found=$(find "$dir" -maxdepth 1 -type f \
            -iname "${escaped_base}.${marker}.*.mp4" 2>/dev/null | head -1)
        [ -n "$found" ] && return 0
    done

    # .remux. counterparts (remux-only.sh Phase 2, remux-select-audio.sh) — any extension
    local found_remux
    found_remux=$(find "$dir" -maxdepth 1 -type f \
        -iname "${escaped_base}.remux.*" 2>/dev/null | head -1)
    [ -n "$found_remux" ] && return 0

    return 1
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

# Main function
main() {
    # Save stdin to fd 3 before process substitutions in the scan loops can clobber it.
    # Used later to read the confirmation prompt from the actual terminal.
    exec 3<&0

    # Parse command-line arguments
    parse_arguments "$@"

    # Video file extensions to process
    local video_extensions=("mp4" "mkv" "avi" "mov" "m4v" "webm" "flv" "wmv" "mpg" "mpeg" "ts")

    # Get list of directories to check (uses GLOBAL_MAX_DEPTH for configurable depth)
    local directories=(".")
    local max_depth="${GLOBAL_MAX_DEPTH:-2}"

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
        local subdir_depth=$((max_depth - 1))
        if [ "$subdir_depth" -gt 0 ]; then
            while IFS= read -r dir; do
                if [ -n "$dir" ] && [ -d "$dir" ]; then
                    directories+=("$dir")
                fi
            done < <(find . -mindepth 1 -maxdepth "$subdir_depth" -type d 2>/dev/null)
        fi
    fi

    local files_with_counterpart=()
    local files_without_counterpart=()
    local directories_checked=0
    local directories_with_originals=0
    local directories_skipped=0

    info "Scanning directories for original video files..."
    echo ""

    # Process each directory
    local dir
    for dir in "${directories[@]}"; do
        directories_checked=$((directories_checked + 1))
        local local_original_files=()
        local local_transcoded_files=0

        # Find video files in this directory — single find call to avoid per-extension
        # process substitutions that exhaust the fd table at high depths.
        # Build: -iname "*.mp4" -o -iname "*.mkv" -o ...
        local find_name_args=()
        local first_ext=1
        local ext
        for ext in "${video_extensions[@]}"; do
            if [ "$first_ext" -eq 1 ]; then
                find_name_args+=("-iname" "*.${ext}")
                first_ext=0
            else
                find_name_args+=("-o" "-iname" "*.${ext}")
            fi
        done
        local tmp_found
        tmp_found=$(find "$dir" -maxdepth 1 -type f \( "${find_name_args[@]}" \) 2>/dev/null)
        while IFS= read -r found; do
            if [ -n "$found" ] && [ -f "$found" ]; then
                if has_transcoding_marker "$found"; then
                    local_transcoded_files=$((local_transcoded_files + 1))
                else
                    local_original_files+=("$found")
                fi
            fi
        done <<< "$tmp_found"

        # Show directory status
        if [ ${#local_original_files[@]} -gt 0 ]; then
            directories_with_originals=$((directories_with_originals + 1))
            local dir_with=0
            local dir_without=0
            local file
            for file in "${local_original_files[@]}"; do
                if has_processed_counterpart "$file"; then
                    files_with_counterpart+=("$file")
                    dir_with=$((dir_with + 1))
                else
                    files_without_counterpart+=("$file")
                    dir_without=$((dir_without + 1))
                fi
            done
            local label="$dir"
            [ "$dir" = "." ] && label="current directory"
            info "Checking $label: ${dir_with} with counterpart, ${dir_without} without counterpart"
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

    # Report files without counterparts — left alone
    if [ ${#files_without_counterpart[@]} -gt 0 ]; then
        echo ""
        warn "${#files_without_counterpart[@]} original file(s) have no processed counterpart and will NOT be trashed:"
        for file in "${files_without_counterpart[@]}"; do
            echo "  - $file"
        done
    fi

    # Check if anything is eligible for trashing
    if [ ${#files_with_counterpart[@]} -eq 0 ]; then
        echo ""
        info "No original files with a processed counterpart found. Nothing to trash."
        return 0
    fi

    echo ""

    # Show files to be moved
    warn "Found ${#files_with_counterpart[@]} original file(s) with a processed counterpart to move to trash:"
    for file in "${files_with_counterpart[@]}"; do
        echo "  - $file"
    done

    # Confirm before proceeding
    echo ""
    if [ -n "${CLEANUP_CONFIRM:-}" ]; then
        REPLY="$CLEANUP_CONFIRM"
    else
        read -p "Move these files to trash? (y/N): " -n 1 -r <&3 || true
    fi
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Cancelled."
        return 0
    fi

    # Move files to trash
    local moved_count=0
    local failed_count=0

    for file in "${files_with_counterpart[@]}"; do
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
    local skipped_count=${#files_without_counterpart[@]}
    if [ $failed_count -eq 0 ]; then
        if [ $skipped_count -gt 0 ]; then
            info "Cleanup complete! Moved ${moved_count} file(s) to trash. ${skipped_count} file(s) skipped (no counterpart)."
        else
            info "Cleanup complete! Moved ${moved_count} file(s) to trash."
        fi
    else
        warn "Cleanup complete with errors. Moved ${moved_count} file(s) to trash, ${failed_count} failed. ${skipped_count} skipped (no counterpart)."
        exit 1
    fi
}

# Run main function (unless in test mode)
if [ -z "${CLEANUP_TEST_MODE:-}" ]; then
    main "$@"
fi

