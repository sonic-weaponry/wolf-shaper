#!/usr/bin/env python3
"""Proves that a signed copy of a macOS program carries exactly the code and data of the unsigned build.

Signing (codesign) writes a code signature at the end of each slice's __LINKEDIT segment: it replaces the linker's ad
hoc signature, or adds one (a LC_CODE_SIGNATURE load command in the header's padding) where the linker left none, and
updates __LINKEDIT's sizes. Nothing else in the file may change. Per slice (matched by CPU type) this compares:
  - the Mach-O header, apart from the load command count and size, whose difference must be exactly one added
    LC_CODE_SIGNATURE;
  - every load command except LC_CODE_SIGNATURE, with __LINKEDIT's file and memory sizes masked;
  - every segment's bytes (the first segment from the end of the load commands on, since it also holds them; the
    header padding the signed copy uses for a new LC_CODE_SIGNATURE must be zeros in the unsigned one);
  - __LINKEDIT up to where the signature starts (padding before it must be zeros), and the signature must lie inside
    __LINKEDIT.
Prints a line per slice and a RESULT line. Exit 0: same code and data; 1: different; 2: couldn't read the files.

Usage: macho_same_code.py <unsigned program> <signed program>
       macho_same_code.py --self-test <program>
The self-test makes changed copies of the program in memory: one changed byte in the code, in the data or in
__LINKEDIT before the signature must be found; changed bytes inside an existing signature must not count.
"""
import struct
import sys

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
CPU_NAMES = {0x01000007: "x86_64", 0x0100000C: "arm64"}
HEADER = struct.Struct("<IiiIIIII")


class Unreadable(Exception):
    pass


def slices(data):
    """{(cputype, cpusubtype): (offset in the file, slice bytes)}"""
    if len(data) < 8:
        raise Unreadable("too short for a Mach-O file")
    magic = struct.unpack_from(">I", data, 0)[0]
    result = {}
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from(">I", data, 4)[0]
        at = 8
        for _ in range(count):
            if magic == FAT_MAGIC:
                cputype, cpusub, offset, size, _align = struct.unpack_from(">IIIII", data, at)
                at += 20
            else:
                cputype, cpusub, offset, size, _align, _reserved = struct.unpack_from(">IIQQII", data, at)
                at += 32
            result[(cputype, cpusub & 0x00FFFFFF)] = (offset, data[offset:offset + size])
        return result
    if struct.unpack_from("<I", data, 0)[0] == MH_MAGIC_64:
        cputype, cpusub = struct.unpack_from("<II", data, 4)
        return {(cputype, cpusub & 0x00FFFFFF): (0, data)}
    raise Unreadable("not a 64-bit Mach-O file (magic %08x)" % magic)


def parse(sl):
    """The parts of one slice that signing may and may not change."""
    if len(sl) < HEADER.size or struct.unpack_from("<I", sl, 0)[0] != MH_MAGIC_64:
        raise Unreadable("slice is not a 64-bit Mach-O")
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, reserved = HEADER.unpack_from(sl, 0)
    commands = []
    segments = []
    signature = None
    at = HEADER.size
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", sl, at)
        if cmdsize < 8 or at + cmdsize > HEADER.size + sizeofcmds:
            raise Unreadable("load command at 0x%x has a bad size" % at)
        raw = bytearray(sl[at:at + cmdsize])
        if cmd == LC_SEGMENT_64:
            name = bytes(raw[8:24]).rstrip(b"\0").decode("ascii", "replace")
            _vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", raw, 24)
            segments.append((name, fileoff, filesize))
            if name == "__LINKEDIT":
                struct.pack_into("<Q", raw, 32, 0)  # vmsize
                struct.pack_into("<Q", raw, 48, 0)  # filesize
            commands.append(("segment %s" % name, bytes(raw)))
        elif cmd == LC_CODE_SIGNATURE:
            if signature is not None:
                raise Unreadable("two code signatures")
            signature = struct.unpack_from("<II", raw, 8)  # dataoff, datasize
        else:
            commands.append(("load command 0x%x" % cmd, bytes(raw)))
        at += cmdsize
    return {
        "fixed header": struct.pack("<IiiIII", magic, cputype, cpusub, filetype, flags, reserved),
        "ncmds": ncmds,
        "sizeofcmds": sizeofcmds,
        "commands": commands,
        "segments": segments,
        "signature": signature,
    }


def zeros(b):
    return not any(b)


def compare_slice(u, s, require_signature=True):
    """Returns (None, details) if only the signature differs, else (a description of the first difference, '')."""
    pu, ps = parse(u), parse(s)
    if pu["fixed header"] != ps["fixed header"]:
        return "the Mach-O header differs", ""
    if ps["signature"] is None and require_signature:
        return "the signed copy has no code signature", ""
    added = (ps["signature"] is not None) - (pu["signature"] is not None)
    if added not in (0, 1) or ps["ncmds"] - pu["ncmds"] != added or \
            ps["sizeofcmds"] - pu["sizeofcmds"] != 16 * added:
        return "the load commands' count or size changed beyond the signature", ""
    if [c[0] for c in pu["commands"]] != [c[0] for c in ps["commands"]]:
        return "the load commands differ in kind or order", ""
    for (label, a), (_label, b) in zip(pu["commands"], ps["commands"]):
        if a != b:
            return "%s differs" % label, ""
    if [(n, o) for n, o, _f in pu["segments"]] != [(n, o) for n, o, _f in ps["segments"]]:
        return "the segments' names or places differ", ""
    end_u = HEADER.size + pu["sizeofcmds"]
    end_s = HEADER.size + ps["sizeofcmds"]
    for (name, fileoff, filesize_u), (_name, _fileoff, filesize_s) in zip(pu["segments"], ps["segments"]):
        if name == "__LINKEDIT":
            content_u = pu["signature"][0] if pu["signature"] else fileoff + filesize_u
            dataoff_s, datasize_s = ps["signature"] or (fileoff + filesize_s, 0)
            if not (fileoff <= dataoff_s and dataoff_s + datasize_s <= fileoff + filesize_s):
                return "the signature doesn't lie inside __LINKEDIT", ""
            common = min(content_u, dataoff_s)
            if u[fileoff:common] != s[fileoff:common]:
                return "__LINKEDIT differs before the signature", ""
            if not zeros(u[common:content_u]) or not zeros(s[common:dataoff_s]):
                return "__LINKEDIT differs before the signature (padding)", ""
            continue
        if filesize_u != filesize_s:
            return "segment %s changed size" % name, ""
        start = fileoff
        if fileoff == 0:  # this segment holds the header and the load commands, compared above
            start = max(end_u, end_s)
            if not zeros(u[end_u:start]):
                return "the header padding the signature uses wasn't empty", ""
        if u[start:fileoff + filesize_u] != s[start:fileoff + filesize_s]:
            return "segment %s differs" % name, ""
    was = "linker's ad hoc signature, %d bytes" % pu["signature"][1] if pu["signature"] else "no signature"
    now = "signature %d bytes" % ps["signature"][1] if ps["signature"] else "no signature"
    return None, "%s (unsigned build: %s)" % (now, was)


def compare(unsigned, signed, require_signature=True):
    """(exit code, lines)"""
    try:
        su, ss = slices(unsigned), slices(signed)
    except Unreadable as e:
        return 2, ["unreadable: %s" % e]
    lines = []
    if sorted(su) != sorted(ss):
        return 1, ["the slices differ: %s against %s" % (sorted(su), sorted(ss))]
    failed = 0
    for key in sorted(su):
        name = CPU_NAMES.get(key[0], "cpu 0x%x" % key[0])
        try:
            problem, details = compare_slice(su[key][1], ss[key][1], require_signature)
        except (Unreadable, struct.error) as e:
            return 2, lines + ["%s: unreadable: %s" % (name, e)]
        if problem:
            failed += 1
            lines.append("%s: DIFFERENT: %s" % (name, problem))
        else:
            lines.append("%s: same code and data; %s" % (name, details))
    return (1 if failed else 0), lines


def self_test(data):
    """Each check: (description, changed file, expected exit code)."""
    checks = [("the program against itself", data, 0)]
    for key, (offset, sl) in sorted(slices(data).items()):
        name = CPU_NAMES.get(key[0], "cpu 0x%x" % key[0])
        p = parse(sl)
        segs = {n: (o, f) for n, o, f in p["segments"]}
        text_o, text_f = segs["__TEXT"]
        code_at = offset + (text_o + HEADER.size + p["sizeofcmds"] + text_o + text_f) // 2
        checks.append(("%s: one byte changed in the code" % name, flip(data, code_at), 1))
        data_seg = next((n for n in ("__DATA", "__DATA_CONST") if n in segs and segs[n][1]), None)
        if data_seg:
            o, f = segs[data_seg]
            checks.append(("%s: one byte changed in %s" % (name, data_seg), flip(data, offset + o + f // 2), 1))
        link_o, link_f = segs["__LINKEDIT"]
        end = p["signature"][0] if p["signature"] else link_o + link_f
        checks.append(("%s: one byte changed in __LINKEDIT before the signature" % name,
                       flip(data, offset + link_o + (end - link_o) // 2), 1))
        if p["signature"]:
            dataoff, datasize = p["signature"]
            changed = bytearray(data)
            for i in range(offset + dataoff + 8, offset + dataoff + datasize, 97):
                changed[i] ^= 0x5A
            checks.append(("%s: bytes changed inside the signature only" % name, bytes(changed), 0))
    failed = 0
    for description, changed, expected in checks:
        # The program itself may be unsigned in a slice (the linker signs only arm64), so no signature is required here.
        code, _lines = compare(data, changed, require_signature=False)
        ok = code == expected
        failed += not ok
        print("%s %s: %s (expected %s)" % ("PASS" if ok else "FAIL", description,
                                            {0: "same", 1: "different", 2: "unreadable"}[code],
                                            {0: "same", 1: "different"}[expected]))
    print("RESULT same-code-self-test %s %d of %d" % ("PASS" if not failed else "FAIL", len(checks) - failed,
                                                       len(checks)))
    return 1 if failed else 0


def flip(data, at):
    changed = bytearray(data)
    changed[at] ^= 0xFF
    return bytes(changed)


def main(argv):
    if len(argv) == 3 and argv[1] == "--self-test":
        with open(argv[2], "rb") as f:
            return self_test(f.read())
    if len(argv) != 3:
        print(__doc__)
        return 2
    with open(argv[1], "rb") as f:
        unsigned = f.read()
    with open(argv[2], "rb") as f:
        signed = f.read()
    code, lines = compare(unsigned, signed)
    for line in lines:
        print(line)
    print("RESULT same-code %s" % {0: "PASS: only the signature differs",
                                   1: "FAIL: the code or data differ",
                                   2: "FAIL: unreadable"}[code])
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
