#!/bin/bash
# Drives the real app on a real Mac desktop: hold the shortcut and click a file, click through
# the wheel, then check the file changed format and never moved. Run from the repo root after build.sh.
set -uo pipefail
BIN="$PWD/morph/build/Morph.app/Contents/MacOS/Morph"
SHOTS=/tmp/morph-shots
mkdir -p "$SHOTS"
FAILED=0

shot() { screencapture -x /tmp/morph-shot.png && sips -s format jpeg -s formatOptions 70 /tmp/morph-shot.png --out "$SHOTS/$1.jpg" >/dev/null 2>&1; }
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; FAILED=1; fi; }
finder() { osascript -e "tell application \"Finder\" to $1" 2>&1; }
center() { "$BIN" --find "$1" | awk '/^CENTER/ {print $2, $3; exit}'; }
wait_for() { for _ in $(seq 1 40); do [ -e "$1" ] && return 0; sleep 0.25; done; return 1; }
# through_wheel <file> <cx> <cy> <category> <format> <shot prefix>
through_wheel() {
  local pts; pts="$("$BIN" --layout "$1" "$2" "$3" "$4" "$5")"; echo "$pts"
  local g f; g="$(echo "$pts" | awk '/^GROUP/ {print $2, $3}')"; f="$(echo "$pts" | awk '/^FORMAT/ {print $2, $3}')"
  "$BIN" --click "$2" "$3" trigger; sleep 1; shot "$6-1-wheel"
  # shellcheck disable=SC2086
  "$BIN" --click $g; sleep 0.6
  # shellcheck disable=SC2086
  "$BIN" --move $f; sleep 0.4; shot "$6-2-formats"
  # shellcheck disable=SC2086
  "$BIN" --click $f; sleep 0.35; shot "$6-3-after"
}

defaults write io.github.jmweinst.morph welcomed -bool true
"$BIN" >/tmp/morph-app.log 2>&1 &
APP_PID=$!
sleep 2
check "app is running" "kill -0 $APP_PID"

echo "--- desktop icon: PNG to JPG"
PNG="$HOME/Desktop/Holiday Photo.png"
screencapture -x "$PNG"; sleep 3
finder 'set desktop position of item "Holiday Photo.png" of desktop to {430, 340}'; sleep 2
"$BIN" --find "Holiday Photo.png"; check "icon and its name both resolve to the file" "[ $? -eq 0 ]"
read -r CX CY <<<"$(center "Holiday Photo.png")"
BEFORE="$(finder 'get desktop position of item "Holiday Photo.png" of desktop')"
through_wheel "$PNG" "$CX" "$CY" Image jpg desktop
check "Holiday Photo.jpg appeared" "wait_for '$HOME/Desktop/Holiday Photo.jpg'"
check "the PNG is gone" "[ ! -e '$PNG' ]"
check "it really is a JPEG" "file '$HOME/Desktop/Holiday Photo.jpg' | grep -q 'JPEG image'"
sleep 3
AFTER="$(finder 'get desktop position of item "Holiday Photo.jpg" of desktop')"
echo "position before: $BEFORE   after: $AFTER"
check "icon stayed exactly where it was" "[ '$BEFORE' = '$AFTER' ] && [ -n '$BEFORE' ]"
shot desktop-4-settled

echo "--- a plain click and a click on empty desktop do nothing"
"$BIN" --click 820 560 trigger; sleep 0.8; shot empty-desktop
"$BIN" --click 820 600; sleep 0.3

echo "--- a file Morph can't convert explains itself"
printf 'x' > "$HOME/Desktop/Mystery.xyz"; sleep 3
finder 'set desktop position of item "Mystery.xyz" of desktop to {700, 300}' >/dev/null; sleep 2
read -r MX MY <<<"$(center "Mystery.xyz")"
"$BIN" --click "$MX" "$MY" trigger; sleep 1; shot unknown-file
"$BIN" --click 100 700; sleep 0.5

echo "--- Finder windows: list, icon and column views"
DIR="$HOME/Documents/Morph Test"
mkdir -p "$DIR"
for i in $(seq 1 40); do echo "Line $i of some meeting notes."; done > "$DIR/Meeting Notes.txt"
cp "$HOME/Desktop/Holiday Photo.jpg" "$DIR/Second Photo.jpg"
osascript <<OSA
tell application "Finder"
  activate
  set w to make new Finder window to (POSIX file "$DIR" as alias)
  set bounds of w to {60, 80, 800, 520}
  set current view of w to icon view
end tell
OSA
sleep 2
"$BIN" --find "Meeting Notes.txt"; check "icon view resolves" "[ $? -eq 0 ]"
finder 'set current view of front Finder window to column view' >/dev/null; sleep 2
"$BIN" --find "Meeting Notes.txt"; check "column view resolves" "[ $? -eq 0 ]"
finder 'set current view of front Finder window to list view' >/dev/null; sleep 2
"$BIN" --find "Meeting Notes.txt"; check "list view resolves" "[ $? -eq 0 ]"

read -r LX LY <<<"$(center "Meeting Notes.txt")"
through_wheel "$DIR/Meeting Notes.txt" "$LX" "$LY" Document pdf window
check "Meeting Notes.pdf appeared" "wait_for '$DIR/Meeting Notes.pdf'"
check "the TXT is gone" "[ ! -e '$DIR/Meeting Notes.txt' ]"
check "it really is a PDF" "file '$DIR/Meeting Notes.pdf' | grep -q 'PDF document'"
sleep 1; shot window-4-settled

kill "$APP_PID" 2>/dev/null
echo "--- app log"; cat /tmp/morph-app.log
exit $FAILED
