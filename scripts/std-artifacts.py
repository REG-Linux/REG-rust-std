#!/usr/bin/env python3
"""Collect the std rlibs of a `cargo -Zbuild-std` build and check licences.

Reads cargo's --message-format=json output, copies every library artifact
(except the probe crate) into the rustlib directory, copies the licence
files of each crates.io crate, writes a third-party list, and fails if any
crate is not under a licence from the allowlist (no copyleft in a std that
gets linked into every Rust program of an image).
"""

import argparse
import json
import pathlib
import re
import shutil
import sys
import tomllib

# SPDX ids we accept. All permissive; no GPL/LGPL/MPL or other copyleft.
ALLOWED = {
    "MIT", "MIT-0", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "Zlib",
    "ISC", "0BSD", "Unicode-3.0", "Unicode-DFS-2016", "BSL-1.0", "CC0-1.0",
    "Unlicense", "NCSA",
}
ALLOWED_EXCEPTIONS = {"LLVM-exception"}
LICENSE_FILES = re.compile(r"^(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE)", re.I)


def licence_ok(expr):
    """Evaluate an SPDX expression: OR needs one side, AND needs both."""
    expr = re.sub(r"\(Rust COPYRIGHT\)", "", expr).replace("/", " OR ")
    tokens = re.findall(r"\(|\)|[A-Za-z0-9.+-]+", expr)
    pos = 0

    def atom():
        nonlocal pos
        tok = tokens[pos]
        pos += 1
        if tok == "(":
            val = disj()
            pos += 1  # ")"
        else:
            val = tok.rstrip("+") in ALLOWED
        if pos < len(tokens) and tokens[pos] == "WITH":
            val = val and tokens[pos + 1] in ALLOWED_EXCEPTIONS
            pos += 2
        return val

    def conj():
        nonlocal pos
        val = atom()
        while pos < len(tokens) and tokens[pos] == "AND":
            pos += 1
            val = atom() and val
        return val

    def disj():
        nonlocal pos
        val = conj()
        while pos < len(tokens) and tokens[pos] == "OR":
            pos += 1
            val = conj() or val
        return val

    return disj()


def package_licence(manifest, libsrc):
    data = tomllib.loads(manifest.read_text())
    lic = data.get("package", {}).get("license")
    if isinstance(lic, dict) and lic.get("workspace"):
        ws = tomllib.loads((libsrc / "library" / "Cargo.toml").read_text())
        lic = ws.get("workspace", {}).get("package", {}).get("license")
    return lic


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build-json", required=True)
    ap.add_argument("--exclude", required=True)
    ap.add_argument("--libsrc", required=True)
    ap.add_argument("--libdir", required=True)
    ap.add_argument("--docdir", required=True)
    ap.add_argument("--third-party", required=True)
    ap.add_argument("--title", required=True)
    a = ap.parse_args()

    libsrc = pathlib.Path(a.libsrc)
    libdir = pathlib.Path(a.libdir)
    docdir = pathlib.Path(a.docdir)
    crates = {}
    copied = 0

    for line in pathlib.Path(a.build_json).read_text().splitlines():
        if not line.startswith("{"):
            continue
        msg = json.loads(line)
        if msg.get("reason") != "compiler-artifact":
            continue
        if "lib" not in msg["target"]["kind"] and "rlib" not in msg["target"]["kind"]:
            continue
        name = msg["target"]["name"]
        if msg["package_id"].find(a.exclude) >= 0:
            continue
        for f in msg["filenames"]:
            if f.endswith(".rlib"):
                shutil.copy2(f, libdir)
                copied += 1
        manifest = pathlib.Path(msg["manifest_path"])
        pkg = tomllib.loads(manifest.read_text()).get("package", {})
        version = pkg.get("version", "0.0.0")
        if isinstance(version, dict):
            version = "(workspace)"
        source = "rust-src" if str(manifest).startswith(str(libsrc)) else "crates.io"
        lic = package_licence(manifest, libsrc)
        if not lic and source == "rust-src":
            # In-tree std crates without a licence field (proc_macro, ...)
            # are part of Rust itself: COPYRIGHT says MIT OR Apache-2.0.
            lic = "MIT OR Apache-2.0 (Rust COPYRIGHT)"
        crates[(name, str(version))] = (source, lic, manifest.parent)

    if not copied:
        sys.exit("no std rlib found in the cargo output")

    bad = []
    rows = []
    for (name, version), (source, lic, pdir) in sorted(crates.items()):
        ok = bool(lic) and licence_ok(lic)
        if not ok:
            bad.append(f"{name} {version}: {lic!r}")
        rows.append(f"| {name} | {version} | {source} | {lic} |")
        if source == "crates.io":
            dest = docdir / "third-party" / f"{name}-{version}"
            for f in sorted(pdir.iterdir()):
                if f.is_file() and LICENSE_FILES.match(f.name):
                    dest.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(f, dest / f.name)

    pathlib.Path(a.third_party).write_text(
        f"# {a.title}: crates and licences\n\n"
        "Every crate compiled into this standard library. Crates from rust-src are\n"
        "covered by Rust's COPYRIGHT, LICENSE-APACHE and LICENSE-MIT; the licence\n"
        "files of crates.io crates are in third-party/<crate>-<version>/.\n\n"
        "| crate | version | source | licence |\n|---|---|---|---|\n"
        + "\n".join(rows) + "\n")

    print(f"{copied} rlibs, {len(crates)} crates")
    if bad:
        sys.exit("licences outside the allowlist:\n  " + "\n  ".join(bad))
    print("licences: all on the allowlist")


if __name__ == "__main__":
    main()
