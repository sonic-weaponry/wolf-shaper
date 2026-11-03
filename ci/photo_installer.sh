#!/usr/bin/env bash
# Report only: opens the package in macOS Installer on this machine's screen and photographs its first two pages (the
# welcome text, then the license), for the record. Nothing is installed: it never gets past the license.
#
# Usage: ci/photo_installer.sh <.pkg> <output folder>
# Run it on macOS in a logged-in session (CI runners have one). Always exits 0.
set -u

pkg=$1
out=$2
mkdir -p "$out"

open -a Installer "$pkg"
sleep 8
screencapture -x "$out/installer-1-welcome.png" || echo "screencapture failed"
osascript -e 'tell application "System Events" to tell process "Installer" to click button "Continue" of window 1' ||
    echo "could not press Continue (no accessibility permission for this process?)"
sleep 3
screencapture -x "$out/installer-2-license.png" || echo "screencapture failed"
osascript -e 'tell application "Installer" to quit' || killall Installer
ls -l "$out"/installer-*.png
exit 0
