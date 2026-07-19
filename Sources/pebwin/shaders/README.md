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

These are deliberately minimal (flat light, no atlas sampling). The full renderer
mirrors the macOS MSL passes: atlas texture sampling, biome tint, per-vertex AO,
the water/lava/portal animation channel, then the shadow / SSAO / bloom / ACES
stages. See `ARCHITECTURE.md` (Rendering) for the target pipeline.
