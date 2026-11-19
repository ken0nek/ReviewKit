#!/usr/bin/env bash
# Usage: scripts/api-check.sh <baseline-tag> [--major]
#
# Fails when the public API breaks against <baseline-tag>, unless --major says
# the next release is a major version. A new case on a public enum counts as a
# break: a consumer's exhaustive `switch` stops compiling.
#
# The exit status decides, not the log text. The log is read only to tell a
# reported break from a build that never got as far as comparing.
set -uo pipefail

baseline="${1:?usage: scripts/api-check.sh <baseline-tag> [--major]}"
major="${2:-}"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

swift package diagnose-api-breaking-changes "$baseline" \
    --products ReviewKit ReviewKitUI 2>&1 | tee "$log"
status="${PIPESTATUS[0]}"

if (( status == 0 )); then
    echo "OK: no API break against $baseline."
    exit 0
fi

if ! grep -qE 'breaking changes? detected' "$log"; then
    echo "::error::diagnose-api-breaking-changes failed before comparing against $baseline (exit $status)."
    exit "$status"
fi

if [[ "$major" == "--major" ]]; then
    echo "API breaks against $baseline, and the next release is a major version: allowed."
    exit 0
fi

echo "::error::The public API breaks against $baseline, and nothing marks the next release as a major version. Label the release pull request tagpr:major, or keep the break out of this release."
exit 1
