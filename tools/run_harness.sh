#!/bin/sh
# Builds the plugins and the Windows harnesses, then runs them (under wine off Windows), once
# from an ASCII directory and once from a Japanese-named one.
# Usage: LUA51_DLL=/path/to/aviutl/lua51.dll tools/run_harness.sh [lut]
# Without LUA51_DLL the legacy plugin harness is skipped.
set -eu

lut=${1:-test/MagicHour.cube}
zig build harness
case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) run() { "$@"; }; winpath() { cygpath -w "$1"; } ;;
    *) export WINEDEBUG=-all; run() { wine "$@"; }; winpath() { winepath -w "$1"; } ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0
for name in ascii テスト用LUT; do
    dir="$work/$name"
    mkdir -p "$dir"
    cp zig-out/bin/Simple_LUT.auf2 zig-out/bin/Simple_LUT.dll "$dir/"
    cp "$lut" "$dir/色補正.${lut##*.}"
    win_lut=$(winpath "$dir/色補正.${lut##*.}")
    echo "== AviUtl2 filter from $name"
    run zig-out/harness/aviutl2_harness.exe "$(winpath "$dir/Simple_LUT.auf2")" "$win_lut" || status=1
    if [ -n "${LUA51_DLL:-}" ]; then
        echo "== legacy plugin from $name"
        # AviUtl 1.x passes paths in the ANSI code page, so run in a Japanese locale (CP932).
        # The harness skips paths the code page cannot spell (e.g. on an English Windows runner).
        LC_ALL=ja_JP.UTF-8 run zig-out/harness/legacy_harness.exe "$(winpath "$LUA51_DLL")" "$(winpath "$dir")" "$win_lut" || status=1
    else
        echo "== legacy plugin skipped (set LUA51_DLL)"
    fi
done
exit $status
