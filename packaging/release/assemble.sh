#!/usr/bin/env bash
# Puts a release together: the five files for the release page, its notes and its title (ci/README.md, "The release").
#
# Usage: packaging/release/assemble.sh <release tag> <installer .pkg> <plugin .zip> <source .tar.gz> <output folder>
#   RELEASE_REHEARSAL=yes  the installer and the zip are unsigned stand-ins: the title and the notes say so
# Writes <output>/assets/ (the files for the release page), <output>/release-notes.md and <output>/release-title.txt.
# Run it from the repository root with the submodules checked out; ci/check_release.py checks the result.
set -euo pipefail

tag=$1
pkg=$2
zip=$3
source=$4
out=$5

case $tag in
    v[0-9]*-sw.[0-9]*) ;;
    *) echo "::error::$tag isn't a release tag like v1.0.2-sw.1"; exit 1 ;;
esac
commit=$(git rev-parse HEAD)
dpf_commit=$(git -C dpf rev-parse HEAD)
pugl_commit=$(git -C dpf/dgl/src/pugl-upstream rev-parse HEAD)

rm -rf "$out"
assets=$out/assets
mkdir -p "$assets"
cp "$pkg" "$assets/wolf-shaper-$tag-macos-universal.pkg"
cp "$zip" "$assets/wolf-shaper-$tag-macos-universal-vst3.zip"
cp "$source" "$assets/wolf-shaper-$tag-source.tar.gz"
cp LICENSE "$assets/LICENSE-GPL-3.0.txt"
if command -v sha256sum >/dev/null; then
    sum() { sha256sum "$@"; }
else
    sum() { shasum -a 256 "$@"; }
fi
(cd "$assets" && ls | LC_ALL=C sort | while IFS= read -r f; do sum "$f"; done >"$out/SHA256SUMS.tmp")
mv "$out/SHA256SUMS.tmp" "$assets/SHA256SUMS"

title="Wolf Shaper 1.0.2 for Mac, Windows-compatible VST3 ($tag)"
banner=
if [ "${RELEASE_REHEARSAL:-no}" = yes ]; then
    title="REHEARSAL, not a release: $title"
    run=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-sonic-weaponry/wolf-shaper}/actions/runs/${GITHUB_RUN_ID:-0}
    banner="> **Rehearsal draft, not a release.** Made by CI run $run to test the release path. The installer and the plugin zip here are unsigned stand-ins. This draft gets deleted.
"
fi
printf '%s\n' "$title" >"$out/release-title.txt"
{
    if [ -n "$banner" ]; then
        printf '%s\n' "$banner"
    fi
    sed -e "s|@RELEASE_TAG@|$tag|g" \
        -e "s|@COMMIT_SHORT@|${commit:0:8}|g" -e "s|@COMMIT@|$commit|g" \
        -e "s|@DPF_COMMIT_SHORT@|${dpf_commit:0:8}|g" -e "s|@DPF_COMMIT@|$dpf_commit|g" \
        -e "s|@PUGL_COMMIT_SHORT@|${pugl_commit:0:8}|g" -e "s|@PUGL_COMMIT@|$pugl_commit|g" \
        packaging/release/release-notes.md.in
} >"$out/release-notes.md"

echo "--- $out"
echo "title: $title"
(cd "$assets" && ls -l)
cat "$assets/SHA256SUMS"
