# Unify Input Extension Lists Plan

## Objective

Eliminate duplicated definitions of "which file extensions are video files" and "which extensions are non-QuickLook (need remuxing)" by introducing a single source of truth. Today, adding a new format (e.g. `.mpg`, `.mpeg`, `.ts`) requires editing the same lists in multiple places across `boiler.sh`, `cleanup-originals.sh`, and `remux-only.sh`, and keeping `is_non_quicklook_format()` case statements in sync. Unifying these reduces drift and human error.

**Status**: Ready to execute | **Blocked on**: User go-ahead

## Current State

| Concept | Where defined | Count |
|--------|----------------|-------|
| **Video extensions** (discovery) | `find_all_video_files()` and `find_skipped_video_files()` in boiler.sh; top-level in cleanup-originals.sh | 3 copies |
| **Non-QuickLook extensions** (remux) | `preprocess_non_quicklook_files()` in boiler.sh; remux-only.sh | 2 copies |
| **is_non_quicklook_format()** (case statement) | boiler.sh; remux-only.sh | 2 copies (same list as non-QuickLook) |

All lists are currently identical across copies. The only source of truth is "we updated them together when we added .mpg/.mpeg/.ts."

## Requirements

1. **Single source of truth**: One place that defines (a) the list of video file extensions used for discovery, and (b) the list of non-QuickLook extensions used for remux/preprocessing.
2. **All three scripts use it**: boiler.sh, cleanup-originals.sh, and remux-only.sh must obtain these lists from the shared definition (no local copies of the full arrays).
3. **is_non_quicklook_format() stays in sync**: The logic that decides "is this extension non-QuickLook?" must use the same list. Options: (a) derive from the shared non-QuickLook array (e.g. check membership), or (b) keep a case statement in each script but document that it must match the shared array (weaker).
4. **No behavior change**: Same extensions supported; same discovery and remux behavior. Existing tests must pass.
5. **Scripts remain runnable standalone**: Each script must be able to find and source the shared file when run from the project (or from PATH if invoked that way). Sourcing must not assume a specific CWD.

## Proposed Approach

- **Shared definitions file**: Add a small file in the project (e.g. `lib/extensions.sh` or `shared-extensions.sh` in repo root) that:
  - Defines `VIDEO_EXTENSIONS` as an array: all extensions used for file discovery (mp4, mkv, avi, mov, m4v, webm, flv, wmv, mpg, mpeg, ts).
  - Defines `NON_QUICKLOOK_EXTENSIONS` as an array: the subset that requires remuxing for QuickLook (mkv, wmv, avi, webm, flv, mpg, mpeg, ts).
  - Does not depend on other project files (no sourcing of boiler.sh, etc.), so it can be sourced by any script without circular dependency.
- **Sourcing**: Each script that needs these lists resolves its own directory (e.g. `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`) and sources the shared file (e.g. `source "$SCRIPT_DIR/lib/extensions.sh"`). If the shared file is in repo root next to the scripts, path is straightforward.
- **Use in boiler.sh**: Replace local `video_extensions` in `find_all_video_files()` and `find_skipped_video_files()` with the sourced array (e.g. `VIDEO_EXTENSIONS`). Replace local `non_quicklook_extensions` in `preprocess_non_quicklook_files()` with the sourced array (e.g. `NON_QUICKLOOK_EXTENSIONS`). Optionally refactor `is_non_quicklook_format()` to loop over `NON_QUICKLOOK_EXTENSIONS` and check membership instead of a case statement, so the list is the only definition.
- **Use in cleanup-originals.sh**: Source the shared file; replace the top-level `video_extensions` array with the sourced array.
- **Use in remux-only.sh**: Source the shared file; replace local `non_quicklook_extensions` with the sourced array. Replace the `is_non_quicklook_format()` case statement with either (a) the same membership check used in boiler.sh (if we expose a function from the shared file or reimplement the same one-liner), or (b) sourcing boiler.sh for that function (heavier; may pull in more than needed). Prefer (a): shared file can define a small `is_non_quicklook_format()` that uses `NON_QUICKLOOK_EXTENSIONS`, and both boiler.sh and remux-only.sh source that file and use the function. Then neither script has a local case statement.
- **Docs**: Update docs/ARCHITECTURE.md (and any other references to "update video_extensions / non_quicklook_extensions in boiler.sh, cleanup-originals.sh, remux-only.sh") to point to the single shared file.

## Todos (execution order)

- [ ] **Create shared definitions file**  
  Add e.g. `lib/extensions.sh` (creating `lib/` if needed) with:
  - `VIDEO_EXTENSIONS=(...)` — same list as today (mp4 mkv avi mov m4v webm flv wmv mpg mpeg ts).
  - `NON_QUICKLOOK_EXTENSIONS=(...)` — same list as today (mkv wmv avi webm flv mpg mpeg ts).
  - Optional but recommended: `is_non_quicklook_format()` function that takes a filename, extracts extension (lowercase), and returns 0 if it's in `NON_QUICKLOOK_EXTENSIONS`, 1 otherwise. This keeps the "non-QuickLook" concept in one place and removes the need for case statements in the scripts.
  - Brief comment at top: purpose of the file and that adding a new format means editing only here.

- [ ] **Update boiler.sh**  
  - Near top (after any set/flags), resolve script dir and source the shared file (e.g. `source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/extensions.sh"` or equivalent).
  - In `find_all_video_files()` and `find_skipped_video_files()`: remove local `video_extensions` array; use `VIDEO_EXTENSIONS` (or "${VIDEO_EXTENSIONS[@]}" in loops).
  - In `preprocess_non_quicklook_files()`: remove local `non_quicklook_extensions`; use `NON_QUICKLOOK_EXTENSIONS`.
  - If shared file defines `is_non_quicklook_format()`: remove the local `is_non_quicklook_format()` implementation in boiler.sh so the sourced one is used. If shared file does not define it: keep local implementation but have it use the sourced `NON_QUICKLOOK_EXTENSIONS` array (e.g. loop and check membership) instead of a case statement.

- [ ] **Update cleanup-originals.sh**  
  - After shebang and any set, resolve script dir and source the shared file.
  - Remove the local `video_extensions=(...)` assignment; use the sourced array name (e.g. `VIDEO_EXTENSIONS`) everywhere that currently uses `video_extensions`. Adjust loop variable if the name changes (e.g. `for ext in "${VIDEO_EXTENSIONS[@]}"`).

- [ ] **Update remux-only.sh**  
  - After shebang and any set, resolve script dir and source the shared file.
  - Remove the local `non_quicklook_extensions` array and use the sourced array (e.g. `NON_QUICKLOOK_EXTENSIONS`) in the loop that finds files.
  - If shared file defines `is_non_quicklook_format()`: remove the local `is_non_quicklook_format()` in remux-only.sh so the sourced one is used. If not: replace the case statement with a membership check over the sourced array.
  - Update any user-facing message that lists extensions (e.g. "Not a non-QuickLook format (mkv, wmv, ...)") to avoid hardcoding; either reference the array in a comment for maintainers or build the message from the array if feasible.

- [ ] **Update documentation**  
  - In docs/ARCHITECTURE.md, update "Adding New File Formats" (or equivalent) to say that new extensions are added in the single shared file (e.g. `lib/extensions.sh`), and that boiler.sh, cleanup-originals.sh, and remux-only.sh source it. Remove or adjust the line that says to update arrays in all three scripts.
  - In PROJECT-CONTEXT.md or README, if extension lists are mentioned, point to the shared file.

- [ ] **Tests**  
  - Run full test suite: `bash test_boiler.sh` and Bats (`run-bats-tests.sh`). All must pass.
  - If tests currently source boiler.sh and depend on functions/arrays being defined there, ensure sourcing the shared file from boiler.sh does not break test isolation (e.g. test helpers that source boiler.sh should still see the same behavior). Fix any tests that assumed a specific script layout.

## Out of Scope

- Changing which extensions are in each list (only unifying where they are defined).
- Unifying other duplicated logic between boiler.sh and remux-only.sh (e.g. other shared functions).

## Success Criteria

- Adding a new video format (e.g. `.m2ts`) requires editing only the shared definitions file (and possibly `is_non_quicklook_format()` if it's defined there). No edits to boiler.sh, cleanup-originals.sh, or remux-only.sh for the list contents.
- All existing tests pass. Discovery and remux behavior unchanged.
- Documentation accurately describes the single source of truth for extension lists.
