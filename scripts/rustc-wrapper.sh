#!/bin/sh
# RUSTC_WRAPPER for the std build. Rust's own build compiles
# compiler_builtins with panic=abort in its rustc wrapper
# (src/bootstrap/src/bin/rustc.rs), not through the library workspace's
# profile; do the same. (panic_abort gets panic=abort from that profile,
# which build.sh copies into the probe crate.)
rustc=$1
shift
case " $* " in
*" --crate-name compiler_builtins "*)
	exec "$rustc" "$@" -C panic=abort ;;
esac
exec "$rustc" "$@"
