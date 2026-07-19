// Translucent fragment shader for the SDL_gpu backend (water/glass pass).
//   glslc -fshader-stage=frag section_blend.frag.glsl -o section_blend.frag.spv
//
// Like section.frag but keeps alpha for blending instead of discarding — the
// translucent pipeline draws with SRC_ALPHA / ONE_MINUS_SRC_ALPHA and no depth
// write. A fixed transparency stands in until per-material alpha is plumbed
// through the vertex format.
#version 450

layout(location = 0) in vec2 vUV;
layout(location = 1) flat in uint vTile;
layout(location = 2) in vec3 vTint;
layout(location = 3) in float vLight;

layout(set = 2, binding = 0) uniform sampler2DArray atlas;

layout(location = 0) out vec4 outColor;

void main() {
    vec4 texel = texture(atlas, vec3(fract(vUV), float(vTile)));
    outColor = vec4(texel.rgb * vTint * vLight, texel.a * 0.6);
}
