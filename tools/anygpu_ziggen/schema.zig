const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Value = std.json.Value;

pub const TypeInfo = struct {
    id: []const u8,
    name: []const u8,
    descriptor: *const Value,
    alias: []const u8,
    is_shared: bool,
};

pub const Model = struct {
    allocator: Allocator,
    types: []TypeInfo,
    shared_count: usize,
};

pub const Layout = struct {
    size: u32,
    alignment: u32,
};

pub const BindingDetails = struct {
    kind: []const u8,
    resource_type: ?[]const u8 = null,
    read_only: ?[]const u8 = null,
    sampler_type: ?[]const u8 = null,
    sample_type: ?[]const u8 = null,
    filterable: ?bool = null,
    view_dimension: ?[]const u8 = null,
    multisampled: ?bool = null,
    storage_access: ?[]const u8 = null,
    format: ?[]const u8 = null,
    has_dynamic_offset: bool = false,
    min_binding_size: ?u64 = null,
};

pub fn object(value: *const Value) !*const std.json.ObjectMap {
    return switch (value.*) {
        .object => |*items| items,
        else => error.InvalidSchema,
    };
}

pub fn field(value: *const Value, name: []const u8) !*const Value {
    return (try object(value)).getPtr(name) orelse error.MissingField;
}

pub fn string(value: *const Value) ![]const u8 {
    return switch (value.*) {
        .string => |text| text,
        else => error.InvalidSchema,
    };
}

pub fn number(value: *const Value) !u32 {
    return switch (value.*) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else error.InvalidSchema,
        else => error.InvalidSchema,
    };
}

pub fn optionalU32(value: *const Value) !?u32 {
    if (value.* == .null) return null;
    return try number(value);
}

pub fn boolean(value: *const Value) !bool {
    return switch (value.*) {
        .bool => |b| b,
        else => error.InvalidSchema,
    };
}

const Tagged = struct {
    name: []const u8,
    payload: *const Value,
};

pub fn tagged(value: *const Value) !Tagged {
    const values = try object(value);
    if (values.count() != 1) return error.InvalidSchema;
    var iterator = values.iterator();
    const entry = iterator.next() orelse return error.InvalidSchema;
    return .{ .name = entry.key_ptr.*, .payload = entry.value_ptr };
}
