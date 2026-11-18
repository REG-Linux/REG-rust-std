# REG-rust-std

Prebuilt Rust standard libraries for targets that the Rust project does not
ship a std for (Tier 3), built with the **official** stable `rustc` of the same
version. Used by [REG-Linux](https://github.com/REG-Linux) so that boards on
these targets install the official compiler plus this std, instead of
building `rustc` from source (about an hour per build).

| target | variant | used by | why a custom build |
|---|---|---|---|
| `mipsel-unknown-linux-musl` | `fpxx` | REG-Linux `jz4770` (RG350, RG280V, GCW Zero) | Tier 3, and hard-float (see below) |

## What is in a release

A release tag is the Rust version (`1.98.1`). For each target:

- `reg-rust-std-<version>-<target>-<variant>.tar.xz`: laid out exactly like
  the official `rust-std-<version>-<target>.tar.xz` component (same
  `install.sh`, top directory `rust-std-<version>-<target>`), so it installs
  with `./install.sh --prefix=<rust prefix>` next to the official `rustc`.
- `.sha256` of it.
- `THIRD-PARTY-<version>-<target>.md`: every crate compiled into it, with its
  licence.

Inside the tarball, `share/doc/rust-std-<target>/` holds Rust's `COPYRIGHT`,
`COPYRIGHT-library.html`, `LICENSE-MIT`, `LICENSE-APACHE`, the third-party
list, the licence files of each crates.io crate, and `BUILD-INFO` (rustc
version and commit, flags).

## How it is built

`build.sh <rust-version> <target>`:

1. Downloads the official `rust-<version>-x86_64-unknown-linux-gnu.tar.xz`
   and `rust-src-<version>.tar.xz` from <https://static.rust-lang.org/dist/>
   and checks them against the sha256 pinned in `versions/<version>.sha256`
   (copied from the `.sha256` files published next to them).
2. Applies `patches/<version>/*.patch` to the std sources, if any. **There are
   none today: std is built from the unmodified official sources.**
3. Builds `std`, `panic_abort` and `panic_unwind` for the target with that
   compiler: `cargo -Zbuild-std` on an empty crate, with
   `RUSTC_BOOTSTRAP=1` (the switch Rust's own build uses for std), the
   target's flags from `targets/<target>.conf`, opt-level 3, one codegen
   unit, embedded bitcode (so crates built against it may use LTO), and
   build paths remapped (`/rustc/<commit>`, as in the official std).
4. Packages the rlibs as a `rust-std-<target>` component.
5. Checks, and fails on any problem:
   - every crate's licence is on the permissive allowlist in
     `scripts/std-artifacts.py` (no GPL/LGPL/MPL or other copyleft);
   - the FP ABI of every object of `core` and `std` (`readelf -A`) is the one
     the target expects (`scripts/check-fp-abi.sh`);
   - a crate using `std`, `libc` and `cfg-if` builds on **stable** `rustc`
     (no `RUSTC_BOOTSTRAP`) against the new std only.
6. Writes a deterministic `tar.xz` (sorted names, mtime 0, uid/gid 0).

The std is tied to the exact compiler: a std built for 1.98.1 only loads in
the official 1.98.1 `rustc`. Every Rust version needs its own release.

### Reproduce a release

On any x86_64 Linux with `curl`, `xz`, `binutils` (`ar`, `readelf`) and
Python ≥ 3.11:

```sh
git clone https://github.com/REG-Linux/REG-rust-std
cd REG-rust-std
./build.sh 1.98.1 mipsel-unknown-linux-musl
sha256sum out/*.tar.xz      # compare with the release's .sha256
```

It needs network access for crates.io (std's own dependencies, at the
versions pinned by `library/Cargo.lock` in `rust-src`). About 2 minutes.

### Add a Rust version

1. `versions/<version>.sha256`: the two lines from
   `https://static.rust-lang.org/dist/rust-<version>-x86_64-unknown-linux-gnu.tar.xz.sha256`
   and `https://static.rust-lang.org/dist/rust-src-<version>.tar.xz.sha256`.
2. Push a tag named `<version>`: the CI builds every target in `targets/`
   and publishes the release.

## mipsel-unknown-linux-musl, `fpxx` variant

Rust's built-in target is soft-float (`+mips32r2,+soft-float`). The JZ4770
has an FPU, and REG-Linux's C toolchain, its musl and every C library are
hard-float with the `fpxx` FP ABI (`readelf -A`: `Hard float (32-bit CPU, Any
FPU)`). With a soft-float std every `f32`/`f64` passed between Rust and C goes
through the wrong registers (libm's `sin(0.5)` came back as a denormal near
zero). So std is built with

```
-Ctarget-feature=-soft-float,+fpxx,+nooddspreg
```

and **every crate of the board must use the same flags**; REG-Linux sets them
in `CARGO_TARGET_MIPSEL_UNKNOWN_LINUX_MUSL_RUSTFLAGS`. These are the features
of Rust's own `mipsel-unknown-linux-gnu` target. rustc 1.98.1 warns that they
are "unknown and unstable" and still applies them; `check-fp-abi.sh` fails
the build if a later rustc stops doing so.

## Sources

- Rust compiler and standard library: <https://github.com/rust-lang/rust>,
  released tarballs at <https://static.rust-lang.org/dist/>. Each tarball's
  `BUILD-INFO` names the exact commit (`rustc -vV`), e.g. 1.98.1 is
  [`48a229ce`](https://github.com/rust-lang/rust/commit/48a229ceaefd4985c50990b14116b6d856af0985).
- std's crates.io dependencies: the versions listed in the release's
  `THIRD-PARTY` file, from <https://crates.io>.

## Licence

The scripts here are MIT (`LICENSE`). The released std is Rust's code and
crates.io crates under their own licences, all permissive; see the files
shipped inside each tarball.
