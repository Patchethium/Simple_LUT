# Simple LUT

Version: see [`VERSION`](VERSION). Changes: see [`CHANGELOG.md`](CHANGELOG.md).

Simple LUT applies 3D `.cube`, `.3dl`, and `.m3d` LUTs with nearest, tetrahedral, or trilinear
interpolation. 8-bit input maps onto the lattice as `x * (size - 1) / 255`, matching ffmpeg's
`lut3d` filter within 1 level. Up to 129-point lattices are supported. `DOMAIN_MIN`/`DOMAIN_MAX`
and `LUT_3D_INPUT_RANGE` remap the input range, and pixels with zero alpha are left untouched.

> **0.5.0 changes the output.** Earlier versions kept the original project's `size / 256` input
> scale, which shifted colors upward and clipped highlights. See the changelog.

## Standalone PNG converter

```sh
zig build
zig build run -- test/sample.png test/MagicHour.cube test/output.png tetrahedral
```

Arguments: `<input.png> <lut> <output.png> [nearest|tetrahedral|trilinear] [strength]`. The
converter requires the system `libpng` development library. `simple-lut --diff a.png b.png [max]`
compares two images.

## Benchmark

Times the multithreaded pixel kernel the plugins use (up to eight workers). PNG decoding and LUT
loading happen before timing starts.

```sh
zig build benchmark
zig build benchmark -- test/sample.png test/MagicHour.cube 50
```

## AviUtl (legacy) script plugin

Build the 32-bit DLL without Visual Studio or MinGW:

```sh
zig build plugin -Doptimize=ReleaseSmall
```

Copy `zig-out/bin/Simple_LUT.dll` and `Simple_LUT.anm` to AviUtl's `script` directory. The DLL
loads `lua51.dll` dynamically and caches parsed LUTs itself, reloading a LUT when the file
changes on disk. Extram is no longer needed. From Lua:

```lua
local ok, err = Simple_LUT.LUT(data, w, h, strength, type, path) -- true, or nil and an error
```

The DLL uses the Universal C Runtime, which is part of Windows 10 and later. On Windows 7 or 8.1,
install the [Universal C Runtime update (KB2999226)](https://support.microsoft.com/kb/2999226)
first.

## AviUtl2 native filter

```sh
zig build aviutl2 -Doptimize=ReleaseSmall
```

Copy `zig-out/bin/Simple_LUT.auf2` to the `Plugin` folder inside AviUtl2's data folder, then
restart AviUtl2:

- Installed version: `C:\ProgramData\aviutl2\Plugin`
- Portable version (a `data` folder next to `aviutl2.exe`): `data\Plugin`. A `Plugin` folder next
  to `aviutl2.exe` itself is not scanned.

Alternatively, drag the `.auf2` onto AviUtl2's preview window to install it into the right folder.

The filter provides a LUT file picker, strength, and interpolation controls. It caches up to four LUTs and opens paths with
wide-character APIs, so non-ASCII folder names work.

## Testing

| Command | What it checks |
| --- | --- |
| `zig build test` | Parsers (identity LUTs of several sizes and bit depths, malformed files, `DOMAIN`), the pixel kernel, and the cache. Leaks fail the tests. |
| `zig build golden` | Output against ffmpeg's `lut3d` for every mode (needs `ffmpeg`). Pass LUTs after `--` to check more. |
| `LUA51_DLL=<aviutl>/lua51.dll tools/run_harness.sh` | Loads the real `.auf2` and `.dll` (the latter through AviUtl's Lua) under Wine, or natively on Windows, from an ASCII and a Japanese-named directory. |
| `zig build sdk-check` | `aviutl2_layout.zig` against the AviUtl2 SDK headers (default `../aviutl2_sdk`, or `-Daviutl2-sdk=<dir>`; needs Wine off Windows). `aviutl2.zig` asserts these layouts at compile time. |

CI (`.github/workflows/ci.yml`) runs the tests and the ffmpeg comparison on Linux, and the
harnesses on Windows.

Before a release, also check by hand in real AviUtl and AviUtl2 under Wine, then on a Windows VM:
the file picker, saving and reopening a project, two objects with different LUTs, and editing a
LUT on disk while it is in use.

## License

Simple LUT 0.4.0 and later is a complete rewrite of the original ffmpeg implementation, which
follows the [LGPLv2.1 license](./LICENSE).

Versions before 0.4.0 are based on the implementation
[here](https://github.com/cpuimage/FFmpeg_Lut3D/), which follows the GPLv2.1 license.
