# Add -s/--include-subtitles Flag to remux-only.sh

## Objective

Add a batch-wide flag, `-s`/`--include-subtitles`, to `remux-only.sh` that
skips the interactive subtitle prompt and auto-selects "include subtitles"
(option `1` of `prompt_subtitle_choice`) for every file processed in the run.

**Status**: To Do

---

## Background

`remux-only.sh` currently prompts per-file via `get_subtitle_mode_for_file()` →
`prompt_subtitle_choice()` whenever a file has subtitle streams (`remux-only.sh:683-407`).
The menu is:

```
[1] Include subtitles (convert to mov_text)
[2] Proceed without subtitles
[3] Abort
```

In practice, the user almost always picks `1` (include). For a large batch run
(non-QuickLook formats + `.mp4` re-checks, both phases in `main()`), this means
answering the same prompt for every file. The goal is to make that the default,
skippable answer.

This is related to `plans/to-do/non-interactive-tty-guard.md`, which separately
considers a broader `--non-interactive`/`--yes` style flag across all interactive
scripts. That plan is **not a prerequisite** for this one — `-s`/`--include-subtitles`
targets one specific prompt (subtitles) rather than acting as a general
interactivity switch. Cross-reference it during implementation in case shared
groundwork (e.g. flag-parsing conventions) emerges, but do not block on it.

---

## Naming decision

Considered and rejected:
- `--yes`/`-y` — too generic; doesn't communicate *what* is being defaulted.
- `--non-interactive` — implies suppressing all prompts broadly, and is a lot to type; only one prompt exists today.
- `--batch` (gpg-style) / `--force-confdef` (dpkg-style) — real precedent for "assume default answer to prompts," but the term doesn't self-describe the outcome.

Chosen: **`-s`, `--include-subtitles`** — names the outcome directly (always
include subtitles), matching the project's existing style of literal,
self-describing flags (`-p`/`--preserve-name`).

---

## Scope

- Applies to **both** processing phases in `main()`: Phase 1 (non-QuickLook
  formats) and Phase 2 (existing `.mp4` re-mux checks) — both call
  `get_subtitle_mode_for_file()` today.
- Batch-wide only: one flag for the whole invocation, consistent with `-L`/`-p`
  (no per-file override).
- Composable with `-p`/`--preserve-name` and `-L`/`--max-depth` (independent
  concerns: naming, depth, and subtitle handling).

## Out of Scope

- **Original-file preservation/deletion behavior.** Deleting the source in
  Phase 1 (`rm -f "$file_path"` in `process_one_file()`) is unaffected by this
  flag. A separate "make deletion defeatable" flag (e.g. `-k`/`--keep-original`)
  was discussed and deliberately deferred — it has broader implications for the
  rest of the script's behavior (re-detection on re-run, naming collisions) that
  need to be thought through independently. Do not fold that into this plan.
- Broader non-interactive/TTY-guard behavior (see `non-interactive-tty-guard.md`).
- Any change to the menu options themselves or to `prompt_subtitle_choice()`'s
  interactive behavior when the flag is *not* passed.

---

## Design

- Add `GLOBAL_INCLUDE_SUBTITLES="${GLOBAL_INCLUDE_SUBTITLES:-0}"` near the other
  global flags (alongside `GLOBAL_PRESERVE_NAME`).
- Add `-s`/`--include-subtitles` to `parse_arguments()`, setting the flag to `1`.
- Update `get_subtitle_mode_for_file()`: if `GLOBAL_INCLUDE_SUBTITLES` is `1` and
  subtitle streams are detected, skip `report_subtitles`/`prompt_subtitle_choice`
  entirely and return `"include"` directly. If no subtitle streams exist, behavior
  is unchanged (`"none"`, no prompt regardless of the flag).
- Update `show_usage()` to document the new flag and add an example.

---

## Todos (execution order, red/green)

### Phase 1: Baseline

- [ ] 1. Run full test suite (`bash test_boiler.sh` + `bats --jobs 8 tests/*.bats`)
  and confirm all green before making any changes.

### Phase 2: Write failing tests (red)

- [ ] 2. In `tests/test_boiler_subtitles.bats` (already covers subtitle
  detection/mapping and is a natural home) or a new
  `tests/test_remux_only_include_subtitles.bats`, add tests for
  `get_subtitle_mode_for_file()` / `remux-only.sh` behavior:
  - `-s`/`--include-subtitles` set + file with convertible subtitles → no
    prompt shown (no stdin read required, e.g. run with `</dev/null` and
    confirm no hang/abort), `mov_text` stream present in output, function
    returns `"include"`.
  - `-s` set + file with only image-based (non-convertible) subtitles → still
    no prompt; convertible-only mapping applied (i.e. output may have zero
    subtitle streams, matching existing "include" semantics for
    all-incompatible input).
  - `-s` set + file with no subtitle streams → unaffected, no prompt (already
    true today); confirm this still holds with the flag on.
  - `-s` **not** set → existing interactive behavior unchanged (regression
    check: prompt still appears, still reads stdin, default abort on empty
    input still applies).
- [ ] 3. Add a legacy `test_boiler.sh` case (per `PROJECT-CONTEXT.md`, both
  suites are required): at minimum, `-s`/`--include-subtitles` is accepted by
  `parse_arguments()` and sets the expected global (or equivalent observable
  behavior), and `-h`/`--help` output includes the new flag.
- [ ] 4. Run the new tests and confirm they fail (red) — `-s`/`--include-subtitles`
  does not exist yet, so `parse_arguments()` should currently error on it and
  `get_subtitle_mode_for_file()` has no short-circuit.

### Phase 3: Implement (green)

- [ ] 5. Add `GLOBAL_INCLUDE_SUBTITLES="${GLOBAL_INCLUDE_SUBTITLES:-0}"` global
  default (near `GLOBAL_PRESERVE_NAME`).
- [ ] 6. Add `-s`/`--include-subtitles` case to `parse_arguments()`, setting
  `GLOBAL_INCLUDE_SUBTITLES=1`.
- [ ] 7. Update `get_subtitle_mode_for_file()` to short-circuit to `"include"`
  when `GLOBAL_INCLUDE_SUBTITLES` is `1` and subtitle streams are detected
  (skip `report_subtitles`/`prompt_subtitle_choice` entirely). No change when
  no subtitle streams exist.
- [ ] 8. Update `show_usage()`: document `-s, --include-subtitles` and add an
  example (e.g. `$0 -p -s` for a fully hands-off pass).

### Phase 4: Verify

- [ ] 9. Run the tests from Phase 2 — assert all green.
- [ ] 10. Run full test suite (`bash test_boiler.sh` + full Bats suite) —
  assert all pass, no regressions (mandatory per `PROJECT-CONTEXT.md` before
  any commit).
- [ ] 11. Manual smoke test: run `remux-only.sh -s` (and `-p -s`) on a file with
  mixed subtitle types; confirm no prompt appears, convertible subtitles are
  present in output, and a run without `-s` still prompts as before.
- [ ] 12. Update `README.md` helper-script section for `remux-only.sh` if it
  documents flags there.

---

## Success Criteria

- Running `remux-only.sh -s` (optionally with `-p`) processes a batch of files
  with subtitles without any interactive prompt, always including convertible
  subtitle streams.
- Without `-s`, behavior is byte-for-byte unchanged from today.
- Both phases (non-QuickLook remux and `.mp4` re-check) honor the flag.
- Full test suite (legacy + Bats) passes.
