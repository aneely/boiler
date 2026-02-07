# Context: Video Transcoding Tool

## Overview

Simplified CLI for transcoding video files on macOS using FFmpeg and VideoToolbox hardware acceleration. Automatically determines optimal encoding settings to achieve target bitrates while maintaining quality.

**Status**: macOS-only | **Architecture**: Modular bash script with focused functions

---

## Development Workflow

### Implementation Approval Process

**When presenting options:**
- Present trade-offs clearly
- **Do NOT automatically implement** - wait for explicit approval
- Only implement after user explicitly requests

**Informational questions** ("Is there a way to...", "How would I..."):
- **STRICTLY provide explanation only** - do NOT implement
- Wait for explicit request like "implement this" before changing code

**Future enhancements without specific item:**
- List undone items from PLAN.md
- Decide together which to work on
- Do not implement until one is chosen

### Token Usage

**Always ask before taking action:**
- Git operations, destructive modifications, dependency installs
- Present options and wait for confirmation

### Reverting Changes

**Prefer version control:**
- `git restore <file>...` to discard specific files
- `git restore .` to discard all uncommitted changes
- Never manually edit line-by-line to undo

### Testing Before Committing

**CRITICAL: MANDATORY TESTING REQUIREMENT**

Before committing ANY changes:
1. **Run test suite**: `bash test_boiler.sh` - MUST exit code 0
2. **Verify output**: Confirm "Passed: X, Failed: 0"
3. **Fix failures**: All failures must be fixed before committing
4. **Never skip**: Even for minor changes

**This is a hard requirement** - commits without tests are incomplete.

### Commit Messages

**Do not add** `Co-authored-by:` or trailers unless explicitly requested.

### Documentation Update Directive

**When user asks to "update for next session" or "remember state":**

1. **PROJECT-CONTEXT.md**: New architectural changes, refactorings, technical decisions
2. **PLAN.md**: Feature status, roadmap updates, known issues
3. **README.md**: User-facing features, usage, troubleshooting

---

## Architecture Summary

The tool is a modular bash script (`boiler.sh`) organized into focused functions:

1. **Discovers video files** using `find_all_video_files()`, skipping already-encoded files
2. **Preprocesses** non-QuickLook formats (remuxes if within tolerance)
3. **Analyzes properties** (resolution, duration) via `ffprobe`
4. **Determines target bitrate** based on resolution
5. **Short-circuits** if source already within ±5% of target or below target
6. **Iteratively finds optimal quality** using constant quality mode (`-q:v`)
7. **Performs multi-pass transcoding** if needed (up to 3 passes with interpolation)

See `docs/TECHNICAL.md` for algorithm details and `docs/ARCHITECTURE.md` for structural decomposition.

---

## File Structure

```
boiler/
├── boiler.sh              # Main transcoding script (modular functions)
├── test_boiler.sh         # Legacy test suite (~6s)
├── run-bats-tests.sh      # Bats test runner
├── copy-1080p-test.sh     # Helper: Copy 1080p test video
├── copy-4k-test.sh        # Helper: Copy 4K test video
├── cleanup-mp4.sh         # Helper: Remove .mp4 files
├── cleanup-originals.sh   # Helper: Remove .orig. files
├── remux-only.sh          # Helper: Remux to MP4
├── .gitignore
├── CLAUDE.md              # AI assistant context (this workflow)
├── PROJECT-CONTEXT.md     # Technical context (this file)
├── PLAN.md                # Development roadmap
├── README.md              # User documentation
├── docs/                  # Technical documentation
│   ├── ARCHITECTURE.md    # Structural decomposition and functional units
│   └── TECHNICAL.md       # Algorithm and design details
├── tests/                 # Bats test suite (~16s parallel)
│   ├── helpers/
│   └── *.bats
└── testdata/              # Test video files
```

---

## Core Components

### Resolution Tiers & Targets
- **2160p (4K)**: 11 Mbps
- **1080p (Full HD)**: 8 Mbps  
- **720p (HD)**: 5 Mbps
- **480p (SD)**: 2.5 Mbps
- **Tolerance**: ±5% of target

### File Naming Convention
- **Transcoded**: `{base}.fmpg.{bitrate}.Mbps.{ext}`
- **Below target**: `{base}.orig.{bitrate}.Mbps.{ext}`
- **Markers**: `.fmpg.`, `.orig.`, `.hbrk.` indicate processed files

### Dependencies
- `ffmpeg`: Video encoding
- `ffprobe`: Video analysis
- `bc`: Bitrate calculations

---

## Known Issues

- **FFmpeg cleanup on interrupt**: Signal handling implemented but may need verification with input seeking

## Current Limitations

- **macOS-only**: VideoToolbox requires macOS
- See README for user-facing limits (depth, bitrate override, etc.)

---

## Quick Reference: Function Categories

**Utility**: file discovery, bitrate measurement, filename parsing
**Configuration**: target bitrate calculation, argument parsing, validation
**Transcoding**: sample transcoding, quality optimization, full video encoding
**Preprocessing**: non-QuickLook format handling
**Orchestration**: main flow control, preprocessing, batch processing

See inline comments in `boiler.sh` for detailed function documentation.
