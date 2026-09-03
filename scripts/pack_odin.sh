#!/usr/bin/env bash
# pack_odin.sh — pack a Magisk-patched boot image into an Odin-flashable .tar.md5
# matching the stock Samsung layout (boot.img.lz4 inside the tar).
#
# Usage: ./scripts/pack_odin.sh magisk_patched-30700_BfrBZ.img
# Output: AP_patched_boot.tar.md5 in the current directory.
set -euo pipefail

SRC="${1:?usage: $0 <magisk_patched.img>}"
[[ -f "$SRC" ]] || { echo "error: file not found: $SRC" >&2; exit 1; }
command -v lz4 >/dev/null || { echo "error: lz4 not installed (sudo apt install lz4)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> 1/3  compress to lz4 (legacy format, like stock Samsung)"
# Samsung uses lz4 legacy frame format (-l) for boot.img.lz4
lz4 -l -12 -f "$SRC" "$WORK/boot.img.lz4"
ls -l "$WORK/boot.img.lz4"

echo "==> 2/3  create tar (GNU format, root owner — Odin-compatible)"
tar --format=gnu --owner=0 --group=0 --numeric-owner \
    -cvf "$WORK/AP_patched_boot.tar" -C "$WORK" boot.img.lz4

echo "==> 3/3  append md5 -> .tar.md5"
OUT="$(pwd)/AP_patched_boot.tar.md5"
cp "$WORK/AP_patched_boot.tar" "$OUT"
# Odin expects ONLY the bare 32-char md5 of the tar appended (no filename, no ' *').
md5sum "$OUT" | awk '{print $1}' >> "$OUT"

echo
echo "Done: $OUT"
echo "Flash this file in Odin's AP slot."
