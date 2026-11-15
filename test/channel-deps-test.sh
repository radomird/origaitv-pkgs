#!/bin/bash

# Checks that a channel never loses a package its origaitv still depends on.
# On 2026-11-11 a build of stable dropped origaitv-voice, which stable's
# origaitv 0.2.0 depends on, since the build only kept what it made itself,
# and the publish then deleted the file. A box couldn't install origaitv from
# stable after that.
#
# bin/channel-deps is run against folders of stand-in packages (a .PKGINFO
# in a zstd tar, which is all it reads), and bin/publish against a stand-in
# gh, to see it uploads nothing for a channel that isn't whole. bin/build's
# own use of it is read from the script. Needs tar and zstd.
#
# Usage: test/channel-deps-test.sh

# The scripts' own lines are matched as they're written.
# shellcheck disable=SC2016

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() {
  printf 'not ok - %s\n' "$1" >&2
  [[ ! -s $work/out ]] || sed 's/^/    /' "$work/out" >&2
  failures=$(( failures + 1 ))
}

# package <dir> <name> <version> [<depend>...]: a stand-in package file,
# with a signature beside it.
package() {
  local dir=$1 name=$2 version=$3 arch=any depend
  shift 3
  [[ $name != origaitv-voice ]] || arch=x86_64
  mkdir -p "$work/pkg" "$dir"
  {
    echo "pkgname = $name"
    echo "pkgver = $version-1"
    for depend in "$@"; do echo "depend = $depend"; done
  } >"$work/pkg/.PKGINFO"
  tar --zstd -cf "$dir/$name-$version-1-$arch.pkg.tar.zst" -C "$work/pkg" .PKGINFO
  echo "a signature" >"$dir/$name-$version-1-$arch.pkg.tar.zst.sig"
}

# database <dir> <name-version>...: the channel's origaitv.db, listing those.
database() {
  local dir=$1 entry
  shift
  rm -rf "$work/db"
  mkdir -p "$work/db"
  for entry in "$@"; do
    mkdir -p "$work/db/$entry"
    echo "%NAME%" >"$work/db/$entry/desc"
  done
  # repo-add's own layout: each entry a folder at the top.
  (cd "$work/db" && tar -czf "$dir/origaitv.db" -- *)
}

deps() { "$ROOT/bin/channel-deps" "$@" >"$work/out" 2>&1; }

# --- What a build keeps ---------------------------------------------------------

# Stable as it was: origaitv 0.2.0 depends on origaitv-voice, and the build
# makes origaitv and origaitv-keyring only.
stable="$work/stable"
package "$stable" origaitv 0.2.0 omarchy origaitv-keyring origaitv-voice "origaitv-voice>=2023" bash
package "$stable" origaitv-keyring 20261022
package "$stable" origaitv-voice 2023.11.14.2
if deps "$stable" "$stable/origaitv-0.2.0-1-any.pkg.tar.zst" &&
  [[ $(sort "$work/out" | paste -sd' ') == "origaitv-keyring-20261022-1-any.pkg.tar.zst origaitv-voice-2023.11.14.2-1-x86_64.pkg.tar.zst" ]]; then
  pass "stable's origaitv 0.2.0 needs origaitv-voice and origaitv-keyring, each by its file, a version limit or not"
else fail "stable's origaitv 0.2.0 needs origaitv-voice and origaitv-keyring, each by its file, a version limit or not"; fi

package "$stable" origaitv-voice 2023.11.14.1
if deps "$stable" "$stable/origaitv-0.2.0-1-any.pkg.tar.zst" && grep -qx "origaitv-voice-2023.11.14.2-1-x86_64.pkg.tar.zst" "$work/out" &&
  ! grep -q "2023.11.14.1" "$work/out"; then
  pass "with two of a package, the newest is kept"
else fail "with two of a package, the newest is kept"; fi

# The day it went wrong: stable's folder with no origaitv-voice in it.
gone="$work/gone"
package "$gone" origaitv 0.2.0 origaitv-keyring origaitv-voice
package "$gone" origaitv-keyring 20261022
if ! deps "$gone" "$gone/origaitv-0.2.0-1-any.pkg.tar.zst" && grep -q "depends on origaitv-voice, and this channel doesn't have it" "$work/out"; then
  pass "a channel without a package its origaitv needs stops the build, and says which"
else fail "a channel without a package its origaitv needs stops the build, and says which"; fi

# A file named like it isn't it.
package "$gone" origaitv-voice-extra 1.0
if ! deps "$gone" "$gone/origaitv-0.2.0-1-any.pkg.tar.zst"; then
  pass "a package whose name only starts the same isn't taken for it"
else fail "a package whose name only starts the same isn't taken for it"; fi

# Edge from after 0.2.0: no voice, and a voice package left in the folder
# isn't kept.
edge="$work/edge"
package "$edge" origaitv 0.2.0.r542.gfc9e31531 omarchy origaitv-keyring pipewire
package "$edge" origaitv-keyring 20261022
package "$edge" origaitv-voice 2023.11.14.2
if deps "$edge" "$edge/origaitv-0.2.0.r542.gfc9e31531-1-any.pkg.tar.zst" && [[ $(cat "$work/out") == "origaitv-keyring-20261022-1-any.pkg.tar.zst" ]]; then
  pass "an origaitv that doesn't need the voice doesn't keep it"
else fail "an origaitv that doesn't need the voice doesn't keep it"; fi

# What isn't origaiTV's own is pacman's to find, not the channel's.
if deps "$edge" "$edge/origaitv-0.2.0.r542.gfc9e31531-1-any.pkg.tar.zst" && ! grep -qE "omarchy|pipewire" "$work/out"; then
  pass "only origaiTV's own packages are the channel's to have"
else fail "only origaiTV's own packages are the channel's to have"; fi

# bin/build keeps what bin/channel-deps prints, with its signature, before
# it clears out what it didn't make.
build=$(cat "$ROOT/bin/build")
keep_at=$(grep -n 'kept=$("$ROOT/bin/channel-deps" "$repo" "$repo/$origaitv_file")' <<<"$build" | cut -d: -f1 || true)
clear_at=$(grep -n '^# Only this build' <<<"$build" | cut -d: -f1 || true)
if [[ -n $keep_at && -n $clear_at ]] && (( keep_at < clear_at )) && grep -qF 'current+=("$name")' <<<"$build"; then
  pass "bin/build keeps what origaitv needs before it clears out the rest"
else fail "bin/build keeps what origaitv needs before it clears out the rest"; fi

# --- What a publish checks ------------------------------------------------------

if database "$stable" origaitv-0.2.0-1 origaitv-keyring-20261022-1 origaitv-voice-2023.11.14.2-1 && deps --db "$stable"; then
  pass "a channel whose origaitv.db lists origaitv and what it needs is whole"
else fail "a channel whose origaitv.db lists origaitv and what it needs is whole"; fi

# What went out on 2026-11-11: the file was still in the folder, and the
# database didn't list it.
if database "$stable" origaitv-0.2.0-1 origaitv-keyring-20261022-1 && ! deps --db "$stable" &&
  grep -q "origaitv depends on origaitv-voice, and origaitv.db doesn't list it" "$work/out"; then
  pass "a database that leaves out a package origaitv needs isn't whole"
else fail "a database that leaves out a package origaitv needs isn't whole"; fi

if database "$gone" origaitv-0.2.0-1 origaitv-keyring-20261022-1 && ! deps --db "$gone"; then
  pass "a folder without a package origaitv needs isn't whole"
else fail "a folder without a package origaitv needs isn't whole"; fi

if database "$edge" origaitv-0.2.0.r542.gfc9e31531-1 origaitv-keyring-20261022-1 && deps --db "$edge"; then
  pass "edge, with no voice, is whole"
else fail "edge, with no voice, is whole"; fi

database "$stable" origaitv-0.2.0-1 origaitv-keyring-20261022-1 origaitv-voice-2023.11.14.2-1
unlink "$stable/origaitv-voice-2023.11.14.2-1-x86_64.pkg.tar.zst.sig"
unlink "$stable/origaitv-voice-2023.11.14.1-1-x86_64.pkg.tar.zst"
unlink "$stable/origaitv-voice-2023.11.14.1-1-x86_64.pkg.tar.zst.sig"
if ! deps --db "$stable" && grep -q "has no signature" "$work/out"; then
  pass "a package origaitv needs with no signature isn't whole"
else fail "a package origaitv needs with no signature isn't whole"; fi
echo "a signature" >"$stable/origaitv-voice-2023.11.14.2-1-x86_64.pkg.tar.zst.sig"

two="$work/two"
cp -r "$edge" "$two"
package "$two" origaitv 0.2.0.r540.g38b376c64 origaitv-keyring
if ! deps --db "$two" && grep -q "has one origaitv package" "$work/out"; then
  pass "a folder with two origaitv packages isn't a channel"
else fail "a folder with two origaitv packages isn't a channel"; fi

# bin/publish asks first, and uploads nothing for a channel that isn't
# whole. A stand-in gh writes down what it's asked.
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'GH'
#!/bin/bash
echo "$*" >>"$CALLS"
GH
chmod +x "$work/bin/gh"
publish() {
  : >"$work/calls"
  env PATH="$work/bin:$PATH" CALLS="$work/calls" GITHUB_REPOSITORY=someone/origaitv-pkgs GITHUB_SHA=abc \
    "$ROOT/bin/publish" "$1" "$2" >"$work/out" 2>&1
}
database "$gone" origaitv-0.2.0-1 origaitv-keyring-20261022-1
if ! publish stable "$gone" && ! grep -qE "release (upload|delete-asset|create)" "$work/calls"; then
  pass "bin/publish uploads and deletes nothing for a channel without a package its origaitv needs"
else fail "bin/publish uploads and deletes nothing for a channel without a package its origaitv needs"; fi

# --- A channel only moves forward -------------------------------------------------

# The stand-in gh now also has a channel on a version: "release view" lists
# release.json, and "release download" gives it.
cat >"$work/bin/gh" <<'GH'
#!/bin/bash
echo "$*" >>"$CALLS"
case "$1 $2" in
  "release view") [[ -z ${LIVE:-} ]] || echo release.json ;;
  "release download") jq -cn --arg version "$LIVE" '{version: $version}' ;;
esac
GH
chmod +x "$work/bin/gh"
whole="$work/whole"
package "$whole" origaitv 0.2.0 origaitv-keyring origaitv-voice
package "$whole" origaitv-keyring 20261022
package "$whole" origaitv-voice 2023.11.14.2
database "$whole" origaitv-0.2.0-1 origaitv-keyring-20261022-1 origaitv-voice-2023.11.14.2-1
for name in origaitv.db origaitv.files origaitv.db.tar.gz origaitv.files.tar.gz release.json; do
  [[ -f $whole/$name ]] || echo x >"$whole/$name"
  echo x >"$whole/$name.sig"
done
jq -n '{version: "0.2.0"}' >"$whole/release.json"
moves() {
  local live=$1
  shift
  : >"$work/calls"
  env PATH="$work/bin:$PATH" CALLS="$work/calls" LIVE="$live" GITHUB_REPOSITORY=someone/origaitv-pkgs GITHUB_SHA=abc "$@" \
    "$ROOT/bin/publish" stable "$whole" >"$work/out" 2>&1
}
uploaded() { grep -q "^release upload" "$work/calls"; }

if ! moves 1.0.0 && ! uploaded && grep -q "on origaitv 1.0.0, and this is 0.2.0, which is older" "$work/out"; then
  pass "an older version isn't published over a newer one, and nothing is uploaded"
else fail "an older version isn't published over a newer one, and nothing is uploaded"; fi
if moves 1.0.0 ORIGAITV_PUBLISH_BACK=1 && uploaded && grep -q "Going back on purpose" "$work/out"; then
  pass "going back on purpose is a run that says so"
else fail "going back on purpose is a run that says so"; fi
for word in 0 true yes; do
  if moves 1.0.0 ORIGAITV_PUBLISH_BACK=$word || uploaded; then fail "only ORIGAITV_PUBLISH_BACK=1 says so, not $word"; fi
done
if moves 0.2.0 && uploaded; then pass "the same version again is published, as a rebuild is"
else fail "the same version again is published, as a rebuild is"; fi
if moves 0.1.4 && uploaded; then pass "a newer version moves the channel"
else fail "a newer version moves the channel"; fi
if moves "" && uploaded; then pass "a channel's first publish goes out"
else fail "a channel's first publish goes out"; fi
jq -n '{version: "1.0.0.r0.gabc1234"}' >"$whole/release.json"
if moves 1.0.0 && uploaded; then pass "edge's 1.0.0.r0 is after 1.0.0, as pacman has it"
else fail "edge's 1.0.0.r0 is after 1.0.0, as pacman has it"; fi
if grep -qF "ORIGAITV_PUBLISH_BACK: \${{ github.event_name == 'workflow_dispatch' && inputs.back && '1' || '' }}" "$ROOT/.github/workflows/build.yml" &&
  [[ $(grep -c ORIGAITV_PUBLISH_BACK "$ROOT/.github/workflows/build.yml") == 1 ]]; then
  pass "only the Build run by hand with back ticked can go back"
else fail "only the Build run by hand with back ticked can go back"; fi

(( failures == 0 )) || { echo "$failures failed" >&2; exit 1; }
echo "all passed"
