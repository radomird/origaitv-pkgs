#!/bin/bash

# Installs OrigaiTV's packages from the published release the way a box does:
# pacman trusts only OrigaiTV's key, the database and every package must be
# signed by it, the keyring package hands that trust on, and origaitv's own
# origaitv-pacman-conf writes a repository line that works. Runs as root in a
# fresh Arch container, after bin/publish.
#
# Usage: test/install-test.sh <channel> <expected origaitv version>
# Needs: ORIGAITV_REPO_URL

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
channel="${1:?usage: test/install-test.sh <channel> <version>}"
version="${2:?usage: test/install-test.sh <channel> <version>}"
: "${ORIGAITV_REPO_URL:?}"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

fpr=$(cut -d: -f1 "$ROOT/origaitv-keyring/origaitv-trusted")

# shellcheck source=bin/arch-container-setup
source "$ROOT/bin/arch-container-setup"
# Node runs origaitv app validate and origaitv app list. origaitv installs here
# without its dependencies (below), so it comes on its own, as Omarchy's
# base brings it on a box.
arch_container_setup gnupg nodejs

pacman-key --init >/dev/null 2>&1
pacman-key --add "$ROOT/origaitv-keyring/origaitv.gpg" >/dev/null 2>&1
pacman-key --lsign-key "$fpr" >/dev/null 2>&1

# Between origaitv-pacman-conf's own markers, so the package's install script
# replaces this section rather than adding a second one. DatabaseRequired
# here makes the first sync prove the database is signed.
cp /etc/pacman.conf /etc/pacman.conf.arch
cat >>/etc/pacman.conf <<CONF

# BEGIN origaitv: added by origaitv-pacman-conf, kept at the end
[origaitv]
SigLevel = Required DatabaseRequired
Server = $ORIGAITV_REPO_URL/$channel
# END origaitv
CONF

pacman -Sy >/dev/null || fail "the $channel database downloads and its signature checks out"
pass "the $channel database downloads and its signature checks out"

# --nodeps twice: Omarchy's own package isn't in a plain Arch container, and
# this checks OrigaiTV's packages, not Omarchy's.
pacman -S --noconfirm --nodeps --nodeps origaitv-keyring origaitv >/dev/null ||
  fail "origaitv and origaitv-keyring install with their signatures checked"
pass "origaitv and origaitv-keyring install with their signatures checked"

pacman-key --list-keys "$fpr" >/dev/null 2>&1 || fail "origaitv-keyring puts OrigaiTV's key in pacman's keyring"
pass "origaitv-keyring puts OrigaiTV's key in pacman's keyring"

installed=$(pacman -Q origaitv | cut -d' ' -f2)
[[ $installed == "$version-1" ]] || fail "the installed origaitv is $version (got $installed)"
pass "the installed origaitv is $version"

output=$(origaitv version)
[[ $output == "OrigaiTV $version ($channel)"* ]] || fail "origaitv version names the version and channel (got: $output)"
pass "origaitv version names the version and channel"

[[ -f /usr/share/origaitv/config/omarchy/hooks/post-update.d/origaitv &&
  -f /etc/skel/.config/omarchy/hooks/post-update.d/origaitv ]] || fail "the post-update hook ships for new and existing users"
pass "the post-update hook ships for new and existing users"

# From stage 1 on: the TV session ships whole, or not at all (ADR-031).
if [[ -f /usr/share/origaitv/session/hypr.lua ]]; then
  for file in /usr/share/wayland-sessions/origaitv.desktop /usr/bin/origaitv-session \
    /usr/lib/systemd/user/origaitv-tv.target /usr/lib/systemd/user/origaitv-screen.service \
    /usr/lib/systemd/user/origaitv-input.service /usr/lib/systemd/user/origaitv-toast.service \
    /usr/lib/udev/rules.d/70-origaitv-uinput.rules /usr/share/origaitv/daemon/screen.ts \
    /usr/share/origaitv/daemon/package.json /usr/share/origaitv/daemon/input.py /usr/share/origaitv/session/toast/shell.qml; do
    [[ -f $file ]] || fail "the TV session ships whole: $file is missing"
  done
  [[ ! -e /usr/lib/systemd/system/multi-user.target.wants/origaitv-screen.service ]] ||
    fail "the TV session's units are the owner's, not the system's"
  pass "the TV session ships whole: its entry, its Hyprland setup, its units and its daemon"
fi

# From stage 2 on: the app contract and its validator ship together.
if [[ -f /usr/bin/origaitv-app-validate ]]; then
  for file in /usr/share/origaitv/apps/package.json /usr/share/origaitv/apps/contract/contract.ts \
    /usr/share/origaitv/apps/contract/manifest.ts /usr/share/origaitv/apps/contract/validate.ts; do
    [[ -f $file ]] || fail "the app contract ships whole: $file is missing"
  done
  status=0
  origaitv app validate >/dev/null 2>&1 || status=$?
  (( status == 2 )) || fail "origaitv app validate runs on the box (it exited $status, not 2 for no package)"
  pass "the app contract ships whole, and origaitv app validate runs"
fi

# From stage 2 on: the app installer ships with the contract, and knows where
# the signed app index lives.
if [[ -f /usr/bin/origaitv-app-install ]]; then
  for file in /usr/share/origaitv/daemon/apps/index.ts /usr/share/origaitv/daemon/apps/install.ts \
    /usr/share/origaitv/daemon/apps/cli.ts /usr/bin/origaitv-app-list /usr/bin/origaitv-app-remove; do
    [[ -f $file ]] || fail "the app installer ships whole: $file is missing"
  done
  # Releases up to v0.1.2 were built before the index moved to origaitv-apps
  # (ADR-036), and a published version keeps its exact file.
  index=origaitv-apps
  if [[ $version != *.r* ]] && (( $(vercmp "$version" 0.1.2) <= 0 )); then
    index=origaitv-index
  fi
  grep -q "^ORIGAITV_INDEX_URL=https://github.com/.*/$index/releases/download/index\$" /usr/share/origaitv/settings ||
    fail "the package says where the app index lives ($index)"
  [[ -z $(origaitv app list) ]] || fail "a new box has no apps installed"
  pass "the app installer ships whole, and knows where the app index lives"
fi

# From stage 3 on: the built-in apps ship whole and pass the app contract's
# checks as OrigaiTV's own, and the package names OrigaiTV's address for the
# User-Agent its apps' requests carry.
if [[ -d /usr/share/origaitv/apps/builtin ]]; then
  for app in origaitv.clock origaitv.weather origaitv.music; do
    for file in manifest.json app.ts icon.svg; do
      [[ -f /usr/share/origaitv/apps/builtin/$app/$file ]] || fail "the built-in apps ship whole: $app/$file is missing"
    done
  done
  [[ -f /usr/share/origaitv/apps/builtin/origaitv.weather/met.ts && -f /usr/share/origaitv/daemon/place.ts ]] ||
    fail "the weather ships whole, with what it reads MET's forecast and the box's place with"
  [[ -f /usr/share/origaitv/daemon/music.ts && -f /usr/share/origaitv/daemon/storage.ts && -x /usr/bin/origaitv-music ]] ||
    fail "Music ships whole, with its library, its player, its storage layer and origaitv music"
  [[ ! -e /usr/share/origaitv/apps/builtin/origaitv.weather/fixtures ]] || fail "an app's fixtures don't ship to the box"
  origaitv app validate --official /usr/share/origaitv/apps/builtin/* >/dev/null ||
    fail "the built-in apps pass the app contract's checks"
  grep -q '^ORIGAITV_HOMEPAGE=https://' /usr/share/origaitv/settings || fail "the package names OrigaiTV's address"
  pass "the built-in apps ship whole and pass the contract's checks, and the package names OrigaiTV's address"
fi

# From stage 2 on: the home screen ships with its sounds, their own licence,
# and the template and hook that give it the Omarchy theme's colours.
if [[ -f /usr/share/origaitv/launcher/index.html ]]; then
  for file in /usr/share/origaitv/launcher/package.json /usr/share/origaitv/launcher/main.ts \
    /usr/share/origaitv/launcher/launcher.css /usr/share/origaitv/launcher/motion.css /usr/share/origaitv/launcher/pages/home.ts \
    /usr/share/origaitv/config/omarchy/themed/launcher.css.tpl /usr/share/origaitv/config/omarchy/hooks/theme-set.d/origaitv \
    /usr/bin/origaitv-theme-sync /usr/lib/systemd/user/origaitv-theme.service /usr/share/licenses/origaitv/sounds; do
    [[ -f $file ]] || fail "the home screen ships whole: $file is missing"
  done
  for sound in move select forward back confirm success failure; do
    [[ -f /usr/share/origaitv/launcher/sounds/$sound.ogg ]] || fail "the home screen ships whole: the $sound sound is missing"
  done
  pass "the home screen ships whole, with its sounds, their licence and the theme's template"
fi

# From phase 2's looks on: home's three looks, each with its look.json, the
# fonts' licence, and the look's route, which the daemon can't start without.
if [[ -f /usr/share/origaitv/launcher/looks/terminal/look.json ]]; then
  for look in terminal glass cinema; do
    [[ -f /usr/share/origaitv/launcher/looks/$look/look.json ]] || fail "home's looks ship whole: $look is missing"
  done
  [[ -f /usr/share/origaitv/daemon/routes/look.ts ]] || fail "the daemon ships with its routes"
  if [[ -d /usr/share/origaitv/launcher/fonts ]]; then
    [[ -f /usr/share/licenses/origaitv/fonts ]] || fail "Glass's and Cinema's fonts ship with their licence"
  fi
  pass "home's three looks ship, with their fonts' licence and the daemon's routes"
fi

# From stage 4 on: the daemon serves the phone companion's page, so it ships
# with the daemon that pairs phones.
if [[ -f /usr/share/origaitv/daemon/phones.ts ]]; then
  for file in index.html companion.css main.ts; do
    [[ -f /usr/share/origaitv/companion-web/$file ]] || fail "the phone companion ships whole: companion-web/$file is missing"
  done
  pass "the phone companion's page ships with the daemon"
fi

# From stage 2 on: wake-on-LAN for every wired connection (ADR-031).
if [[ -f /usr/share/origaitv/daemon/tv-power.ts ]]; then
  grep -qx 'ethernet.wake-on-lan=64' /usr/lib/NetworkManager/conf.d/90-origaitv-wol.conf ||
    fail "wired connections get wake-on-LAN"
  pass "wired connections get wake-on-LAN"
fi

# From stage 2 on: the daily update check is enabled, the install from the TV
# isn't (the TV starts it), and polkit lets the TV start the two.
if [[ -f /usr/lib/systemd/system/origaitv-update-check.timer ]]; then
  [[ -L /usr/lib/systemd/system/timers.target.wants/origaitv-update-check.timer ]] ||
    fail "the daily update check is enabled"
  [[ ! -e /usr/lib/systemd/system/multi-user.target.wants/origaitv-update-tv.service ]] ||
    fail "an update from the TV only runs when the TV starts it"
  [[ -L /usr/lib/systemd/system/multi-user.target.wants/origaitv-daemon.service ]] ||
    fail "OrigaiTV's daemon is still enabled"
  grep -q 'origaitv-update-tv.service' /usr/share/polkit-1/rules.d/50-origaitv-update.rules ||
    fail "polkit lets the TV start an update"
  pass "the daily update check is enabled, and the TV may start an update"
fi

# From stage 4 on: the provider key's hand-over is enabled, and the move as
# root only runs when the daemon leaves a key (S4.6).
if [[ -f /usr/bin/origaitv-key-store ]]; then
  [[ -L /usr/lib/systemd/system/paths.target.wants/origaitv-key.path ]] ||
    fail "the provider key's hand-over is enabled"
  [[ -f /usr/lib/systemd/system/origaitv-key.service ]] || fail "the move as root is there"
  if compgen -G "/usr/lib/systemd/system/*.wants/origaitv-key.service" >/dev/null; then
    fail "the move as root only runs when the daemon leaves a key"
  fi
  pass "the provider key's hand-over is enabled, and the move as root waits for a key"
fi

# From stage 4 on: the setup hotspot opens on first boot only when it's
# needed, its hand-over to root is enabled, and the package names dnsmasq to
# hand phones their addresses. origaitv went in without its dependencies, so
# this reads what it depends on from pacman's own record of it.
if [[ -f /usr/bin/origaitv-hotspot ]]; then
  [[ -L /usr/lib/systemd/system/multi-user.target.wants/origaitv-hotspot-boot.service ]] ||
    fail "the setup hotspot's first-boot check is enabled"
  [[ -L /usr/lib/systemd/system/paths.target.wants/origaitv-hotspot.path ]] ||
    fail "the setup hotspot's hand-over is enabled"
  if compgen -G "/usr/lib/systemd/system/*.wants/origaitv-hotspot.service" >/dev/null; then
    fail "the setup hotspot itself only opens when asked"
  fi
  sed -n '/^%DEPENDS%$/,/^$/p' "/var/lib/pacman/local/origaitv-$version-1/desc" | grep -qx dnsmasq ||
    fail "the package depends on dnsmasq"
  [[ -f /usr/share/origaitv/companion-web/setup.html && -f /usr/share/origaitv/companion-web/setup.ts ]] ||
    fail "the captive page ships with the daemon"
  pass "the setup hotspot opens only when it's needed, with dnsmasq named and its captive page"
fi

# A TV that loses its network opens its hotspot again by itself. The watch
# that does it starts with the TV, so the package has to ship it enabled.
if [[ -f /usr/lib/systemd/system/origaitv-hotspot-watch.service ]]; then
  [[ -L /usr/lib/systemd/system/multi-user.target.wants/origaitv-hotspot-watch.service ]] ||
    fail "the watch for a lost network is enabled"
  pass "the watch for a lost network starts with the TV"
fi

# From stage 5 on: TV setup's screens ship whole, in place of the stage 0
# welcome page, with the daemon's side that keeps their step.
if [[ -f /usr/share/origaitv/daemon/setup.ts ]]; then
  for file in index.html main.ts setup.css; do
    [[ -f /usr/share/origaitv/setup/$file ]] || fail "TV setup's $file ships"
  done
  [[ ! -e /usr/share/origaitv/setup/welcome ]] || fail "the stage 0 welcome page is gone"
  pass "TV setup's screens ship whole, with the daemon's side that keeps their step"
fi

# From setup's apps step on: the hand-over that installs the apps picked is
# enabled, and the installs as root only run when the daemon leaves some.
if [[ -f /usr/bin/origaitv-setup-apps ]]; then
  [[ -L /usr/lib/systemd/system/paths.target.wants/origaitv-setup-apps.path ]] ||
    fail "setup's apps hand-over is enabled"
  if compgen -G "/usr/lib/systemd/system/*.wants/origaitv-setup-apps.service" >/dev/null; then
    fail "the installs as root only run when the daemon leaves the apps picked"
  fi
  pass "setup's apps hand-over is enabled, and the installs wait for the apps picked"
fi

# From setup's look on (S5.2): a theme's colours reach the TV as soon as
# Omarchy swaps it in, in every session of the owner's.
if [[ -f /usr/lib/systemd/user/origaitv-theme.path ]]; then
  [[ -L /usr/lib/systemd/user/default.target.wants/origaitv-theme.path ]] ||
    fail "the owner's theme hand-over is on in every session"
  if compgen -G "/usr/lib/systemd/user/*.wants/origaitv-theme.service" >/dev/null; then
    fail "the theme's hand-over only runs when a theme changes or the TV starts"
  fi
  pass "a new theme's colours go to the TV as soon as Omarchy swaps it in"
fi

# From stage 3's NAS shares on (ADR-038): the hand-over to root is enabled,
# the shares mount at boot, the drop folder lets anyone add a request and
# only root read one, and the package names cifs-utils for mount.cifs.
if [[ -f /usr/bin/origaitv-share-store ]]; then
  [[ -L /usr/lib/systemd/system/paths.target.wants/origaitv-share.path ]] ||
    fail "the NAS share hand-over is enabled"
  [[ -L /usr/lib/systemd/system/multi-user.target.wants/origaitv-shares.service ]] ||
    fail "the NAS shares mount at boot"
  if compgen -G "/usr/lib/systemd/system/*.wants/origaitv-share.service" >/dev/null; then
    fail "the mount as root only runs when Music leaves a request"
  fi
  [[ -f /usr/lib/tmpfiles.d/origaitv-shares.conf ]] || fail "the drop folder's tmpfiles entry is in the package"
  systemd-tmpfiles --create /usr/lib/tmpfiles.d/origaitv-shares.conf
  [[ $(stat -c '%a %U' /var/lib/origaitv/share-drop) == "1733 root" ]] ||
    fail "the drop folder lets anyone add a request and only root read one"
  sed -n '/^%DEPENDS%$/,/^$/p' "/var/lib/pacman/local/origaitv-$version-1/desc" | grep -qx cifs-utils ||
    fail "the package depends on cifs-utils"
  pass "a NAS share's hand-over to root is enabled, its drop folder is root's to read, and cifs-utils is named"
fi

# The TV has no voice of its own from after 0.2.0: origaitv doesn't ask for
# origaitv-voice. It still names pipewire, for pw-play, which plays an AI's
# own voice where a key has one. Stable's 0.2.0 does depend on origaitv-voice,
# and then the channel has to have it, or a box can't install origaitv.
depends=$(sed -n '/^%DEPENDS%$/,/^$/p' "/var/lib/pacman/local/origaitv-$version-1/desc")
grep -qx pipewire <<<"$depends" || fail "the package depends on pipewire"
if grep -qx origaitv-voice <<<"$depends"; then
  # origaitv went in with --nodeps above, so the voice isn't installed: it's
  # the channel that has to offer it, for a box that installs origaitv whole.
  pacman -Si origaitv-voice >/dev/null || fail "origaitv $version depends on origaitv-voice, and the $channel channel has it"
  pass "origaitv $version depends on origaitv-voice, and the $channel channel has it"
else
  if pacman -Si origaitv-voice >/dev/null 2>&1; then
    fail "the repository has no origaitv-voice"
  fi
  [[ ! -e /usr/lib/origaitv-voice ]] || fail "nothing of a voice is on the box"
  pass "there's no origaitv-voice: origaitv installs without it, and still names pipewire"
fi

# Every module OrigaiTV's TypeScript imports is in the package: the daemon and
# the home screen import each other's files, and a missing one only shows
# when the daemon starts or the TV draws the page. A builder recipe's
# template isn't run from here: the builder copies it into a build's own
# folder, so its imports are the built app's, not the package's.
while IFS= read -r file; do
  while IFS= read -r module; do
    [[ -f $(dirname "$file")/$module ]] || fail "${file#/usr/share/origaitv/} imports $module, which the package doesn't have"
  done < <(grep -oE "from \"\.\.?/[^\"]+\"" "$file" | sed -E 's/^from "(.*)"$/\1/')
done < <(find /usr/share/origaitv -name '*.ts' -not -path '*/node_modules/*' -not -path '/usr/share/origaitv/builder/recipes/*/template/*')
pass "every module OrigaiTV's TypeScript imports is in the package"

# From stage 6 on: the builds and the builder's home are mounted nosuid and
# nodev from boot, so nothing set-user-ID the builder writes counts (ADR-052).
if [[ -f /usr/lib/systemd/system/origaitv-builder@.service ]]; then
  for mount in var-lib-origaitv-build.mount var-lib-origaitv-builder.mount; do
    [[ -L /usr/lib/systemd/system/local-fs.target.wants/$mount ]] || fail "$mount is enabled from boot"
    grep -qx 'Options=bind,nosuid,nodev' "/usr/lib/systemd/system/$mount" || fail "$mount is nosuid and nodev"
  done
  pass "the builds and the builder's home are mounted nosuid and nodev from boot"
fi

# From stage 7 on: the router's two services start with the box, its user
# is made, and the phrase set origaitv selftest S7.4 runs is there.
if [[ -f /usr/lib/systemd/system/origaitv-router.service ]]; then
  for unit in origaitv-router.service origaitv-router-cli.service; do
    [[ -L /usr/lib/systemd/system/multi-user.target.wants/$unit ]] || fail "$unit starts with the box"
  done
  [[ -f /usr/lib/sysusers.d/origaitv-router.conf ]] || fail "the router's user is in the package"
  for file in daemon/router-serve.ts daemon/providers/index.ts daemon/executors/index.ts test/origaitv/evals/router/phrases.json test/origaitv/evals/router/run.mts; do
    [[ -f /usr/share/origaitv/$file ]] || fail "the package has $file"
  done
  pass "the router's services start with the box, with their user, and the phrase set is on it"
fi

# From phase 2's track 2 on: the boot splash stays up until the TV takes
# over, through a drop-in for Plymouth's own quit, and the TV session draws
# the same splash until home is drawn.
if [[ -f /usr/bin/origaitv-boot-splash ]]; then
  dropin=/usr/lib/systemd/system/plymouth-quit.service.d/origaitv.conf
  [[ -f $dropin ]] || fail "Plymouth's drop-in is in the package"
  grep -qx 'ExecStart=-/usr/bin/origaitv-boot-splash quit' "$dropin" || fail "Plymouth quits through origaitv-boot-splash"
  [[ -f /usr/share/origaitv/session/splash/shell.qml ]] || fail "the TV session's splash is in the package"
  pass "the boot splash's drop-in for Plymouth and the TV session's splash ship"
fi

# Every OrigaiTV file a system unit runs is in the package, so a unit never
# points at a file an older package had, as the daemon's once pointed at the
# stage 0 placeholder.
for unit in /usr/lib/systemd/system/origaitv-*.service; do
  while IFS= read -r file; do
    [[ -f $file ]] || fail "${unit##*/} runs $file, which the package doesn't have"
  done < <(grep -o '/usr/share/origaitv/[^ ]*' "$unit")
done
pass "every OrigaiTV file a system unit runs is in the package"

[[ ! -e /usr/bin/origaitv-check ]] || fail "the developers' gate isn't on the box"
pass "the developers' gate isn't on the box"

# What Omarchy does to pacman.conf, then what OrigaiTV does about it.
cp /etc/pacman.conf.arch /etc/pacman.conf
origaitv-pacman-conf >/dev/null
origaitv-pacman-conf --check >/dev/null || fail "origaitv-pacman-conf puts the repository back"
pacman -Sy >/dev/null || fail "the repository line origaitv-pacman-conf writes works"
pacman -Si origaitv >/dev/null || fail "the repository line origaitv-pacman-conf writes works"
pass "the repository line origaitv-pacman-conf writes works"
