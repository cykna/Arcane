const std = @import("std");
const zgpu = @import("zgpu");
const RenderingContext = @import("../core/RenderingContext.zig").RenderingContext;
const TypeArray = @import("TypeArray.zig").TypeArray;
const ecs = @import("Main.zig");
const World = ecs.World;
const Mesh = @import("../objects/Mesh.zig").Mesh;
const Material = @import("../objects/Material.zig").Material;

pub const ShaderPool = struct {
    pipelines: std.array_hash_map.Auto(ecs.TypeId, zgpu.RenderPipelineHandle) = .empty,
    rendering_context: RenderingContext,
    const Self = @This();

    pub fn initialize(self: *Self, comptime Shader: type) !zgpu.RenderPipelineHandle {
        const pipeline = Material(Shader).initPipeline(self.rendering_context, Shader.Source);
        try self.pipelines.put(self.rendering_context.allocator, ecs.typeId(Shader), pipeline);
        return pipeline;
    }

    pub fn deinit(self: *Self) void {
        self.pipelines.deinit();
    }
    pub fn endInstances(self: *Self, comptime Shader: type) void {
        const pipeline = self.pipelines.get(ecs.typeId(Shader)) orelse return;
        Shader.Pipeline.destroy(self.rendering_context.context, pipeline);
    }
};

pub const Scene = struct {
    pool: ShaderPool,
    const Self = @This();
    pub fn prepareFor(self: *const Self, comptime Shader: type, pass: zgpu.wgpu.RenderPassEncoder) !void {
        const pipeline = self.pool.pipelines.get(ecs.typeId(Shader)) orelse return error.PipelineNotExistant;
        try Shader.Pipeline.bind(self.pool.rendering_context.context, pass, pipeline);
    }
};
