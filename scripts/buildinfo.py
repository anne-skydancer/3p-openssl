#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later OR GPL-3.0-or-later
"""Write and read the build-info file that every Vulkanstorm 3p package carries.

  buildinfo.py write --name openssl --flavour linux64-lts --out stage/LICENSES/openssl-buildinfo.json ...
  buildinfo.py notes dist [--intro TEXT]      (markdown release notes from the archives in dist)

The file is LICENSES/<name>-buildinfo.json inside the package.  Needs the
`llsd` module (installed with autobuild) to read the dependency URLs and
hashes from autobuild.xml, and `zstandard` for `notes`.
"""
import argparse
import datetime
import glob
import hashlib
import io
import json
import os
import platform
import re
import subprocess
import sys
import tarfile


def sh(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, errors="replace",
                              timeout=60).stdout.strip()
    except Exception:
        return ""


def first_line(s):
    return s.splitlines()[0] if s else ""


def dependencies(autobuild_xml, plat):
    import llsd
    with open(autobuild_xml, "rb") as f:
        doc = llsd.parse(f.read())
    out = {}
    for name, inst in sorted(doc.get("installables", {}).items()):
        arch = inst.get("platforms", {}).get(plat, {}).get("archive")
        if not arch:
            continue
        fn = arch["url"].rsplit("/", 1)[-1]
        m = re.match(r"^" + re.escape(name.replace("-", "_")) + r"[-_](.+?)-" + plat + r"(?:-lts)?-\d+\.tar\.zst$",
                     fn) or re.match(r"^" + re.escape(name) + r"-(.+?)-" + plat + r"(?:-lts)?-\d+\.tar\.zst$", fn)
        out[name] = {"version": m.group(1) if m else inst.get("version"),
                     "archive_url": arch["url"],
                     "sha1": arch.get("hash")}
    return out


def write(a):
    env = os.environ
    plat = "windows64" if a.flavour == "windows64" else "linux64"
    info = {
        "schema": 1,
        "package": a.name,
        "package_version": open("VERSION.txt").read().strip(),
        "flavour": a.flavour,
        "upstream": {"version": a.upstream_version, "source_url": a.upstream_url,
                     "source_sha256": a.upstream_sha256},
        "three_p_repo": {
            "url": "%s/%s" % (env.get("GITHUB_SERVER_URL", "https://github.com"),
                              env.get("GITHUB_REPOSITORY", "")),
            "commit": env.get("GITHUB_SHA", ""),
            "ref": env.get("GITHUB_REF", "")},
        "ci": {"run_id": env.get("GITHUB_RUN_ID", ""),
               "run_url": "%s/%s/actions/runs/%s" % (env.get("GITHUB_SERVER_URL", "https://github.com"),
                                                     env.get("GITHUB_REPOSITORY", ""),
                                                     env.get("GITHUB_RUN_ID", "")),
               "autobuild_build_id": env.get("AUTOBUILD_BUILD_ID", "")},
        "build_date_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "build_type": "Release, static libraries",
        "configure_options": a.options,
        "dependencies": dependencies("autobuild.xml", plat),
    }
    if plat == "linux64":
        osr = {}
        try:
            for line in open("/etc/os-release"):
                if "=" in line:
                    k, v = line.rstrip().split("=", 1)
                    osr[k] = v.strip('"')
        except OSError:
            pass
        host = "ubuntu:24.04 container on an ubuntu-latest runner" if a.container else \
            "ubuntu-latest runner (no container), image %s %s" % (env.get("ImageOS", "?"), env.get("ImageVersion", "?"))
        info["build_os"] = {"description": host, "os_release": osr.get("PRETTY_NAME", ""),
                            "container_image": a.container or None,
                            "glibc_version": platform.libc_ver()[1] or first_line(sh("ldd", "--version")),
                            "ldd": first_line(sh("ldd", "--version"))}
        info["compiler"] = {"cc": first_line(sh("gcc", "--version")),
                            "full_version": sh("gcc", "-dumpfullversion")}
        if a.glibc_json and os.path.exists(a.glibc_json):
            g = json.load(open(a.glibc_json))
            info["glibc_floor"] = {"newest_glibc_symbol_version_needed": g["newest_glibc"],
                                   "symbol": g.get("symbol"),
                                   "limit_enforced": g.get("limit"),
                                   "method": "nm -u of the static archives, each undefined symbol looked up in "
                                             "the build system's libc/libm/libpthread/libdl/librt (objdump -T)"}
    else:
        vs = ""
        vw = os.path.join(env.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
                          "Microsoft Visual Studio", "Installer", "vswhere.exe")
        if os.path.exists(vw):
            vs = sh(vw, "-latest", "-products", "*", "-property", "displayName") + " " + \
                sh(vw, "-latest", "-products", "*", "-property", "catalog_productDisplayVersion")
        info["build_os"] = {"description": "windows runner, image %s %s" % (env.get("ImageOS", "?"),
                                                                           env.get("ImageVersion", "?")),
                            "platform": platform.platform()}
        info["compiler"] = {"cc": "MSVC, %s (AUTOBUILD_VSVER=%s)" % (vs.strip() or "Visual Studio", env.get("AUTOBUILD_VSVER", ""))}
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    with open(a.out, "w") as f:
        json.dump(info, f, indent=2)
        f.write("\n")
    print(json.dumps(info, indent=2))


def notes(a):
    import zstandard
    rows, details = [], []
    for path in sorted(glob.glob(os.path.join(a.dir, "*.tar.zst"))):
        data = open(path, "rb").read()
        sha1 = hashlib.sha1(data).hexdigest()
        tar = tarfile.open(fileobj=io.BytesIO(zstandard.ZstdDecompressor().decompressobj().decompress(data)))
        member = [n for n in tar.getnames() if n.endswith("-buildinfo.json")]
        info = json.load(tar.extractfile(member[0])) if member else {}
        g = info.get("glibc_floor", {})
        rows.append("| `%s` | %s | `%s` | %s | %s | %s |" % (
            os.path.basename(path), info.get("flavour", "?"), sha1,
            info.get("build_os", {}).get("description", "?") +
            (" (%s)" % info["build_os"]["os_release"] if info.get("build_os", {}).get("os_release") else ""),
            ("glibc %s" % g["newest_glibc_symbol_version_needed"]) if g else "n/a",
            info.get("compiler", {}).get("cc", "?")))
    out = [a.intro, "", "| Asset | Platform | sha1 | Build OS | glibc floor | Compiler |",
           "|---|---|---|---|---|---|"] + rows + [
        "", "Each package carries `LICENSES/<name>-buildinfo.json` (source hash, 3p commit, CI run, "
            "toolchain, options, dependency URLs and hashes) and a full `autobuild-package.xml`."]
    print("\n".join(out))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("write")
    w.add_argument("--name", required=True)
    w.add_argument("--flavour", required=True, choices=["windows64", "linux64", "linux64-lts"])
    w.add_argument("--out", required=True)
    w.add_argument("--upstream-version", required=True)
    w.add_argument("--upstream-url", required=True)
    w.add_argument("--upstream-sha256", required=True)
    w.add_argument("--options", required=True)
    w.add_argument("--container")
    w.add_argument("--glibc-json")
    n = sub.add_parser("notes")
    n.add_argument("dir")
    n.add_argument("--intro", default="")
    a = ap.parse_args()
    {"write": write, "notes": notes}[a.cmd](a)


main()
