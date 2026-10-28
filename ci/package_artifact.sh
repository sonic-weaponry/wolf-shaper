#!/usr/bin/env bash
# Packs a built wolf-shaper.vst3 with its licenses, the credits and the link to its exact source, for a CI artifact.
#
# Usage: ci/package_artifact.sh <folder holding wolf-shaper.vst3> <output folder> <platform>
# Run it from the repository root after the build, with the dpf submodule checked out.
set -e

from=$1
to=$2
platform=$3

mkdir -p "$to/licenses"
cp -R "$from/wolf-shaper.vst3" "$to/"
cp LICENSE "$to/licenses/Wolf-Shaper-GPL-3.0.txt"
cp dpf/LICENSE "$to/licenses/DPF-ISC.txt"
cp dpf/dgl/src/pugl-upstream/COPYING "$to/licenses/pugl-ISC.txt"
cp dpf/dgl/src/nanovg/LICENSE.txt "$to/licenses/NanoVG-zlib.txt"
cp dpf/dgl/src/resources/LICENSE-DejaVuSans.ttf.txt "$to/licenses/DPF-DejaVu-Sans-font.txt"
cp libs/DSPFilters/README.md "$to/licenses/DSPFilters-MIT-README.md"
cp "resources/fonts/Chivo/SIL Open Font License.txt" "$to/licenses/Chivo-font-OFL-1.1.txt"

commit=$(git rev-parse HEAD)
dpf_commit=$(git -C dpf rev-parse HEAD)
cat >"$to/SOURCE.txt" <<EOF
Wolf Shaper VST3 for $platform. A CI build for testing, not a release.

Wolf Shaper is made by Patrick Desaulniers: https://github.com/wolf-plugins/wolf-shaper
It is free software under the GNU General Public License, version 3 or later (licenses/Wolf-Shaper-GPL-3.0.txt).
It is built on DPF, the DISTRHO Plugin Framework, by Filipe Coelho (falkTX): https://github.com/DISTRHO/DPF (ISC).
It also contains pugl (ISC), NanoVG (zlib), DSPFilters (MIT) and the Chivo font (SIL OFL 1.1). Their licenses are in
licenses/, with the license of the DejaVu Sans font that DPF carries.

The complete source of this exact build:
  https://github.com/sonic-weaponry/wolf-shaper/tree/$commit
  with the dpf submodule at https://github.com/sonic-weaponry/DPF/tree/$dpf_commit
EOF
echo "packed $to:"
find "$to" -maxdepth 3 | sort
