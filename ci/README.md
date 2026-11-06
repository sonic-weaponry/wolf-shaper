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
| `gui` | Loads a test state into the component and the controller, opens the editor the way the VST3 SDK's own editor host does (`createView`, `setFrame`, `getSize`, a window of that size, `attached`), and waits until the editor has settled (see "When a picture is taken" below). Then it reads what the editor drew from its OpenGL buffer (`glReadPixels` with the editor's own context). That picture must not be blank: no color may cover 98 % or more of it, and it must have at least 32 colors. With the nine-point test curve, the host then sets Wet to 0.25 with the window open, as a rack's macro does, and once the editor has settled again a second picture must show the knob move (at least 50 pixels change) |
| `compare` | Each picture of our build against the official v1.0.2's picture of the same state, drawn on the same runner just before: the same size, and at most `GUI_MAX_DIFFERENT_SHARE` of the pixels may differ by more than 1/8 of full scale in a color channel. Measured: no pixel differs at all, so the limit is 0.01 % (about 40 pixels) |

Why the editor's own picture and not a photo of the window: GitHub's macOS runners are virtual machines without a GPU.
OpenGL there is Apple's software renderer, and it can't give the editor the accelerated, double-buffered pixel format
the editor asks for, so the editor falls back to a single-buffered one. It draws its complete picture into that
buffer, but the window, layer-backed as in every current host, stays white: the official v1.0.2's window as much as
ours. The check still photographs every window with Apple's `screencapture` and logs whether the photo is blank, so a
runner that does show OpenGL windows would be noticed.

What the runner can't show: the last step on a real Mac, where its graphics card puts the editor's frames into the
window. That code is the same in our build and the official one, so the Mac customer's test covers it.

When a picture is taken: the check used to run the event loop for a fixed 3 seconds (2 after the Wet change). Twice
so far, the first editor a job opened through Rosetta stalled for seconds on a fresh runner: after 3
seconds it had had only about 4 ticks of its 16 ms timer instead of dozens, macOS didn't report its window visible
yet, and its picture showed the Remove DC switch ("CENTER", on) before its 0.2 s light-up was drawn. The values were
there (DPF hands the editor every value inside `attached`); the frames weren't. So the fixed time is now only the
least wait. Before each picture the check also waits until macOS reports the window visible, the values have reached
the editor (the controller's opening values, or the new Wet value), at least 0.5 s and 10 timer ticks have passed
since then, and two reads of the picture 5 ticks apart are identical. It sees the ticks and the values in DPF's own
messages between the editor and the controller ("idle", "parameter-set" and "ready" for the editor), which the host
creates for the plugin. If that doesn't happen within `GUI_TIME_LIMIT_SECONDS` (30 by default), the check fails and
says what was missing. The log line `WAIT` says when the editor settled, and `OLD RULE` what the fixed wait would
have seen: whether the window was visible, how many ticks the editor had, and whether that picture differs from the
settled one. A newer DPF that renamed those messages would make the wait fail with that message, never pass wrongly.

The pictures land in `ci-results/<label>/gui/`: what the editor drew as `<state>.png`, the photo of the window as
`<state>-window.png`, and on a failure the whole screen as `<state>-screen.png`. The `gui` log also records what the
editor drew with: the OpenGL renderer and the pixel format it got, the screen's scale and whether macOS considered the
window visible. `ci/self_test_gui.sh` proves that the checks can fail: a black and a flat gray picture must fail the
blank rule, the pictures of two different states, or of one state before and after the host turned Wet, must not
match, and a `gui` check whose time limit (1 s) passes before the editor has settled must fail and say so.

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
| `vst3_check locale` | Loads each state in the "C" locale and in de_DE.UTF-8 (decimal comma) and compares the values the controller shows and the state saved back. DPF a4c83bfd reads saved values with `atof`, which follows the C locale the host process runs in (it writes them in the "C" locale) |

On macOS both builds render natively on Apple Silicon and through Rosetta as Intel code; on Windows the same with the
official v1.0.2 and our Windows build. The `sound-compare` job nulls our macOS renders against the Windows ones. The
limits come from the reviewed results: on Windows our build must equal the official v1.0.2 bit for bit; our macOS build
(arm64 and x86_64) must null against the official Windows build below -100 dBFS (measured: -110.5 dBFS at worst, most
states bit-identical or below -129 dBFS), and its x86_64 slice against the official macOS build and against its own
arm64 slice below -100 dBFS too. Our arm64 slice is built without fused multiply-adds (src/Makefile) so that it
computes like the Windows build; the official macOS build fuses them, so that pair (up to -76 dBFS apart on the sharp
test curves) is only reported.

The locale check is a limit too. Our DPF fork reads saved values in the "C" locale (falkTX's upstream commits 50a55c6e
and c24763e9), so our build, on Apple Silicon and through Rosetta, must load and save every public test state under
de_DE.UTF-8 exactly as under "C". The official v1.0.2 reads them in the process's locale ("0.98" becomes 0 under a
decimal comma) and must still fail the check: the control that proves the check sees the problem.

Two facts about Wolf Shaper v1.0.2 that the renders have to respect:
- **The knobs glide.** After a state loads, Pre Gain, Wet, Post Gain and the warp amounts glide to their new values
  (a 20 Hz one-pole), and the DC remover settles slowly, so every render starts with 10 s of silence.
- **The glide stops a few hundred float steps short of the value**, and where exactly depends on the glide speed. That
  speed is set from the sample rate the plugin knows when a state sets the Oversample knob, and isn't updated when the
  host changes the rate afterwards. A host that loads the state before `setupProcessing` therefore renders slightly
  differently from one that loads it after: about -110 dBFS, and more where the signal crosses a sharp corner of a
  curve (up to -34 dBFS for a few samples with the nine-point test curve). It's the same for every build; renders are
  only comparable in the same call order. `vst3_check render` sets up processing first, then loads the state.

## The macOS installer
`packaging/macos/make_pkg.sh` builds the installer from the bundle the macOS job built and checked: one package that
installs only `wolf-shaper.vst3` into /Library/Audio/Plug-Ins/VST3. It has the official v1.0.2 installer's package
identifier (`studio.kx.distrho.plugins.wolf-shaper.vst3bundles`), so it replaces the official Wolf Shaper VST3 and its
receipt, and leaves the official VST2, LV2 and CLAP alone. The bundle gets the GPL, the other licenses, the credits
and the link to its exact source commit in `Contents/Resources`; the installer shows a welcome text and the GPL in its
License pane. `component.plist` switches off bundle relocation and version checks, so it always installs into
/Library/Audio/Plug-Ins/VST3 and replaces the bundle there. The License pane's copy of the GPL has each paragraph on
one line (`unwrap_license.py`, which fails if a single word differs), so the pane wraps it cleanly; the copy in the
bundle stays exactly as published. The installer built on every push is unsigned; see "Signing" below.

The bundle's `Info.plist`, `PkgInfo` and `Resources/empty.lproj` come from DPF's Makefile (DPF eba58491, a typo fix
the DPF commit v1.0.2 was built with lacks). Hosts don't need them, but signing does; nothing in them identifies the
plugin to a host (the class IDs come from the binary, and none of the files is a `moduleinfo.json`).

`ci/check_pkg.sh` installs the package on the runner and removes it again: what the package holds (one component, no
relocation, no scripts, `hostArchitectures` naming arm64 so Apple Silicon doesn't ask for Rosetta, exactly our built
bundle plus the license files), a clean install, an install over the official v1.0.2 installer, and going back to the
official one (report only). On every installed copy: the files exactly the package's, owned by root:wheel, our
receipt, and `ci/run_checks.sh` on Apple Silicon and Intel. At the end it removes everything it installed, the official
VST2, LV2 and CLAP included. To uninstall by hand:
```
sudo rm -rf /Library/Audio/Plug-Ins/VST3/wolf-shaper.vst3
sudo pkgutil --forget studio.kx.distrho.plugins.wolf-shaper.vst3bundles
```
Report only: `ci/photo_installer.sh` photographs the installer's first two pages.

## Signing
The installer customers get is signed, notarized and stapled:
- `packaging/macos/make_pkg.sh` signs the bundle with a Developer ID Application identity (hardened runtime, secure
  timestamp, no entitlements) after the license files are in, so the seal covers them, and the installer with a
  Developer ID Installer identity (`SIGN_APP_IDENTITY`, `SIGN_INSTALLER_IDENTITY`, `SIGN_KEYCHAIN`).
- `packaging/macos/notarize.sh` sends the installer to Apple's notary service with an App Store Connect API key, waits
  up to 60 minutes, saves Apple's log and staples the ticket to the installer.
- `ci/keychain.sh` holds the identities in a temporary keychain with a random password, with Apple's Developer ID G2
  intermediate certificate (checked against Apple's root on the runner), and deletes it afterwards.

Signing changes nothing in the program but its signature: codesign replaces the linker's ad hoc signature at the end of
each slice, or adds one where the linker left none (the x86_64 slice). `ci/macho_same_code.py` proves it for every
signed copy: per slice, the header, every load command but the signature's, and every segment's bytes up to where the
signature starts must equal our build's. Its self-test runs on every push.

Two ways it runs:
- **Rehearsal, every push** (not on pull requests): `ci/make_test_identity.sh` makes two throwaway self-signed
  identities that no Mac trusts, and they go through the same keychain and lookup code as the real certificates. The
  plugin is signed with the throwaway one, with Apple's secure timestamp; the installer stays unsigned, because
  productbuild signs only with an installer certificate the Mac trusts, and the rehearsal doesn't change the runner's
  trust settings. `ci/check_signed_pkg.sh rehearsal` checks the plugin's signature (seal, hardened runtime,
  identifier, both slices, no entitlements), and `ci/check_pkg.sh` installs the package and checks the installed copy
  (`PKG_SIGNED=rehearsal`). Nothing from the rehearsal is uploaded. The installer's own signature is first made and
  checked in the release job, before anything goes to Apple.
- **Release, started by hand**: `gh workflow run build.yml --ref sw/mac-fix -f sign=true`. After every other job of
  the run has passed, the `macos-release` job signs the build the macos job checked (its sha256 must match) with the
  Developer ID certificates, checks the signatures, notarizes and staples, checks Apple's verdict (accepted with no
  issues, for exactly this file, the ticket covering both slices of the plugin), the staple and Gatekeeper ("Notarized
  Developer ID"), then installs the stapled package clean and over the official installer and checks the installed
  copy (`PKG_SIGNED=developer-id`: also Apple's Developer ID requirement for our team), and zips the signed plugin for
  the release page (`packaging/macos/make_zip.sh`, see "The release"). The installer, the zip and Apple's log are
  uploaded as `wolf-shaper-pkg-macos-notarized`. A run whose notarization didn't finish uploads its installer as
  `wolf-shaper-pkg-macos-signed-NOT-notarized`, for diagnosis only.

A new or changed Apple team's first notarizations can stay "In Progress" for days. `notary-status.yml` lists the team's
submissions without sending anything (`gh workflow run notary-status.yml --ref sw/mac-fix`); once Apple has accepted
one, a new signing run goes through in minutes.

The secrets live in the `mac-release` environment, which only `sw/*` branches and `v*` tags can use:
`MACOS_CERT_APPLICATION_P12` and `MACOS_CERT_INSTALLER_P12` (base64 of the .p12 files), their passwords
`MACOS_CERT_APPLICATION_PASSWORD` and `MACOS_CERT_INSTALLER_PASSWORD`, `APPLE_API_KEY_P8`, `APPLE_API_KEY_ID`,
`APPLE_API_ISSUER_ID` and `APPLE_TEAM_ID`. They reach only the steps that need them, nothing prints them, the .p12 and
key files are written with owner-only access and deleted, and the keychain is deleted at the end of the job, also
after a failure. The certificates must be in the name of `EXPECTED_SIGNER` and our Team ID, or the job stops.

## The release
A release on our fork's release page carries five files: the signed installer, the signed plugin as a zip, the
complete source, the license (GPL-3.0) and SHA256SUMS, with notes that credit Wolf Shaper's and DPF's authors and say
exactly what changed. The GPL asks that whoever hands out the plugin also hands out its complete source, so the source
goes on the same page as the plugin. `RELEASE_TAG` in build.yml names the release (its last number is `PKG_VERSION`'s).

- **The source** (`packaging/release/make_source_tarball.py`): GitHub's own "Source code" downloads leave out the dpf
  folder (a submodule), and the pugl commit inside dpf is reachable only from a side branch of DISTRHO/pugl, so the
  release carries its own: this commit, dpf and pugl as one .tar.gz, every file read from git's objects (not the
  working tree, and not `git archive`, which applies the machine's line-ending settings), the symlink
  `dpf/dgl/src/pugl.mm` kept, plus `ABOUT THIS SOURCE CODE.txt` at the top (who changed it and when, the three
  commits, our commits since v1.0.2 and since DPF a4c83bfd). Sorted, with fixed times and owners, so the same commits
  give the same file. `check` recomputes every file's git ID from the tarball and compares it with the three commits;
  its self-test must catch a CRLF copy, pugl left out, the symlink as a plain file, an extra file, a changed notice and
  a lost executable bit. On every run the linux job makes it twice (identical), checks it and builds the plugin from it
  in a folder without git; the macos job does the same with the universal build. Both builds must come out byte for
  byte the same as the normal ones, and the tar must be the same on macOS and Linux.
- **The zip** (`packaging/macos/make_zip.sh`): the bundle exactly as the installer installs it, with HOW TO
  INSTALL.txt (`packaging/release/how-to-install.txt.in`) and the credits and licenses next to it, zipped with ditto
  without extended attributes. In a signing run Apple's ticket is also stapled to the bundle, if Apple's stapler takes
  a plugin bundle (report only). Checked after unzipping: the same files, the signature, the staple.
- **The credits** in a release build (`PKG_RELEASE_TAG` for make_pkg.sh) also point at the release page with the
  source as one download; every other build keeps the commit links only (the `[test]` / `[release]` lines in
  CREDITS.txt.in), and `ci/check_pkg.sh` checks which.
- **Put together** (`packaging/release/assemble.sh`) and **checked** (`ci/check_release.py`) on every run, by the
  release-folder job: exactly the five files, SHA256SUMS right, the license Wolf Shaper's, the source tarball checked
  again, the zip's layout and credits, and the notes (`packaging/release/release-notes.md.in`): nothing left to fill
  in, no issue or pull request reference and no @mention (GitHub would show those on other people's projects or notify
  people), the credits, the GPL version 3, every file and the three commits. Its self-test must catch an issue number,
  an upstream issue link, an @mention, a placeholder, "or later", a changed byte, an extra or missing file and a wrong
  title. On ordinary runs it uses the macos job's unsigned stand-ins (artifact `release-folder`, 7 days).
- **A draft on the release page**, only when started by hand on an sw/ branch, after every job passed (job
  release-draft, the only one allowed to write to the repository):
  - `gh workflow run build.yml --ref sw/mac-fix -f release=rehearsal-draft`: the stand-ins under a throwaway name
    (`rehearsal-<run>-<attempt>`, titled REHEARSAL), to try the path; delete it afterwards with
    `gh release delete <name> --yes --cleanup-tag`.
  - `gh workflow run build.yml --ref sw/mac-fix -f release=draft`: signs, notarizes and staples (macos-release), then
    the draft under `RELEASE_TAG`.

  `ci/check_release_draft.py` then checks the draft on GitHub: a draft at this run's commit, the title and notes, the
  five files uploaded with the sha256 in SHA256SUMS, and reports whether the draft already made the tag.
  Publishing is a separate step after Isaac has looked at the draft: `gh release edit <tag> --draft=false`, which
  creates the tag at the draft's commit.

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
releases. The check tool, the scripts and the test states are GPL-3.0-or-later; Wolf Shaper itself is GPL-3.0
(version 3; its source names no later version).
