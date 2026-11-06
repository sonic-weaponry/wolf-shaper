#!/usr/bin/env bash
# Packs the plugin from an installer into the zip for the release page: one folder with wolf-shaper.vst3 exactly as the
# installer installs it, HOW TO INSTALL.txt (packaging/release/how-to-install.txt.in), and the credits and license
# files the bundle carries, copied next to it. Zipped with ditto, Apple's tool for zipping signed bundles, without
# extended attributes or AppleDouble ("._") files.
#
# ZIP_STAPLE=yes (a notarized installer only): staple Apple's ticket to the plugin bundle too, so Gatekeeper finds it
# without going online. Report only: if Apple's stapler can't, the zip holds the bundle as the installer has it, and
# Gatekeeper looks the ticket up online (notarizing the installer covers the plugin inside it).
#
# Usage: packaging/macos/make_zip.sh <installer .pkg> <release tag> <output .zip>
# Run it on macOS from the repository root. Checks: the zip unpacks to exactly that folder, byte for byte; the bundle
# in it is the installer's (plus the stapled ticket, Contents/CodeResources, if stapled); a signed bundle still
# verifies after unzipping; the program is still executable. Exits 1 if any check fails.
set -euo pipefail

pkg=$1
tag=$2
output=$3
name=wolf-shaper-$tag-macos-universal-vst3

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pkgutil --expand-full "$pkg" "$work/expanded"
payload=$work/expanded/dpf-wolf-shaper-vst3bundles.pkg/Payload/wolf-shaper.vst3
if [ ! -f "$payload/Contents/MacOS/wolf-shaper" ]; then
    echo "::error::$pkg holds no wolf-shaper.vst3"
    exit 1
fi

folder=$work/zip/$name
bundle=$folder/wolf-shaper.vst3
mkdir -p "$folder"
ditto "$payload" "$bundle"
res=$bundle/Contents/Resources
cp "$res/CREDITS and SOURCE.txt" "$res/LICENSE (GPL-3.0).txt" "$folder/"
ditto "$res/LICENSES" "$folder/LICENSES"
sed -e "s|@RELEASE_TAG@|$tag|g" packaging/release/how-to-install.txt.in >"$folder/HOW TO INSTALL.txt"
if grep -q '@[A-Z_]*@' "$folder/HOW TO INSTALL.txt"; then
    echo "::error::HOW TO INSTALL.txt came out with a placeholder left"
    exit 1
fi

signed=no
if [ -f "$bundle/Contents/_CodeSignature/CodeResources" ]; then
    signed=yes
fi
stapled=no
if [ "${ZIP_STAPLE:-no}" = yes ]; then
    if xcrun stapler staple -v "$bundle" && xcrun stapler validate -v "$bundle"; then
        stapled=yes
    else
        echo "REPORT Apple's stapler can't staple the plugin bundle; the zip holds it as the installer has it"
        rm -rf "$bundle"
        ditto "$payload" "$bundle"
    fi
fi
echo "REPORT plugin bundle signed: $signed, stapled: $stapled"
chmod -R u=rwX,go=rX "$folder"

mkdir -p "$(dirname "$output")"
rm -f "$output"
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$folder" "$output"

# --- Checks, on what comes out of the zip
failed=0
check() {
    if [ "$1" = PASS ]; then echo "PASS $2"; else echo "::error::FAIL $2"; failed=1; fi
}
unzipped=$work/unzipped
ditto -x -k "$output" "$unzipped"
got=$unzipped/$name

top=$(cd "$unzipped" && ls -A)
listing=$(cd "$got" && ls -A | LC_ALL=C sort | tr '\n' '|')
if [ "$top" = "$name" ] && [ "$listing" = "CREDITS and SOURCE.txt|HOW TO INSTALL.txt|LICENSE (GPL-3.0).txt|LICENSES|wolf-shaper.vst3|" ]; then
    check PASS "the zip holds one folder, $name, with the plugin, HOW TO INSTALL, the credits and the licenses"
else
    check FAIL "the zip's layout: top $top, folder $listing"
fi
if zipinfo -1 "$output" | grep -q -E '(^|/)(__MACOSX|\._)'; then
    check FAIL "the zip holds AppleDouble or __MACOSX entries"
else
    check PASS "no AppleDouble or __MACOSX entries"
fi
if diff -r "$folder" "$got" >/dev/null; then
    check PASS "unzipped, byte for byte the folder that was zipped"
else
    diff -r "$folder" "$got" || true
    check FAIL "unzipped, the folder differs from what was zipped"
fi
want=$( { (cd "$payload" && find . -type f); [ $stapled = no ] || echo ./Contents/CodeResources; } | LC_ALL=C sort)
have=$(cd "$got/wolf-shaper.vst3" && find . -type f | LC_ALL=C sort)
same=PASS
[ "$want" = "$have" ] || { same=FAIL; diff <(echo "$want") <(echo "$have") || true; }
while IFS= read -r f; do
    cmp -s "$payload/$f" "$got/wolf-shaper.vst3/$f" || { same=FAIL; echo "differs from the installer's: $f"; }
done < <(cd "$payload" && find . -type f)
check $same "the plugin is the installer's bundle, file for file$([ $stapled = no ] || echo ', plus the stapled ticket')"
if [ -x "$got/wolf-shaper.vst3/Contents/MacOS/wolf-shaper" ]; then
    check PASS "the program is executable after unzipping"
else
    check FAIL "the program isn't executable after unzipping"
fi
for f in "CREDITS and SOURCE.txt" "LICENSE (GPL-3.0).txt"; do
    if cmp -s "$got/$f" "$got/wolf-shaper.vst3/Contents/Resources/$f"; then
        check PASS "$f next to the plugin is the bundle's"
    else
        check FAIL "$f next to the plugin isn't the bundle's"
    fi
done
if [ $signed = yes ]; then
    if codesign --verify --deep --strict --verbose=2 "$got/wolf-shaper.vst3"; then
        check PASS "the signature verifies after unzipping"
    else
        check FAIL "the signature doesn't verify after unzipping"
    fi
fi
if [ $stapled = yes ]; then
    if xcrun stapler validate "$got/wolf-shaper.vst3"; then
        check PASS "the stapled ticket validates after unzipping"
    else
        check FAIL "the stapled ticket doesn't validate after unzipping"
    fi
fi

echo "--- $output"
ls -l "$output"
shasum -a 256 "$output"
exit $failed
