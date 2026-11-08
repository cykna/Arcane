const std = @import("std");
const zgpu = @import("zgpu");
const TypeArray = @import("TypeArray.zig").TypeArray;
const ecs = @import("Main.zig");
const World = ecs.World;
const Mesh = @import("../objects/Mesh.zig").Mesh;
const Material = @import("../objects/Material.zig").Material;

pub const ShaderPool = struct {
    pipelines: std.array_hash_map.Auto(ecs.TypeId, zgpu.RenderPipelineHandle) = .empty,
    allocator: std.mem.Allocator,
    const Self = @This();

    pub fn initialize(self: *Self, comptime Shader: type, context: *zgpu.GraphicsContext) !zgpu.RenderPipelineHandle {
        const pipeline = Material(Shader).initPipeline(context, Shader.Source);
        try self.pipelines.put(self.allocator, ecs.typeId(Shader), pipeline);
        return pipeline;
    }

    pub fn deinit(self: *Self) void {
        self.pipelines.deinit();
    }
    pub fn endInstances(self: *Self, comptime Shader: type, context: *zgpu.GraphicsContext) void {
        const pipeline = self.pipelines.get(ecs.typeId(Shader)) orelse return;
        Shader.Pipeline.destroy(context, pipeline);
    }
};

pub const Scene = struct {
    pool: ShaderPool,
};
