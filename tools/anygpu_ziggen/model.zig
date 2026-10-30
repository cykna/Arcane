const std = @import("std");
const schema_lib = @import("schema.zig");
const layout = @import("layout.zig");
const identifiers = @import("identifiers.zig");
const Value = schema_lib.Value;
const Allocator = std.mem.Allocator;
const field = schema_lib.field;
const string = schema_lib.string;
const tagged = schema_lib.tagged;
const TypeInfo = schema_lib.TypeInfo;
const Model = schema_lib.Model;
const typeLayout = layout.typeLayout;
const isOpaque = layout.isOpaque;
const zigIdentifier = identifiers.zigIdentifier;
const nameExists = identifiers.nameExists;

pub fn buildModel(schema_value: *const Value, allocator: Allocator) !Model {
    const type_values = try field(schema_value, "types");
    if (type_values.* != .array) return error.InvalidSchema;
    const root_object = try schema_lib.object(schema_value);
    const shared_values = root_object.getPtr("shared");
    const shared_type_values: ?*const Value = if (shared_values) |shared| blk: {
        if (shared.* == .null) break :blk null;
        const values = try field(shared, "types");
        if (values.* != .array) return error.InvalidSchema;
        break :blk values;
    } else null;
    const shared_count = if (shared_type_values) |values| values.array.items.len else 0;
    const types = try allocator.alloc(TypeInfo, shared_count + type_values.array.items.len);
    var model = Model{ .allocator = allocator, .types = types, .shared_count = shared_count };
    if (shared_type_values) |values| {
        for (values.array.items, 0..) |*value, index| {
            try readType(&model, value, index, true, allocator);
        }
    }
    for (model.types[0..shared_count]) |ty| {
        const descriptor = try tagged(ty.descriptor);
        if (!std.mem.eql(u8, descriptor.name, "Scalar") and
            !std.mem.eql(u8, descriptor.name, "Atomic") and
            !std.mem.eql(u8, descriptor.name, "Vector") and
            !std.mem.eql(u8, descriptor.name, "Matrix")) return error.UnsupportedSharedType;
    }
    for (type_values.array.items, 0..) |*value, local_index| {
        try readType(&model, value, shared_count + local_index, false, allocator);
    }
    for (model.types, 0..) |ty, index| {
        const tag = try tagged(ty.descriptor);
        if (!isOpaque(tag.name)) _ = try typeLayout(&model, index, 0);
    }
    for (model.types[shared_count..], 0..) |*ty, local_index| {
        const index = shared_count + local_index;
        var collision_index = index;
        while (nameExists(model.types[shared_count..], local_index, ty.alias)) {
            collision_index += 1;
            ty.alias = try std.fmt.allocPrint(allocator, "{s}_type_{d}", .{ ty.alias, collision_index });
        }
    }
    return model;
}

fn readType(model: *Model, value: *const Value, index: usize, is_shared: bool, allocator: Allocator) !void {
    const id = try string(try field(value, "id"));
    const name = try string(try field(value, "name"));
    const descriptor = try field(value, "descriptor");
    for (model.types[0..index]) |previous| {
        if (std.mem.eql(u8, previous.id, id)) return error.DuplicateTypeId;
    }
    const alias = try zigIdentifier(allocator, name, index);
    model.types[index] = .{ .id = id, .name = name, .descriptor = descriptor, .alias = alias, .is_shared = is_shared };
}
