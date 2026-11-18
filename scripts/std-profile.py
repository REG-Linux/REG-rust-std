#!/usr/bin/env python3
"""Print the std workspace's [profile.release.package.*] overrides.

Usage: std-profile.py <rust-src>/library/Cargo.toml >> probe/Cargo.toml

A `cargo -Zbuild-std` build uses the profile of the crate being built, not
the one of Rust's library workspace. These per-package overrides matter:
compiler_builtins with one object per intrinsic (so it never clashes with
libgcc), no debuginfo for the backtrace crates. Read from the Rust version
being built, so they follow upstream.
"""

import sys
import tomllib


def value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return str(v)


with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)

packages = data.get("profile", {}).get("release", {}).get("package", {})
for name in sorted(packages):
    print(f'\n[profile.release.package."{name}"]')
    for key, val in packages[name].items():
        print(f"{key} = {value(val)}")
