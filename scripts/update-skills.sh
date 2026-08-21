#!/usr/bin/env bash
# Refresh every skill pinned in THIS repo's skills-lock.json by re-adding it with
# its full repo subpath — the same install source the lock's own update builds,
# which keeps the lock entry byte-stable.
#
# Use this instead of `npx skills experimental_install` / `npx skills update`:
# the project-scope path drops the lockfile skillPath and skill discovery stops
# at the first root-level SKILL.md, so nested skills (for example openai/plugins keeps
# theirs under plugins/build-ios-apps/skills/) fail with a bare "Failed to
# update". `npx skills add <repo>/<subpath>` takes the deep path directly.
# Upstream: vercel-labs/skills#1376 — delete this workaround once that's fixed.
#
# This never checks for upstream deletions (that check is broken too, #1376):
# a skill deleted from its source repo shows up here as a persistent failure.
#
# Generated file — local edits are overwritten on the next refresh.
# Requires: jq, network (npx resolves the skills CLI + shallow-clones per skill).
set -euo pipefail
cd "$(dirname "$0")/.."

pairs="$(jq -r '
  .skills | to_entries[] |
  "\(.key) \(.value.source)/\(.value.skillPath | sub("(^|/)SKILL\\.md$"; ""))\(if .value.ref then "#\(.value.ref)" else "" end)"
' skills-lock.json)"

failed=""
while read -r name source; do
  [[ -n "$name" ]] || continue
  echo "=== ${name}"
  npx skills add "$source" --skill "$name" -y </dev/null || failed="$failed $name"
done <<<"$pairs"

if [[ -n "$failed" ]]; then
  echo "Failed to refresh:$failed" >&2
  exit 1
fi
