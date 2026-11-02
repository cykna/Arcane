// Generated from anygpu JSON. Do not edit by hand.
const shared = @import("shared.zig");
const canonical = @import("types.zig");
pub const Type_8 = extern struct {
    _alignment: [0]u8 align(16) = .{},
    items: [0]canonical.MeshData,
};

pub const array_package_globals_MeshData_ = Type_8;
pub const package_triangle_VertexInput = canonical.VertexInput;
pub const VertexInput = canonical.VertexInput;
pub const package_triangle_VertexOutput = canonical.VertexOutput;
pub const VertexOutput = canonical.VertexOutput;
pub const package_globals_Camera = canonical.Camera;
pub const Camera = canonical.Camera;
pub const package_globals_MeshData = canonical.MeshData;
pub const MeshData = canonical.MeshData;

pub const type_layouts = [_]shared.WgslTypeLayout{
    .{ .id = "t4", .name = "array<package_globals_MeshData>", .size = null, .alignment = 16, .array_stride = 128, .array_length = null },
};

pub const bindings = [_]shared.Binding{
    .{ .group = 0, .binding = 0, .name = "camera", .kind = .buffer, .address_space = .uniform, .access = .read, .visibility = .{ .vertex = true, .fragment = false, .compute = false}, .count = null, .resource_type = .uniform, .read_only = null, .sampler_type = null, .sample_type = null, .filterable = null, .view_dimension = null, .multisampled = null, .storage_access = null, .format = null, .has_dynamic_offset = false, .min_binding_size = 256, .ty = canonical.Camera },
    .{ .group = 1, .binding = 0, .name = "instances", .kind = .buffer, .address_space = .storage, .access = .read, .visibility = .{ .vertex = true, .fragment = false, .compute = false}, .count = null, .resource_type = .storage, .read_only = .load, .sampler_type = null, .sample_type = null, .filterable = null, .view_dimension = null, .multisampled = null, .storage_access = null, .format = null, .has_dynamic_offset = false, .min_binding_size = 128, .ty = canonical.MeshData },
};

pub const group_indices = [_]u32{0, 1};

pub const group_bindings = [_][]const shared.Binding{
    bindings[0..1],
    bindings[1..2],
};

pub fn bindingsOfGroup(comptime group: u32) []const shared.Binding {
    inline for (group_indices, 0..) |candidate, index| {
        if (group == candidate) return group_bindings[index];
    }
    @compileError("unknown bind group");
}

const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
pub const VertexStreamInput = struct {
    field_name: []const u8,
    element_type: type,
    location: u32,
    step_mode: wgpu.VertexStepMode = .vertex,
};

pub const vertex_inputs = [_]VertexStreamInput{
    .{ .field_name = "position", .element_type = [3]f32, .location = 0 },
    .{ .field_name = "color", .element_type = [4]f32, .location = 1 },
};

pub const Pipeline = struct {
    pub const present = true;
    pub const bind_group_count = 2;
    pub const bind_group_indices = [_]u32{0, 1};
    pub const vertex_entry_point: ?[:0]const u8 = "vs_main";
    pub const vertex_constants = [_]shared.PipelineConstant{
    };
    pub const vertex_zero_initialize_workgroup_memory = false;
    pub const fragment_entry_point: ?[:0]const u8 = "fs_main";
    pub const fragment_constants = [_]shared.PipelineConstant{
    };
    pub const fragment_zero_initialize_workgroup_memory = false;
    pub const compute_entry_point: ?[:0]const u8 = null;
    pub const compute_constants = [_]shared.PipelineConstant{
    };
    pub const compute_zero_initialize_workgroup_memory = false;
    pub const push_constant_ranges = [_]shared.PushConstantRange{
    };
    const vertex_attributes_0 = [_]wgpu.VertexAttribute{
        .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
        .{ .format = .float32x4, .offset = 16, .shader_location = 1 },
    };
    pub const vertex_buffer_layouts = [_]wgpu.VertexBufferLayout{
        .{ .array_stride = 32, .step_mode = .vertex, .attribute_count = 2, .attributes = &vertex_attributes_0 },
    };
    pub const CreateOptions = struct {
        color_format: wgpu.TextureFormat = zgpu.GraphicsContext.swapchain_format,
        primitive: wgpu.PrimitiveState = .{},
        layout: zgpu.PipelineLayoutHandle = .{},
    };

    pub fn create(gctx: *zgpu.GraphicsContext, source: [:0]const u8) zgpu.RenderPipelineHandle {
        return createWithOptions(gctx, source, .{});
    }

    pub fn createWithOptions(
        gctx: *zgpu.GraphicsContext,
        source: [:0]const u8,
        options: CreateOptions,
    ) zgpu.RenderPipelineHandle {
        return createWithVertexLayoutsAndOptions(gctx, source, &vertex_buffer_layouts, options);
    }

    pub fn createWithVertexLayouts(
        gctx: *zgpu.GraphicsContext,
        source: [:0]const u8,
        layouts: []const wgpu.VertexBufferLayout,
    ) zgpu.RenderPipelineHandle {
        return createWithVertexLayoutsAndOptions(gctx, source, layouts, .{});
    }

    pub fn createWithVertexLayoutsAndLayout(
        gctx: *zgpu.GraphicsContext,
        source: [:0]const u8,
        layouts: []const wgpu.VertexBufferLayout,
        layout: zgpu.PipelineLayoutHandle,
    ) zgpu.RenderPipelineHandle {
        return createWithVertexLayoutsAndOptions(gctx, source, layouts, .{ .layout = layout });
    }

    pub fn createWithVertexLayoutsAndOptions(
        gctx: *zgpu.GraphicsContext,
        source: [:0]const u8,
        layouts: []const wgpu.VertexBufferLayout,
        options: CreateOptions,
    ) zgpu.RenderPipelineHandle {
        const shader = zgpu.createWgslShaderModule(gctx.device, source, null);
        defer shader.release();
        const color_targets = [_]wgpu.ColorTargetState{.{
            .format = options.color_format,
        }};
        const fragment = wgpu.FragmentState{
            .module = shader,
            .entry_point = fragment_entry_point.?,
            .target_count = color_targets.len,
            .targets = &color_targets,
        };
        const descriptor = wgpu.RenderPipelineDescriptor{
            .layout = null,
            .vertex = .{
                .module = shader,
                .entry_point = vertex_entry_point.?,
                .buffer_count = layouts.len,
                .buffers = if (layouts.len == 0) null else layouts.ptr,
            },
            .primitive = options.primitive,
            .fragment = &fragment,
        };
        return gctx.createRenderPipeline(options.layout, descriptor);
    }

    pub fn bind(
        gctx: *zgpu.GraphicsContext,
        pass: wgpu.RenderPassEncoder,
        handle: zgpu.RenderPipelineHandle,
    ) error{InvalidPipelineHandle}!void {
        const pipeline = gctx.lookupResource(handle) orelse return error.InvalidPipelineHandle;
        pass.setPipeline(pipeline);
    }

    pub fn destroy(gctx: *zgpu.GraphicsContext, handle: zgpu.RenderPipelineHandle) void {
        gctx.releaseResource(handle);
    }
};

comptime {
    _ = bindings;
    _ = Pipeline;
    if (@alignOf(Type_8) != 16) @compileError("anygpu layout mismatch: generated type alignment does not match the schema");
    for (bindings) |binding| {
        const minimum = binding.min_binding_size orelse continue;
        if ((minimum == 32) or (minimum == 32) or (minimum == 256) or (minimum == 128) or (minimum == 12) or (minimum == 16) or (minimum == 64) or (minimum == 4) or (minimum == 128)) {} else @compileError("anygpu binding min_binding_size does not match any reflected type size or runtime array stride");
    }
}
