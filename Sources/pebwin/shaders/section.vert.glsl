// Section vertex shader for the SDL_gpu backend.
//   glslc -fshader-stage=vert section.vert.glsl -o section.vert.spv
//
// SDL_gpu SPIR-V resource model: vertex uniform buffers are in descriptor set 1.
// The engine's 28-byte vertex: vec3 pos, vec2 uv, uint A, uint B.
//   A: tile[0..11] normal[12..14] ao[15..16] sky[17..20] blk[21..24] emissive[25]
//   B: tint 0xRRGGBB [0..23] anim [24..31]
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
layout(location = 1) flat out uint vTile;
layout(location = 2) out vec3 vTint;
layout(location = 3) out float vLight;

void main() {
    uint tile = inA & 0xFFFu;
    uint ao   = (inA >> 15) & 3u;
    uint sky  = (inA >> 17) & 15u;
    uint blk  = (inA >> 21) & 15u;
    float light = max(float(sky), float(blk)) / 15.0;
    vLight = (0.25 + 0.75 * light) * (1.0 - float(ao) * 0.15);
    vTile  = tile;
    vTint  = vec3(float((inB >> 16) & 0xFFu), float((inB >> 8) & 0xFFu), float(inB & 0xFFu)) / 255.0;
    vUV    = inUV;
    gl_Position = ubo.viewProj * vec4(inPos + ubo.origin.xyz, 1.0);
}
