// Section fragment shader for the SDL_gpu backend.
//   glslc -fshader-stage=frag section.frag.glsl -o section.frag.spv
//
// Samples the texture atlas (a 2-D array texture, one 16×16 layer per tile) at
// the tile-local UV (wrapped with fract for greedy-merged quads) and applies the
// baked biome tint and light. SDL_gpu SPIR-V: fragment samplers are in set 2.
#version 450

layout(location = 0) in vec2 vUV;
layout(location = 1) flat in uint vTile;
layout(location = 2) in vec3 vTint;
layout(location = 3) in float vLight;

layout(set = 2, binding = 0) uniform sampler2DArray atlas;

layout(location = 0) out vec4 outColor;

void main() {
    vec4 texel = texture(atlas, vec3(fract(vUV), float(vTile)));
    if (texel.a < 0.5) discard;
    outColor = vec4(texel.rgb * vTint * vLight, 1.0);
}
