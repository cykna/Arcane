const std = @import("std");
const schema = @import("schema.zig");
const model_builder = @import("model.zig");
const layout = @import("layout.zig");
const types = @import("emit_types.zig");
const shared_types = @import("emit_shared.zig");
const bindings = @import("emit_bindings.zig");
const pipeline = @import("emit_pipeline.zig");
const Value = schema.Value;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const writeZigString = @import("emit_common.zig").writeZigString;
const buildModel = model_builder.buildModel;
const typeLayout = layout.typeLayout;

pub fn generateShared(schemas: []const *const Value, allocator: Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const work_allocator = arena.allocator();
    var output: Writer.Allocating = .init(work_allocator);
    const w = &output.writer;
    try w.writeAll(@embedFile("shared_base.zig"));
    try w.writeAll("\n// WGSL aliases derived from anygpu type metadata.\n");
    var seen: [][]const u8 = &.{};
    for (schemas) |schema_value| {
        const model = try buildModel(schema_value, work_allocator);
        try shared_types.emit(w, &model, work_allocator, &seen);
    }
    return try allocator.dupe(u8, try output.toOwnedSlice());
}

pub fn generate(schema_value: *const Value, allocator: Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const work_allocator = arena.allocator();
    const model = try buildModel(schema_value, work_allocator);
    var output: Writer.Allocating = .init(work_allocator);
    const w = &output.writer;
    try w.writeAll(
        \\// Generated from anygpu JSON. Do not edit by hand.
        \\const shared = @import("shared.zig");
        \\
    );
    try types.emit(w, &model);
    try bindings.emit(w, schema_value);
    try pipeline.emit(w, schema_value, work_allocator);

    try w.writeAll("\ncomptime {\n    _ = bindings;\n    _ = Pipeline;\n");
    for (model.types[model.shared_count..], model.shared_count..) |ty, index| {
        const descriptor = try schema.tagged(ty.descriptor);
        if (std.mem.eql(u8, descriptor.name, "Scalar") or
            std.mem.eql(u8, descriptor.name, "Atomic") or
            std.mem.eql(u8, descriptor.name, "Vector")) continue;
        const computed_layout = typeLayout(&model, index, 0) catch |err| {
            if (err == error.NoMemoryLayout) continue;
            return err;
        };
        if (std.mem.eql(u8, descriptor.name, "Array") and
            (try schema.field(descriptor.payload, "size")).* == .null) continue;
        try w.writeAll("    if (@sizeOf(");
        try types.writeTypeRef(w, &model, index);
        try w.print(") != {d}) @compileError(", .{computed_layout.size});
        try writeZigString(w, "anygpu layout mismatch: generated type size does not match the schema");
        try w.writeAll(");\n");
        if ((std.mem.eql(u8, descriptor.name, "Struct") and computed_layout.size % computed_layout.alignment == 0) or
            std.mem.eql(u8, descriptor.name, "Matrix") or
            std.mem.eql(u8, descriptor.name, "Array"))
        {
            try w.writeAll("    if (@alignOf(");
            try types.writeTypeRef(w, &model, index);
            try w.print(") != {d}) @compileError(", .{computed_layout.alignment});
            try writeZigString(w, "anygpu layout mismatch: generated type alignment does not match the schema");
            try w.writeAll(");\n");
        }
    }
    try w.writeAll("}\n");
    return try allocator.dupe(u8, try output.toOwnedSlice());
}

test "generates padded, strongly typed WGSL structs and binding metadata" {
    const source =
        \\{
        \\  "types": [
        \\    {"id":"t0","name":"f32","descriptor":{"Scalar":{"scalar":{"name":"float","width":4}}}},
        \\    {"id":"t1","name":"vec3<f32>","descriptor":{"Vector":{"length":3,"scalar":{"name":"float","width":4}}}},
        \\    {"id":"t2","name":"Frame","descriptor":{"Struct":{"size":16,"alignment":16,"members":[
        \\      {"name":"position","offset":0,"ty":"t1"},
        \\      {"name":"exposure","offset":12,"ty":"t0"}
        \\    ]}}}
        \\    ,{"id":"t3","name":"array<vec3<f32>, 2>","descriptor":{"Array":{"base":"t1","size":2,"stride":16}}}
        \\  ],
        \\  "pipelines":{"layout":{"bind_group_layouts":[{"group":0,"entries":[
        \\    {"binding":2,"name":"frame","visibility":[],"ty":{"Buffer":{"buffer_type":"Uniform","has_dynamic_offset":false,"min_binding_size":null}},"count":null},
        \\    {"binding":3,"name":"target","visibility":["Fragment"],"ty":{"StorageTexture":{"access":"WriteOnly","format":"rgba8unorm","view_dimension":"D2"}},"count":null}
        \\  ]}],"push_constant_ranges":[]},"vertex":null,"fragment":null,"compute":null},
        \\  "bindgroups":[]
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const generated = try generate(&parsed.value, std.testing.allocator);
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "position: shared.WgslVec3f32 align(16)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "exposure: f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "const shared = @import(\"shared.zig\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const bindings = [_]shared.Binding{") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const ShaderStage = enum") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const Frame = extern struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub fn init(position: shared.WgslVec3f32, exposure: f32) @This()") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".resource_type = .uniform") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".kind = .storage_texture") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".storage_access = .write_only") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "@sizeOf(Frame) != 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "Type_2") == null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".array_stride = 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".size = 32") != null);
}

test "initializes WGSL structs without exposing generated padding fields" {
    const source =
        \\{"types":[
        \\{"id":"t0","name":"VertexInput","descriptor":{"Struct":{"size":32,"alignment":16,"members":[
        \\{"name":"position","offset":0,"ty":"st0"},{"name":"color","offset":16,"ty":"st1"}
        \\]}}}
        \\],"shared":{"types":[
        \\{"id":"st0","name":"vec3<f32>","descriptor":{"Vector":{"length":3,"scalar":{"name":"float","width":4}}}},
        \\{"id":"st1","name":"vec4<f32>","descriptor":{"Vector":{"length":4,"scalar":{"name":"float","width":4}}}}
        \\]},"pipelines":null,"bindgroups":[]}
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const generated = try generate(&parsed.value, std.testing.allocator);
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub fn init(position: shared.WgslVec3f32, color: shared.WgslVec4f32) @This()") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".position = position,") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "._padding_0 = .{ 0, 0, 0, 0 },") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".color = color,") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub fn init(_alignment") == null);
}

test "generates common types from anygpu shared metadata" {
    const source =
        \\{
        \\  "types":[{"id":"t0","name":"Frame","descriptor":{"Struct":{"size":64,"alignment":16,"members":[
        \\    {"name":"transform","offset":0,"ty":"st2"}
        \\  ]}}}],
        \\  "shared":{"types":[
        \\    {"id":"st0","name":"f32","descriptor":{"Scalar":{"scalar":{"name":"float","width":4}}}},
        \\    {"id":"st1","name":"vec3<f32>","descriptor":{"Vector":{"length":3,"scalar":{"name":"float","width":4}}}},
        \\    {"id":"st2","name":"mat4x4<f32>","descriptor":{"Matrix":{"columns":4,"rows":4,"scalar":{"name":"float","width":4}}}}
        \\  ]},
        \\  "pipelines":null,"bindgroups":[]
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const schemas = [_]*const Value{&parsed.value};
    const shared_generated = try generateShared(&schemas, std.testing.allocator);
    defer std.testing.allocator.free(shared_generated);
    const generated = try generate(&parsed.value, std.testing.allocator);
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, shared_generated, "pub const Wgslf32 = f32;") != null);
    try std.testing.expect(std.mem.indexOf(u8, shared_generated, "pub const WgslVec3f32 = Vec3f32;") != null);
    try std.testing.expect(std.mem.indexOf(u8, shared_generated, "pub const WgslMat4x4f32 = extern struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "transform: shared.WgslMat4x4f32 align(16)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "@sizeOf(Frame) != 64") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".id = \"st2\"") == null);
}

test "rejects unresolved type references instead of emitting unsafe bindings" {
    const source =
        \\{"types":[{"id":"t0","name":"Bad","descriptor":{"Struct":{"size":4,"alignment":4,"members":[
        \\{"name":"value","offset":0,"ty":"missing"}
        \\]}}}],"pipelines":null,"bindgroups":[]}
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownType, buildModel(&parsed.value, arena.allocator()));
}

test "sanitizes Zig keywords and punctuation in exported aliases" {
    const source =
        \\{"types":[
        \\{"id":"t0","name":"type","descriptor":{"Struct":{"size":4,"alignment":4,"members":[
        \\{"name":"value","offset":0,"ty":"t1"}]}}},
        \\{"id":"t1","name":"u32","descriptor":{"Scalar":{"scalar":{"name":"uint","width":4}}}}
        \\],"pipelines":null,"bindgroups":[]}
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const generated = try generate(&parsed.value, std.testing.allocator);
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const type_type_0 = extern struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "Type_0") == null);
}

test "disambiguates member names that sanitize to the same Zig identifier" {
    const source =
        \\{"types":[
        \\{"id":"t0","name":"f32","descriptor":{"Scalar":{"scalar":{"name":"float","width":4}}}},
        \\{"id":"t1","name":"Pair","descriptor":{"Struct":{"size":8,"alignment":4,"members":[
        \\{"name":"a-b","offset":0,"ty":"t0"},{"name":"a b","offset":4,"ty":"t0"}
        \\]}}}
        \\],"pipelines":null,"bindgroups":[]}
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const generated = try generate(&parsed.value, std.testing.allocator);
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const Pair = extern struct") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "a_b: f32") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "a_b_field_1: f32") != null);
}

test "emits zgpu helpers for render pipelines" {
    const source =
        \\{"types":[
        \\{"id":"st0","name":"vec3<f32>","descriptor":{"Vector":{"length":3,"scalar":{"name":"float","width":4}}}},
        \\{"id":"st1","name":"vec4<f32>","descriptor":{"Vector":{"length":4,"scalar":{"name":"float","width":4}}}}
        \\],"pipelines":{
        \\"layout":{"bind_group_layouts":[],"push_constant_ranges":[]},
        \\"vertex":{"entry_point":"vs_main","compilation_options":{"constants":{},"zero_initialize_workgroup_memory":false},"inputs":[],"buffers":[{"array_stride":32,"step_mode":"Vertex","attributes":[{"name":"position","shader_location":0,"ty":"st0","format":"Float32x3","offset":0},{"name":"color","shader_location":1,"ty":"st1","format":"Float32x4","offset":16}]}]},
        \\"fragment":{"entry_point":"fs_main","compilation_options":{"constants":{},"zero_initialize_workgroup_memory":false}},
        \\"compute":null},"bindgroups":[]}
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const generated = try generate(&parsed.value, std.testing.allocator);
    defer std.testing.allocator.free(generated);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub fn create(gctx: *zgpu.GraphicsContext, source: [:0]const u8)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub fn createWithOptions(") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "gctx.createRenderPipeline(.{}, descriptor)") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".format = .float32x3, .offset = 0, .shader_location = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".array_stride = 32, .step_mode = .vertex") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".field_name = \"position\", .element_type = [3]f32, .location = 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".field_name = \"color\", .element_type = [4]f32, .location = 1 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".buffers = if (layouts.len == 0) null else layouts.ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub fn createWithVertexLayouts(") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, ".buffers = if (layouts.len == 0) null else layouts.ptr") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub fn bind(") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub fn destroy(") != null);
}

test "rejects vertex metadata with a format that disagrees with its type" {
    const source =
        \\{"types":[{"id":"t0","name":"vec3<f32>","descriptor":{"Vector":{"length":3,"scalar":{"name":"float","width":4}}}}],
        \\"pipelines":{"layout":{"bind_group_layouts":[],"push_constant_ranges":[]},
        \\"vertex":{"entry_point":"vs_main","compilation_options":{"constants":{},"zero_initialize_workgroup_memory":false},"inputs":[],"buffers":[{"array_stride":12,"step_mode":"Vertex","attributes":[{"name":"position","shader_location":0,"ty":"t0","format":"Float32x4","offset":0}]}]},
        \\"fragment":null,"compute":null},"bindgroups":[]}
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.VertexInputFormatMismatch, generate(&parsed.value, std.testing.allocator));
}

test "rejects vertex stages without usable input metadata" {
    const source =
        \\{"types":[],"pipelines":{
        \\"layout":{"bind_group_layouts":[],"push_constant_ranges":[]},
        \\"vertex":{"entry_point":"vs_main","compilation_options":{"constants":{},"zero_initialize_workgroup_memory":false},"inputs":[],"buffers":[]},
        \\"fragment":null,"compute":null},"bindgroups":[]}
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.UnsupportedVertexInputs, generate(&parsed.value, std.testing.allocator));
}

test "rejects pipelines without a usable vertex buffer layout" {
    const source =
        \\{"types":[],"pipelines":{
        \\"layout":{"bind_group_layouts":[],"push_constant_ranges":[]},
        \\"vertex":{"entry_point":"vs_main","compilation_options":{"constants":{},"zero_initialize_workgroup_memory":false},"inputs":[{"name":"input","shader_location":0,"ty":"st0","format":null,"offset":0}],"buffers":null},
        \\"fragment":null,"compute":null},"bindgroups":[]}
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.UnsupportedVertexBufferLayout, generate(&parsed.value, std.testing.allocator));
}
