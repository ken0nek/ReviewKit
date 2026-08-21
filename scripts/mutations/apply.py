#!/usr/bin/env python3
"""Reads mutations.json — the machine-readable twin of CLAUDE.md's mutation table.

Each mutation is a set of exact find/replace edits on one file. Find/replace rather
than a diff, for one reason: a diff carries three things — the edit, three lines of
surrounding context, and hunk line numbers — and only the first is wanted. The other
two rot whenever anything near the mutation moves, and that break has nothing to do
with the mutation itself.

What replaces `patch -F0`'s zero-fuzz guarantee: every find-string must occur
**exactly once** in the target file. A mutation site that moved, changed, or was
duplicated still fails loudly and by name — more precisely than before, because
the check is now about the mutated lines rather than their neighbours.

Only insertions carry an anchor line, because an insertion point cannot be named
without one; the anchor is a single line, not a diff's default three.

Usage:
    apply.py --list                        # id<TAB>expectedReds<TAB>description
    apply.py --reds                        # expectedReds, one per line, in order
    apply.py --apply <id> --root <dir>     # mutate the copy rooted at <dir>
"""
import argparse
import json
import pathlib
import sys

MANIFEST = pathlib.Path(__file__).with_name("mutations.json")


def load():
    return json.loads(MANIFEST.read_text())["mutations"]


def apply(mutation, root):
    target = root / mutation["file"]
    if not target.is_file():
        sys.exit(f"{mutation['id']}: {mutation['file']} does not exist under {root}")
    text = target.read_text()

    for index, edit in enumerate(mutation["edits"], start=1):
        find = "\n".join(edit["find"])
        replace = "\n".join(edit["replace"])
        # A deletion consumes the trailing newline too, so removing a line does
        # not leave a blank one behind.
        key = find + "\n" if not replace else find
        found = text.count(key)
        if found != 1:
            sys.exit(
                f"{mutation['id']}: edit {index} of {len(mutation['edits'])} matched "
                f"{found} times in {mutation['file']}, expected exactly 1.\n"
                f"The source has moved. Update this mutation's find lines in "
                f"{MANIFEST.name}, never loosen the match.\n"
                f"  first find line: {edit['find'][0]!r}"
            )
        text = text.replace(key, "" if not replace else replace, 1)

    target.write_text(text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--reds", action="store_true")
    parser.add_argument("--apply")
    parser.add_argument("--root")
    args = parser.parse_args()

    mutations = load()

    if args.list:
        for m in mutations:
            print(f"{m['id']}\t{m['expectedReds']}\t{m['description']}")
        return
    if args.reds:
        for m in mutations:
            print(m["expectedReds"])
        return
    if args.apply:
        if not args.root:
            sys.exit("--apply requires --root")
        match = next((m for m in mutations if m["id"] == args.apply), None)
        if match is None:
            sys.exit(f"unknown mutation id: {args.apply}")
        apply(match, pathlib.Path(args.root))
        return

    parser.error("one of --list, --reds or --apply is required")


if __name__ == "__main__":
    main()
