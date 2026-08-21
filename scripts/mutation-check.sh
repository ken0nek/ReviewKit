#!/usr/bin/env bash
# Makes CLAUDE.md's mutation table a command instead of a comment.
#
# For each mutation in scripts/mutations/mutations.json, applies it to a scratch
# copy of the package — never to this working tree — runs `swift test`, and
# compares the number of FAILING TESTS against the count recorded beside it in
# that same file, which is the machine-readable twin of CLAUDE.md's table
# (.github/workflows/mutation.yml checks the two agree).
#
# The mutations are find/replace entries rather than diffs. A diff carries the
# edit, three lines of incidental context and hunk line numbers. Only the first
# is wanted, and the other two rot whenever anything nearby moves.
# scripts/mutations/apply.py explains the format.
#
# "Reds" means failing *tests*, not recorded *issues* — an exhaustive-matrix
# test can fail with hundreds of issues at once, which would make an
# issues-based count meaningless as a stable expectation. Both numbers are
# printed, clearly labelled, so nobody re-derives the wrong one from the logs.
#
# A count BELOW expectation is a hard failure: a test that used to catch this
# mutation no longer does, which is the exact silent regression this whole
# script exists to catch. A count ABOVE expectation is a warning, printed
# prominently but not fatal — usually a new test earning credit for a
# mutation it already covered. A mutation that fails to apply is also a hard
# failure: the source has moved and that mutation's find lines need updating,
# never loosening the match and never silently skipping.
#
# Runs in debug (`swift test`), the documented default. At least one row's
# count is different in release — see CLAUDE.md.
#
# Usage:
#   scripts/mutation-check.sh
#   MUTATION_SCRATCH=/some/path/outside/the/repo scripts/mutation-check.sh
#
# Requires: rsync, python3, swift.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
MUTATIONS_DIR="$REPO_ROOT/scripts/mutations"
MANIFEST="$MUTATIONS_DIR/mutations.json"

# --- Scratch setup: this is the one thing that must never touch the working
# tree, so the path is resolved and checked before anything else runs. ---

if [[ -n "${MUTATION_SCRATCH:-}" ]]; then
    mkdir -p "$MUTATION_SCRATCH"
    SCRATCH="$(cd "$MUTATION_SCRATCH" && pwd -P)"
else
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/reviewkit-mutation.XXXXXX")"
    SCRATCH="$(cd "$SCRATCH" && pwd -P)"
fi

case "$SCRATCH" in
    "$REPO_ROOT" | "$REPO_ROOT"/*)
        echo "refusing to run: scratch path '$SCRATCH' is inside the repo '$REPO_ROOT'." >&2
        echo "set MUTATION_SCRATCH to a path outside the repo, or unset it to use mktemp." >&2
        exit 1
        ;;
esac

cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

echo "Configuration: debug (swift test). At least one row's count differs in"
echo "release — see CLAUDE.md's \"Build and test\" section."
echo "Scratch (outside the repo): $SCRATCH"
echo

mkdir -p "$SCRATCH/pristine"
rsync -a --delete --exclude .build --exclude .git --exclude .swiftpm \
    "$REPO_ROOT"/ "$SCRATCH/pristine"/

# A quick sanity build so a broken baseline is reported as exactly that,
# rather than showing up as every row's count reading zero. Built in its own
# throwaway copy, never in "$SCRATCH/pristine" itself: SwiftPM's module cache
# bakes in the *absolute path* it was built at, so a `.build` directory
# copied from one path into another (pristine → work, below) fails with
# "missing required module" instead of just rebuilding. Keeping pristine
# free of any `.build` is what makes `cp -a` a safe way to reset between
# mutations.
echo "Sanity-building the pristine copy (in a disposable copy of it)…"
rm -rf "$SCRATCH/sanity-check"
cp -a "$SCRATCH/pristine" "$SCRATCH/sanity-check"
if ! (cd "$SCRATCH/sanity-check" && swift build 2>&1); then
    echo "FAIL: the unmutated package does not build in the scratch copy." >&2
    exit 1
fi
rm -rf "$SCRATCH/sanity-check"
echo

work="$SCRATCH/work"
overall_status=0
declare -a rows=()

while IFS=$'\t' read -r mutation expected description; do
    [[ -n "$mutation" ]] || continue

    rm -rf "$work"
    cp -a "$SCRATCH/pristine" "$work"

    # Exact substitution, and every find-string must match exactly once — the
    # replacement for `patch -F0`'s zero fuzz, and a tighter check: it is about
    # the mutated lines rather than their neighbours. A site that moved fails
    # loudly and by name instead of silently mutating the wrong thing.
    if ! python3 "$MUTATIONS_DIR/apply.py" --apply "$mutation" --root "$work" \
            >"$SCRATCH/apply.log" 2>&1; then
        echo "FAIL  $mutation — did not apply:"
        sed 's/^/      /' "$SCRATCH/apply.log"
        rows+=("$mutation	$expected	APPLY-FAILED	—")
        overall_status=1
        continue
    fi

    test_log="$SCRATCH/test-$mutation.log"
    if ! (cd "$work" && swift test) >"$test_log" 2>&1; then
        : # swift test exits non-zero on any failing test; that is expected.
    fi

    summary_line="$(grep -E 'Test run with [0-9]+ tests? in [0-9]+ suites? ' "$test_log" || true)"

    if [[ -z "$summary_line" ]]; then
        echo "FAIL  $mutation — swift test produced no summary line, which means"
        echo "      the mutated package did not build. This is a compile"
        echo "      error, not a test regression:"
        tail -20 "$test_log" | sed 's/^/      /'
        rows+=("$mutation	$expected	BUILD-ERROR	—")
        overall_status=1
        continue
    fi

    actual="$(grep -cE 'Test ".*" failed after' "$test_log" || true)"
    issues="$(printf '%s\n' "$summary_line" | grep -Eo 'with [0-9]+ issues?' | grep -Eo '[0-9]+' || echo 0)"
    [[ -n "$issues" ]] || issues=0

    result="ok"
    if (( actual < expected )); then
        result="REGRESSION"
        overall_status=1
    elif (( actual > expected )); then
        result="WARNING (higher than expected)"
    fi

    rows+=("$mutation	$expected	$actual	$issues	$result	$description")
done < <(python3 "$MUTATIONS_DIR/apply.py" --list)

echo
printf '%-46s %8s %8s %10s  %s\n' "mutation" "expect" "reds" "issues" "result"
printf '%-46s %8s %8s %10s  %s\n' "--------" "------" "----" "------" "------"
for row in "${rows[@]}"; do
    IFS=$'\t' read -r mutation expected actual issues result description <<<"$row"
    if [[ "$actual" == "APPLY-FAILED" || "$actual" == "BUILD-ERROR" ]]; then
        printf '%-46s %8s %8s %10s  %s\n' "$mutation" "$expected" "-" "-" "$actual"
    else
        printf '%-46s %8s %8s %10s  %s\n' "$mutation" "$expected" "$actual" "$issues" "$result"
        if [[ "$result" == "REGRESSION" ]]; then
            echo "      ^ a test that used to catch this mutation no longer does." >&2
        elif [[ "$result" == WARNING* ]]; then
            echo "      ^ likely a new test — update mutations.json and CLAUDE.md together." >&2
        fi
    fi
done
echo

if (( overall_status == 0 )); then
    echo "All ${#rows[@]} mutations produced at least their expected reds."
else
    echo "FAILED: see rows above marked REGRESSION, APPLY-FAILED or BUILD-ERROR." >&2
fi

exit "$overall_status"
