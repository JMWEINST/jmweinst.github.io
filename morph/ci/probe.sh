#!/bin/bash
# Throwaway: what can a hosted Mac runner actually do?
set -x
sw_vers; uname -m; swiftc --version; xcode-select -p
which ffmpeg pandoc soffice cwebp || true
ls -la ~/Desktop
printf 'hello' > ~/Desktop/morph-probe.txt
sleep 3
osascript -e 'tell application "Finder" to get desktop position of item "morph-probe.txt" of desktop' || true
osascript -e 'tell application "Finder" to get name of every item of desktop' || true
swiftc -O -o /tmp/probe morph/ci/probe.swift && /tmp/probe
# does an external rename keep the icon where it was?
osascript -e 'tell application "Finder" to set desktop position of item "morph-probe.txt" of desktop to {333, 444}' || true
sleep 2
osascript -e 'tell application "Finder" to get desktop position of item "morph-probe.txt" of desktop' || true
printf 'changed contents' > ~/Desktop/morph-probe.txt
mv ~/Desktop/morph-probe.txt ~/Desktop/morph-probe.md
sleep 4
osascript -e 'tell application "Finder" to get desktop position of item "morph-probe.md" of desktop' || true
# and a brand-new file that replaces by name (new inode)?
printf 'x' > ~/Desktop/morph-probe2.txt; sleep 3
osascript -e 'tell application "Finder" to set desktop position of item "morph-probe2.txt" of desktop to {600, 300}' || true
sleep 2
printf 'y' > /tmp/new.rtf; rm ~/Desktop/morph-probe2.txt; mv /tmp/new.rtf ~/Desktop/morph-probe2.rtf; sleep 4
osascript -e 'tell application "Finder" to get desktop position of item "morph-probe2.rtf" of desktop' || true
screencapture -x /tmp/desk.png && sips -Z 1200 -s format jpeg -s formatOptions 50 /tmp/desk.png --out /tmp/desk.jpg && ls -la /tmp/desk.jpg
