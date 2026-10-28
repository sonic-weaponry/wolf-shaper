# CI checks

`.github/workflows/build.yml` builds the Wolf Shaper VST3 with DPF's Makefiles on macOS (universal: arm64 and x86_64),
Linux (x64) and Windows (x64, cross-compiled with MinGW), using the same compiler flags as the official v1.0.2
releases. Every build is then checked against the frozen tables in `ci/frozen/`, and the same checks run on the
official v1.0.2 release on each platform, side by side.

## Why
A host finds a VST3 plugin by its class ID, which it stores in every project, together with parameter IDs (for
automation and mappings) and the plugin's saved state. If any of these change, saved projects can't find the plugin
or load it wrong. On macOS, the official v1.0.2 VST3 reports a different class ID than on Windows, so projects saved
on Windows show Wolf Shaper as missing on a Mac (wolf-plugins/wolf-shaper#171). These checks pin down everything a
host sees, so that a fix can change the macOS class ID and provably nothing else.

## The checks
`ci/vst3_check` is a small VST3 host. It runs one check per process, so a crash can't hide other results.

| Check | What it does | Frozen file |
|---|---|---|
| `ids` | Reads the class IDs through the VST3 SDK's own FUID code, through all three class-info calls, and compares them with the table for this platform and build | `class-ids.txt` |
| `params` | Opens the component and the controller the way a host does and lists every parameter: VST3 ID, title, units, range, default, steps and their labels, flags. It also measures the symbol each parameter is saved under, by loading a state that changes only that symbol and seeing which parameter moves | `parameters.json` |
| `states` | Loads each test state into a fresh instance (component `setState`, then controller `setComponentState`, as hosts do) and requires `getState` to give back the same bytes and the controller to show every value under the right ID. Then loads all of them one after another into one instance. A fresh instance must save exactly `default.vst3state` | `states/*.vst3state` |
| `instance` | Creates the component from its class ID and the controller from `getControllerClassId`, connects them, opens a second instance alongside, and tears everything down. Compares what a host sees (names, vendor, version, categories, buses, latency) with the table | `plugin-info.json` |

`ci/run_checks.sh` runs all four on one bundle. A check also fails when DPF prints an assertion or a warning, because a
host that follows the VST3 rules never triggers one. `ci/self_test.sh` proves that each check can fail: it feeds them
deliberately wrong frozen values and requires a failure, and the untouched values and requires a pass.

## The frozen files
- `class-ids.txt`: the IDs measured on the official v1.0.2 releases, per platform.
- `parameters.json` and `plugin-info.json`: generated from the official Windows v1.0.2 release on the Windows runner,
  reviewed, and committed. Every build on every platform must produce them byte for byte.
- `states/`: test states made for these checks by `ci/make_test_states.py`, not taken from anyone's projects. They
  cover the default state, a nine-point curve longer than DPF's 511-byte read chunk, every horizontal and vertical
  warp type, every oversampling setting, and the ends of every range.

Changing a frozen file is deliberate: its diff shows exactly what a change does to what hosts see.

## Running the checks yourself
```
git clone --depth 1 --branch v3.8.1_build_84 https://github.com/steinbergmedia/vst3_pluginterfaces.git ci/vst3_check/sdk/pluginterfaces
cmake -S ci/vst3_check -B ci/vst3_check/build -DCMAKE_BUILD_TYPE=Release
cmake --build ci/vst3_check/build --config Release
bash ci/run_checks.sh ci/vst3_check/build/vst3_check bin/wolf-shaper.vst3 ours local
```
Run them from the repository root. On Windows the tool is `ci/vst3_check/build/Release/vst3_check.exe`.

## Third-party code
The check tool uses Steinberg's VST3 SDK interfaces (vst3_pluginterfaces, MIT license since VST 3.8), cloned at build
time and not committed. The build flags follow DISTRHO/dpf-makefile-action (ISC license), which built the official
releases. The check tool, the scripts and the test states are GPL-3.0-or-later, like Wolf Shaper.
