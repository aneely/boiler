# Architecture Documentation

Structural decomposition and orchestration flow for the video transcoding tool.

---

## Overview

The transcoding tool is implemented as a modular bash script (`boiler.sh`) organized into focused, composable functions. Each functional unit has a single responsibility and clear inputs/outputs, making the architecture suitable for both batch processing and potential future subcommand interfaces.

---

## Functional Units

The codebase is organized into seven functional categories:

### 1. Discovery & Listing

Functions for finding and filtering video files.

| Function | Responsibility |
|----------|---------------|
| `find_all_video_files()` | Discover videos, filter out processed files |
| `find_skipped_video_files()` | List already-processed files |
| `should_skip_file()` | Check if file should be skipped based on markers |
| `has_encoded_version()` | Check if original has encoded companion |
| `has_original_file()` | Check if encoded file has original companion |
| `extract_original_filename()` | Parse encoded filename to get original |

**Output**: File paths (one per line, sorted alphabetically)

### 2. File Analysis

Functions for extracting video properties.

| Function | Responsibility |
|----------|---------------|
| `get_video_resolution()` | Video height in pixels |
| `get_video_duration()` | Duration in seconds |
| `measure_bitrate()` | Calculate bitrate from file or metadata |
| `get_source_bitrate()` | Wrapper for source file bitrate |
| `get_video_codec()` | Detect video codec name |

**Output**: Numeric values (resolution, duration, bitrate in bps, codec name)

### 3. Target & Decision Logic

Functions for determining targets and making processing decisions.

| Function | Responsibility |
|----------|---------------|
| `calculate_target_bitrate()` | Resolution-based target (2160p→11Mbps, 1080p→8Mbps, etc.) |
| `is_within_tolerance()` | Check if bitrate within ±5% of target |
| `is_non_quicklook_format()` | Detect MKV, WMV, AVI, WEBM, FLV |
| `is_codec_mp4_compatible()` | Check if codec can be copied to MP4 |

**Output**: Target values (Mbps/bps), boolean decisions (0/1 exit codes)

### 4. Remuxing

Functions for format conversion without transcoding.

| Function | Responsibility |
|----------|---------------|
| `remux_to_mp4()` | Copy streams to MP4 container |
| `remux_mkv_to_mp4()` | Backward compatibility alias |
| `handle_non_quicklook_at_target()` | Remux or compatibility-transcode |
| `is_mkv_file()` | MKV format detection |

**Output**: New MP4 file path, transcoding flag for incompatible codecs

### 5. Quality Optimization

Functions for finding optimal encoding quality.

| Function | Responsibility |
|----------|---------------|
| `calculate_sample_points()` | Determine sample positions (1-3 samples) |
| `transcode_sample()` | Transcode 60s segment with quality setting |
| `find_optimal_quality()` | Iterative search for quality value |
| `calculate_adjusted_quality()` | Second-pass adjustment algorithm |
| `calculate_interpolated_quality()` | Third-pass linear interpolation |

**Output**: Quality value (0-100), bitrate estimates from samples

### 6. Full Transcoding

Functions for complete video encoding.

| Function | Responsibility |
|----------|---------------|
| `transcode_full_video()` | Encode entire file with quality setting |
| `transcode_video()` | **Orchestrates complete single-file workflow** |
| `cleanup_samples()` | Remove temporary sample files |

**Output**: Transcoded file with `.fmpg.{bitrate}.Mbps.{ext}` naming

### 7. Batch Orchestration

Functions for coordinating multiple files.

| Function | Responsibility |
|----------|---------------|
| `preprocess_non_quicklook_files()` | Batch remux pass before main processing |
| `main()` | Entry point, batch processor |
| `parse_arguments()` | Command-line argument parsing |
| `check_requirements()` | Dependency validation |

**Output**: Processed file count, progress indicators, exit codes

---

## Flow Composition

The `main()` function composes functional units into the complete workflow:

```
main()
├── parse_arguments()
│   └── validate_bitrate() / validate_depth()
├── check_requirements()
├── preprocess_non_quicklook_files()
│   ├── find_all_non_quicklook_files()
│   ├── get_video_duration()
│   ├── get_source_bitrate()
│   ├── calculate_target_bitrate()
│   ├── is_within_tolerance()
│   ├── is_codec_mp4_compatible()
│   └── remux_to_mp4() / handle_non_quicklook_at_target()
├── find_all_video_files()
│   └── should_skip_file()
│       └── has_encoded_version()
└── for each file:
    └── transcode_video()
        ├── get_video_resolution()
        ├── get_video_duration()
        ├── get_source_bitrate()
        ├── calculate_target_bitrate()
        ├── is_within_tolerance() → short-circuit if optimized
        ├── is_non_quicklook_format() → handle_non_quicklook_at_target()
        ├── calculate_sample_points()
        ├── find_optimal_quality()
        │   └── transcode_sample() [1-3 samples]
        ├── transcode_full_video() [Pass 1]
        ├── measure_bitrate()
        ├── calculate_adjusted_quality() → transcode_full_video() [Pass 2 if needed]
        ├── calculate_interpolated_quality() → transcode_full_video() [Pass 3 if needed]
        └── cleanup_samples()
```

### Key Orchestration Points

1. **Preprocessing Pass**: Runs once before discovery to remux optimized non-QuickLook files
2. **Discovery**: Builds work list, filters out already-processed files
3. **Per-File Orchestration**: `transcode_video()` handles complete single-file workflow
4. **Multi-Pass Logic**: Pass 1 (optimized) → Pass 2 (adjusted) → Pass 3 (interpolated)

---

## Function Dependencies

### Input/Output Relationships

```
find_all_video_files()
  ├─ depends on: should_skip_file()
  └─ outputs: file paths

should_skip_file()
  ├─ depends on: has_encoded_version()
  └─ outputs: skip decision (0/1)

transcode_video()
  ├─ depends on:
  │   ├─ get_video_resolution() → resolution
  │   ├─ get_video_duration() → duration
  │   ├─ get_source_bitrate() → source_bitrate
  │   ├─ calculate_target_bitrate() ← resolution
  │   ├─ is_within_tolerance() ← source_bitrate, target
  │   ├─ find_optimal_quality() ← video_file, target, sample_points
  │   │   └─ transcode_sample() ← sample_points
  │   └─ transcode_full_video() ← quality
  └─ outputs: transcoded file
```

---

## CLI Subcommand Potential

The modular architecture naturally supports exposing functional units as CLI subcommands. The seven functional categories map to distinct operations that could be invoked individually:

**Discovery & Analysis**: `discover`, `analyze`, `target`, `should-skip`
**Operations**: `remux`, `optimize-quality`, `transcode`, `batch`

**Implementation Status**: Planned - See [plans/SUBCOMMAND-INTERFACE-PLAN.md](../plans/SUBCOMMAND-INTERFACE-PLAN.md) for detailed specifications including:
- Subcommand specifications with options and output formats
- Implementation phases and modified functions
- Global variable handling strategy
- Signal handling considerations
- Exit code standardization
- Testing strategy

---

## Design Principles

### Single Responsibility
Each function has one clear purpose. For example:
- `find_optimal_quality()` only searches for quality value
- `transcode_full_video()` only encodes with given quality
- `transcode_video()` orchestrates the complete single-file workflow

### Composability
Functions can be chained:
```bash
quality=$(find_optimal_quality "$file" "$target" ...)
transcode_full_video "$file" "$output" "$quality"
```

### Side Effect Transparency
Functions declare their side effects:
- **Pure functions**: `calculate_target_bitrate()`, `is_within_tolerance()`
- **File operations**: `remux_to_mp4()`, `transcode_full_video()`
- **Global state**: `transcode_video()` sets `VIDEO_FILE` for cleanup

### Testability
Modular design enables unit testing:
- Functions tested in isolation (see `tests/*.bats`)
- Mocking at function boundaries
- No reliance on global state for core logic

---

## Extension Points

The architecture supports these extension patterns:

### Adding New Subcommands
Add case in argument parsing, call existing function:
```bash
case "$1" in
    discover)
        find_all_video_files
        ;;
esac
```

### Adding New File Formats
Update `is_non_quicklook_format()` case statement:
```bash
ts|m2ts)  # Add new format
    return 0
    ;;
```

### Adding New Resolution Tiers
Update `calculate_target_bitrate()`:
```bash
elif [ "$resolution" -ge 1440 ]; then
    TARGET_BITRATE_MBPS=10  # 1440p tier
```

---

*See [TECHNICAL.md](TECHNICAL.md) for algorithm details and [PROJECT-CONTEXT.md](../PROJECT-CONTEXT.md) for development workflow.*
