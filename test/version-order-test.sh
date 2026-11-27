#!/bin/bash

# Checks, with pacman's own vercmp, that every version the origaitv package
# can have sorts the way the channels count on: a box on edge only ever
# moves forward, from the 0.2.0 builds through each candidate's to 1.0.0's,
# and stable's 1.0.0 is newer than every build before it.
#
# The versions below are oldest first. Every pair is asked both ways round,
# so one that sorts wrong anywhere in the list fails. bin/version-sort,
# which orders versions where there's no pacman (bin/publish runs on
# Ubuntu), has to give the same order.
#
# Needs pacman's vercmp, so it runs in an Arch container: bin/build runs it
# before it builds anything, and the Check workflow on every pull request.
#
# Usage: test/version-order-test.sh

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if ! type -P vercmp >/dev/null; then
  echo "not ok - vercmp isn't here. It comes with pacman: run this in an Arch container." >&2
  exit 1
fi

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() {
  printf 'not ok - %s\n' "$1" >&2
  failures=$(( failures + 1 ))
}

# Oldest first.
versions=(
  # Before any release, and the 0.x days.
  0.0.0.r3.gabc1234
  0.2.0
  0.2.0.r9.gabc1234
  # The last build before edge counted from candidates.
  0.2.0.r1157.g8880c58c5
  # Builds after a candidate's tag: on its commit, then five and ten after.
  1.0.0rc6.r0.g8880c58c5
  1.0.0rc6.r5.gabc1234
  1.0.0rc6.r10.gabc1234
  # A later candidate's builds are newer, and rc10 comes after rc9.
  1.0.0rc7.r0.gabc1234
  1.0.0rc9.r2.gabc1234
  1.0.0rc10.r0.gabc1234
  # The release is newer than every candidate's build. Stable's is bare,
  # and edge's of the same commit says its commit.
  1.0.0
  1.0.0.r0.gabc1234
  1.0.0.r1.gabc1234
  # And on to the next release.
  1.0.1rc1.r0.gabc1234
  1.0.1
  1.0.9.r4.gabc1234
  1.0.10rc1.r0.gabc1234
  1.0.10
  1.1.0rc1.r0.gabc1234
)

wrong=0
for (( i = 0; i < ${#versions[@]}; i++ )); do
  [[ $(vercmp "${versions[i]}" "${versions[i]}") == 0 ]] || { fail "pacman says ${versions[i]} isn't itself"; wrong=1; }
  for (( j = i + 1; j < ${#versions[@]}; j++ )); do
    older=${versions[i]} newer=${versions[j]}
    if [[ $(vercmp "$older" "$newer") != -1 || $(vercmp "$newer" "$older") != 1 ]]; then
      fail "pacman doesn't put $older before $newer"
      wrong=1
    fi
  done
done
(( wrong )) || pass "pacman puts all ${#versions[@]} versions in order, every pair of them"

# pkgrel comes after all of it: the image layer's update test builds the
# same commit again with pkgrel 99.
if [[ $(vercmp 1.0.0rc6.r5.gabc1234-1 1.0.0rc6.r5.gabc1234-99) == -1 && $(vercmp 1.0.0rc6.r5.gabc1234-99 1.0.0rc6.r6.gabc1234-1) == -1 ]]; then
  pass "a higher pkgrel is newer, and the next commit newer still"
else
  fail "a higher pkgrel is newer, and the next commit newer still"
fi

# bin/version-sort, handed the list backwards, gives pacman's order.
want=$(printf '%s\n' "${versions[@]}")
got=$(printf '%s\n' "${versions[@]}" | tac | "$ROOT/bin/version-sort")
if [[ $got == "$want" ]]; then
  pass "bin/version-sort gives the same order"
else
  fail "bin/version-sort gives the same order"
  diff <(echo "$want") <(echo "$got") >&2 || true
fi
got=$(printf '%s\n' 1.0.0 1.0.0rc6.r0.gabc1234 1.0.0 | "$ROOT/bin/version-sort" -u | paste -sd' ')
if [[ $got == "1.0.0rc6.r0.gabc1234 1.0.0" ]]; then
  pass "bin/version-sort -u says each version once"
else
  fail "bin/version-sort -u says each version once (got: $got)"
fi

(( failures == 0 )) || { echo "$failures failed" >&2; exit 1; }
echo "all passed"
