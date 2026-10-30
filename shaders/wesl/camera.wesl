struct Camera {
    view: mat4x4<f32>,
    projection: mat4x4<f32>,
    view_projection: mat4x4<f32>,
    inverse_view_projection: mat4x4<f32>,
}
struct Mesh {
    model: mat4x4<f32>,
    normal_matrix: mat4x4<f32>,
}
