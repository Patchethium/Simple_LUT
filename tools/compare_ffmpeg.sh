#!/bin/sh
# Compares simple-lut against ffmpeg's lut3d filter for every interpolation mode.
# Usage: tools/compare_ffmpeg.sh <simple-lut> [image.png] [lut ...]
# Without LUT arguments it checks test/MagicHour.cube and a generated non-linear 65-point LUT.
# Fails when any RGB channel differs by more than 1.
set -eu

tool=$1
shift
image=${1:-test/sample.png}
[ $# -gt 0 ] && shift

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [ $# -eq 0 ]; then
    awk 'BEGIN {
        n = 65; print "TITLE \"curve65\""; print "LUT_3D_INPUT_RANGE 0.0 1.0"; print "LUT_3D_SIZE " n
        for (b = 0; b < n; b++) for (g = 0; g < n; g++) for (r = 0; r < n; r++) {
            R = r / (n - 1); G = g / (n - 1); B = b / (n - 1)
            printf "%.6f %.6f %.6f\n", R ^ 0.8 * 0.9 + B * 0.1, G * G * 0.7 + R * 0.3, sqrt(B) * 0.8 + G * 0.2
        }
    }' > "$work/curve65.cube"
    set -- test/MagicHour.cube "$work/curve65.cube"
fi
status=0
for lut in "$@"; do
    for mode in nearest trilinear tetrahedral; do
        # lut3d parses ':' and '\' in its arguments, so hand it a plain copy of the LUT.
        cp "$lut" "$work/lut.${lut##*.}"
        ffmpeg -loglevel error -y -i "$image" -vf "format=rgb24,lut3d=file=$work/lut.${lut##*.}:interp=$mode" "$work/ffmpeg.png"
        "$tool" "$image" "$lut" "$work/ours.png" "$mode"
        printf '%-40s %-12s ' "$(basename "$lut")" "$mode"
        "$tool" --diff "$work/ffmpeg.png" "$work/ours.png" 1 || status=1
    done
done
exit $status
