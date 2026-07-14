# Simple LUT

Version: see [`VERSION`](VERSION).

This Zig implementation applies 3D `.cube`, `.3dl`, and `.m3d` LUTs with nearest, tetrahedral, or
trilinear interpolation. It preserves the original project's `lutsize / 256`
input scale, red-first `.cube` storage order, transparent-pixel handling, and
saturates output channels to avoid overflow artifacts.

## Standalone PNG converter

```sh
zig build
zig build run -- test/sample.png test/MagicHour.cube test/output.png tetrahedral
```

The interpolation argument is optional and defaults to `tetrahedral`. The LUT
argument may be a `.cube`, `.3dl`, or `.m3d` file. The converter requires the
system `libpng` development library.

## Benchmark

The benchmark measures the DLL-equivalent multithreaded pixel interpolation
loop. PNG decoding and LUT loading finish before timing begins. It uses up to
eight CPU workers, defaults to `test/` inputs, and runs 10 iterations.

```sh
zig build benchmark
zig build benchmark -- test/sample.png test/MagicHour.cube 50
```

## AviUtl (legacy) script plugin

Build the 32-bit DLL without Visual Studio or MinGW:

```sh
zig build plugin -Doptimize=ReleaseSmall
```

Copy `zig-out/bin/Simple_LUT.dll` and `Simple_LUT.lua` to AviUtl's `script`
directory. The DLL exports `luaopen_Simple_LUT`, dynamically loads `lua51.dll`,
and supports `.cube`, `.3dl`, and `.m3d` LUT files through `LUT`, `getBuffer`,
and `getDir`.
Images with at least 65,536 pixels use up to eight CPU threads.

## AviUtl2 native filter

Build the native 64-bit `.auf2` filter with no Lua bridge:

```sh
zig build aviutl2 -Doptimize=ReleaseSmall
```

Copy `zig-out/bin/Simple_LUT.auf2` to AviUtl2's `Plugin` directory. The filter
provides a `.cube`, `.3dl`, and `.m3d` file picker, strength, and nearest/tetrahedral/trilinear
controls. It caches the selected LUT and processes AviUtl2 SDK RGBA frame
buffers directly.

## License

Simple LUT 0.4.0 is a complete rewrite out of the original ffmpeg implementation, which follows the LGPLv2.1 license.

Versions before 0.4.0 are based on the implementation [here](https://github.com/cpuimage/FFmpeg_Lut3D/), which follows GPLv2.1 license.