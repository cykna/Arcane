// Generated from anygpu JSON. Do not edit by hand.
const shared = @import("shared.zig");
pub const VertexInput = extern struct {
    _alignment: [0]u8 align(16),
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
    _alignment: [0]u8 align(16),
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
pub const package_camera_Camera = extern struct {
    _alignment: [0]u8 align(16),
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


pub const type_layouts = [_]shared.WgslTypeLayout{
    .{ .id = "t0", .name = "VertexInput", .size = 32, .alignment = 16, .array_stride = null, .array_length = null },
    .{ .id = "t1", .name = "VertexOutput", .size = 32, .alignment = 16, .array_stride = null, .array_length = null },
    .{ .id = "t2", .name = "package_camera_Camera", .size = 256, .alignment = 16, .array_stride = null, .array_length = null },
};

pub const bindings = [_]shared.Binding{
    .{ .group = 0, .binding = 0, .name = "camera", .kind = .buffer, .visibility = &.{}, .count = null, .resource_type = .uniform, .read_only = null, .sampler_type = null, .sample_type = null, .filterable = null, .view_dimension = null, .multisampled = null, .storage_access = null, .format = null, .has_dynamic_offset = false, .min_binding_size = null },
};

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
    pub const bind_group_count = 1;
    pub const bind_group_indices = [_]u32{0};
    pub const vertex_entry_point: ?[]const u8 = "vs_main";
    pub const vertex_constants = [_]shared.PipelineConstant{
    };
    pub const vertex_zero_initialize_workgroup_memory = false;
    pub const fragment_entry_point: ?[]const u8 = "fs_main";
    pub const fragment_constants = [_]shared.PipelineConstant{
    };
    pub const fragment_zero_initialize_workgroup_memory = false;
    pub const compute_entry_point: ?[]const u8 = null;
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
            .entry_point = "fs_main",
            .target_count = color_targets.len,
            .targets = &color_targets,
        };
        const descriptor = wgpu.RenderPipelineDescriptor{
            .layout = null,
            .vertex = .{
                .module = shader,
                .entry_point = "vs_main",
                .buffer_count = layouts.len,
                .buffers = if (layouts.len == 0) null else layouts.ptr,
            },
            .primitive = options.primitive,
            .fragment = &fragment,
        };
        return gctx.createRenderPipeline(.{}, descriptor);
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
    if (@sizeOf(VertexInput) != 32) @compileError("anygpu layout mismatch: generated type size does not match the schema");
    if (@alignOf(VertexInput) != 16) @compileError("anygpu layout mismatch: generated type alignment does not match the schema");
    if (@sizeOf(VertexOutput) != 32) @compileError("anygpu layout mismatch: generated type size does not match the schema");
    if (@alignOf(VertexOutput) != 16) @compileError("anygpu layout mismatch: generated type alignment does not match the schema");
    if (@sizeOf(package_camera_Camera) != 256) @compileError("anygpu layout mismatch: generated type size does not match the schema");
    if (@alignOf(package_camera_Camera) != 16) @compileError("anygpu layout mismatch: generated type alignment does not match the schema");
}
