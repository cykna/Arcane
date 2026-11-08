const std = @import("std");
const Material = @import("../objects/Material.zig");
const Mesh = @import("../objects/Mesh.zig");

pub fn ShaderContent(comptime Shader: type) type {
    return struct {
        material: Material.Material(Shader),
        mesh: Mesh.Mesh(Shader),

        const Self = @This();
    };
}
