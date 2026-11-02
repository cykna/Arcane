struct VertexInput {
    @location(0)
    position: vec3f,
    @location(1)
    color: vec4f
}

struct VertexOutput {
    @builtin(position)
    position: vec4f,
    @location(0)
    color: vec4f
}

@binding(0) @group(0)
var<uniform> camera: package_globals_Camera;

@binding(0) @group(1)
var<storage, read> instances: array<package_globals_MeshData>;

@vertex
fn vs_main(input: VertexInput, @builtin(instance_index) index: u32) -> VertexOutput {
    var out: VertexOutput;
    let world_position = vec4(input.position, 1.0);
    out.position = camera.view_projection * instances[index].model * world_position;
    out.color = input.color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    return in.color;
}

struct package_globals_Camera {
    view: mat4x4<f32>,
    projection: mat4x4<f32>,
    view_projection: mat4x4<f32>,
    inverse_view_projection: mat4x4<f32>
}

struct package_globals_MeshData {
    model: mat4x4<f32>,
    normal_matrix: mat4x4<f32>
}

