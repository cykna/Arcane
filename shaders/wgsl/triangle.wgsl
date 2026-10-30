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
var<uniform> camera: package_camera_Camera;

@vertex
fn vs_main(input: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    let world_position = vec4(input.position, 1.0);
    out.position = camera.view_projection * world_position;
    out.color = input.color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4f {
    return in.color;
}

struct package_camera_Camera {
    view: mat4x4<f32>,
    projection: mat4x4<f32>,
    view_projection: mat4x4<f32>,
    inverse_view_projection: mat4x4<f32>
}

