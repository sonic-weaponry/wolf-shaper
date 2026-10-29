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
| `ids` | Reads the class IDs through the VST3 SDK's own FUID code, through all three class-info calls, and compares them with the table for this platform and build. Then calls the module's exit function, enters it again with the library still loaded (hosts may do that), and requires the same IDs | `class-ids.txt` |
| `params` | Opens the component and the controller the way a host does and lists every parameter: VST3 ID, title, units, range, default, steps and their labels, flags. It also measures the symbol each parameter is saved under, by loading a state that changes only that symbol and seeing which parameter moves | `parameters.json` |
| `states` | Loads each test state into a fresh instance (component `setState`, then controller `setComponentState`, as hosts do) and requires `getState` to give back the same bytes and the controller to show every value under the right ID. Then loads all of them one after another into one instance. A fresh instance must save exactly `default.vst3state` | `states/*.vst3state` |
| `instance` | Creates the component from its class ID and the controller from `getControllerClassId`, connects them, opens a second instance alongside, and tears everything down. Compares what a host sees (names, vendor, version, categories, buses, latency) with the table | `plugin-info.json` |
| `render`, `locale` | The sound and the locale check, below | `test-signal.sha256` |

`ci/run_checks.sh` runs all four on one bundle. A check also fails when DPF prints an assertion or a warning, because a
host that follows the VST3 rules never triggers one. `ci/self_test.sh` proves that each check can fail: it feeds them
deliberately wrong frozen values and requires a failure, and the untouched values and requires a pass.

## The editor window (macOS)
Mac users reported Wolf Shaper's window staying blank for builds of newer source (wolf-plugins/wolf-shaper#176, where
DPF prints "Failed to create NanoVG context, expect a black screen"). `ci/run_gui_checks.sh` checks the editor on the
macOS runner, natively and as Intel code through Rosetta:

| Check | What it does |
|---|---|
| `gui` | Loads a test state into the component and the controller, opens the editor the way the VST3 SDK's own editor host does (`createView`, `setFrame`, `getSize`, a window of that size, `attached`), and lets it run for 3 seconds. Then it reads what the editor drew from its OpenGL buffer (`glReadPixels` with the editor's own context). That picture must not be blank: no color may cover 98 % or more of it, and it must have at least 32 colors. With the nine-point test curve, the host then sets Wet to 0.25 with the window open, as a rack's macro does, and a second picture must show the knob move (at least 50 pixels change) |
| `compare` | Each picture of our build against the official v1.0.2's picture of the same state, drawn on the same runner just before: the same size, and at most `GUI_MAX_DIFFERENT_SHARE` of the pixels may differ by more than 1/8 of full scale in a color channel. Measured: no pixel differs at all, so the limit is 0.01 % (about 40 pixels) |

Why the editor's own picture and not a photo of the window: GitHub's macOS runners are virtual machines without a GPU.
OpenGL there is Apple's software renderer, and it can't give the editor the accelerated, double-buffered pixel format
the editor asks for, so the editor falls back to a single-buffered one. It draws its complete picture into that
buffer, but the window, layer-backed as in every current host, stays white: the official v1.0.2's window as much as
ours. The check still photographs every window with Apple's `screencapture` and logs whether the photo is blank, so a
runner that does show OpenGL windows would be noticed.

What the runner can't show: the last step on a real Mac, where its graphics card puts the editor's frames into the
window. That code is the same in our build and the official one, so the Mac customer's test covers it.

The pictures land in `ci-results/<label>/gui/`: what the editor drew as `<state>.png`, the photo of the window as
`<state>-window.png`, and on a failure the whole screen as `<state>-screen.png`. The `gui` log also records what the
editor drew with: the OpenGL renderer and the pixel format it got, the screen's scale and whether macOS considered the
window visible. `ci/self_test_gui.sh` proves that the two checks can fail: a black and a flat gray picture must fail
the blank rule, and the pictures of two different states, or of one state before and after the host turned Wet, must
not match.

## The sound
A fix for the class ID must not change how Wolf Shaper sounds. The sound checks play one test signal through our
build and the official v1.0.2 with each public test state loaded, and null the renders against each other: subtract
one from the other and measure what's left.

| Tool | What it does |
|---|---|
| `ci/make_test_signal.py` | The test signal, one mono 32-bit float WAV per sample rate (44.1 and 48 kHz, 8.175 s): a log sine sweep, a 110 Hz sine stepped from -40 to +3 dBFS, white and pink noise bursts, and silence between them. Made from fixed formulas and a fixed noise seed; `frozen/test-signal.sha256` pins the files, and every runner checks it before rendering |
| `vst3_check render` | Opens the plugin as a host does, sets up 32-bit float processing at the signal's rate and the given block size, loads the state (component `setState`, controller `setComponentState`), activates the plugin, plays 10 s of silence, then the signal (mono to both channels), and writes the output as a 32-bit float stereo WAV. Fails on NaN or infinity |
| `ci/run_sound_checks.sh` | Renders every public test state at both rates in blocks of 512 and 64. The two block sizes must give bit-identical output: Wolf Shaper works sample by sample |
| `ci/null_test.py` | Per pair of renders: "bit-identical", or the residual's peak and RMS in dBFS and where its peak is |
| `vst3_check locale` | Loads each state in the "C" locale and in de_DE.UTF-8 (decimal comma) and compares the values the controller shows and the state saved back. DPF a4c83bfd reads saved values with `atof` and writes them with printf-style formatting, both of which follow the C locale the host process runs in |

On macOS both builds render natively on Apple Silicon and through Rosetta as Intel code; on Windows the same with the
official v1.0.2 and our Windows build. The `sound-compare` job nulls our macOS renders against the Windows ones. The
limits come from the reviewed results: on Windows our build must equal the official v1.0.2 bit for bit; our macOS build
(arm64 and x86_64) must null against the official Windows build below -100 dBFS (measured: -110.5 dBFS at worst, most
states bit-identical or below -129 dBFS), and its x86_64 slice against the official macOS build and against its own
arm64 slice below -100 dBFS too. Our arm64 slice is built without fused multiply-adds (src/Makefile) so that it
computes like the Windows build; the official macOS build fuses them, so that pair (up to -76 dBFS apart on the sharp
test curves) is only reported. The locale check only reports: the official v1.0.2 behaves the same.

Two facts about Wolf Shaper v1.0.2 that the renders have to respect:
- **The knobs glide.** After a state loads, Pre Gain, Wet, Post Gain and the warp amounts glide to their new values
  (a 20 Hz one-pole), and the DC remover settles slowly, so every render starts with 10 s of silence.
- **The glide stops a few hundred float steps short of the value**, and where exactly depends on the glide speed. That
  speed is set from the sample rate the plugin knows when a state sets the Oversample knob, and isn't updated when the
  host changes the rate afterwards. A host that loads the state before `setupProcessing` therefore renders slightly
  differently from one that loads it after: about -110 dBFS, and more where the signal crosses a sharp corner of a
  curve (up to -34 dBFS for a few samples with the nine-point test curve). It's the same for every build; renders are
  only comparable in the same call order. `vst3_check render` sets up processing first, then loads the state.

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
GUI_MAX_DIFFERENT_SHARE=0.0001 bash ci/run_gui_checks.sh ci/vst3_check/build/vst3_check bin/wolf-shaper.vst3 local -
python3 ci/make_test_signal.py sound-signal
bash ci/run_sound_checks.sh ci/vst3_check/build/vst3_check bin/wolf-shaper.vst3 local sound-signal sound-renders
```
Run them from the repository root. On Windows the tool is `ci/vst3_check/build/Release/vst3_check.exe`. The GUI checks
run on macOS only, in a logged-in session, and macOS asks once for permission to record the screen.

## Third-party code
The check tool uses Steinberg's VST3 SDK interfaces (vst3_pluginterfaces, MIT license since VST 3.8), cloned at build
time and not committed. The build flags follow DISTRHO/dpf-makefile-action (ISC license), which built the official
releases. The check tool, the scripts and the test states are GPL-3.0-or-later, like Wolf Shaper.
