# Changelog

## 0.5.0

### Behavior changes

- **LUT input mapping fixed.** 8-bit input now maps onto the lattice as `x * (size - 1) / 255`,
  so 0 and 255 land exactly on the first and last lattice points. The previous `size / 256`
  scale (inherited from the original project) shifted every color upward and flattened
  highlights from about 248 up; an identity LUT moved mid-grey 128 to about 131. Output now
  matches ffmpeg's `lut3d` within 1 level. Projects graded with 0.4.x will look slightly
  different.
- `DOMAIN_MIN`/`DOMAIN_MAX` (and Resolve's `LUT_3D_INPUT_RANGE`) now remap the input range
  instead of scaling the output, as the `.cube` spec describes.
- Strength blending is done in float and rounded once.

### Fixes

- Failed LUT loads no longer leak the ~3 MB table.
- `.3dl`: the shaper/mesh line is no longer read as the first color, lattice size and output bit
  depth (10/12/16-bit) are detected instead of assuming 17 points and 12 bits, and `3DMESH`/`Mesh`
  headers are understood.
- `.cube`: 65-point LUTs (Resolve's default) are accepted (up to 129 points), unknown keywords are
  ignored, and 1D LUTs are rejected with a clear error.
- `.m3d`: arbitrary `values` column orders are honored.
- AviUtl2: LUT paths with non-ASCII characters (e.g. Japanese folder names) now open, using
  wide-character Windows APIs.
- Worker threads on Windows no longer panic under Wine.

### AviUtl (legacy) plugin

- Parsed LUTs are cached inside the DLL (4 entries, reloaded when the file changes on disk); the
  Extram dependency is gone.
- `Simple_LUT.LUT(data, w, h, strength, type, path)` returns `true`, or `nil` and an error
  message. `getBuffer` was removed. `getDir` returns AviUtl's directory rather than the current
  directory.
- `Simple_LUT.anm`: the unused `AMP` track was removed, and files without an extension no longer
  raise an error.

### AviUtl2 filter

- The single-slot cache was replaced with a locked 4-entry cache, so several objects with
  different LUTs no longer reparse every frame.
- Struct layouts are checked against the SDK headers at compile time.

### Development

- `zig build test`, `zig build golden` (ffmpeg comparison), `zig build harness` plus
  `tools/run_harness.sh` (Windows/Wine plugin harnesses), `zig build sdk-check`, and GitHub
  Actions CI.
- The PNG tool, benchmark, and both plugins share one parser and one pixel kernel.
