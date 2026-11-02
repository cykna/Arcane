import package::globals::{Camera, MeshData};
struct VertexInput {
    @location(0) position: vec3f,
    @location(1) color: vec4f
}

struct VertexOutput {
    @builtin(position) position: vec4f,
    @location(0) color: vec4f,
}

@binding(0) @group(0) var<uniform> camera: Camera;
@binding(0) @group(1) var<storage, read> instances: array<MeshData>;

@vertex
fn vs_main(input: VertexInput, @builtin(instance_index) index: u32) -> VertexOutput {
    var out: VertexOutput;
    // O WebGPU exige vec4f para posições. Z = 0.0, W = 1.0 para 2D.
    let world_position = vec4(input.position, 1.0);
    out.position = camera.view_projection * instances[index].model * world_position;
    out.color = input.color;

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    // O pipeline rasteriza o triângulo interpolando automaticamente as cores
    return in.color;
}
