#!/bin/bash

# Single-file remux with audio track selection. Lists audio tracks, lets the user
# choose which to keep, and remuxes to a Boiler-compatible file (stream copy, no
# transcoding). Output container matches input (e.g. MKV→MKV) so all subtitles
# are preserved; use case: drop commentary or extra language tracks before encoding.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_usage() {
    cat >&2 <<EOF
Usage: $0 [-h] <video_file>

Remux a single video file with selected audio tracks only (no transcoding).
Lists audio streams, prompts for which to keep, and writes a Boiler-compatible
file. Output container matches input (e.g. MKV→MKV, MP4→MP4) so all subtitles
are preserved.

OPTIONS:
    -h, --help    Show this help and exit

Requires exactly one video file path. Output: same directory, {base}.remux.{ext}
EOF
}

# Get video codec using ffprobe (same logic as remux-only.sh)
get_video_codec() {
    local video_file="$1"
    local codec
    codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null | head -1 | tr -d '\n\r')
    if [ -z "$codec" ]; then
        error "Could not determine video codec"
        return 1
    fi
    echo "$codec"
}

# Count video streams (for safe HEVC tagging: only tag when exactly one video stream)
count_video_streams() {
    local input="$1"
    local csv
    csv=$(ffprobe -v error -select_streams v -show_entries stream=index -of csv=p=0 "$input" 2>/dev/null) || true
    if [ -z "$csv" ]; then
        echo "0"
        return 0
    fi
    local n=0
    for _ in $(echo "$csv" | tr ',' ' '); do n=$((n + 1)); done
    echo "$n"
}

# Check if video codec can be copied into MP4 (same as remux-only.sh)
is_codec_mp4_compatible() {
    local codec="$1"
    local codec_lower
    codec_lower=$(echo "$codec" | tr '[:upper:]' '[:lower:]')
    case "$codec_lower" in
        wmv3|wmv1|wmv2|vc1|rv40|rv30|theora) return 1 ;;
        *) return 0 ;;
    esac
}

# Probe subtitle streams: output one codec_name per line (order = 0-based subtitle index).
# Used to only map MP4-compatible subtitle codecs (e.g. mov_text); subrip/srt cannot be stream-copied into MP4.
probe_subtitle_codecs() {
    local input="$1"
    ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 "$input" 2>/dev/null || true
}

# Return 0 if subtitle codec can be stream-copied into MP4, 1 otherwise (e.g. subrip/srt cannot).
is_subtitle_codec_mp4_compatible() {
    local codec="$1"
    local codec_lower
    codec_lower=$(echo "$codec" | tr '[:upper:]' '[:lower:]')
    case "$codec_lower" in
        mov_text) return 0 ;;
        *) return 1 ;;
    esac
}

# Get output format and extension from input path. Echo "format_name ext" (e.g. "matroska mkv" or "mp4 mp4").
# Same container as input preserves all subtitle codecs (e.g. SubRip in MKV); unknown defaults to matroska.
get_output_format_from_input() {
    local input_path="$1"
    local ext
    ext=$(echo "${input_path##*.}" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
        mkv)   echo "matroska mkv" ;;
        mp4|m4v|mov) echo "mp4 mp4" ;;
        webm)  echo "webm webm" ;;
        *)     echo "matroska mkv" ;;
    esac
}

check_requirements() {
    if ! command -v ffmpeg &> /dev/null; then
        error "ffmpeg is not installed or not in PATH"
        exit 1
    fi
    if ! command -v ffprobe &> /dev/null; then
        error "ffprobe is not installed or not in PATH"
        exit 1
    fi
}

# Probe audio streams: output one label per line (codec + optional language/title). Order = 0-based audio index.
probe_audio_streams() {
    local input="$1"
    local csv
    csv=$(ffprobe -v error -select_streams a -show_entries stream=codec_name:stream_tags=language,title -of csv=p=0 "$input" 2>/dev/null) || true
    if [ -z "$csv" ]; then
        return 0
    fi
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        # CSV: codec_name,language,title (tags may be empty)
        local codec lang title
        codec=$(echo "$line" | cut -d',' -f1)
        lang=$(echo "$line" | cut -d',' -f2)
        title=$(echo "$line" | cut -d',' -f3)
        local label="$codec"
        [ -n "$lang" ] && [ "$lang" != "N/A" ] && label="$label ($lang)"
        [ -n "$title" ] && [ "$title" != "N/A" ] && label="$label - $title"
        echo "$label"
    done <<< "$csv"
    return 0
}

# Output 0-based video stream indices that have valid dimensions (width and height > 0).
# Used for non-MP4 so we skip attached-pic streams with no dimensions (they break the muxer).
get_muxable_video_stream_indices() {
    local input="$1"
    local csv
    csv=$(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0 "$input" 2>/dev/null) || true
    if [ -z "$csv" ]; then
        return 0
    fi
    local idx=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local w h
        w=$(echo "$line" | cut -d',' -f1)
        h=$(echo "$line" | cut -d',' -f2)
        if [ -n "$w" ] && [ -n "$h" ] && [ "$w" != "N/A" ] && [ "$h" != "N/A" ] && [ "$w" -gt 0 ] 2>/dev/null && [ "$h" -gt 0 ] 2>/dev/null; then
            echo "$idx"
        fi
        idx=$((idx + 1))
    done <<< "$csv"
    return 0
}

# Probe video streams: one label per line (codec + optional title/filename). Order = 0-based video index.
probe_video_streams() {
    local input="$1"
    local csv
    csv=$(ffprobe -v error -select_streams v -show_entries stream=codec_name:stream_tags=title,filename -of csv=p=0 "$input" 2>/dev/null) || true
    if [ -z "$csv" ]; then
        return 0
    fi
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local codec title filename
        codec=$(echo "$line" | cut -d',' -f1)
        title=$(echo "$line" | cut -d',' -f2)
        filename=$(echo "$line" | cut -d',' -f3)
        local label="$codec"
        if [ -n "$title" ] && [ "$title" != "N/A" ]; then
            label="$label ($title)"
        elif [ -n "$filename" ] && [ "$filename" != "N/A" ]; then
            label="$label ($filename)"
        fi
        echo "$label"
    done <<< "$csv"
    return 0
}

# Count audio streams (ffprobe -select_streams a -show_entries stream=index -of csv)
count_audio_streams() {
    local input="$1"
    local csv
    csv=$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$input" 2>/dev/null) || true
    if [ -z "$csv" ]; then
        echo "0"
        return 0
    fi
    local n=0
    for _ in $(echo "$csv" | tr ',' ' '); do n=$((n + 1)); done
    echo "$n"
}

main() {
    local input_file=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            -*)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [ -n "$input_file" ]; then
                    error "Exactly one video file required. Got multiple arguments."
                    show_usage
                    exit 1
                fi
                input_file="$1"
                ;;
        esac
        shift
    done

    if [ -z "$input_file" ]; then
        error "No input file specified."
        show_usage
        exit 1
    fi

    if [ ! -f "$input_file" ]; then
        error "File not found: $input_file"
        exit 1
    fi

    check_requirements

    # Output container matches input so all subtitles can be preserved (e.g. SubRip in MKV).
    local output_format output_ext
    read -r output_format output_ext <<< "$(get_output_format_from_input "$input_file")"

    local num_audio
    num_audio=$(count_audio_streams "$input_file")
    if [ "$num_audio" -eq 0 ]; then
        info "No audio tracks to select. Nothing to do."
        exit 0
    fi
    if [ "$num_audio" -eq 1 ]; then
        info "Only one audio track; nothing to select. Nothing to do."
        exit 0
    fi

    # Get video codec; only enforce MP4 compatibility when output is MP4
    local video_codec
    video_codec=$(get_video_codec "$input_file") || exit 1
    if [ "$output_format" = "mp4" ] && ! is_codec_mp4_compatible "$video_codec"; then
        error "Video codec '$video_codec' is not compatible with MP4 container (cannot copy without transcoding)."
        exit 1
    fi

    # Build list of video streams for header display
    local -a video_labels
    local line
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        video_labels+=("$line")
    done < <(probe_video_streams "$input_file")

    # Build list of audio streams (labels only; position is 0-based audio index for -map 0:a:N)
    local -a labels
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        labels+=("$line")
    done < <(probe_audio_streams "$input_file")

    # Display 1-based list: video streams first, then audio tracks
    echo ""
    if [ ${#video_labels[@]} -gt 0 ]; then
        info "Video streams:"
        for j in "${!video_labels[@]}"; do
            echo "  $((j + 1)): ${video_labels[$j]}"
        done
        echo ""
    fi
    info "Audio tracks:"
    for j in "${!labels[@]}"; do
        echo "  $((j + 1)): ${labels[$j]}"
    done
    echo ""
    printf "Audio tracks to keep (e.g. 1,3 or 'all'): "
    read -r user_input || true
    user_input=$(echo "$user_input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Parse selection -> 0-based audio indices for -map 0:a:N
    local -a selected=()
    if [ -z "$user_input" ] || [ "$user_input" = "all" ]; then
        for j in "${!labels[@]}"; do selected+=("$j"); done
    else
        local raw
        raw=$(echo "$user_input" | tr ',' ' ')
        for tok in $raw; do
            if ! echo "$tok" | grep -qE '^[0-9]+$'; then
                error "Invalid input: '$tok' is not a number."
                exit 1
            fi
            local one_based=$tok
            if [ "$one_based" -lt 1 ] || [ "$one_based" -gt "${#labels[@]}" ]; then
                error "Track number $one_based is out of range (1 to ${#labels[@]})."
                exit 1
            fi
            local zero_based=$((one_based - 1))
            # Avoid duplicates
            local seen=0
            for s in "${selected[@]}"; do
                if [ "$s" = "$zero_based" ]; then seen=1; break; fi
            done
            [ "$seen" -eq 0 ] && selected+=("$zero_based")
        done
    fi

    if [ ${#selected[@]} -eq 0 ]; then
        error "You must keep at least one audio track (or use 'all')."
        exit 1
    fi

    # Keep-all = no-op: no remux when user chose to keep every audio track
    if [ ${#selected[@]} -eq ${#labels[@]} ]; then
        info "Keeping all audio tracks; nothing to do."
        exit 0
    fi

    # MP4 + multiple video streams: warn and require explicit confirmation before stripping to first video only
    local num_video
    num_video=$(count_video_streams "$input_file")
    if [ "$output_format" = "mp4" ] && [ "$num_video" -gt 1 ]; then
        warn "Only the first video stream will be included; other video streams (e.g. cover art) will be dropped."
        printf "Type 'yes' to continue: "
        read -r confirm || true
        if [ "$confirm" != "yes" ]; then
            info "Aborted."
            exit 0
        fi
    fi

    # Output path: same directory, {base}.remux.{ext} (ext matches input container)
    local dirname base_name
    dirname=$(dirname "$input_file")
    base_name=$(basename "$input_file")
    base_name="${base_name%.*}"
    if [ -z "$base_name" ]; then
        base_name="output"
    fi
    local output_file
    if [ "$dirname" = "." ]; then
        output_file="${base_name}.remux.${output_ext}"
    else
        output_file="${dirname}/${base_name}.remux.${output_ext}"
    fi

    if [ "$output_file" = "$input_file" ]; then
        error "Output path would overwrite input file. Aborting."
        exit 1
    fi
    if [ -f "$output_file" ]; then
        error "Output file already exists: $output_file. Remove it or choose a different source. Aborting."
        exit 1
    fi

    # Build ffmpeg: -i input, video map (MP4: first only; non-MP4: only streams with valid dimensions to avoid attached-pic mux errors), -map 0:a:N, then subtitles
    local -a ffmpeg_args=(-i "$input_file")
    if [ "$output_format" = "mp4" ]; then
        ffmpeg_args+=(-map 0:v:0)
    else
        local -a muxable_v
        while IFS= read -r n; do
            [ -z "$n" ] && continue
            muxable_v+=("$n")
        done < <(get_muxable_video_stream_indices "$input_file")
        if [ ${#muxable_v[@]} -eq 0 ]; then
            error "No video streams with valid dimensions found (e.g. only attached pictures)."
            exit 1
        fi
        for n in "${muxable_v[@]}"; do
            ffmpeg_args+=(-map "0:v:$n")
        done
    fi
    for n in "${selected[@]}"; do
        ffmpeg_args+=(-map "0:a:$n")
    done
    if [ "$output_format" = "mp4" ]; then
        # MP4: only map mov_text subtitles; SubRip/SRT cannot be stream-copied into MP4
        local sub_codecs
        sub_codecs=$(probe_subtitle_codecs "$input_file") || true
        local sub_index=0
        local skipped_subs=0
        while IFS= read -r codec; do
            [ -z "$codec" ] && continue
            if is_subtitle_codec_mp4_compatible "$codec"; then
                ffmpeg_args+=(-map "0:s:$sub_index")
            else
                skipped_subs=$((skipped_subs + 1))
            fi
            sub_index=$((sub_index + 1))
        done <<< "$sub_codecs"
        if [ "$skipped_subs" -gt 0 ]; then
            warn "Skipped $skipped_subs subtitle track(s) not supported in MP4 (e.g. SRT); only mov_text is copied."
        fi
    else
        # Same container as input (e.g. Matroska): copy all subtitle streams
        ffmpeg_args+=(-map 0:s)
    fi
    ffmpeg_args+=(-c copy -f "$output_format")
    if [ "$output_format" = "mp4" ]; then
        ffmpeg_args+=(-movflags +faststart)
        local num_video
        num_video=$(count_video_streams "$input_file")
        local codec_lower
        codec_lower=$(echo "$video_codec" | tr '[:upper:]' '[:lower:]')
        if [ "$num_video" -eq 1 ] && { [ "$codec_lower" = "hevc" ] || [ "$codec_lower" = "h265" ]; }; then
            ffmpeg_args+=(-tag:v hvc1)
        fi
    fi
    ffmpeg_args+=("$output_file")

    if ! ffmpeg "${ffmpeg_args[@]}" -loglevel info -stats -y; then
        error "Remux failed. Original file preserved."
        exit 1
    fi

    info "  ✓ Successfully remuxed to: $output_file"
    info "  You can pass this file to Boiler for transcoding."
}

main "$@"
