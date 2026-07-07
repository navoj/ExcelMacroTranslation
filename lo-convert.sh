#!/usr/bin/env bash
#
# lo-convert.sh - Headless LibreOffice document converter.
#
# WHY THIS EXISTS
#   On this Wayland host the distro/deb LibreOffice (/usr/bin/soffice,
#   v25.8) fails every headless conversion with "source file could not be
#   loaded" (a broken X11/Wayland VCL backend). The snap build
#   (/snap/bin/libreoffice) bundles its own GUI libraries and works headless,
#   but it is strictly confined: it can only read files under $HOME (non-
#   hidden) and /media, and it has a PRIVATE /tmp it cannot share with us.
#
#   This wrapper hides those quirks: it always uses the working snap build and
#   stages the input/output through a non-hidden, snap-accessible work area
#   under $HOME, so callers can convert files that live anywhere (including
#   /tmp and hidden dirs).
#
# USAGE
#   lo-convert.sh <input-file> [format] [output-dir]
#     format      LibreOffice target filter (default: xlsx). May be a bare
#                 extension ("csv", "pdf") or "ext:Filter Name".
#     output-dir  Destination directory (default: the input file's directory).
#
# EXAMPLES
#   lo-convert.sh book.xls                 # -> book.xlsx beside the input
#   lo-convert.sh book.xls csv .           # -> ./book.csv
#   lo-convert.sh /tmp/x.xls xlsx /out/dir # stages /tmp, writes /out/dir/x.xlsx
#
# On success the absolute path of the converted file is printed to stdout.
#
set -euo pipefail

LO_BIN="${LO_BIN:-/snap/bin/libreoffice}"

die() { echo "lo-convert: $*" >&2; exit 1; }
usage() { echo "Usage: $0 <input-file> [format=xlsx] [output-dir]" >&2; exit 2; }

[ $# -ge 1 ] || usage
[ -x "$LO_BIN" ] || die "snap LibreOffice not found at $LO_BIN (set LO_BIN=...)"

IN="$1"; FMT="${2:-xlsx}"
[ -f "$IN" ] || die "input file not found: $IN"

IN_ABS="$(readlink -f "$IN")"
IN_BASE="$(basename "$IN_ABS")"
STEM="${IN_BASE%.*}"
EXT="${FMT%%:*}"                       # extension part of a "ext:Filter" spec
OUT_DIR="${3:-$(dirname "$IN_ABS")}"
mkdir -p "$OUT_DIR"
OUT_DIR_ABS="$(readlink -f "$OUT_DIR")"

# Non-hidden, snap-accessible staging + a persistent profile (faster reuse).
WORK_ROOT="$HOME/lo-convert-work"
PROFILE="$WORK_ROOT/profile"
STAGE="$WORK_ROOT/stage.$$"
mkdir -p "$PROFILE" "$STAGE"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

cp -f "$IN_ABS" "$STAGE/$IN_BASE"

# Force the headless "svp" backend and a dedicated profile so we never collide
# with an interactive session. Snap bundles its libs, so Wayland is a non-issue.
SAL_USE_VCLPLUGIN=svp "$LO_BIN" --headless --norestore --nologo --nolockcheck \
  -env:UserInstallation="file://$PROFILE" \
  --convert-to "$FMT" --outdir "$STAGE" "$STAGE/$IN_BASE" \
  > "$STAGE/.convert.log" 2>&1 || true

OUT_NAME="$STEM.$EXT"
if [ ! -f "$STAGE/$OUT_NAME" ]; then
  echo "lo-convert: conversion failed for: $IN" >&2
  # Surface any real error lines, hiding the harmless snap library warnings.
  grep -viE 'libpxbackend|gio-modules|gdk-pixbuf|libpixbufloader|Schema .* has path|g_module_open|Warning:' \
    "$STAGE/.convert.log" >&2 || true
  exit 1
fi

mv -f "$STAGE/$OUT_NAME" "$OUT_DIR_ABS/$OUT_NAME"
echo "$OUT_DIR_ABS/$OUT_NAME"
