#!/usr/bin/env bash
# Sends the signed installer to Apple's notary service, waits for Apple's answer, saves Apple's log, and staples the
# ticket to the installer (ci/README.md, "Signing").
#
# Usage: packaging/macos/notarize.sh <signed .pkg> <folder for Apple's log>
# Needs APPLE_API_KEY_PATH (the App Store Connect API key, a .p8 file), APPLE_API_KEY_ID and APPLE_API_ISSUER_ID.
# NOTARY_TIMEOUT (default 60m) is how long to wait for Apple. Writes submitted.sha256, submission.json, info.json and
# notary-log.json into the folder.
# Exit 0: accepted and stapled. Exit 1: Apple rejected it, hasn't finished in time (a new team's first submissions can
# take days; the message names the submission), or stapling failed.
set -euo pipefail

pkg=$1
logs=$2
: "${APPLE_API_KEY_PATH:?}" "${APPLE_API_KEY_ID:?}" "${APPLE_API_ISSUER_ID:?}"
timeout=${NOTARY_TIMEOUT:-60m}
auth=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
mkdir -p "$logs"

field() {
    python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null || true
}

shasum -a 256 "$pkg" | tee "$logs/submitted.sha256"
echo "--- the team's latest notarization submissions"
xcrun notarytool history "${auth[@]}" 2>&1 | head -n 25 || true

echo "--- submitting"
xcrun notarytool submit "$pkg" "${auth[@]}" --output-format json >"$logs/submission.json"
cat "$logs/submission.json"
echo
id=$(field "$logs/submission.json" id)
if [ -z "$id" ]; then
    echo "::error::Apple's notary service didn't return a submission ID"
    exit 1
fi
echo "submission $id: waiting up to $timeout for Apple"
xcrun notarytool wait "$id" "${auth[@]}" --timeout "$timeout" || true
xcrun notarytool info "$id" "${auth[@]}" --output-format json >"$logs/info.json" || true
cat "$logs/info.json"
echo
status=$(field "$logs/info.json" status)
xcrun notarytool log "$id" "${auth[@]}" "$logs/notary-log.json" || echo "(no log from Apple yet)"
if [ -f "$logs/notary-log.json" ]; then
    echo "--- Apple's log"
    cat "$logs/notary-log.json"
    echo
fi

case $status in
    Accepted) echo "Apple accepted submission $id" ;;
    "In Progress" | "")
        echo "::error::Apple hasn't finished checking submission $id after $timeout, so nothing was stapled. A new or changed team's first submissions can take days. Check on it with the notary-status workflow; once Apple has accepted it, start a new signing run."
        exit 1
        ;;
    *)
        echo "::error::Apple's notary service answered '$status' for submission $id; its log above says why."
        exit 1
        ;;
esac

# Apple's ticket can take a moment to reach the servers stapler asks.
for attempt in 1 2 3 4 5; do
    if xcrun stapler staple -v "$pkg"; then
        break
    fi
    if [ $attempt -eq 5 ]; then
        echo "::error::stapling the ticket failed 5 times"
        exit 1
    fi
    echo "stapling failed (attempt $attempt), trying again in 20 s"
    sleep 20
done
xcrun stapler validate -v "$pkg"
echo "--- stapled"
shasum -a 256 "$pkg"
