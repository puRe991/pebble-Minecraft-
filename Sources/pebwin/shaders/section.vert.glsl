// Section vertex shader (skeleton) for the SDL_gpu backend.
// Compile to SPIR-V and place section.vert.spv beside the executable:
//   glslc -fshader-stage=vert section.vert.glsl -o section.vert.spv
//
// SDL_gpu's SPIR-V resource model: vertex uniform buffers live in descriptor
// set 1 (samplers set 0, etc.). The engine's vertex is 28 bytes:
//   vec3 position (section-local), vec2 uv, uint A, uint B (packed light/normal/…).
#version 450

layout(location = 0) in vec3 inPos;
layout(location = 1) in vec2 inUV;
layout(location = 2) in uint inA;
layout(location = 3) in uint inB;

layout(set = 1, binding = 0) uniform UBO {
    mat4 viewProj;
    vec4 origin;   // section world origin (xyz)
} ubo;

layout(location = 0) out vec2 vUV;
layout(location = 1) out float vLight;

void main() {
    // low byte of A stands in for baked light until A/B are fully decoded
    vLight = 0.35 + 0.65 * float(inA & 0xFFu) / 255.0;
    vUV = inUV;
    gl_Position = ubo.viewProj * vec4(inPos + ubo.origin.xyz, 1.0);
}
