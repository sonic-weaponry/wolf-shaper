#!/usr/bin/env python3
"""Checks a release folder from packaging/release/assemble.sh before anything goes to GitHub (ci/README.md, "The
release"):
- the release page gets exactly five files: the installer, the plugin zip, the source tarball, the license and
  SHA256SUMS, and SHA256SUMS is right for the other four;
- the license is Wolf Shaper's LICENSE, byte for byte; the installer is an installer (xar archive);
- the source tarball holds exactly this checkout's three commits (packaging/release/make_source_tarball.py check);
- the zip holds one folder with the plugin (its program executable), HOW TO INSTALL.txt, the credits pointing at this
  release and these commits, and the licenses; no AppleDouble or __MACOSX entries;
- the notes and the title: no placeholder left; no issue or pull request reference (#123, GH-123, an /issues/,
  /pull/ or /discussions/ link) and no @mention, because GitHub would show those on other people's projects or notify
  people (CLAUDE.md HARD LIMITS); the credits to Patrick Desaulniers and Filipe Coelho (falkTX), the GPL version 3
  (never "or later"), every file name and this build's three commits are in them; a rehearsal says so at the top.

Usage, from the repository root (full history and submodules, as make_source_tarball.py needs):
  ci/check_release.py [--rehearsal] <release folder> <release tag>
  ci/check_release.py --self-test [--rehearsal] <release folder> <release tag>   broken copies must fail
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

PLACEHOLDER = re.compile(r"@[A-Z_]+@")
ISSUE_REFERENCE = re.compile(r"(?<![\w&/])#\d+|\bGH-\d+|github\.com/[^/\s]+/[^/\s]+/(issues|pull|discussions)\b",
                             re.IGNORECASE)
MENTION = re.compile(r"(?<![\w.@/+-])@[A-Za-z0-9][A-Za-z0-9-]*")
BANNER = "> **Rehearsal draft, not a release.**"


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout.strip()


def names(tag):
    return [f"wolf-shaper-{tag}-macos-universal.pkg", f"wolf-shaper-{tag}-macos-universal-vst3.zip",
            f"wolf-shaper-{tag}-source.tar.gz", "LICENSE-GPL-3.0.txt"]


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def problems(folder, tag, rehearsal, tarball=True):
    """Returns (passes, failures) as lists of messages."""
    ok, bad = [], []

    def result(good, message):
        (ok if good else bad).append(message)

    commit, dpf, pugl = git("rev-parse", "HEAD"), git("-C", "dpf", "rev-parse", "HEAD"), \
        git("-C", "dpf/dgl/src/pugl-upstream", "rev-parse", "HEAD")
    assets = os.path.join(folder, "assets")
    files = names(tag)
    present = sorted(os.listdir(assets)) if os.path.isdir(assets) else []
    result(present == sorted(files + ["SHA256SUMS"]), f"the release files are exactly {files + ['SHA256SUMS']} "
           f"(found {present})")

    sums = open(os.path.join(assets, "SHA256SUMS"), encoding="utf-8").read() if "SHA256SUMS" in present else ""
    lines = sums.splitlines()
    listed = []
    for line in lines:
        m = re.fullmatch(r"([0-9a-f]{64}) [ *](.+)", line)
        if not m:
            result(False, f"SHA256SUMS line not in shasum format: {line!r}")
            continue
        listed.append(m.group(2))
        path = os.path.join(assets, m.group(2))
        result(os.path.isfile(path) and sha256(path) == m.group(1), f"SHA256SUMS matches {m.group(2)}")
    result(sorted(listed) == sorted(files) and len(lines) == len(files), "SHA256SUMS lists exactly the other four files")

    lic = os.path.join(assets, "LICENSE-GPL-3.0.txt")
    repo_license = subprocess.run(["git", "show", "HEAD:LICENSE"], check=True, capture_output=True).stdout
    result(os.path.isfile(lic) and open(lic, "rb").read() == repo_license and
           b"Version 3, 29 June 2007" in repo_license[:200], "LICENSE-GPL-3.0.txt is Wolf Shaper's LICENSE (GPL-3.0)")

    pkg = os.path.join(assets, files[0])
    result(os.path.isfile(pkg) and open(pkg, "rb").read(4) == b"xar!", "the installer is a flat package (xar)")

    if tarball:
        tgz = os.path.join(assets, files[2])
        code = subprocess.run([sys.executable, "packaging/release/make_source_tarball.py", "check", tag, tgz],
                              capture_output=True, text=True)
        last = (code.stdout.strip().splitlines() or ["(no output)"])[-1]
        result(code.returncode == 0, f"the source tarball: {last}")

    top = f"wolf-shaper-{tag}-macos-universal-vst3/"
    zpath = os.path.join(assets, files[1])
    try:
        with zipfile.ZipFile(zpath) as z:
            entries = {i.filename: i for i in z.infolist()}
            result(all(n.startswith(top) for n in entries), f"the zip holds one folder, {top}")
            result(not any(re.search(r"(^|/)(__MACOSX|\._)", n) for n in entries), "no AppleDouble or __MACOSX entries")
            program = entries.get(top + "wolf-shaper.vst3/Contents/MacOS/wolf-shaper")
            result(program is not None and (program.external_attr >> 16) & 0o111 != 0,
                   "the zip's plugin program is there and executable")
            result(top + "wolf-shaper.vst3/Contents/Info.plist" in entries, "the zip's plugin has its Info.plist")
            licenses = [n for n in entries if n.startswith(top + "LICENSES/") and not n.endswith("/")]
            result(len(licenses) == 6, f"the zip has the 6 license files next to the plugin (found {len(licenses)})")

            def text(name):
                return z.read(top + name).decode("utf-8") if top + name in entries else ""

            how = text("HOW TO INSTALL.txt")
            page = f"https://github.com/sonic-weaponry/wolf-shaper/releases/tag/{tag}\n"
            result(f"wolf-shaper-{tag}-macos-universal.pkg" in how and page in how and
                   not PLACEHOLDER.search(how), "HOW TO INSTALL.txt names this release's installer and page")
            credits = text("CREDITS and SOURCE.txt")
            result(page in credits and f"wolf-shaper-{tag}-source.tar.gz" in credits and
                   f"wolf-shaper/tree/{commit}" in credits and f"DPF/tree/{dpf}" in credits and
                   not PLACEHOLDER.search(credits) and credits == text("wolf-shaper.vst3/Contents/Resources/"
                                                                         "CREDITS and SOURCE.txt"),
                   "the credits point at this release page and this build's commits (and match the bundle's)")
            result(text("LICENSE (GPL-3.0).txt").encode("utf-8") == repo_license.replace(b"\r", b""),
                   "the zip's LICENSE (GPL-3.0).txt is Wolf Shaper's LICENSE")
    except (OSError, zipfile.BadZipFile) as e:
        result(False, f"the zip can't be read: {e}")

    notes = open(os.path.join(folder, "release-notes.md"), encoding="utf-8").read()
    title = open(os.path.join(folder, "release-title.txt"), encoding="utf-8").read().strip()
    want_title = f"Wolf Shaper 1.0.2 for Mac, Windows-compatible VST3 ({tag})"
    if rehearsal:
        want_title = "REHEARSAL, not a release: " + want_title
    result(title == want_title, f"the title is {want_title!r} (found {title!r})")
    both = title + "\n" + notes
    left = PLACEHOLDER.findall(both)
    result(not left, f"no placeholder left in the notes (found {left})")
    refs = [m.group(0) for m in ISSUE_REFERENCE.finditer(both)]
    result(not refs, f"no issue or pull request references in the notes (found {refs})")
    mentions = MENTION.findall(both)
    result(not mentions, f"no @mentions in the notes (found {mentions})")
    result("or later" not in both and "GNU General Public License, version 3" in notes,
           "the notes give the license as the GPL version 3 (not \"or later\")")
    for phrase in ("Patrick Desaulniers", "Filipe Coelho (falkTX)", "The Sonic Weaponry Team",
                   "Wolf Shaper's authors don't endorse Sonic Weaponry"):
        result(phrase in notes, f"the notes say {phrase!r}")
    for name in files + ["SHA256SUMS"]:
        result(name in notes, f"the notes name {name}")
    for repo, sha in (("sonic-weaponry/wolf-shaper", commit), ("sonic-weaponry/DPF", dpf), ("DISTRHO/pugl", pugl)):
        result(f"github.com/{repo}/tree/{sha}" in notes, f"the notes link {repo} at {sha[:8]}")
    if rehearsal:
        result(notes.startswith(BANNER), "a rehearsal's notes say so at the top")
    else:
        result("rehearsal" not in both.lower(), "a release's notes don't mention a rehearsal")
    return ok, bad


def self_test(folder, tag, rehearsal):
    ok, bad = problems(folder, tag, rehearsal, tarball=False)
    if bad:
        sys.exit(f"FAIL self-test: the release folder given isn't good to start with ({bad[0]})")
    pkg = names(tag)[0]

    def append(text):
        def change(d):
            with open(os.path.join(d, "release-notes.md"), "a", encoding="utf-8") as f:
                f.write(text)
        return change

    def flip_byte(d):
        path = os.path.join(d, "assets", pkg)
        data = bytearray(open(path, "rb").read())
        data[len(data) // 2] ^= 1
        open(path, "wb").write(bytes(data))

    def extra_file(d):
        open(os.path.join(d, "assets", "notes.txt"), "w").write("x")

    def no_license(d):
        os.remove(os.path.join(d, "assets", "LICENSE-GPL-3.0.txt"))

    def title_changed(d):
        open(os.path.join(d, "release-title.txt"), "w").write("Wolf Shaper\n")

    cases = [("an issue number (#171)", append("\nSee #171.\n")),
             ("an upstream issue link", append("\nhttps://github.com/wolf-plugins/wolf-shaper/issues/171\n")),
             ("an @mention", append("\nThanks @falkTX\n")),
             ("a placeholder left", append("\n@COMMIT@\n")),
             ("\"or later\"", append("\nGPL version 3 or later\n")),
             ("one changed byte in the installer", flip_byte), ("an extra file", extra_file),
             ("no license file", no_license), ("a wrong title", title_changed)]
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        for label, change in cases:
            copy = os.path.join(tmp, "release")
            shutil.copytree(folder, copy)
            change(copy)
            _, found = problems(copy, tag, rehearsal, tarball=False)
            if found:
                print(f"PASS self-test: {label}: found ({found[0]})")
            else:
                print(f"FAIL self-test: {label}: not found")
                failed = 1
            shutil.rmtree(copy)
    sys.exit(failed)


def main():
    args = sys.argv[1:]
    test = "--self-test" in args
    rehearsal = "--rehearsal" in args
    args = [a for a in args if a not in ("--self-test", "--rehearsal")]
    if len(args) != 2:
        sys.exit(__doc__)
    folder, tag = args
    if test:
        self_test(folder, tag, rehearsal)
    ok, bad = problems(folder, tag, rehearsal)
    for message in ok:
        print(f"PASS {message}")
    for message in bad:
        print(f"::error::FAIL {message}")
    print(f"{len(ok)} passed, {len(bad)} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
