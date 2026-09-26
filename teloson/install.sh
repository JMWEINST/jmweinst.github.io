#!/bin/bash
# Teloson desk installer.
#
#   curl -fsSL https://jmweinst.github.io/teloson/install.sh | bash -s -- TL-XXXX-XXXX-XXXX you@example.com
#
# This only works for a client the operators have already set up. It puts the desk in
# ~/Teloson, installs Node beside it if the Mac has none, writes your signed mandate,
# runs the desk's own setup under it, starts the practice desk (fake money) and opens
# it in your browser. Nothing here needs sudo, and nothing is placed outside your home
# folder. Running the same line again updates the desk and keeps your settings and data.

# ---- when piped from curl, save the rest of this file and re-run it with the keyboard attached
if [ ! -t 0 ] && [ -z "${TELOSON_INSTALLER:-}" ]; then
  TMP="$(mktemp "${TMPDIR:-/tmp}/teloson-install.XXXXXX")"
  { echo '#!/bin/bash'; cat; } > "$TMP"
  if [ -r /dev/tty ]; then TELOSON_INSTALLER="$TMP" exec bash "$TMP" "$@" < /dev/tty
  else TELOSON_INSTALLER="$TMP" exec bash "$TMP" "$@"; fi
fi
set -euo pipefail

SUPABASE="https://jiyujojygjufkfdkcycd.supabase.co"
API="$SUPABASE/rest/v1/rpc"
BUNDLE="$SUPABASE/functions/v1/teloson-desk"
KEY="sb_publishable_YxqbAEU_h_R0GI-OqCpKhA_H-Z2mL2V"
HOME_DIR="${TELOSON_HOME:-$HOME/Teloson}"
DESK="$HOME_DIR/desk"
NODE_DIR="$HOME_DIR/node"
LOG="$HOME_DIR/install.log"
CODE="${1:-}"; EMAIL="${2:-}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
fail() { printf '\n\033[1m✗ %s\033[0m\n' "$1"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; echo; exit 1; }
json() { # json <key> <text>  -> the string value for key, or empty
  printf '%s' "$2" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}
jsonbool() { printf '%s' "$2" | grep -q "\"$1\"[[:space:]]*:[[:space:]]*true"; }
b64d() { base64 -D 2>/dev/null || base64 -d; }

echo; bold "Teloson"; dim "A private desk. This installer only works with an account the operators made for you."; echo
[ "$(uname -s)" = "Darwin" ] || fail "This installer is for macOS." "Your desk is set up on a Mac. Talk to us if that is a problem."
# Node 24 (what the installer brings) needs macOS 13.5 or later.
OSV="$(sw_vers -productVersion 2>/dev/null || echo 0)"
OS_MAJ="${OSV%%.*}"; OS_MIN="$(printf '%s' "$OSV" | cut -d. -f2)"; OS_MIN="${OS_MIN:-0}"
if [ "$OS_MAJ" -lt 13 ] || { [ "$OS_MAJ" -eq 13 ] && [ "$OS_MIN" -lt 5 ]; }; then
  fail "This Mac runs macOS $OSV." "The desk needs macOS 13.5 or later (14 or later recommended). Update macOS, then run this line again."
fi

# ---- the account --------------------------------------------------------------
while [ -z "$CODE" ]; do read -r -p "  Your client code (TL-…): " CODE || true; done
while [ -z "$EMAIL" ]; do read -r -p "  The email address on your account: " EMAIL || true; done
CODE="$(printf '%s' "$CODE" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
EMAIL="$(printf '%s' "$EMAIL" | tr -d '[:space:]"\\')"
HOSTN="$(scutil --get ComputerName 2>/dev/null || hostname)"; HOSTN="$(printf '%s' "$HOSTN" | tr -d '"\\')"
BODY="$(printf '{"p_code":"%s","p_email":"%s","p_host":"%s"}' "$CODE" "$EMAIL" "$HOSTN")"
printf '  → checking your account… '
RESP="$(curl -fsS -X POST "$API/teloson_claim" -H "apikey: $KEY" -H "Content-Type: application/json" -d "$BODY" 2>/dev/null || true)"
if ! jsonbool ok "$RESP"; then
  REASON="$(json reason "$RESP")"
  case "$REASON" in
    no_account) fail "No account matches that code and email." "Teloson is not a public service. If you were expecting an account, reply to the email we sent you.";;
    paused|revoked) fail "This account is $REASON." "Reply to the email we sent you and we will sort it out.";;
    throttled) fail "Too many attempts right now. Try again in a few minutes.";;
    *) fail "Could not reach the account service." "Check your connection and try again.";;
  esac
fi
NAME="$(json name "$RESP")"; MANDATE="$(json mandate "$RESP")"
PROFILE_B64="$(json profile_b64 "$RESP")"; IDENTITY_B64="$(json identity_b64 "$RESP")"
echo "ok"
bold "  Welcome, $NAME."; dim "  Mandate on file: $MANDATE"; echo
case "$MANDATE" in example-client) fail "This account points at the shipped example mandate, not a signed one." "Reply to the email we sent you; the operators need to attach your mandate.";; esac
case "$MANDATE" in ''|*[!a-z0-9-]*) fail "Your account has no mandate name on file yet." "Reply to the email we sent you; the operators need to finish your account.";; esac
jsonbool ready "$RESP" || [ -n "${TELOSON_BUNDLE_FILE:-}" ] || fail "The desk is not ready to hand out yet." "The operators have not switched on downloads. Reply to the email we sent you."

mkdir -p "$HOME_DIR"; chmod 700 "$HOME_DIR"
umask 077; printf 'CODE=%s\nEMAIL=%s\nMANDATE=%s\n' "$CODE" "$EMAIL" "$MANDATE" > "$HOME_DIR/.account"; umask 022
rm -f "$HOME_DIR/.token"   # older installers kept a download key here; it is no longer needed
exec > >(tee -a "$LOG") 2>&1
echo "---- $(date) install for $MANDATE on $HOSTN" >> "$LOG"

# ---- Node -------------------------------------------------------------------
need_node=1
if [ -x "$NODE_DIR/bin/node" ]; then export PATH="$NODE_DIR/bin:$PATH"; fi
if command -v node >/dev/null 2>&1; then
  MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [ "$MAJOR" -ge 20 ]; then need_node=0; echo "  ✓ Node $(node -v)"; fi
fi
if [ "$need_node" -eq 1 ]; then
  ARCH="$(uname -m)"; case "$ARCH" in arm64) NARCH=arm64;; x86_64) NARCH=x64;; *) fail "Unsupported Mac ($ARCH).";; esac
  printf '  → Node is not on this Mac; putting a copy in ~/Teloson/node… '
  SUMS="$(curl -fsSL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt)" || fail "Could not reach nodejs.org."
  TARBALL="$(printf '%s' "$SUMS" | grep -o "node-v[0-9.]*-darwin-$NARCH.tar.gz" | head -1)"
  [ -n "$TARBALL" ] || fail "Could not find a Node build for this Mac."
  TMPD="$(mktemp -d)"; curl -fsSL "https://nodejs.org/dist/latest-v24.x/$TARBALL" -o "$TMPD/$TARBALL" || fail "The Node download failed. Check your connection and run this again."
  EXPECT="$(printf '%s' "$SUMS" | grep " $TARBALL\$" | awk '{print $1}')"
  ACTUAL="$(shasum -a 256 "$TMPD/$TARBALL" | awk '{print $1}')"
  [ "$EXPECT" = "$ACTUAL" ] || fail "The Node download did not verify. Nothing was installed."
  rm -rf "$NODE_DIR"; mkdir -p "$NODE_DIR"; tar -xzf "$TMPD/$TARBALL" -C "$NODE_DIR" --strip-components=1; rm -rf "$TMPD"
  export PATH="$NODE_DIR/bin:$PATH"; echo "done ($(node -v))"
fi

# ---- the desk itself --------------------------------------------------------
printf '  → downloading your desk… '
TMPD="$(mktemp -d)"
if [ -n "${TELOSON_BUNDLE_FILE:-}" ]; then
  cp "$TELOSON_BUNDLE_FILE" "$TMPD/desk.tgz"      # operator testing only
else
  DL_BODY="$(printf '{"code":"%s","email":"%s","host":"%s"}' "$CODE" "$EMAIL" "$HOSTN")"
  HTTP="$(curl -sS -X POST "$BUNDLE" -H "apikey: $KEY" -H "Content-Type: application/json" -d "$DL_BODY" -o "$TMPD/desk.tgz" -w '%{http_code}' || echo 000)"
  if [ "$HTTP" != "200" ]; then
    case "$HTTP" in
      503) fail "The desk is not ready to hand out yet." "The operators have not switched on downloads. Reply to the email we sent you.";;
      403) fail "The download was refused for this account." "Reply to the email we sent you.";;
      *) fail "The download did not complete (HTTP $HTTP)." "Check your connection and run this again. If it keeps happening, reply to the email we sent you.";;
    esac
  fi
fi
mkdir -p "$TMPD/x"; tar -xzf "$TMPD/desk.tgz" -C "$TMPD/x" --strip-components=1 || fail "The download was damaged. Run this again."
[ -f "$TMPD/x/bin/setup.sh" ] || fail "The download is not a complete desk." "Reply to the email we sent you."
echo "done"

# Your mandate, and only yours, from your account.
mkdir -p "$TMPD/x/profiles"
if [ -n "$PROFILE_B64" ]; then
  printf '%s' "$PROFILE_B64" | b64d > "$TMPD/x/profiles/$MANDATE.json" || fail "Your mandate did not download cleanly. Run this again."
elif [ -f "$DESK/profiles/$MANDATE.json" ]; then
  cp "$DESK/profiles/$MANDATE.json" "$TMPD/x/profiles/"
fi
if [ -n "$IDENTITY_B64" ]; then
  umask 077; printf '%s' "$IDENTITY_B64" | b64d > "$TMPD/x/profiles/$MANDATE.identity.json"; umask 022
elif [ -f "$DESK/profiles/$MANDATE.identity.json" ]; then
  cp -p "$DESK/profiles/$MANDATE.identity.json" "$TMPD/x/profiles/"
fi
[ -f "$TMPD/x/profiles/$MANDATE.json" ] || fail "Your signed mandate ($MANDATE) is not on your account yet." "Reply to the email we sent you; the operators will add it and you can run this again."
# The desk refuses to run on a mandate with anything still to be confirmed with you. Say so here, plainly.
if ! PROBLEMS="$(cd "$TMPD/x" && node -e '
  const r = require("./src/client-profile").loadProfile(process.argv[1], process.cwd());
  if (!r.ok) { console.log(r.errors.map(e => "    · " + e).join("\n")); process.exit(1); }' "$MANDATE" 2>&1)"; then
  fail "Your mandate is on file but is not ready to run yet." "The operators still need to confirm something with you in writing. Reply to the email we sent you.
$PROBLEMS"
fi

# Swap the new code in, keeping the old one until setup has passed.
if [ -d "$DESK" ]; then
  [ -f "$DESK/.env" ] && cp -p "$DESK/.env" "$TMPD/x/.env"
  rm -rf "$DESK.old"; mv "$DESK" "$DESK.old"
fi
mv "$TMPD/x" "$DESK"; rm -rf "$TMPD"

rollback() {
  echo
  if [ -d "$DESK.old" ]; then
    rm -rf "$DESK.failed"; mv "$DESK" "$DESK.failed" 2>/dev/null || true; mv "$DESK.old" "$DESK"
    echo "  Your previous desk has been put back; nothing about it changed."
  fi
  fail "Setup did not finish." "The full log is in ~/Teloson/install.log. Send us the last 50 lines of it."
}

# ---- setup under the signed mandate ------------------------------------------
echo; bold "  Setting up the desk under your mandate. It will ask for your own keys; blank is allowed for each."; echo
cd "$DESK"; chmod +x bin/*.sh 2>/dev/null || true
bin/setup.sh "$MANDATE" || rollback
rm -rf "$DESK.old" "$DESK.failed"

# ---- start the practice desk and open it -------------------------------------
PLIST="$HOME/Library/LaunchAgents/com.portfolio-command.practice.plist"
if [ -z "${TELOSON_NO_LAUNCH:-}" ] && [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" >/dev/null 2>&1 || true
  launchctl load "$PLIST" && echo "  ✓ practice desk starts at login and restarts itself if it crashes"
fi
TOKEN_LINE="$(grep '^AUTH_TOKEN=' .env | tail -1 | cut -d= -f2- | tr -d "\"'[:space:]" || true)"
PORT_SIM="$(grep '^SIM_PORT=' .env | tail -1 | cut -d= -f2- | tr -d "\"'[:space:]" || true)"; PORT_SIM="${PORT_SIM:-8766}"
URL="http://localhost:$PORT_SIM/"; [ -n "$TOKEN_LINE" ] && URL="$URL?token=$TOKEN_LINE"
if [ -z "${TELOSON_NO_LAUNCH:-}" ]; then
  printf '  → waiting for the desk to answer'
  for i in $(seq 1 40); do
    # Any HTTP answer means it is up (the page itself asks for the token).
    CODE_NOW="$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT_SIM/" 2>/dev/null || true)"
    if [ -n "$CODE_NOW" ] && [ "$CODE_NOW" != "000" ]; then echo " ✓"; open "$URL"; break; fi
    printf '.'; sleep 1.5
    [ "$i" -eq 40 ] && echo && echo "  The desk has not answered yet. Open this in a minute: $URL"
  done
fi
cat <<EOF

$(bold "Done.")  Your practice desk is running on fake money with real prices.
  Dashboard:   $URL   (used once, then your browser remembers it)
  Status:      ~/Teloson/desk/bin/status.sh
  Update:      run this same command again, or ~/Teloson/desk/bin/update.sh.
               Either keeps your settings and your data.

  Real money is switched on separately, with us, after the practice period.
EOF
