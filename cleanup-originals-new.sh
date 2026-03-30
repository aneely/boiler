#!/bin/bash

set -e

GLOBAL_MAX_DEPTH="${GLOBAL_MAX_DEPTH:-2}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

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
    $0
    $0 -L 1      # Current directory only
    $0 -L 3      # Three levels deep
    $0 -L 0      # Unlimited depth

The script scans for video files that don't have transcoding markers
(.fmpg., .orig., or .hbrk.) and identifies which ones have a processed
counterpart in the same directory. Only files WITH a counterpart are
offered for trashing. Files without a counterpart are reported but left
alone.
EOF
}

parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -L|--max-depth)
                if [ $# -lt 2 ]; then
                    error "Error: --max-depth requires a value"
                    exit 1
                fi
                local val="$2"
                if ! echo "$val" | grep -qE '^[0-9]+$'; then
                    error "Error: Invalid depth value '$val'"
                    error "Depth must be a non-negative integer (0 for unlimited, or positive integer)"
                    exit 1
                fi
                GLOBAL_MAX_DEPTH="$val"
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

VIDEO_EXTENSIONS=("mp4" "mkv" "avi" "mov" "m4v" "webm" "flv" "wmv" "mpg" "mpeg" "ts")

has_transcoding_marker() {
    local basename
    basename=$(basename "$1")
    [[ "$basename" == *".fmpg."* || "$basename" == *".orig."* || "$basename" == *".hbrk."* ]]
}

has_processed_counterpart() {
    local file="$1"
    local dir
    dir=$(dirname "$file")
    local basename
    basename=$(basename "$file")
    local base="${basename%.*}"

    # Escape glob metacharacters for find -iname
    local escaped
    escaped=$(printf '%s' "$base" | sed 's/[][*?]/\\&/g')

    for marker in fmpg orig hbrk; do
        local found
        found=$(find "$dir" -maxdepth 1 -type f -iname "${escaped}.${marker}.*.mp4" 2>/dev/null | head -1)
        [ -n "$found" ] && return 0
    done

    local found_remux
    found_remux=$(find "$dir" -maxdepth 1 -type f -iname "${escaped}.remux.*" 2>/dev/null | head -1)
    [ -n "$found_remux" ] && return 0

    return 1
}

find_video_files_in_dir() {
    local dir="$1"
    local find_args=()
    local first=1
    for ext in "${VIDEO_EXTENSIONS[@]}"; do
        if [ "$first" -eq 1 ]; then
            find_args+=("-iname" "*.${ext}")
            first=0
        else
            find_args+=("-o" "-iname" "*.${ext}")
        fi
    done
    find "$dir" -maxdepth 1 -type f \( "${find_args[@]}" \) 2>/dev/null
}

collect_directories() {
    local max_depth="$GLOBAL_MAX_DEPTH"
    local dirs=(".")

    if [ "$max_depth" -eq 0 ]; then
        while IFS= read -r d; do
            [ -n "$d" ] && [ -d "$d" ] && dirs+=("$d")
        done < <(find . -type d ! -path . 2>/dev/null)
    else
        local subdir_depth=$((max_depth - 1))
        if [ "$subdir_depth" -gt 0 ]; then
            while IFS= read -r d; do
                [ -n "$d" ] && [ -d "$d" ] && dirs+=("$d")
            done < <(find . -mindepth 1 -maxdepth "$subdir_depth" -type d 2>/dev/null)
        fi
    fi

    printf '%s\n' "${dirs[@]}"
}

move_to_trash() {
    local file_path="$1"
    if command -v trash >/dev/null 2>&1; then
        trash "$file_path" 2>/dev/null
    else
        local abs_path
        abs_path=$(cd "$(dirname "$file_path")" && pwd)/$(basename "$file_path")
        osascript -e "tell application \"Finder\" to move POSIX file \"$abs_path\" to trash" 2>/dev/null
    fi
}

main() {
    exec 3<&0
    parse_arguments "$@"

    local files_with_counterpart=()
    local files_without_counterpart=()
    local directories_checked=0
    local directories_with_originals=0
    local directories_skipped=0

    info "Scanning directories for original video files..."
    echo ""

    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        directories_checked=$((directories_checked + 1))
        local originals=()
        local transcoded_count=0

        while IFS= read -r file; do
            [ -n "$file" ] && [ -f "$file" ] || continue
            if has_transcoding_marker "$file"; then
                transcoded_count=$((transcoded_count + 1))
            else
                originals+=("$file")
            fi
        done <<< "$(find_video_files_in_dir "$dir")"

        local label="$dir"
        [ "$dir" = "." ] && label="current directory"

        if [ ${#originals[@]} -gt 0 ]; then
            directories_with_originals=$((directories_with_originals + 1))
            local dir_with=0
            local dir_without=0
            for file in "${originals[@]}"; do
                if has_processed_counterpart "$file"; then
                    files_with_counterpart+=("$file")
                    dir_with=$((dir_with + 1))
                else
                    files_without_counterpart+=("$file")
                    dir_without=$((dir_without + 1))
                fi
            done
            info "Checking $label: ${dir_with} with counterpart, ${dir_without} without counterpart"
        else
            directories_skipped=$((directories_skipped + 1))
            if [ $transcoded_count -gt 0 ]; then
                info "Checking $label: Skipped (${transcoded_count} transcoded file(s), no originals)"
            else
                info "Checking $label: Skipped (no video files)"
            fi
        fi
    done <<< "$(collect_directories)"

    echo ""
    info "Scan complete: Checked ${directories_checked} directory/directories, found originals in ${directories_with_originals}, skipped ${directories_skipped}"

    # Report files without counterparts
    if [ ${#files_without_counterpart[@]} -gt 0 ]; then
        echo ""
        warn "${#files_without_counterpart[@]} original file(s) have no processed counterpart and will NOT be trashed:"
        for file in "${files_without_counterpart[@]}"; do
            echo "  - $file"
        done
    fi

    # Nothing eligible
    if [ ${#files_with_counterpart[@]} -eq 0 ]; then
        echo ""
        info "No original files with a processed counterpart found. Nothing to trash."
        return 0
    fi

    echo ""
    warn "Found ${#files_with_counterpart[@]} original file(s) with a processed counterpart to move to trash:"
    for file in "${files_with_counterpart[@]}"; do
        echo "  - $file"
    done

    # Confirmation
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

    # Trash files
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

if [ -z "${CLEANUP_TEST_MODE:-}" ]; then
    main "$@"
fi
