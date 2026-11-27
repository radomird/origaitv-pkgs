#!/bin/bash

# Checks which release notes a build shows as What's new (bin/release-notes):
# a release its own, and an edge build the notes of the release it leads
# to, also when it counts from a candidate. Needs nothing but coreutils.
#
# Usage: test/release-notes-test.sh

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() {
  printf 'not ok - %s\n' "$1" >&2
  failures=$(( failures + 1 ))
}

notes="$work/release-notes"
mkdir -p "$notes"
for version in 0.1.4 0.2.0 1.0.0 1.0.10; do
  echo "What's new in $version" >"$notes/$version.txt"
done

is() {
  local name=$1 version=$2 want=$3 got
  got=$("$ROOT/bin/release-notes" "$notes" "$version")
  got=${got//"$notes/"/}
  if [[ $got == "$want" ]]; then pass "$name"; else fail "$name: $version got '$got', not '$want'"; fi
}

is "a release shows its own notes" 1.0.0 "own 1.0.0.txt"
is "a release without notes shows none" 1.0.1 ""
is "a build after 0.2.0 shows 1.0.0's" 0.2.0.r1157.g8880c58c5 "borrowed 1.0.0.txt"
is "a build after a candidate shows its release's" 1.0.0rc6.r0.g8880c58c5 "borrowed 1.0.0.txt"
is "after rc10 too" 1.0.0rc10.r3.gabc1234 "borrowed 1.0.0.txt"
is "a build after 1.0.0 shows the next release's, not 1.0.0's" 1.0.0.r2.gabc1234 "borrowed 1.0.10.txt"
is "a candidate of a release with no notes yet shows the next one's" 1.0.1rc1.r0.gabc1234 "borrowed 1.0.10.txt"
is "versions sort as numbers: 1.0.9's builds lead to 1.0.10" 1.0.9.r4.gabc1234 "borrowed 1.0.10.txt"
is "a build after the last notes shows none" 1.0.10.r1.gabc1234 ""
is "a candidate after the last notes shows none" 1.1.0rc1.r0.gabc1234 ""
if [[ -z $("$ROOT/bin/release-notes" "$work/none" 1.0.0rc6.r0.gabc1234) ]]; then
  pass "a commit with no release notes at all shows none"
else fail "a commit with no release notes at all shows none"; fi

# bin/build asks here, and never borrows a security mark.
# shellcheck disable=SC2016 # the script's own line, as it's written
if grep -qF '"$ROOT/bin/release-notes" "$source_dir/release-notes" "$version"' "$ROOT/bin/build" &&
  ! grep -q 'sort -uV\|sort -V' "$ROOT/bin/build" "$ROOT/bin/publish" "$ROOT/bin/channel-deps"; then
  pass "bin/build asks bin/release-notes, and nothing sorts versions with sort -V on its own"
else fail "bin/build asks bin/release-notes, and nothing sorts versions with sort -V on its own"; fi

(( failures == 0 )) || { echo "$failures failed" >&2; exit 1; }
echo "all passed"
