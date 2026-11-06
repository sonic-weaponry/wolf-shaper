#!/usr/bin/env python3
"""Checks a draft release on GitHub against the release folder it was made from (the release-draft job, ci/README.md
"The release"): exactly one release with that tag name, still a draft, aimed at this run's commit, with the folder's
title and notes, holding exactly the folder's files, every one uploaded with the sha256 in SHA256SUMS (GitHub's own
digest of the file, or the file downloaded again where GitHub gives none). Reports whether making the draft already
created the tag (GitHub's documentation doesn't say; it should appear only when the draft is published).

Usage: ci/check_release_draft.py <release folder> <tag> <commit> <owner/repo>
Needs gh with a token that can read the repository's draft releases (GH_TOKEN). Exits 1 if any check failed.
"""
import hashlib
import json
import os
import subprocess
import sys


def gh_api(*args):
    r = subprocess.run(["gh", "api", *args], capture_output=True)
    return r.returncode, r.stdout


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    folder, tag, commit, repo = sys.argv[1:]
    failed = 0

    def result(good, message):
        nonlocal failed
        print(f"PASS {message}" if good else f"::error::FAIL {message}")
        if not good:
            failed = 1

    code, out = gh_api("--paginate", f"repos/{repo}/releases", "--jq", f'.[] | select(.tag_name == "{tag}")')
    releases = [json.loads(line) for line in out.decode().splitlines() if line.strip()] if code == 0 else []
    result(len(releases) == 1, f"exactly one release named {tag} (found {len(releases)})")
    if len(releases) != 1:
        sys.exit(1)
    rel = releases[0]
    title = open(os.path.join(folder, "release-title.txt"), encoding="utf-8").read().strip()
    notes = open(os.path.join(folder, "release-notes.md"), encoding="utf-8").read()
    result(rel.get("draft") is True, "it's a draft (visible only to people with write access)")
    result(rel.get("target_commitish") == commit, f"it's aimed at this run's commit {commit[:8]} "
           f"(found {rel.get('target_commitish')})")
    result(rel.get("name") == title, f"its title is {title!r}")
    body = (rel.get("body") or "").replace("\r\n", "\n").strip()
    result(body == notes.replace("\r\n", "\n").strip(), "its notes are the folder's release-notes.md")

    assets_dir = os.path.join(folder, "assets")
    local = {}
    for name in sorted(os.listdir(assets_dir)):
        with open(os.path.join(assets_dir, name), "rb") as f:
            data = f.read()
        local[name] = (len(data), hashlib.sha256(data).hexdigest())
    remote = {a["name"]: a for a in rel.get("assets", [])}
    result(sorted(remote) == sorted(local), f"it holds exactly the files {sorted(local)} (found {sorted(remote)})")
    for name, (size, sha) in local.items():
        a = remote.get(name)
        if a is None:
            continue
        digest = a.get("digest") or ""
        if digest.startswith("sha256:"):
            got, how = digest.split(":", 1)[1], "GitHub's digest"
        else:
            code, data = gh_api("-H", "Accept: application/octet-stream", f"repos/{repo}/releases/assets/{a['id']}")
            got, how = (hashlib.sha256(data).hexdigest() if code == 0 else "download failed"), "downloaded again"
        result(a.get("state") == "uploaded" and a.get("size") == size and got == sha,
               f"{name}: uploaded, {size} bytes, sha256 {sha[:16]}... ({how})")

    code, _ = gh_api(f"repos/{repo}/git/ref/tags/{tag}")
    print(f"REPORT the tag {tag} {'exists already: making the draft created it' if code == 0 else 'does not exist yet (GitHub makes it when the draft is published)'}")
    url = rel.get("html_url", "")
    print(f"draft: {url}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(f"### Draft release {tag}\n\n{url}\n\nVisible only to people with write access. "
                    f"Tag created by the draft: {'yes' if code == 0 else 'no'}.\n")
    sys.exit(failed)


if __name__ == "__main__":
    main()
