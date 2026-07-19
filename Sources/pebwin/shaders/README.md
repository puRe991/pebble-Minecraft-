# pebwin GPU shaders

The SDL_gpu GPU backend (`GPURenderer.swift`, built with `PEBBLE_GPU=1`) loads
compiled shader bytecode at runtime — `section.vert.spv` and `section.frag.spv`
next to the executable. SDL_gpu accepts SPIR-V (Vulkan), DXIL (D3D12), or MSL
(Metal); this skeleton targets SPIR-V.

Compile with the Vulkan SDK's `glslc`:

```sh
glslc -fshader-stage=vert section.vert.glsl       -o section.vert.spv
glslc -fshader-stage=frag section.frag.glsl       -o section.frag.spv
glslc -fshader-stage=frag section_blend.frag.glsl -o section_blend.frag.spv   # translucent pass
# then run pebwin from a directory containing the .spv files
```

CI compiles all three shaders (`glslangValidator`, in the `gpu-compile` job) to
verify they translate, and uploads the `.spv` set as the `pebwin-shaders-spv`
artifact — so you can grab prebuilt bytecode instead of installing a compiler.

The shaders sample the atlas (a 2-D array texture) and apply the baked light and
biome tint. The full renderer
mirrors the macOS MSL passes: atlas texture sampling, biome tint, per-vertex AO,
the water/lava/portal animation channel, then the shadow / SSAO / bloom / ACES
stages. See `ARCHITECTURE.md` (Rendering) for the target pipeline.
