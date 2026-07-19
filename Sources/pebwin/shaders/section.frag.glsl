// Section fragment shader (skeleton) for the SDL_gpu backend.
//   glslc -fshader-stage=frag section.frag.glsl -o section.frag.spv
//
// Flat terrain-ish colour modulated by the baked light. The real shader samples
// the texture atlas (bound as a texture in set 2) and applies biome tint, AO,
// and the animation channel — mirroring the macOS MSL fragment stage.
#version 450

layout(location = 0) in vec2 vUV;
layout(location = 1) in float vLight;
layout(location = 0) out vec4 outColor;

void main() {
    vec3 base = vec3(0.48, 0.56, 0.40);
    outColor = vec4(base * vLight, 1.0);
}
