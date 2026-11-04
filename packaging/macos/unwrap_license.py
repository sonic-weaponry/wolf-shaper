#!/usr/bin/env python3
"""Reflows the GPL for the macOS Installer's License pane.

The license text has hard line breaks at about 78 characters, and the pane is narrower, so most lines wrap a second
time and the right edge looks ragged. This puts each paragraph on one line, which the pane then wraps cleanly, from
"Preamble" on. Kept as they are: the title and copyright lines at the top, and after "END OF TERMS AND CONDITIONS" the
indented examples of notices (every line indented by four spaces or more), whose line breaks matter. Only line breaks
and the spaces around them change: the script fails if the sequence of words differs from the input's.

Usage: unwrap_license.py < LICENSE > LICENSE.txt
"""
import sys

START = "Preamble"
END = "END OF TERMS AND CONDITIONS"


def is_example(paragraph):
    return all(len(line) - len(line.lstrip(" ")) >= 4 for line in paragraph)


def unwrap(text):
    lines = text.split("\n")
    out = []
    paragraph = []
    state = "before"  # before the preamble, inside the terms, after the terms

    def flush():
        if not paragraph:
            return
        if state == "before" or (state == "after" and is_example(paragraph)):
            out.extend(paragraph)
        else:
            first = paragraph[0].rstrip()
            out.append(" ".join([first] + [line.strip() for line in paragraph[1:]]))
        paragraph.clear()

    for line in lines:
        stripped = line.strip()
        if stripped == "":
            flush()
            out.append(line)
            continue
        if state == "before" and stripped == START:
            flush()
            state = "inside"
        if state == "inside" and stripped == END:
            flush()
            state = "after"
        paragraph.append(line)
    flush()
    if state != "after":
        raise SystemExit("unwrap_license.py: didn't find %r and then %r in the license" % (START, END))
    return "\n".join(out)


def main():
    text = sys.stdin.read().replace("\r", "")
    result = unwrap(text)
    if result.split() != text.split():
        raise SystemExit("unwrap_license.py: the words changed; refusing to write the license")
    sys.stdout.write(result)


if __name__ == "__main__":
    main()
