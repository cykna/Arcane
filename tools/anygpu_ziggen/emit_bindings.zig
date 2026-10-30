const std = @import("std");
const schema_lib = @import("schema.zig");
const common = @import("emit_common.zig");
const Writer = std.Io.Writer;
const Value = schema_lib.Value;
const BindingDetails = schema_lib.BindingDetails;
const field = schema_lib.field;
const object = schema_lib.object;
const string = schema_lib.string;
const number = schema_lib.number;
const optionalU32 = schema_lib.optionalU32;
const boolean = schema_lib.boolean;
const tagged = schema_lib.tagged;
const writeZigString = common.writeZigString;
const writeStageList = common.writeStageList;
const writeSnakeEnum = common.writeSnakeEnum;
const writeOptionalEnum = common.writeOptionalEnum;
const writeOptionalString = common.writeOptionalString;

pub fn emit(w: *Writer, schema_value: *const Value) !void {
    try writeBindings(w, schema_value);
}

fn enumPayload(value: *const Value) ![]const u8 {
    if (value.* == .string) return value.string;
    return (try tagged(value)).name;
}

fn bindingDetails(value: *const Value) !BindingDetails {
    const binding_type = try tagged(value);
    var details = BindingDetails{ .kind = binding_type.name };
    if (std.mem.eql(u8, binding_type.name, "Buffer")) {
        const buffer_type = try field(binding_type.payload, "buffer_type");
        if (buffer_type.* == .string) {
            details.resource_type = try string(buffer_type);
        } else {
            const storage = try tagged(buffer_type);
            details.resource_type = storage.name;
            if (std.mem.eql(u8, storage.name, "Storage")) {
                details.read_only = try enumPayload(try field(storage.payload, "read_only"));
            }
        }
        details.has_dynamic_offset = try boolean(try field(binding_type.payload, "has_dynamic_offset"));
        const minimum = try field(binding_type.payload, "min_binding_size");
        if (minimum.* != .null) {
            details.min_binding_size = switch (minimum.*) {
                .integer => |n| if (n >= 0) @intCast(n) else return error.InvalidSchema,
                .number_string => |text| std.fmt.parseInt(u64, text, 10) catch return error.InvalidSchema,
                else => return error.InvalidSchema,
            };
        }
        return details;
    }
    if (std.mem.eql(u8, binding_type.name, "Sampler")) {
        details.sampler_type = try enumPayload(binding_type.payload);
        return details;
    }
    if (std.mem.eql(u8, binding_type.name, "Texture")) {
        details.sample_type = try enumPayload(try field(binding_type.payload, "sample_type"));
        const sample = try tagged(try field(binding_type.payload, "sample_type"));
        if (std.mem.eql(u8, sample.name, "Float")) {
            details.filterable = try boolean(try field(sample.payload, "filterable"));
        }
        details.view_dimension = try enumPayload(try field(binding_type.payload, "view_dimension"));
        details.multisampled = try boolean(try field(binding_type.payload, "multisampled"));
        return details;
    }
    if (std.mem.eql(u8, binding_type.name, "StorageTexture")) {
        details.storage_access = try enumPayload(try field(binding_type.payload, "access"));
        details.format = try string(try field(binding_type.payload, "format"));
        details.view_dimension = try enumPayload(try field(binding_type.payload, "view_dimension"));
        return details;
    }
    return error.UnsupportedBinding;
}

fn writeBinding(w: *Writer, binding: *const Value, group: ?u32) !void {
    const binding_number = try number(try field(binding, "binding"));
    const name = try string(try field(binding, "name"));
    const visibility = try field(binding, "visibility");
    const count = try optionalU32(try field(binding, "count"));
    const details = try bindingDetails(try field(binding, "ty"));
    try w.writeAll("    .{ .group = ");
    if (group) |group_number| {
        try w.print("{d}", .{group_number});
    } else {
        try w.writeAll("null");
    }
    try w.print(", .binding = {d}, .name = ", .{binding_number});
    try writeZigString(w, name);
    try w.writeAll(", .kind = .");
    try writeSnakeEnum(w, details.kind);
    try w.writeAll(", .visibility = ");
    try writeStageList(w, visibility);
    try w.writeAll(", .count = ");
    if (count) |amount| {
        try w.print("{d}", .{amount});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(", .resource_type = ");
    try writeOptionalEnum(w, details.resource_type);
    try w.writeAll(", .read_only = ");
    try writeOptionalEnum(w, details.read_only);
    try w.writeAll(", .sampler_type = ");
    try writeOptionalEnum(w, details.sampler_type);
    try w.writeAll(", .sample_type = ");
    try writeOptionalEnum(w, details.sample_type);
    try w.writeAll(", .filterable = ");
    if (details.filterable) |value| try w.writeAll(if (value) "true" else "false") else try w.writeAll("null");
    try w.writeAll(", .view_dimension = ");
    try writeOptionalEnum(w, details.view_dimension);
    try w.writeAll(", .multisampled = ");
    if (details.multisampled) |value| try w.writeAll(if (value) "true" else "false") else try w.writeAll("null");
    try w.writeAll(", .storage_access = ");
    try writeOptionalEnum(w, details.storage_access);
    try w.writeAll(", .format = ");
    try writeOptionalString(w, details.format);
    try w.print(", .has_dynamic_offset = {}, .min_binding_size = ", .{details.has_dynamic_offset});
    if (details.min_binding_size) |minimum| try w.print("{d}", .{minimum}) else try w.writeAll("null");
    try w.writeAll(" },\n");
}

fn writeBindings(w: *Writer, schema: *const Value) !void {
    try w.writeAll(
        \\pub const bindings = [_]shared.Binding{
    );
    try w.writeByte('\n');
    const pipelines_value = try field(schema, "pipelines");
    if (pipelines_value.* != .null) {
        const layout = try field(pipelines_value, "layout");
        const groups = try field(layout, "bind_group_layouts");
        if (groups.* != .array) return error.InvalidSchema;
        for (groups.array.items) |*group_value| {
            const group = try number(try field(group_value, "group"));
            const entries = try field(group_value, "entries");
            if (entries.* != .array) return error.InvalidSchema;
            for (entries.array.items) |*entry| try writeBinding(w, entry, group);
        }
    }
    const bindgroups = try field(schema, "bindgroups");
    if (bindgroups.* != .array) return error.InvalidSchema;
    for (bindgroups.array.items) |*entry| try writeBinding(w, entry, null);
    try w.writeAll("};\n\n");
}
