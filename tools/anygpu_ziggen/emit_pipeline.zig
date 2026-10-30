const std = @import("std");
const schema_lib = @import("schema.zig");
const common = @import("emit_common.zig");
const Writer = std.Io.Writer;
const Value = schema_lib.Value;
const field = schema_lib.field;
const object = schema_lib.object;
const string = schema_lib.string;
const number = schema_lib.number;
const boolean = schema_lib.boolean;
const tagged = schema_lib.tagged;
const writeZigString = common.writeZigString;
const writeStageList = common.writeStageList;

pub fn emit(w: *Writer, schema_value: *const Value, allocator: std.mem.Allocator) !void {
    try writePipeline(w, schema_value, allocator);
}

fn writePipelineOptions(w: *Writer, name: []const u8, stage: *const Value) !void {
    try w.print("    pub const {s}_constants = [_]shared.PipelineConstant{{", .{name});
    var zero_initialize = false;
    if (stage.* != .null) {
        const options = try field(stage, "compilation_options");
        const constants = try field(options, "constants");
        const entries = try object(constants);
        var iterator = entries.iterator();
        while (iterator.next()) |entry| {
            try w.writeAll("\n        .{ .name = ");
            try writeZigString(w, entry.key_ptr.*);
            try w.writeAll(", .value = ");
            switch (entry.value_ptr.*) {
                .integer => |n| try w.print("{d}", .{n}),
                .float => |n| try w.print("{d}", .{n}),
                .number_string => |text| {
                    const n = std.fmt.parseFloat(f64, text) catch return error.InvalidSchema;
                    try w.print("{d}", .{n});
                },
                else => return error.InvalidSchema,
            }
            try w.writeAll(" },");
        }
        zero_initialize = try boolean(try field(options, "zero_initialize_workgroup_memory"));
    }
    try w.writeAll("\n    };\n");
    try w.print("    pub const {s}_zero_initialize_workgroup_memory = {};\n", .{ name, zero_initialize });
}

fn writePipeline(w: *Writer, schema: *const Value, allocator: std.mem.Allocator) !void {
    try w.writeAll(
        \\const zgpu = @import("zgpu");
        \\const wgpu = zgpu.wgpu;
        \\
    );
    const pipelines_value = try field(schema, "pipelines");
    if (pipelines_value.* == .null) {
        try w.writeAll(
            \\pub const Pipeline = struct {
            \\    pub const present = false;
            \\    pub const vertex_entry_point: ?[]const u8 = null;
            \\    pub const fragment_entry_point: ?[]const u8 = null;
            \\    pub const compute_entry_point: ?[]const u8 = null;
            \\    pub const bind_group_count = 0;
            \\    pub const bind_group_indices = [_]u32{};
            \\    pub const vertex_constants = [_]shared.PipelineConstant{};
            \\    pub const fragment_constants = [_]shared.PipelineConstant{};
            \\    pub const compute_constants = [_]shared.PipelineConstant{};
            \\    pub const vertex_zero_initialize_workgroup_memory = false;
            \\    pub const fragment_zero_initialize_workgroup_memory = false;
            \\    pub const compute_zero_initialize_workgroup_memory = false;
            \\    pub const push_constant_ranges = [_]shared.PushConstantRange{};
            \\};
            \\
        );
        return;
    }
    const vertex_stage = (try object(pipelines_value)).get("vertex") orelse return error.MissingField;
    if (vertex_stage != .null) try writeVertexInputs(w, schema, &vertex_stage, allocator);
    try w.writeAll("pub const Pipeline = struct {\n");
    try w.writeAll("    pub const present = true;\n");
    const layout = try field(pipelines_value, "layout");
    const groups = try field(layout, "bind_group_layouts");
    if (groups.* != .array) return error.InvalidSchema;
    try w.print("    pub const bind_group_count = {d};\n    pub const bind_group_indices = [_]u32{{", .{groups.array.items.len});
    for (groups.array.items, 0..) |*group, index| {
        if (index != 0) try w.writeAll(", ");
        try w.print("{d}", .{try number(try field(group, "group"))});
    }
    try w.writeAll("};\n");
    const stage_names = [_][]const u8{ "vertex", "fragment", "compute" };
    for (stage_names) |name| {
        try w.print("    pub const {s}_entry_point: ?[]const u8 = ", .{name});
        const stage = (try object(pipelines_value)).get(name) orelse return error.MissingField;
        if (stage == .null) {
            try w.writeAll("null;\n");
        } else {
            try writeZigString(w, try string(try field(&stage, "entry_point")));
            try w.writeAll(";\n");
        }
        try writePipelineOptions(w, name, &stage);
    }
    const ranges = try field(layout, "push_constant_ranges");
    if (ranges.* != .array) return error.InvalidSchema;
    try w.writeAll("    pub const push_constant_ranges = [_]shared.PushConstantRange{\n");
    for (ranges.array.items) |*range| {
        try w.writeAll("        .{ .stages = ");
        try writeStageList(w, try field(range, "stages"));
        try w.print(", .start = {d}, .end = {d} }},\n", .{
            try number(try field(range, "range_start")),
            try number(try field(range, "range_end")),
        });
    }
    try w.writeAll("    };\n");
    try writeRenderHelpers(w, pipelines_value);
    try w.writeAll("};\n");
}

fn writeRenderHelpers(w: *Writer, pipelines: *const Value) !void {
    const vertex = (try object(pipelines)).get("vertex") orelse return error.MissingField;
    if (vertex == .null) return;
    const fragment = (try object(pipelines)).get("fragment") orelse return error.MissingField;
    const vertex_entry = try string(try field(&vertex, "entry_point"));
    const fragment_entry = if (fragment != .null) try string(try field(&fragment, "entry_point")) else null;
    try writeVertexBufferLayouts(w, &vertex);

    try w.writeAll(
        \\    pub const CreateOptions = struct {
        \\        color_format: wgpu.TextureFormat = zgpu.GraphicsContext.swapchain_format,
        \\        primitive: wgpu.PrimitiveState = .{},
        \\    };
        \\
        \\    pub fn create(gctx: *zgpu.GraphicsContext, source: [:0]const u8) zgpu.RenderPipelineHandle {
        \\        return createWithOptions(gctx, source, .{});
        \\    }
        \\
        \\    pub fn createWithOptions(
        \\        gctx: *zgpu.GraphicsContext,
        \\        source: [:0]const u8,
        \\        options: CreateOptions,
        \\    ) zgpu.RenderPipelineHandle {
        \\        return createWithVertexLayoutsAndOptions(gctx, source, &vertex_buffer_layouts, options);
        \\    }
        \\
        \\    pub fn createWithVertexLayouts(
        \\        gctx: *zgpu.GraphicsContext,
        \\        source: [:0]const u8,
        \\        layouts: []const wgpu.VertexBufferLayout,
        \\    ) zgpu.RenderPipelineHandle {
        \\        return createWithVertexLayoutsAndOptions(gctx, source, layouts, .{});
        \\    }
        \\
        \\    pub fn createWithVertexLayoutsAndOptions(
        \\        gctx: *zgpu.GraphicsContext,
        \\        source: [:0]const u8,
        \\        layouts: []const wgpu.VertexBufferLayout,
        \\        options: CreateOptions,
        \\    ) zgpu.RenderPipelineHandle {
        \\        const shader = zgpu.createWgslShaderModule(gctx.device, source, null);
        \\        defer shader.release();
        \\
    );

    if (fragment_entry) |entry| {
        try w.writeAll(
            \\        const color_targets = [_]wgpu.ColorTargetState{.{
            \\            .format = options.color_format,
            \\        }};
            \\        const fragment = wgpu.FragmentState{
            \\            .module = shader,
            \\            .entry_point = 
        );
        try writeZigString(w, entry);
        try w.writeAll(
            \\,
            \\            .target_count = color_targets.len,
            \\            .targets = &color_targets,
            \\        };
            \\
        );
    }

    try w.writeAll(
        \\        const descriptor = wgpu.RenderPipelineDescriptor{
        \\            .layout = null,
        \\            .vertex = .{
        \\                .module = shader,
        \\                .entry_point = 
    );
    try writeZigString(w, vertex_entry);
    try w.writeAll(
        \\,
        \\                .buffer_count = layouts.len,
        \\                .buffers = if (layouts.len == 0) null else layouts.ptr,
        \\            },
        \\            .primitive = options.primitive,
    );
    if (fragment_entry != null) {
        try w.writeAll(
            \\
            \\            .fragment = &fragment,
        );
    }
    try w.writeAll(
        \\
        \\        };
        \\        return gctx.createRenderPipeline(.{}, descriptor);
        \\    }
        \\
        \\    pub fn bind(
        \\        gctx: *zgpu.GraphicsContext,
        \\        pass: wgpu.RenderPassEncoder,
        \\        handle: zgpu.RenderPipelineHandle,
        \\    ) error{InvalidPipelineHandle}!void {
        \\        const pipeline = gctx.lookupResource(handle) orelse return error.InvalidPipelineHandle;
        \\        pass.setPipeline(pipeline);
        \\    }
        \\
        \\    pub fn destroy(gctx: *zgpu.GraphicsContext, handle: zgpu.RenderPipelineHandle) void {
        \\        gctx.releaseResource(handle);
        \\    }
        \\
    );
}

fn writeVertexInputs(
    w: *Writer,
    schema: *const Value,
    vertex: *const Value,
    allocator: std.mem.Allocator,
) !void {
    const buffers = try field(vertex, "buffers");
    if (buffers.* != .array) return error.UnsupportedVertexBufferLayout;

    var input_count: usize = 0;
    for (buffers.array.items) |*buffer| {
        const attributes = try field(buffer, "attributes");
        if (attributes.* != .array) return error.InvalidSchema;
        input_count += attributes.array.items.len;
    }
    if (input_count == 0) return error.UnsupportedVertexInputs;

    const inputs = try allocator.alloc(*const Value, input_count);
    var cursor: usize = 0;
    for (buffers.array.items) |*buffer| {
        const attributes = try field(buffer, "attributes");
        for (attributes.array.items) |*attribute| {
            inputs[cursor] = attribute;
            cursor += 1;
        }
    }

    for (1..inputs.len) |index| {
        const current = inputs[index];
        const current_location = try number(try field(current, "shader_location"));
        var insertion = index;
        while (insertion > 0) {
            const previous_location = try number(try field(inputs[insertion - 1], "shader_location"));
            if (previous_location <= current_location) break;
            inputs[insertion] = inputs[insertion - 1];
            insertion -= 1;
        }
        inputs[insertion] = current;
    }

    for (inputs, 0..) |input, index| {
        const name = try string(try field(input, "name"));
        const location = try number(try field(input, "shader_location"));
        for (inputs[0..index]) |previous| {
            if (std.mem.eql(u8, name, try string(try field(previous, "name")))) return error.DuplicateVertexInputName;
            if (location == try number(try field(previous, "shader_location"))) return error.DuplicateVertexInputLocation;
        }
        const ty_id = try string(try field(input, "ty"));
        const mapped = try vertexElementType(schema, ty_id, allocator);
        const schema_format = try string(try field(input, "format"));
        if (!std.mem.eql(u8, schema_format, mapped.format)) return error.VertexInputFormatMismatch;
    }

    try w.writeAll(
        \\pub const VertexStreamInput = struct {
        \\    field_name: []const u8,
        \\    element_type: type,
        \\    location: u32,
        \\    step_mode: wgpu.VertexStepMode = .vertex,
        \\};
        \\
        \\pub const vertex_inputs = [_]VertexStreamInput{
    );
    try w.writeByte('\n');
    for (inputs) |input| {
        const name = try string(try field(input, "name"));
        const location = try number(try field(input, "shader_location"));
        const mapped = try vertexElementType(schema, try string(try field(input, "ty")), allocator);
        try w.writeAll("    .{ .field_name = ");
        try writeZigString(w, name);
        try w.writeAll(", .element_type = ");
        try w.writeAll(mapped.zig_type);
        try w.print(", .location = {d} }},\n", .{location});
    }
    try w.writeAll("};\n\n");
}

const VertexElementType = struct {
    zig_type: []const u8,
    format: []const u8,
};

fn vertexElementType(schema: *const Value, id: []const u8, allocator: std.mem.Allocator) !VertexElementType {
    const ty = try findType(schema, id);
    const descriptor = try tagged(try field(ty, "descriptor"));
    if (std.mem.eql(u8, descriptor.name, "Scalar")) {
        const scalar = try field(descriptor.payload, "scalar");
        const zig_type = try vertexScalarType(scalar);
        const format = if (std.mem.eql(u8, zig_type, "f32"))
            "Float32"
        else if (std.mem.eql(u8, zig_type, "i32"))
            "Sint32"
        else
            "Uint32";
        return .{ .zig_type = zig_type, .format = format };
    }
    if (std.mem.eql(u8, descriptor.name, "Vector")) {
        const length = try number(try field(descriptor.payload, "length"));
        if (length < 2 or length > 4) return error.UnsupportedVertexInputType;
        const scalar = try field(descriptor.payload, "scalar");
        const zig_scalar = try vertexScalarType(scalar);
        const format_scalar = if (std.mem.eql(u8, zig_scalar, "f32"))
            "Float32"
        else if (std.mem.eql(u8, zig_scalar, "i32"))
            "Sint32"
        else
            "Uint32";
        return .{
            .zig_type = try std.fmt.allocPrint(allocator, "[{d}]{s}", .{ length, zig_scalar }),
            .format = try std.fmt.allocPrint(allocator, "{s}x{d}", .{ format_scalar, length }),
        };
    }
    return error.UnsupportedVertexInputType;
}

fn vertexScalarType(scalar: *const Value) ![]const u8 {
    const name = try string(try field(scalar, "name"));
    const width = try number(try field(scalar, "width"));
    if (width != 4) return error.UnsupportedVertexInputType;
    if (std.mem.eql(u8, name, "float")) return "f32";
    if (std.mem.eql(u8, name, "sint")) return "i32";
    if (std.mem.eql(u8, name, "uint")) return "u32";
    return error.UnsupportedVertexInputType;
}

fn findType(schema: *const Value, id: []const u8) !*const Value {
    const types = try field(schema, "types");
    if (types.* != .array) return error.InvalidSchema;
    for (types.array.items) |*ty| {
        if (std.mem.eql(u8, try string(try field(ty, "id")), id)) return ty;
    }
    if ((try object(schema)).get("shared")) |shared| {
        const shared_types = try field(&shared, "types");
        if (shared_types.* != .array) return error.InvalidSchema;
        for (shared_types.array.items) |*ty| {
            if (std.mem.eql(u8, try string(try field(ty, "id")), id)) return ty;
        }
    }
    return error.UnknownType;
}

fn writeVertexBufferLayouts(w: *Writer, vertex: *const Value) !void {
    const buffers_value = try field(vertex, "buffers");
    if (buffers_value.* == .null) return error.UnsupportedVertexBufferLayout;
    if (buffers_value.* != .array) return error.InvalidSchema;

    for (buffers_value.array.items, 0..) |*buffer, buffer_index| {
        const attributes = try field(buffer, "attributes");
        if (attributes.* != .array) return error.InvalidSchema;
        try w.print("    const vertex_attributes_{d} = [_]wgpu.VertexAttribute{{\n", .{buffer_index});
        for (attributes.array.items) |*attribute| {
            try w.writeAll("        .{ .format = .");
            try w.writeAll(try vertexFormatName(try string(try field(attribute, "format"))));
            try w.print(", .offset = {d}, .shader_location = {d} }},\n", .{
                try number(try field(attribute, "offset")),
                try number(try field(attribute, "shader_location")),
            });
        }
        try w.writeAll("    };\n");
    }

    try w.writeAll("    pub const vertex_buffer_layouts = [_]wgpu.VertexBufferLayout{\n");
    for (buffers_value.array.items, 0..) |*buffer, buffer_index| {
        const attributes = try field(buffer, "attributes");
        try w.writeAll("        .{ .array_stride = ");
        try writeU64(w, try field(buffer, "array_stride"));
        try w.writeAll(", .step_mode = .");
        try w.writeAll(try vertexStepModeName(try string(try field(buffer, "step_mode"))));
        try w.writeAll(", .attribute_count = ");
        try w.print("{d}, .attributes = ", .{attributes.array.items.len});
        if (attributes.array.items.len == 0) {
            try w.writeAll("&.{} },\n");
        } else {
            try w.print("&vertex_attributes_{d} }},\n", .{buffer_index});
        }
    }
    try w.writeAll("    };\n");
}

fn writeU64(w: *Writer, value: *const Value) !void {
    switch (value.*) {
        .integer => |n| {
            if (n < 0) return error.InvalidSchema;
            try w.print("{d}", .{n});
        },
        else => return error.InvalidSchema,
    }
}

fn vertexFormatName(format: []const u8) ![]const u8 {
    const names = .{
        .{ "Float16x2", "float16x2" },
        .{ "Float16x4", "float16x4" },
        .{ "Float32", "float32" },
        .{ "Float32x2", "float32x2" },
        .{ "Float32x3", "float32x3" },
        .{ "Float32x4", "float32x4" },
        .{ "Sint32", "sint32" },
        .{ "Sint32x2", "sint32x2" },
        .{ "Sint32x3", "sint32x3" },
        .{ "Sint32x4", "sint32x4" },
        .{ "Uint32", "uint32" },
        .{ "Uint32x2", "uint32x2" },
        .{ "Uint32x3", "uint32x3" },
        .{ "Uint32x4", "uint32x4" },
    };
    inline for (names) |entry| {
        if (std.mem.eql(u8, format, entry.@"0")) return entry.@"1";
    }
    return error.UnsupportedVertexFormat;
}

fn vertexStepModeName(mode: []const u8) ![]const u8 {
    if (std.mem.eql(u8, mode, "Vertex")) return "vertex";
    return error.UnsupportedVertexStepMode;
}
