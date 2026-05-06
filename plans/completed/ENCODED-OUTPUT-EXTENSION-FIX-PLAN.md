# Encoded Output Extension Fix Plan

## Objective

Fix the bug where non-.mp4 originals (e.g. `.mpg`, `.mkv`, `.ts`) are never considered "already transcoded" on a second run, causing redundant re-transcoding. Root cause: `has_encoded_version()` looks for encoded files using the *original* file's extension, while the script always produces encoded output with `.mp4`. Introduce a single, explicit concept for "encoded output extension" so the rule lives in one place and is used everywhere.

**Status**: Implemented

## Bug Summary

- **Symptom**: After transcoding a file that was originally `.mpg` (or `.mkv`, `.avi`, etc.), a second run of the script finds the original again, does not find an "encoded version" (because it looks for `video.fmpg.*.mpg`), and re-transcodes. Output is overwritten with a similar result—wasted work.
- **Cause**: `has_encoded_version()` in `boiler.sh` derives `ext_part` from the *original* filename and searches for `{base}.{marker}.*.{ext_part}`. Encoded output is always `.mp4`, so when original is not `.mp4`, the search never matches.
- **Design gap**: The rule "encoded output is always .mp4" is implicit (hardcoded in every place that *creates* output) and was never applied in the one place that *detects* existing output.

## Requirements

1. **Single source of truth**: One named concept for the encoded output extension (e.g. a constant or a small helper) used by both "create output" and "detect existing output" logic.
2. **Fix `has_encoded_version()`**: When checking whether an original file has an encoded version, search for encoded files with the *encoded* output extension (`.mp4`), not the original's extension.
3. **No behavior change** for `.mp4` originals (they already work).
4. **Tests**: Existing tests must pass; add or adjust tests so the fix is covered (e.g. "original .mpg with existing .fmpg.*.mp4 is skipped").

## Todos (execution order)

- [ ] **Define encoded output extension**  
  In `boiler.sh`, introduce a single definition for the encoded output extension (e.g. near the top or with other "output" constants). Options:
  - Constant: `ENCODED_OUTPUT_EXTENSION="mp4"` (or `READONLY_ENCODED_EXT="mp4"` if you prefer a naming convention).
  - Or a one-line helper: `get_encoded_output_extension() { echo "mp4"; }` if you want a function for consistency with other helpers.
  - Document in a brief comment that transcoded/remuxed output is always this extension (HEVC in MP4 container).

- [ ] **Update `has_encoded_version()`**  
  In `has_encoded_version()`:
  - Do **not** use `ext_part` from the original filename when searching for encoded files.
  - Use the encoded output extension from the single definition above (e.g. search for `{base}.{marker}.*.mp4` or `*.${ENCODED_OUTPUT_EXTENSION}`).
  - Keep same-directory search and marker list (`fmpg`, `orig`, `hbrk`). No other behavior change.

- [ ] **Use the same concept where final output is set (optional but recommended)**  
  Where the final transcoded filename is built (e.g. `OUTPUT_FILE="${BASE_NAME}.fmpg.${actual_bitrate_mbps}.Mbps.mp4"` and the `.orig.` variant), use the constant/helper instead of the literal `mp4` so "encoded output extension" is not re-specified in multiple places. This prevents future drift.

- [ ] **Tests**  
  - Run full test suite: `bash test_boiler.sh` and Bats (`run-bats-tests.sh`). All must pass.
  - Add or extend tests so that an original with a non-.mp4 extension (e.g. `.mpg` or `.mkv`) is skipped when a matching encoded file exists (e.g. `video.fmpg.10.25.Mbps.mp4` in the same directory). This can be in the existing file-discovery / should-skip tests or in a small dedicated test.

- [ ] **Docs**  
  - If PROJECT-CONTEXT or ARCHITECTURE mentions output naming or skip logic, add a sentence that encoded output is always `.mp4` and that "already transcoded" detection uses that extension. Optional: reference the constant/helper name.

## Out of Scope (this plan)

- **Unifying input extension lists**: The duplicated `video_extensions` and `non_quicklook_extensions` arrays across `boiler.sh`, `cleanup-originals.sh`, and `remux-only.sh` are a separate refactor. This plan only addresses the encoded *output* extension and the `has_encoded_version()` bug.

## Success Criteria

- Running the script twice in a directory where the first run produced `.fmpg.*.mp4` (or `.orig.*.mp4`) from `.mpg`/`.mkv`/etc. originals results in those originals being skipped on the second run.
- No regression for `.mp4` originals.
- One explicit, named concept for "encoded output extension" in the codebase; `has_encoded_version()` and final output naming use it.
