# Plan: Clean Implementation of cleanup-originals-new.sh

## Research

### Source: tests/test_cleanup_originals.bats — acceptance tests only

**Acceptance tests (main() e2e):**

| Test | Setup | Confirm | Expected outcome |
|---|---|---|---|
| trashes original with counterpart, skips without, user confirms | `movie.mkv` + counterpart; `other.mkv` no counterpart | `y` | `move_to_trash` called for `movie.mkv`; not for `other.mkv`; summary includes "1 file(s) skipped (no counterpart)" |
| trashes nothing when user declines | `movie.mkv` + counterpart | `n` | No trash calls; output includes "Cancelled" |
| exits cleanly with no eligible files | two originals, no counterparts | none | Output includes "Nothing to trash"; exits 0 |
| cancels gracefully when stdin is closed | `movie.mkv` + counterpart | EOF (stdin closed) | Output includes "Cancelled"; no trash calls; exits 0 |
| reports originals without counterparts in warn list | `orphan.mkv`, no counterpart | none | Output includes "will NOT be trashed" and "orphan.mkv"; exits 0 |

**Depth traversal tests (also acceptance-level via main()):**

| Test | Setup | Depth | Expected outcome |
|---|---|---|---|
| depth 1 scans only current directory | originals in `.` and `level1/` | 1 | Only `.` original trashed |
| depth 2 scans current + one subdir | originals in `.`, `level1/`, `level1/level2/` | 2 | `.` and `level1/` originals trashed; `level1/level2/` skipped |
| depth 0 scans all recursively | originals in `.` and `level1/level2/level3/` | 0 | Both trashed |

**Environment variables the script must respect:**
- `GLOBAL_MAX_DEPTH` — default 2; 0 = unlimited; 1 = current dir only

**Counterpart matching rules (inferred from acceptance tests):**
- `{base}.fmpg.*.mp4` — transcoded counterpart
- `{base}.orig.*.mp4` — within-tolerance counterpart
- `{base}.hbrk.*.mp4` — hardbreak counterpart
- `{base}.remux.*` — remux counterpart (any extension)
- A peer file with no marker does NOT qualify
- Filenames with special characters (brackets, parentheses) must be handled correctly

---

## Plan

- [x] 1. Create `tests/test_cleanup_originals_new.bats` by copying only the `main()` acceptance tests and depth traversal tests from the existing test file, updated to source `cleanup-originals-new.sh`. Add acceptance test fixtures covering all counterpart patterns: `.orig.*.mp4`, `.hbrk.*.mp4`, and `.remux.*`.
- [x] 2. Create `cleanup-originals-new.sh` with shebang, `set -e`, and env-variable defaults — no logic yet. Run new tests: confirm sourcing works without errors (all tests expected to fail on behavior, not on sourcing).
- [x] 3. Implement enough internal logic to make the first acceptance test pass. Add unit tests only if a specific function warrants isolated testing. Run tests.
- [x] 4. Continue incrementally until all acceptance tests pass. Run tests after each increment.
- [x] 5. Run full test suite (`bash test_boiler.sh` + bats) as a regression checkpoint. Review any failures case by case — expect possible noise from unit tests tied to the old implementation or fixture differences. Record result.
- [x] 6. Add colored log prefixes (`[INFO]`, `[WARN]`, `[ERROR]`) to output messages.
- [x] 7. Add directory scan progress output (per-directory status and scan summary).
- [x] 8. Add `parse_arguments` with `-L`/`--max-depth` and `-h`/`--help` support, including usage/help text.
- [x] 9. Re-run acceptance tests against both implementations and diff stdout to confirm output parity.
- [ ] 10. Hold — review with user before any renaming or deletion of the original file.
