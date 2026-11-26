#!/bin/bash
# Morph installer.
#
#   curl -fsSL https://raw.githubusercontent.com/jmweinst/jmweinst.github.io/claude/eloquent-fermi-0opgln/morph/install.sh | bash
#
# Downloads the app, puts it in Applications and opens it. No sudo. Running it again updates Morph.
set -euo pipefail

SITE="https://jmweinst.github.io/morph"
BRANCH="https://raw.githubusercontent.com/jmweinst/jmweinst.github.io/claude/eloquent-fermi-0opgln/morph"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[1m✗ %s\033[0m\n\n' "$1"; exit 1; }

echo; bold "Morph"; echo "  Click a file, pick a format, done."; echo
[ "$(uname -s)" = "Darwin" ] || fail "Morph is a Mac app; this isn't a Mac."
OS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$OS_MAJOR" -ge 12 ] || fail "Morph needs macOS 12 or later (this Mac has $(sw_vers -productVersion))."

TMP="$(mktemp -d "${TMPDIR:-/tmp}/morph-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

printf '  → downloading… '
curl -fsSL "${MORPH_URL:-$SITE/dist/Morph.zip}" -o "$TMP/Morph.zip" 2>/dev/null \
  || curl -fsSL "$BRANCH/dist/Morph.zip" -o "$TMP/Morph.zip" 2>/dev/null \
  || fail "Couldn't download Morph. Check your connection and try again."
ditto -x -k "$TMP/Morph.zip" "$TMP/app" || fail "The download was damaged. Try again."
[ -x "$TMP/app/Morph.app/Contents/MacOS/Morph" ] || fail "The download was damaged. Try again."
codesign --verify --deep "$TMP/app/Morph.app" 2>/dev/null || fail "The download failed its integrity check. Try again."
echo "ok"

DEST="/Applications"
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi

printf '  → installing in %s… ' "$DEST"
pkill -x Morph 2>/dev/null || true
if [ -d "$DEST/Morph.app" ]; then
  rm -rf "$DEST/Morph.app"
  # An updated app is a different program as far as macOS privacy settings go, so start its
  # permission from a clean slate instead of leaving a stale switch that looks on but isn't.
  tccutil reset Accessibility io.github.jmweinst.morph >/dev/null 2>&1 || true
fi
ditto "$TMP/app/Morph.app" "$DEST/Morph.app"
xattr -dr com.apple.quarantine "$DEST/Morph.app" 2>/dev/null || true
echo "ok"

open "$DEST/Morph.app"

echo
bold "  One thing left: let Morph see which file you're pointing at."
cat <<'TEXT'
  macOS is asking for this now. Click "Open System Settings", then switch Morph on
  under Privacy & Security → Accessibility. (That is the only permission it needs.)

  Then hold ⌥ Option and click any file on your desktop or in Finder.
  Morph lives in the menu bar: the small ring icon at the top right of your screen.

TEXT
