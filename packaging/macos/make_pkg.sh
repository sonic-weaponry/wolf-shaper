#!/usr/bin/env bash
# Builds the macOS installer: one package that installs only wolf-shaper.vst3 into /Library/Audio/Plug-Ins/VST3, under
# the official v1.0.2 installer's package identifier, so it replaces the official Wolf Shaper VST3 and its receipt.
# The bundle gets the licenses, the credits and the link to its exact source in Contents/Resources; the installer shows
# a welcome text and the GPL in its License pane.
#
# Unsigned unless these are set (ci/keychain.sh finds them; see ci/README.md, "Signing"):
#   SIGN_APP_IDENTITY        signs the bundle (codesign: hardened runtime, after the licenses are in, so the seal
#                            covers them): a Developer ID Application identity, its SHA-1, or "-" for ad hoc
#   SIGN_INSTALLER_IDENTITY  signs the installer (productbuild): the Developer ID Installer identity's name
#   SIGN_KEYCHAIN            the keychain holding both identities
#   SIGN_TIMESTAMP           "no" leaves out the secure timestamp (ad hoc signatures can't have one)
# A release build (PKG_RELEASE_TAG, e.g. v1.0.2-sw.1): the credits also point at the release page, which carries the
# complete source as one download. Other builds keep the commit links only (the "[test]" lines of CREDITS.txt.in).
#
# Usage: packaging/macos/make_pkg.sh <wolf-shaper.vst3> <version> <output .pkg>
# Run it on macOS from the repository root after the build, with the dpf submodule checked out. See ci/README.md.
set -euo pipefail

bundle=$1
version=$2
output=$3

here=packaging/macos
identifier=studio.kx.distrho.plugins.wolf-shaper.vst3bundles
commit=$(git rev-parse HEAD)
dpf_commit=$(git -C dpf rev-parse HEAD)

if [ ! -f "$bundle/Contents/Info.plist" ] || [ ! -f "$bundle/Contents/MacOS/wolf-shaper" ]; then
    echo "::error::$bundle has no Contents/Info.plist or no Contents/MacOS/wolf-shaper (is dpf at a commit with DPF's fix eba58491?)"
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root=$work/root
target=$root/wolf-shaper.vst3
mkdir -p "$root" "$work/resources"
ditto "$bundle" "$target"

# License texts with Unix line endings (some are stored with Windows ones in the source tree). DSPFilters keeps its
# license in each header's comment.
text() {
    tr -d '\r' <"$1" >"$2"
}
res=$target/Contents/Resources
mkdir -p "$res/LICENSES"
text LICENSE "$res/LICENSE (GPL-3.0).txt"
text dpf/LICENSE "$res/LICENSES/DPF (ISC).txt"
text dpf/dgl/src/pugl-upstream/COPYING "$res/LICENSES/pugl (ISC).txt"
text dpf/dgl/src/nanovg/LICENSE.txt "$res/LICENSES/NanoVG (zlib).txt"
tr -d '\r' <libs/DSPFilters/include/DspFilters/Bessel.h |
    sed -n '/^"A Collection of Useful/,/^THE SOFTWARE\.$/p' >"$res/LICENSES/DSPFilters (MIT).txt"
text "resources/fonts/Chivo/SIL Open Font License.txt" "$res/LICENSES/Chivo font (SIL OFL 1.1).txt"
text dpf/dgl/src/resources/LICENSE-DejaVuSans.ttf.txt "$res/LICENSES/DejaVu Sans font (Bitstream Vera).txt"
release_tag=${PKG_RELEASE_TAG:-}
if [ -n "$release_tag" ]; then
    case $release_tag in v[0-9]*) ;; *) echo "::error::PKG_RELEASE_TAG $release_tag isn't a release tag"; exit 1 ;; esac
    variant=(-e '/^\[test\]/d' -e 's/^\[release\] \{0,1\}//')
else
    variant=(-e '/^\[release\]/d' -e 's/^\[test\] //')
fi
sed "${variant[@]}" -e "s|@RELEASE_TAG@|$release_tag|g" -e "s|@COMMIT@|$commit|g" -e "s|@DPF_COMMIT@|$dpf_commit|g" \
    "$here/CREDITS.txt.in" >"$res/CREDITS and SOURCE.txt"
if ! grep -q 'Permission is hereby granted' "$res/LICENSES/DSPFilters (MIT).txt" ||
    grep -q -e '@[A-Z_]*@' -e '^\[test\]' -e '^\[release\]' "$res/CREDITS and SOURCE.txt"; then
    echo "::error::the DSPFilters license or the credits came out wrong"
    exit 1
fi
chmod -R u=rwX,go=rX "$root"

# retry <command...>: Apple's timestamp server sometimes doesn't answer; three tries, 15 s apart.
retry() {
    local attempt
    for attempt in 1 2 3; do
        if "$@"; then
            return 0
        fi
        if [ $attempt -lt 3 ]; then
            echo "attempt $attempt failed, trying again in 15 s"
            sleep 15
        fi
    done
    return 1
}

timestamp=--timestamp
if [ "${SIGN_TIMESTAMP:-yes}" = no ]; then
    timestamp=--timestamp=none
fi

# Signing the bundle: the program inside keeps its code byte for byte; codesign replaces the linker's ad hoc signature
# at the end of each slice and seals every other file of the bundle in Contents/_CodeSignature/CodeResources. No
# entitlements: a plugin runs inside its host, whose own entitlements apply.
if [ -n "${SIGN_APP_IDENTITY:-}" ]; then
    echo "--- signing the bundle"
    sign_args=(--force --sign "$SIGN_APP_IDENTITY" --options runtime "$timestamp")
    if [ -n "${SIGN_KEYCHAIN:-}" ]; then
        sign_args+=(--keychain "$SIGN_KEYCHAIN")
    fi
    retry codesign "${sign_args[@]}" "$target"
    codesign --verify --deep --strict --verbose=2 "$target"
    codesign -dvv "$target" 2>&1 | grep -E '^(Identifier|Format|Authority|TeamIdentifier|Timestamp|Signed Time|Runtime Version|Sealed Resources|Info.plist)=' || true
    chmod -R u=rwX,go=rX "$root"
fi

# What pkgbuild would do with the bundle on its own, for the record. component.plist sets every key explicitly (see
# pkgbuild(1)): not relocatable (always /Library/Audio/Plug-Ins/VST3, never over a bundle with the same identifier
# somewhere else), not version-checked (installs even if the bundle on disk says it's newer), and "upgrade" (the
# bundle in the package atomically replaces the one on disk, the official v1.0.2 VST3 for example).
echo "--- pkgbuild's defaults for this bundle (not used)"
if pkgbuild --analyze --root "$root" "$work/analyzed.plist" >/dev/null; then
    plutil -p "$work/analyzed.plist"
fi

pkgbuild \
    --root "$root" \
    --component-plist "$here/component.plist" \
    --identifier "$identifier" \
    --version "$version" \
    --install-location /Library/Audio/Plug-Ins/VST3 \
    "$work/dpf-wolf-shaper-vst3bundles.pkg"

sed -e "s|@COMMIT@|$commit|g" "$here/welcome.txt.in" >"$work/resources/welcome.txt"
# The License pane gets the GPL with each paragraph on one line (same words; the script checks), so the pane wraps it
# cleanly. The copy in the bundle stays exactly as published.
tr -d '\r' <LICENSE | python3 "$here/unwrap_license.py" >"$work/resources/LICENSE.txt"
sed -e "s|@IDENTIFIER@|$identifier|g" -e "s|@VERSION@|$version|g" "$here/distribution.xml.in" >"$work/distribution.xml"

product_args=(
    --distribution "$work/distribution.xml"
    --resources "$work/resources"
    --package-path "$work"
    --identifier studio.kx.distrho.wolf-shaper
    --version "$version"
)
if [ -n "${SIGN_INSTALLER_IDENTITY:-}" ]; then
    echo "--- the installer will be signed by: $SIGN_INSTALLER_IDENTITY"
    product_args+=(--sign "$SIGN_INSTALLER_IDENTITY" "$timestamp")
    if [ -n "${SIGN_KEYCHAIN:-}" ]; then
        product_args+=(--keychain "$SIGN_KEYCHAIN")
    fi
fi

mkdir -p "$(dirname "$output")"
rm -f "$output"
retry productbuild "${product_args[@]}" "$output"

echo "--- $output"
ls -l "$output"
shasum -a 256 "$output"
echo "--- files it installs into /Library/Audio/Plug-Ins/VST3"
pkgutil --payload-files "$output"
