#!/bin/bash
#
# check-fp-abi.sh <libdir> [<expected readelf -A "FP ABI" value>]
#
# Every object of core and std must carry the expected FP ABI. Fails if
# rustc ignored the target-feature flags (it only warns about them).

set -euo pipefail
LIBDIR=$1
EXPECT=${2:-}

if [ -z "$EXPECT" ]; then
	echo "FP ABI: no expectation for this target, skipped"
	exit 0
fi

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
bad=0
for lib in "$LIBDIR"/libcore-*.rlib "$LIBDIR"/libstd-*.rlib; do
	rm -f "$T"/*
	(cd "$T" && ar x "$lib")
	for o in "$T"/*.o; do
		got=$(LC_ALL=C readelf -A "$o" | sed -n 's/^ *FP ABI: *//p')
		if [ "$got" != "$EXPECT" ]; then
			echo "FP ABI mismatch: $(basename "$lib")/$(basename "$o"): '$got', expected '$EXPECT'" >&2
			bad=1
		fi
	done
done
[ $bad -eq 0 ] || exit 1
echo "FP ABI of core and std: $EXPECT: OK"
