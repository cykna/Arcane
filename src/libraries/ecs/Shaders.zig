const zgpu = @import("zgpu");
const std = @import("std");
const RenderingContext = @import("../core/RenderingContext.zig").RenderingContext;
const Material = @import("../objects/Material.zig");
const Mesh = @import("../objects/Mesh.zig");

pub fn ShaderContent(comptime Shader: type) type {
    return struct {
        material: Material.Material(Shader),
        mesh: Mesh.Mesh(Shader),

        const Self = @This();
        pub fn draw(self: *const Self, rendering_context: RenderingContext, pass: zgpu.wgpu.RenderPassEncoder) !void {
            try self.material.bind(rendering_context, pass);
            try self.mesh.bind(rendering_context, pass);
            self.mesh.draw(pass);
        }
    };
}
