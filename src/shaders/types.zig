// Generated canonical WESL types. Do not edit by hand.
const shared = @import("shared.zig");
pub const VertexInput = extern struct {
    _alignment: [0]u8 align(16)=.{},
    position: shared.WgslVec3f32 align(16),
    _padding_0: [4]u8,
    color: shared.WgslVec4f32 align(16),

    pub fn init(position: shared.WgslVec3f32, color: shared.WgslVec4f32) @This() {
        return .{
            ._alignment = .{},
            .position = position,
            ._padding_0 = .{ 0, 0, 0, 0 },
            .color = color,
        };
    }
};
pub const VertexOutput = extern struct {
    _alignment: [0]u8 align(16)=.{},
    position: shared.WgslVec4f32 align(16),
    color: shared.WgslVec4f32 align(16),

    pub fn init(position: shared.WgslVec4f32, color: shared.WgslVec4f32) @This() {
        return .{
            ._alignment = .{},
            .position = position,
            .color = color,
        };
    }
};
pub const Camera = extern struct {
    _alignment: [0]u8 align(16)=.{},
    view: shared.WgslMat4x4f32 align(16),
    projection: shared.WgslMat4x4f32 align(16),
    view_projection: shared.WgslMat4x4f32 align(16),
    inverse_view_projection: shared.WgslMat4x4f32 align(16),

    pub fn init(view: shared.WgslMat4x4f32, projection: shared.WgslMat4x4f32, view_projection: shared.WgslMat4x4f32, inverse_view_projection: shared.WgslMat4x4f32) @This() {
        return .{
            ._alignment = .{},
            .view = view,
            .projection = projection,
            .view_projection = view_projection,
            .inverse_view_projection = inverse_view_projection,
        };
    }
};
pub const MeshData = extern struct {
    _alignment: [0]u8 align(16)=.{},
    model: shared.WgslMat4x4f32 align(16),
    normal_matrix: shared.WgslMat4x4f32 align(16),

    pub fn init(model: shared.WgslMat4x4f32, normal_matrix: shared.WgslMat4x4f32) @This() {
        return .{
            ._alignment = .{},
            .model = model,
            .normal_matrix = normal_matrix,
        };
    }
};


pub const type_layouts = [_]shared.WgslTypeLayout{
    .{ .id = "ct0", .name = "VertexInput", .size = 32, .alignment = 16, .array_stride = null, .array_length = null },
    .{ .id = "ct1", .name = "VertexOutput", .size = 32, .alignment = 16, .array_stride = null, .array_length = null },
    .{ .id = "ct2", .name = "Camera", .size = 256, .alignment = 16, .array_stride = null, .array_length = null },
    .{ .id = "ct3", .name = "MeshData", .size = 128, .alignment = 16, .array_stride = null, .array_length = null },
};


comptime {
    if (@sizeOf(VertexInput) != 32) @compileError("anygpu layout mismatch: generated type size does not match the schema");
    if (@alignOf(VertexInput) != 16) @compileError("anygpu layout mismatch: generated type alignment does not match the schema");
    if (@offsetOf(VertexInput, "position") != 0) @compileError("anygpu layout mismatch: generated field offset does not match the schema");
    if (@offsetOf(VertexInput, "color") != 16) @compileError("anygpu layout mismatch: generated field offset does not match the schema");
    if (@sizeOf(VertexOutput) != 32) @compileError("anygpu layout mismatch: generated type size does not match the schema");
    if (@alignOf(VertexOutput) != 16) @compileError("anygpu layout mismatch: generated type alignment does not match the schema");
    if (@offsetOf(VertexOutput, "position") != 0) @compileError("anygpu layout mismatch: generated field offset does not match the schema");
    if (@offsetOf(VertexOutput, "color") != 16) @compileError("anygpu layout mismatch: generated field offset does not match the schema");
    if (@sizeOf(Camera) != 256) @compileError("anygpu layout mismatch: generated type size does not match the schema");
    if (@alignOf(Camera) != 16) @compileError("anygpu layout mismatch: generated type alignment does not match the schema");
    if (@offsetOf(Camera, "view") != 0) @compileError("anygpu layout mismatch: generated field offset does not match the schema");
    if (@offsetOf(Camera, "projection") != 64) @compileError("anygpu layout mismatch: generated field offset does not match the schema");
    if (@offsetOf(Camera, "view_projection") != 128) @compileError("anygpu layout mismatch: generated field offset does not match the schema");
    if (@offsetOf(Camera, "inverse_view_projection") != 192) @compileError("anygpu layout mismatch: generated field offset does not match the schema");
    if (@sizeOf(MeshData) != 128) @compileError("anygpu layout mismatch: generated type size does not match the schema");
    if (@alignOf(MeshData) != 16) @compileError("anygpu layout mismatch: generated type alignment does not match the schema");
    if (@offsetOf(MeshData, "model") != 0) @compileError("anygpu layout mismatch: generated field offset does not match the schema");
    if (@offsetOf(MeshData, "normal_matrix") != 64) @compileError("anygpu layout mismatch: generated field offset does not match the schema");
    _ = type_layouts;
}
