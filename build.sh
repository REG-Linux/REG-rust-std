#!/bin/bash
#
# Build the Rust standard library for a target that has no official
# prebuilt std (Tier 3), with the official stable compiler of the same
# version, and package it like an official rust-std component.
#
#   ./build.sh <rust-version> <target>
#   ./build.sh 1.98.1 mipsel-unknown-linux-musl
#
# Environment (all optional):
#   WORK  scratch directory           (default: ./work)
#   OUT   output directory            (default: ./out)
#   DL    download cache              (default: ./dl)
#
# Output, in $OUT:
#   reg-rust-std-<version>-<target>[-<variant>].tar.xz         the std
#   reg-rust-std-<version>-<target>[-<variant>].tar.xz.sha256
#   THIRD-PARTY-<version>-<target>.md                           crates and licences
#
# Why it works: std only has to be built by the very same rustc that will
# use it. The official x86_64 rustc already carries the LLVM backend of
# every target; only std is missing for Tier 3 ones. `cargo -Zbuild-std`
# (RUSTC_BOOTSTRAP=1, the same switch Rust's own build uses) compiles std
# from the official rust-src component with that compiler.

set -euo pipefail

usage() { echo "usage: $0 <rust-version> <target>" >&2; exit 2; }
[ $# -eq 2 ] || usage
VER=$1
TARGET=$2

HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$PWD/work}
OUT=${OUT:-$PWD/out}
DL=${DL:-$PWD/dl}
HOST=x86_64-unknown-linux-gnu
SITE=https://static.rust-lang.org/dist

CONF="$HERE/targets/$TARGET.conf"
SUMS="$HERE/versions/$VER.sha256"
[ -f "$CONF" ] || { echo "no $CONF" >&2; exit 1; }
[ -f "$SUMS" ] || { echo "no $SUMS (pin the official sha256 first)" >&2; exit 1; }

TARGET_RUSTFLAGS=""
EXPECT_FP_ABI=""
VARIANT=""
# shellcheck source=/dev/null
. "$CONF"

NAME="reg-rust-std-$VER-$TARGET${VARIANT:+-$VARIANT}"
COMPONENT="rust-std-$TARGET"

for t in curl sha256sum tar xz ar readelf python3; do
	command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

rm -rf "${WORK:?}"
mkdir -p "$WORK" "$OUT" "$DL"

# --- 1. official toolchain, checked against the pinned sha256 ---------------
fetch() {
	local f=$1
	if [ ! -f "$DL/$f" ]; then
		curl -fL --retry 3 -o "$DL/$f.part" "$SITE/$f"
		mv "$DL/$f.part" "$DL/$f"
	fi
	grep -E "^[0-9a-f]{64}  $f\$" "$SUMS" | (cd "$DL" && sha256sum -c -)
}

RUST_TB="rust-$VER-$HOST.tar.xz"
SRC_TB="rust-src-$VER.tar.xz"
fetch "$RUST_TB"
fetch "$SRC_TB"

TC="$WORK/toolchain"
tar -xf "$DL/$RUST_TB" -C "$WORK"
tar -xf "$DL/$SRC_TB" -C "$WORK"
"$WORK/rust-$VER-$HOST/install.sh" --prefix="$TC" --disable-ldconfig \
	--components="rustc,cargo,rust-std-$HOST" >/dev/null
"$WORK/rust-src-$VER/install.sh" --prefix="$TC" --disable-ldconfig >/dev/null

export PATH="$TC/bin:$PATH"
RUSTC_VERSION=$(rustc -vV)
echo "$RUSTC_VERSION"
COMMIT=$(echo "$RUSTC_VERSION" | sed -n 's/^commit-hash: //p')
LIBSRC="$TC/lib/rustlib/src/rust"

# --- 2. REG patches to the std sources, if any --------------------------------
if [ -d "$HERE/patches/$VER" ]; then
	for p in "$HERE/patches/$VER"/*.patch; do
		[ -e "$p" ] || continue
		echo "applying $(basename "$p")"
		patch -d "$LIBSRC" -p1 --no-backup-if-mismatch < "$p"
	done
fi

# --- 3. build std with the official compiler --------------------------------
PROBE="$WORK/probe"
mkdir -p "$PROBE/src"
cat > "$PROBE/Cargo.toml" <<EOF
[package]
name = "reg-std-probe"
version = "0.0.0"
edition = "2021"
publish = false

[lib]
path = "src/lib.rs"

# The profile std is built with (Rust's own dist builds use the same
# opt-level, one codegen unit and line tables).
[profile.release]
opt-level = 3
codegen-units = 1
debug = "line-tables-only"
EOF
echo 'pub fn probe() -> std::string::String { std::format!("{}", 1) }' > "$PROBE/src/lib.rs"

export CARGO_HOME="$WORK/cargo-home"
export CARGO_TARGET_DIR="$WORK/target"
# - embed-bitcode: the crates built against this std may use LTO
# - remap-path-prefix: no build machine paths in the rlibs (the same
#   /rustc/<commit> prefix as the official std), so two builds of one
#   version give the same bytes. The last matching prefix wins: the
#   broad $WORK one comes first.
STD_RUSTFLAGS="$TARGET_RUSTFLAGS -Cembed-bitcode=yes \
	--remap-path-prefix=$WORK=/build \
	--remap-path-prefix=$LIBSRC=/rustc/$COMMIT \
	--remap-path-prefix=$CARGO_HOME=/rust/deps"

(cd "$PROBE" && RUSTC_BOOTSTRAP=1 RUSTFLAGS="$STD_RUSTFLAGS" \
	cargo build --release --target "$TARGET" \
		-Zbuild-std=std,panic_abort,panic_unwind \
		--message-format=json-render-diagnostics) > "$WORK/build.json"

# --- 4. package it like an official rust-std component -----------------------
STAGE="$WORK/stage/rust-std-$VER-$TARGET"
LIBDIR="$STAGE/$COMPONENT/lib/rustlib/$TARGET/lib"
DOCDIR="$STAGE/$COMPONENT/share/doc/$COMPONENT"
mkdir -p "$LIBDIR" "$DOCDIR"

python3 -I "$HERE/scripts/std-artifacts.py" \
	--build-json "$WORK/build.json" \
	--exclude reg-std-probe \
	--libsrc "$LIBSRC" \
	--libdir "$LIBDIR" \
	--docdir "$DOCDIR" \
	--third-party "$OUT/THIRD-PARTY-$VER-$TARGET.md" \
	--title "Rust $VER standard library for $TARGET"

# Rust's own licence and copyright notices (COPYRIGHT-library covers std)
for f in COPYRIGHT LICENSE-APACHE LICENSE-MIT; do
	cp "$WORK/rust-$VER-$HOST/$f" "$DOCDIR/"
done
cp "$WORK/rust-$VER-$HOST/rustc/share/doc/rust/COPYRIGHT-library.html" "$DOCDIR/"
cp "$OUT/THIRD-PARTY-$VER-$TARGET.md" "$DOCDIR/THIRD-PARTY.md"
cat > "$DOCDIR/BUILD-INFO" <<EOF
Built by https://github.com/REG-Linux/REG-rust-std
rust:      $VER ($SITE/$RUST_TB, $SITE/$SRC_TB)
target:    $TARGET
rustflags: $TARGET_RUSTFLAGS
$RUSTC_VERSION
EOF

# The installer is the generic one of the official tarball.
cp "$WORK/rust-$VER-$HOST/install.sh" "$WORK/rust-$VER-$HOST/rust-installer-version" "$STAGE/"
echo "$COMPONENT" > "$STAGE/components"
(cd "$STAGE/$COMPONENT" && find . -type f ! -name manifest.in | sed 's|^\./|file:|' | LC_ALL=C sort) \
	> "$STAGE/$COMPONENT/manifest.in"

# --- 5. checks -----------------------------------------------------------------
"$HERE/scripts/check-fp-abi.sh" "$LIBDIR" "$EXPECT_FP_ABI"

# A crate using std and two crates.io crates that std itself also uses
# (libc, cfg-if) must build on STABLE rustc against the new std only:
# proves the std loads, and that its own copies of those crates do not
# clash with the ones from crates.io.
"$STAGE/install.sh" --prefix="$TC" --disable-ldconfig >/dev/null
CONSUMER="$WORK/consumer"
mkdir -p "$CONSUMER/src"
cat > "$CONSUMER/Cargo.toml" <<EOF
[package]
name = "reg-std-consumer"
version = "0.0.0"
edition = "2021"
publish = false

[dependencies]
libc = "0.2"
cfg-if = "1"
EOF
cat > "$CONSUMER/src/lib.rs" <<'EOF'
use std::collections::HashMap;
cfg_if::cfg_if! {
    if #[cfg(target_os = "linux")] {
        pub fn pid() -> i32 { unsafe { libc::getpid() } }
    }
}
pub fn work(x: f64) -> String {
    let mut m = HashMap::new();
    m.insert("sin", x.sin());
    std::thread::spawn(move || format!("{:?} {}", m, pid())).join().unwrap()
}
EOF
if ! (cd "$CONSUMER" && env -u RUSTC_BOOTSTRAP RUSTFLAGS="$TARGET_RUSTFLAGS" \
	CARGO_TARGET_DIR="$CONSUMER/target" \
	cargo build --release --target "$TARGET") > "$WORK/consumer.log" 2>&1; then
	cat "$WORK/consumer.log" >&2
	echo "consumer crate failed to build against the new std" >&2
	exit 1
fi
ls "$CONSUMER/target/$TARGET/release/libreg_std_consumer.rlib" >/dev/null
echo "consumer crate built on stable rustc against the new std: OK"

# --- 6. deterministic tarball --------------------------------------------------
# Modes are normalised too: the umask differs between machines.
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --mode=a+rX,u+w,go-w \
	-C "$WORK/stage" -cf - "rust-std-$VER-$TARGET" | xz -T1 -9 > "$OUT/$NAME.tar.xz"
(cd "$OUT" && sha256sum "$NAME.tar.xz" > "$NAME.tar.xz.sha256" && cat "$NAME.tar.xz.sha256")
