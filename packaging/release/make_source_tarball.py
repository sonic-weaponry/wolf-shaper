#!/usr/bin/env python3
"""The complete source of a Wolf Shaper release as one reproducible .tar.gz.

It holds this repository and its submodules (dpf, and pugl inside dpf) at the commits checked out, every file read
from git's own objects: never from the working tree, and never through `git archive`, which applies the machine's
line-ending settings (on a Windows clone with core.autocrlf it writes CRLF into most files). Symlinks stay symlinks
(dpf/dgl/src/pugl.mm -> pugl.cpp, which the macOS build compiles). One file is added at the top, "ABOUT THIS SOURCE
CODE.txt" (packaging/release/about-source.txt.in): who changed it and when (GPL-3.0 section 5a), the exact commits,
and our commits since v1.0.2 and since the DPF the official v1.0.2 was built with.

Reproducible: entries sorted, every time set to this repository's commit time, owner 0:0 without names, PAX format,
gzip without a name or a time. The same commits give the same tar on any machine; the gzip stream also depends on
zlib, so `check` prints the uncompressed tar's sha256 for comparing builds made on different machines.

Usage, from the repository root of a clone with full history (the notice lists commits) and its submodules:
  make_source_tarball.py make      <release tag> <output .tar.gz>
  make_source_tarball.py check     <release tag> <.tar.gz>   exactly the three commits plus the notice, or exit 1
  make_source_tarball.py self-test <release tag> <.tar.gz>   check must fail on broken copies of a good tarball
"""
import gzip
import hashlib
import io
import os
import re
import subprocess
import sys
import tarfile
import tempfile

# Where our changes start: tag v1.0.2 of Wolf Shaper, and the DPF commit the official Windows v1.0.2 was built with.
WOLF_SHAPER_BASE = "4d7b6a1805d774fad553323bc9325c508428ac9e"
DPF_BASE = "a4c83bfdc925db48f272e66a006a6630625c3e20"
# Where the submodules come from; the notice names them, so a change here has to be deliberate.
SUBMODULE_URLS = {
    "dpf": "https://github.com/sonic-weaponry/DPF",
    "dpf/dgl/src/pugl-upstream": "https://github.com/DISTRHO/pugl.git",
}
NOTICE = "ABOUT THIS SOURCE CODE.txt"
TEMPLATE = "packaging/release/about-source.txt.in"
# Files that belong to Sonic Weaponry's private project and must never be in the public source (CLAUDE.md, HARD
# LIMITS). They can't be in a commit of the public fork; this is the backstop.
FORBIDDEN = re.compile(
    r"(^|/)(CLAUDE\.md|REQUESTS\.md|WAITING_ON_ME\.md|NEXT_SESSION\.md|ASSETS_NEEDED\.md|TIMING\.md)$"
    r"|\.(adg|als|vstpreset)$|(^|/)(sw_tools|research|assets/incoming)/",
    re.IGNORECASE,
)


def git(*args, cwd=".", data=None):
    return subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True, input=data).stdout


def head(path):
    return git("rev-parse", "HEAD", cwd=path).decode().strip()


def tree(path=".", rel=""):
    """(path in the source, git mode, blob ID, repository) for every file and symlink of HEAD, submodules included."""
    commit = head(path)
    for record in git("ls-tree", "-r", "-z", "--full-tree", commit, cwd=path).split(b"\0"):
        if not record:
            continue
        meta, name = record.split(b"\t", 1)
        mode, _kind, sha = meta.decode().split()
        name = name.decode("utf-8")
        if mode == "160000":
            sub = os.path.join(path, name)
            if head(sub) != sha:
                sys.exit(f"{rel}{name} is checked out at {head(sub)}, but the commit records {sha}")
            url = git("config", "-f", os.path.join(path, ".gitmodules"), "--get", f"submodule.{name}.url", cwd=".")
            want = SUBMODULE_URLS.get(f"{rel}{name}")
            if url.decode().strip() != want:
                sys.exit(f"{rel}{name} comes from {url.decode().strip()}, expected {want}")
            yield from tree(sub, f"{rel}{name}/")
        elif mode in ("100644", "100755", "120000"):
            yield f"{rel}{name}", mode, sha, path
        else:
            sys.exit(f"unexpected entry {rel}{name} (mode {mode})")


def blob_id(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def read_blobs(entries):
    by_repo = {}
    for _name, _mode, sha, repo in entries:
        by_repo.setdefault(repo, []).append(sha)
    blobs = {}
    for repo, shas in by_repo.items():
        out = git("cat-file", "--batch", cwd=repo, data=("\n".join(shas) + "\n").encode())
        pos = 0
        for _ in shas:
            nl = out.index(b"\n", pos)
            sha, kind, size = out[pos:nl].decode().split()
            if kind != "blob":
                sys.exit(f"{sha} is a {kind}, not a blob")
            start = nl + 1
            blobs[sha] = out[start:start + int(size)]
            pos = start + int(size) + 1
    return blobs


def log(path, base, with_author):
    fmt = "%cs%x09%H%x09%an%x09%s"
    lines = []
    for line in git("log", "--reverse", f"--format={fmt}", f"{base}..HEAD", cwd=path).decode("utf-8").splitlines():
        date, sha, author, subject = line.split("\t", 3)
        lines.append(f"  {date}  {sha[:8]}  {subject}" + (f" ({author})" if with_author else ""))
    return "\n".join(lines) if lines else "  (none)"


def notice_text(tag):
    # The template as committed, like everything else in the tarball.
    text = git("show", f"HEAD:{TEMPLATE}").decode("utf-8")
    values = {
        "RELEASE_TAG": tag,
        "COMMIT": head("."),
        "DPF_COMMIT": head("dpf"),
        "PUGL_COMMIT": head("dpf/dgl/src/pugl-upstream"),
        "WOLF_SHAPER_LOG": log(".", WOLF_SHAPER_BASE, False),
        "DPF_LOG": log("dpf", DPF_BASE, True),
    }
    for key, value in values.items():
        text = text.replace(f"@{key}@", value)
    left = re.findall(r"@[A-Z_]+@", text)
    if left:
        sys.exit(f"the notice still holds {left}")
    return text.encode("utf-8")


def wanted(tag):
    """What the tarball must hold: {name: (git mode, blob bytes or None, blob ID)} plus its folders, and its time."""
    top = f"wolf-shaper-{tag}"
    entries = sorted(tree())
    forbidden = [name for name, *_ in entries if FORBIDDEN.search(name)]
    if forbidden:
        sys.exit(f"private project files in the source: {forbidden}")
    blobs = read_blobs(entries)
    files = {f"{top}/{name}": (mode, blobs[sha]) for name, mode, sha, _repo in entries}
    files[f"{top}/{NOTICE}"] = ("100644", notice_text(tag))
    folders = {top}
    for name in files:
        parts = name.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            folders.add("/".join(parts[:i]))
    mtime = int(git("show", "-s", "--format=%ct", "HEAD").decode())
    return top, files, folders, mtime


def write(path, files, folders, mtime):
    """files: {name: (git mode, bytes)}; the bytes of a symlink are its target."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as t:
        items = [(name, None) for name in folders] + list(files.items())
        for name, value in sorted(items, key=lambda item: item[0]):
            info = tarfile.TarInfo(name)
            info.mtime, info.uid, info.gid, info.uname, info.gname = mtime, 0, 0, "", ""
            data = None
            if value is None:
                info.type, info.mode = tarfile.DIRTYPE, 0o755
            elif value[0] == "120000":
                info.type, info.mode, info.linkname = tarfile.SYMTYPE, 0o777, value[1].decode("utf-8")
            else:
                data = value[1]
                info.size, info.mode = len(data), 0o755 if value[0] == "100755" else 0o644
            t.addfile(info, io.BytesIO(data) if data is not None else None)
    with open(path, "wb") as f, gzip.GzipFile(filename="", mode="wb", fileobj=f, mtime=0, compresslevel=9) as g:
        g.write(raw.getvalue())


def problems_in(path, tag):
    """Everything that differs from what `make` would write for these commits."""
    top, files, folders, mtime = wanted(tag)
    want = {name: (mode, blob_id(data)) for name, (mode, data) in files.items()}
    problems = []
    with open(path, "rb") as f:
        header = f.read(10)
    if header[:2] != b"\x1f\x8b" or header[3] & 0x08 or header[4:8] != b"\0\0\0\0":
        problems.append("the gzip header holds a file name or a time")
    got, got_folders = {}, set()
    with tarfile.open(path, "r:gz") as t:
        for m in t.getmembers():
            if m.name != top and not m.name.startswith(top + "/"):
                problems.append(f"outside the top folder: {m.name}")
            if m.uid or m.gid or m.uname or m.gname or m.mtime != mtime:
                problems.append(f"owner or time not normalized: {m.name}")
            if m.isdir():
                got_folders.add(m.name)
            elif m.issym():
                got[m.name] = ("120000", blob_id(m.linkname.encode("utf-8")))
            elif m.isfile():
                got[m.name] = ("100755" if m.mode & 0o111 else "100644", blob_id(t.extractfile(m).read()))
            else:
                problems.append(f"not a file, folder or symlink: {m.name}")
    problems += [f"missing: {n}" for n in sorted(set(want) - set(got))]
    problems += [f"extra: {n}" for n in sorted(set(got) - set(want))]
    problems += [f"different (mode or content): {n}" for n in sorted(set(want) & set(got)) if want[n] != got[n]]
    problems += [f"missing folder: {n}" for n in sorted(folders - got_folders)]
    problems += [f"extra folder: {n}" for n in sorted(got_folders - folders)]
    return problems, len(got)


def tar_sha256(path):
    with gzip.open(path, "rb") as g:
        return hashlib.sha256(g.read()).hexdigest()


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("make", "check", "self-test"):
        sys.exit(__doc__)
    command, tag, path = sys.argv[1:]
    if not re.fullmatch(r"[A-Za-z0-9._-]+", tag):
        sys.exit(f"not a usable release tag: {tag!r}")

    if command == "make":
        top, files, folders, mtime = wanted(tag)
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        write(path, files, folders, mtime)
        links = sum(1 for mode, _ in files.values() if mode == "120000")
        print(f"made {path}: {top}/ with {len(files) - links} files, {links} symlink(s), {len(folders)} folders, "
              f"{os.path.getsize(path)} bytes")
        print(f"commits: wolf-shaper {head('.')}, dpf {head('dpf')}, pugl {head('dpf/dgl/src/pugl-upstream')}")
        return

    if command == "check":
        problems, count = problems_in(path, tag)
        for p in problems[:40]:
            print(f"PROBLEM {p}")
        if len(problems) > 40:
            print(f"PROBLEM ... and {len(problems) - 40} more")
        with open(path, "rb") as f:
            print(f"GZ_SHA256={hashlib.sha256(f.read()).hexdigest()}")
        print(f"TAR_SHA256={tar_sha256(path)}")
        if problems:
            print(f"FAIL the source tarball: {len(problems)} problem(s) in {count} entries")
            sys.exit(1)
        print(f"PASS the source tarball holds exactly the three commits and the notice ({count} files and symlinks, "
              "every one checked against git)")
        return

    # self-test: broken copies of a good tarball must fail the check.
    problems, _ = problems_in(path, tag)
    if problems:
        sys.exit(f"FAIL self-test: the tarball given isn't good to start with ({problems[0]})")
    top, files, folders, mtime = wanted(tag)
    executable = next(n for n, (mode, _) in sorted(files.items()) if mode == "100755")
    pugl = f"{top}/dpf/dgl/src/pugl-upstream"

    def crlf(f):
        mode, data = f[f"{top}/src/Makefile"]
        f[f"{top}/src/Makefile"] = (mode, data.replace(b"\n", b"\r\n"))

    def no_pugl(f):
        for n in [n for n in f if n.startswith(pugl + "/")]:
            del f[n]

    def symlink_as_file(f):
        f[f"{top}/dpf/dgl/src/pugl.mm"] = ("100644", f[f"{top}/dpf/dgl/src/pugl.mm"][1])

    def extra_file(f):
        f[f"{top}/.git/config"] = ("100644", b"[core]\n")

    def notice_changed(f):
        mode, data = f[f"{top}/{NOTICE}"]
        f[f"{top}/{NOTICE}"] = (mode, data.replace(b"Patrick Desaulniers", b"someone else"))

    def mode_changed(f):
        f[executable] = ("100644", f[executable][1])

    cases = [("a text file with Windows line endings", crlf), ("pugl left out", no_pugl),
             ("the symlink stored as a plain file", symlink_as_file), ("an extra file (.git/config)", extra_file),
             ("the notice changed", notice_changed), (f"{executable} not executable", mode_changed)]
    failed = 0
    with tempfile.TemporaryDirectory() as tmp:
        for label, change in cases:
            broken = dict(files)
            change(broken)
            bad_folders = set(folders)
            if change is no_pugl:
                bad_folders = {d for d in folders if d != pugl and not d.startswith(pugl + "/")}
            if change is extra_file:
                bad_folders.add(f"{top}/.git")
            copy = os.path.join(tmp, "broken.tar.gz")
            write(copy, broken, bad_folders, mtime)
            found, _ = problems_in(copy, tag)
            if found:
                print(f"PASS self-test: {label}: found ({found[0]})")
            else:
                print(f"FAIL self-test: {label}: not found")
                failed = 1
    sys.exit(failed)


if __name__ == "__main__":
    main()
