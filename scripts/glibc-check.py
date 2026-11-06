#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later OR GPL-3.0-or-later
"""Report the newest glibc a static archive needs, and fail on a miss.

Every undefined symbol of the given archives must be defined by the archives
themselves, by the dependency archives (--dep-dir), by the compiler runtime
or by this system's libc, libm, libpthread, libdl, librt, libstdc++ and
libgcc_s.  For a symbol taken from libc/libm/... the default GLIBC_ version
is the one a new link binds to; the maximum is the glibc the archive needs.
With --max X.Y the check fails when that maximum is newer than X.Y;
with --json FILE the result is also written there (for the build-info file).
"""
import argparse
import glob
import os
import re
import subprocess
import sys

SYSLIBS = ["libc.so.6", "libm.so.6", "libpthread.so.0", "libdl.so.2",
           "librt.so.1", "libstdc++.so.6", "libgcc_s.so.1"]
SYSDIRS = ["/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu", "/lib64", "/usr/lib64"]


def run(*cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True,
                          errors="replace").stdout


def ver(s):
    return tuple(int(x) for x in s.split("."))


def undefined(archive):
    out = set()
    for line in run("nm", "-u", "--no-demangle", archive).splitlines():
        t = line.split()
        if len(t) == 2 and t[0] == "U":  # weak (w, v) references may stay unresolved
            out.add(t[1].split("@")[0])
    return out


def defined_static(archive):
    out = set()
    for line in run("nm", "-g", "--defined-only", "--no-demangle", archive).splitlines():
        t = line.split()
        if len(t) == 3:
            out.add(t[2])
    return out


def shared_defs(path):
    """name -> GLIBC version tuple (or None) for the dynamic symbols of path."""
    out = {}
    for line in run("objdump", "-T", path).splitlines():
        t = line.split()
        if len(t) < 7 or "*UND*" in line or not re.match(r"^[0-9a-f]{8,}$", t[0]):
            continue
        name, vtok = t[-1], t[-2]
        hidden = vtok.startswith("(")
        m = re.match(r"^\(?GLIBC_(\d+(?:\.\d+)*)\)?$", vtok)
        v = ver(m.group(1)) if m else None
        if name not in out or (not hidden and v is not None):
            out[name] = v
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--max")
    ap.add_argument("--json", help="write the result to this file")
    ap.add_argument("--dep-dir", action="append", default=[])
    ap.add_argument("archives", nargs="+")
    a = ap.parse_args()

    need, have = set(), set()
    for ar in a.archives:
        need |= undefined(ar)
        have |= defined_static(ar)
    for d in a.dep_dir:
        for ar in glob.glob(os.path.join(d, "*.a")):
            have |= defined_static(ar)
    for extra in (run("gcc", "-print-libgcc-file-name").strip(),
                  run("gcc", "-print-file-name=libc_nonshared.a").strip()):
        if os.path.isabs(extra) and os.path.exists(extra):
            have |= defined_static(extra)
    sysdefs = {}
    for lib in SYSLIBS:
        for d in SYSDIRS:
            p = os.path.join(d, lib)
            if os.path.exists(p):
                for n, v in shared_defs(p).items():
                    if n not in sysdefs or (v and (sysdefs[n] is None or v > sysdefs[n])):
                        sysdefs[n] = v
                break
    top, top_sym, missing = (0,), None, []
    for s in sorted(need - have):
        if s == "_GLOBAL_OFFSET_TABLE_":
            continue
        if s not in sysdefs:
            missing.append(s)
        elif sysdefs[s] and sysdefs[s] > top:
            top, top_sym = sysdefs[s], s
    print("archives:", " ".join(a.archives))
    print("undefined symbols resolved by system libraries: %d" % len(need - have - set(missing)))
    print("newest glibc needed: %s%s" % (".".join(map(str, top)),
                                         " (%s)" % top_sym if top_sym else ""))
    bad = False
    if missing:
        print("UNRESOLVED (defined by nothing here, not in this system's libc/libm/...):",
              file=sys.stderr)
        print("  " + "\n  ".join(missing), file=sys.stderr)
        bad = True
    if a.max and top > ver(a.max):
        print("needs glibc %s, newer than %s" % (".".join(map(str, top)), a.max),
              file=sys.stderr)
        bad = True
    if a.json:
        import json
        with open(a.json, "w") as f:
            json.dump({"newest_glibc": ".".join(map(str, top)), "symbol": top_sym,
                       "limit": a.max, "unresolved": missing, "archives": a.archives}, f)
    sys.exit(1 if bad else 0)


main()
