const std = @import("std");
const schema_lib = @import("schema.zig");
const common = @import("emit_common.zig");
const layout_mod = @import("layout.zig");
const types_emit = @import("emit_types.zig");
const identifiers = @import("identifiers.zig");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const Value = schema_lib.Value;
const Model = schema_lib.Model;
const findType = layout_mod.findType;
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
const writeStageMask = common.writeStageMask;
const writeSnakeEnum = common.writeSnakeEnum;
const writeOptionalEnum = common.writeOptionalEnum;
const writeOptionalString = common.writeOptionalString;
const zigIdentifier = identifiers.zigIdentifier;

pub const GroupEntries = struct {
    group: u32,
    entries: []const *const Value,
};

pub fn collectGroups(schema_value: *const Value, allocator: Allocator) ![]GroupEntries {
    const pipelines_value = try field(schema_value, "pipelines");
    if (pipelines_value.* == .null) return try allocator.alloc(GroupEntries, 0);
    const layout_value = try field(pipelines_value, "layout");
    const groups = try field(layout_value, "bind_group_layouts");
    if (groups.* != .array) return error.InvalidSchema;
    const result = try allocator.alloc(GroupEntries, groups.array.items.len);
    for (groups.array.items, 0..) |*group_value, index| {
        const entries = try field(group_value, "entries");
        if (entries.* != .array) return error.InvalidSchema;
        const entry_values = try allocator.alloc(*const Value, entries.array.items.len);
        for (entries.array.items, 0..) |*entry, entry_index| entry_values[entry_index] = entry;
        std.mem.sort(*const Value, entry_values, {}, lessBindingNumber);
        for (entry_values, 0..) |entry, entry_index| {
            const binding_number = try number(try field(entry, "binding"));
            const name = try string(try field(entry, "name"));
            const slot_name = try zigIdentifier(allocator, name, binding_number);
            for (entry_values[0..entry_index]) |previous| {
                if (binding_number == try number(try field(previous, "binding"))) {
                    std.debug.print("anygpu-ziggen: duplicate binding index {d} in group {d}\n", .{ binding_number, try number(try field(group_value, "group")) });
                    return error.DuplicateBindingIndex;
                }
                const previous_name = try string(try field(previous, "name"));
                const previous_binding = try number(try field(previous, "binding"));
                const previous_slot = try zigIdentifier(allocator, previous_name, previous_binding);
                if (std.mem.eql(u8, slot_name, previous_slot)) {
                    std.debug.print("anygpu-ziggen: ambiguous Zig slot name `{s}` in group {d}\n", .{ slot_name, try number(try field(group_value, "group")) });
                    return error.AmbiguousSlotName;
                }
            }
        }
        result[index] = .{
            .group = try number(try field(group_value, "group")),
            .entries = entry_values,
        };
    }
    std.mem.sort(GroupEntries, result, {}, lessGroup);
    if (result.len > 1) {
        for (result[1..], 1..) |group, index| {
            if (group.group == result[index - 1].group) return error.DuplicateBindGroup;
        }
    }
    return result;
}

fn lessGroup(_: void, lhs: GroupEntries, rhs: GroupEntries) bool {
    return lhs.group < rhs.group;
}

fn lessBindingNumber(_: void, lhs: *const Value, rhs: *const Value) bool {
    return (schema_lib.number(schema_lib.field(lhs, "binding") catch unreachable) catch unreachable) <
        (schema_lib.number(schema_lib.field(rhs, "binding") catch unreachable) catch unreachable);
}

pub fn emit(w: *Writer, schema_value: *const Value, model: *const Model, allocator: Allocator) !void {
    try writeBindings(w, schema_value, model, allocator);
}

pub fn hasMinBindingSize(schema_value: *const Value, allocator: Allocator) !bool {
    const groups = try collectGroups(schema_value, allocator);
    for (groups) |group| {
        for (group.entries) |entry| {
            if (try bindingHasMinBindingSize(entry)) return true;
        }
    }
    const bindgroups = try field(schema_value, "bindgroups");
    if (bindgroups.* != .array) return error.InvalidSchema;
    for (bindgroups.array.items) |*entry| {
        if (try bindingHasMinBindingSize(entry)) return true;
    }
    return false;
}

fn bindingHasMinBindingSize(entry: *const Value) !bool {
    const binding_type = try tagged(try field(entry, "ty"));
    if (!std.mem.eql(u8, binding_type.name, "Buffer")) return false;
    return (try field(binding_type.payload, "min_binding_size")).* != .null;
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
        const ty_value = field(binding_type.payload, "ty") catch null;
        if (ty_value) |ty_payload| {
            if (ty_payload.* != .null) details.ty = try string(ty_payload);
        }
        return details;
    }
    if (std.mem.eql(u8, binding_type.name, "Sampler")) {
        details.sampler_type = try enumPayload(binding_type.payload);
        return details;
    }
    if (std.mem.eql(u8, binding_type.name, "Texture")) {
        details.sample_type = try enumPayload(try field(binding_type.payload, "sample_type"));
        const sample_value = try field(binding_type.payload, "sample_type");
        if (sample_value.* != .string) {
            const sample = try tagged(sample_value);
            if (std.mem.eql(u8, sample.name, "Float")) {
                details.filterable = try boolean(try field(sample.payload, "filterable"));
            }
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

fn optionalStringField(value: *const Value, name: []const u8) !?[]const u8 {
    const item = (try object(value)).getPtr(name) orelse return null;
    if (item.* == .null) return null;
    return try string(item);
}

fn writeBinding(w: *Writer, binding: *const Value, group: ?u32, model: *const Model) !void {
    const binding_number = try number(try field(binding, "binding"));
    const name = try string(try field(binding, "name"));
    const visibility = try field(binding, "visibility");
    const count = try optionalU32(try field(binding, "count"));
    var details = try bindingDetails(try field(binding, "ty"));
    if (details.ty) |type_id| {
        const type_index = try findType(model, type_id);
        const descriptor = try schema_lib.tagged(model.types[type_index].descriptor);
        if (std.mem.eql(u8, descriptor.name, "Array")) {
            details.array_stride = try number(try field(descriptor.payload, "stride"));
            const array_size = try field(descriptor.payload, "size");
            if (array_size.* == .null) {
                details.runtime_sized_array = true;
            } else {
                details.array_length = try number(array_size);
            }
        }
    }
    const slot_name = try zigIdentifier(model.allocator, name, binding_number);
    const address_space = try optionalStringField(binding, "address_space");
    const access = try optionalStringField(binding, "access");
    try w.writeAll("    .{ .group = ");
    if (group) |group_number| {
        try w.print("{d}", .{group_number});
    } else {
        try w.writeAll("null");
    }
    try w.print(", .binding = {d}, .name = ", .{binding_number});
    try writeZigString(w, name);
    try w.writeAll(", .slot_name = ");
    try writeZigString(w, slot_name);
    try w.writeAll(", .kind = .");
    try writeSnakeEnum(w, details.kind);
    try w.writeAll(", .address_space = ");
    try writeOptionalEnum(w, address_space);
    try w.writeAll(", .access = ");
    try writeOptionalEnum(w, access);
    try w.writeAll(", .visibility = ");
    try writeStageMask(w, visibility);
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
    try w.writeAll(", .array_stride = ");
    if (details.array_stride) |stride| try w.print("{d}", .{stride}) else try w.writeAll("null");
    try w.writeAll(", .array_length = ");
    if (details.array_length) |length| try w.print("{d}", .{length}) else try w.writeAll("null");
    try w.print(", .runtime_sized_array = {}", .{details.runtime_sized_array});
    try w.writeAll(", .ty = ");
    if (details.ty) |type_id| {
        const type_index = try findType(model, type_id);
        const descriptor = try schema_lib.tagged(model.types[type_index].descriptor);
        if (std.mem.eql(u8, descriptor.name, "Array")) {
            const base_index = try layout_mod.findTypeReference(model, try schema_lib.field(descriptor.payload, "base"));
            try types_emit.writeTypeRef(w, model, base_index);
        } else {
            try types_emit.writeTypeRef(w, model, type_index);
        }
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(" },\n");
}

fn writeBindings(w: *Writer, schema: *const Value, model: *const Model, allocator: Allocator) !void {
    const groups = collectGroups(schema, allocator) catch |err| {
        std.debug.print("anygpu-ziggen: invalid bind-group layout: {s}\n", .{@errorName(err)});
        return err;
    };
    const bindgroups = try field(schema, "bindgroups");
    if (bindgroups.* != .array) return error.InvalidSchema;

    try w.writeAll(
        \\pub const bindings = [_]shared.Binding{
    );
    try w.writeByte('\n');
    const ranges = try allocator.alloc([2]usize, groups.len);
    var binding_count: usize = 0;
    for (groups, 0..) |group, index| {
        ranges[index][0] = binding_count;
        for (group.entries) |entry| {
            writeBinding(w, entry, group.group, model) catch |err| {
                std.debug.print("anygpu-ziggen: invalid binding group {d}, binding {d}: {s}\n", .{
                    group.group,
                    schema_lib.number(try field(entry, "binding")) catch 0,
                    @errorName(err),
                });
                return err;
            };
        }
        binding_count += group.entries.len;
        ranges[index][1] = binding_count;
    }
    for (bindgroups.array.items) |*entry| {
        writeBinding(w, entry, null, model) catch |err| {
            std.debug.print("anygpu-ziggen: invalid ungrouped binding {d}: {s}\n", .{
                schema_lib.number(try field(entry, "binding")) catch 0,
                @errorName(err),
            });
            return err;
        };
    }
    try w.writeAll("};\n\npub const BindingMetadata = shared.Binding;\n\n");

    try emitMaterialSelectors(w, groups, model);
    try w.writeAll(
        \\pub fn materialBindGroupLayoutEntry(binding: shared.Binding) wgpu.BindGroupLayoutEntry {
        \\    return shared.toBindGroupLayoutEntry(binding, null);
        \\}
        \\
        \\
    );

    try w.writeAll("pub const group_indices = [_]u32{");
    for (groups, 0..) |group, index| {
        if (index != 0) try w.writeAll(", ");
        try w.print("{d}", .{group.group});
    }
    try w.writeAll("};\n\n");

    try w.writeAll("pub const group_bindings = [_][]const shared.Binding{");
    if (groups.len != 0) try w.writeByte('\n');
    for (ranges) |range| {
        try w.print("    bindings[{d}..{d}],\n", .{ range[0], range[1] });
    }
    try w.writeAll("};\n\n");

    try w.writeAll(
        \\pub fn bindingsOfGroup(comptime group: u32) []const shared.Binding {
        \\    inline for (group_indices, 0..) |candidate, index| {
        \\        if (group == candidate) return group_bindings[index];
        \\    }
        \\    @compileError("unknown bind group");
        \\}
        \\
        \\
    );
}

fn emitMaterialSelectors(w: *Writer, groups: []const GroupEntries, model: *const Model) !void {
    try w.writeAll("pub const MaterialGroup = enum(u32) {\n");
    for (groups) |group| try w.print("    group{d} = {d},\n", .{ group.group, group.group });
    try w.writeAll("};\n\npub const MaterialSlots = struct {\n");
    for (groups) |group| {
        try w.print("    pub const group{d} = enum(u32) {{\n", .{group.group});
        for (group.entries) |entry| {
            const binding_number = try number(try field(entry, "binding"));
            const name = try string(try field(entry, "name"));
            const safe_name = try zigIdentifier(model.allocator, name, binding_number);
            try w.print("        {s} = {d},\n", .{ safe_name, binding_number });
        }
        try w.writeAll("    };\n");
    }
    try w.writeAll("};\n\n");
}
