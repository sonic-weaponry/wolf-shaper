#!/usr/bin/env bash
# Report only; nothing here is shipped or kept. Does the bundle sign, and does it need its Info.plist for that? Signs
# throwaway copies ad hoc (no certificate, no secret) with the hardened runtime, as the release signing will with a
# Developer ID: the bundle as the package holds it, the same without Info.plist and PkgInfo, and the official v1.0.2's
# layout (our binary alone, no other file). Each copy is then verified the way Gatekeeper checks a bundle
# (codesign --verify --deep --strict) and opened with the ids check.
#
# Usage: ci/probe_codesign.sh <vst3_check> <.pkg>
# Run it from the repository root on macOS. Always exits 0.
set -u

tool=$1
pkg=$2

work=$(mktemp -d)
pkgutil --expand-full "$pkg" "$work/expanded" >/dev/null
src=$work/expanded/dpf-wolf-shaper-vst3bundles.pkg/Payload/wolf-shaper.vst3
table="| Copy | Sign | Verify (deep, strict) | Opens with the frozen IDs |
|---|---|---|---|"

probe() {
    local name=$1 dir=$work/$1/wolf-shaper.vst3 sign=0 verify=0 ids
    echo "::group::$name"
    (cd "$dir" && find . -type f | LC_ALL=C sort)
    codesign --force --sign - --options runtime --timestamp=none "$dir" 2>&1 || sign=$?
    codesign --verify --deep --strict --verbose=2 "$dir" 2>&1 || verify=$?
    codesign -dvv "$dir" 2>&1 | grep -E '^(Identifier|Format|CodeDirectory|Signature|Info.plist|Sealed Resources|Runtime)' || true
    ids=$("$tool" ids "$dir" ours ci/frozen/class-ids.txt 2>&1 | grep '^RESULT' | tail -n 1)
    echo "::endgroup::"
    echo "PROBE $name: sign exit $sign, verify exit $verify, $ids"
    table="$table
| $name | exit $sign | exit $verify | ${ids:-no result} |"
}

mkdir -p "$work/as-packaged" "$work/no-info-plist" "$work/official-layout/wolf-shaper.vst3/Contents/MacOS"
ditto "$src" "$work/as-packaged/wolf-shaper.vst3"
ditto "$src" "$work/no-info-plist/wolf-shaper.vst3"
rm "$work/no-info-plist/wolf-shaper.vst3/Contents/Info.plist" "$work/no-info-plist/wolf-shaper.vst3/Contents/PkgInfo"
ditto "$src/Contents/MacOS" "$work/official-layout/wolf-shaper.vst3/Contents/MacOS"
for name in as-packaged no-info-plist official-layout; do
    probe "$name"
done

rm -rf "$work"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### Code signing probe (ad hoc, report only)"
        echo
        echo "$table"
        echo
    } >>"$GITHUB_STEP_SUMMARY"
fi
exit 0
