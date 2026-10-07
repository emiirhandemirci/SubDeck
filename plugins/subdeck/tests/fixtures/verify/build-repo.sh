#!/usr/bin/env bash
# Builds a small git repo for verify-checks tests: usage build-repo.sh <dir>
# Result: tag/branch base..head where head adds a BEL line (ctrl.txt), a "C:<TAB>arget" line (tabpath.txt),
# a clean file (ok.txt) and a binary file (bin.dat, contains NUL and BEL bytes).
set -e
D="${1:?usage: build-repo.sh <dir>}"
mkdir -p "$D"; cd "$D"
git init -q . 2>/dev/null
git config user.email t@example.com; git config user.name t
printf 'one\n' > base.txt
git add base.txt; git commit -qm base
git tag base
printf 'fine line\nbell\007here\n' > ctrl.txt
printf 'start\nC:\ttarget\\file\n' > tabpath.txt
printf 'clean\n' > ok.txt
printf '\000\001\007binary\n' > bin.dat
git add ctrl.txt tabpath.txt ok.txt bin.dat; git commit -qm head
git tag head
