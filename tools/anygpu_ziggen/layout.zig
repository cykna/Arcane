const std = @import("std");
const schema = @import("schema.zig");
const Model = schema.Model;
const Layout = schema.Layout;
const Value = schema.Value;
const field = schema.field;
const string = schema.string;
const number = schema.number;
const optionalU32 = schema.optionalU32;
const tagged = schema.tagged;

pub fn scalarType(value: *const Value) ![]const u8 {
    const scalar_name = try string(try field(value, "name"));
    const width = try number(try field(value, "width"));
    if (std.mem.eql(u8, scalar_name, "bool")) return "u32";
    if (std.mem.eql(u8, scalar_name, "sint")) return switch (width) {
        1 => "i8",
        2 => "i16",
        4 => "i32",
        8 => "i64",
        else => error.UnsupportedScalar,
    };
    if (std.mem.eql(u8, scalar_name, "uint")) return switch (width) {
        1 => "u8",
        2 => "u16",
        4 => "u32",
        8 => "u64",
        else => error.UnsupportedScalar,
    };
    if (std.mem.eql(u8, scalar_name, "float")) return switch (width) {
        2 => "f16",
        4 => "f32",
        8 => "f64",
        else => error.UnsupportedScalar,
    };
    return error.UnsupportedScalar;
}

pub fn scalarName(value: *const Value) ![]const u8 {
    const scalar_name = try string(try field(value, "name"));
    if (std.mem.eql(u8, scalar_name, "bool")) return "bool";
    return try scalarType(value);
}

pub fn scalarSize(value: *const Value) !u32 {
    const scalar_name = try string(try field(value, "name"));
    const width = try number(try field(value, "width"));
    if (std.mem.eql(u8, scalar_name, "bool")) return 4;
    if (width == 1 or width == 2 or width == 4 or width == 8) return width;
    return error.UnsupportedScalar;
}

pub fn roundUp(value: u32, alignment: u32) !u32 {
    if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidLayout;
    const mask = alignment - 1;
    const sum = @addWithOverflow(value, mask);
    if (sum[1] != 0) return error.InvalidLayout;
    return sum[0] & ~mask;
}

pub fn checkedMul(a: u32, b: u32) !u32 {
    const result = @mulWithOverflow(a, b);
    if (result[1] != 0) return error.InvalidLayout;
    return result[0];
}

pub fn checkedAdd(a: u32, b: u32) !u32 {
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return error.InvalidLayout;
    return result[0];
}

pub fn vectorAlignment(length: u32, scalar_size: u32) !u32 {
    return try checkedMul(scalar_size, if (length == 2) 2 else if (length == 3 or length == 4) 4 else return error.InvalidLayout);
}

pub fn findType(model: *const Model, id: []const u8) !usize {
    for (model.types, 0..) |ty, index| {
        if (std.mem.eql(u8, ty.id, id)) return index;
    }
    return error.UnknownType;
}

pub fn typeLayout(model: *const Model, index: usize, depth: usize) anyerror!Layout {
    if (depth > model.types.len) return error.InvalidLayout;
    const ty = model.types[index];
    const descriptor = try tagged(ty.descriptor);
    if (std.mem.eql(u8, descriptor.name, "Scalar") or std.mem.eql(u8, descriptor.name, "Atomic")) {
        const scalar = try field(descriptor.payload, "scalar");
        const size = try scalarSize(scalar);
        return .{ .size = size, .alignment = size };
    }
    if (std.mem.eql(u8, descriptor.name, "Vector")) {
        const length = try number(try field(descriptor.payload, "length"));
        const scalar = try field(descriptor.payload, "scalar");
        const size = try scalarSize(scalar);
        return .{
            .size = try checkedMul(length, size),
            .alignment = try vectorAlignment(length, size),
        };
    }
    if (std.mem.eql(u8, descriptor.name, "Matrix")) {
        const columns = try number(try field(descriptor.payload, "columns"));
        const rows = try number(try field(descriptor.payload, "rows"));
        const scalar_size = try scalarSize(try field(descriptor.payload, "scalar"));
        const column_size = try checkedMul(rows, scalar_size);
        const alignment = try vectorAlignment(rows, scalar_size);
        const stride = try roundUp(column_size, alignment);
        return .{
            .size = try checkedMul(columns, stride),
            .alignment = alignment,
        };
    }
    if (std.mem.eql(u8, descriptor.name, "Array")) {
        const base_id = try string(try field(descriptor.payload, "base"));
        const base = try typeLayout(model, try findType(model, base_id), depth + 1);
        const stride = try number(try field(descriptor.payload, "stride"));
        if (stride < base.size or stride % base.alignment != 0) return error.InvalidLayout;
        const size_value = try field(descriptor.payload, "size");
        const size = try optionalU32(size_value);
        return .{
            .size = if (size) |count| try checkedMul(stride, count) else 0,
            .alignment = base.alignment,
        };
    }
    if (std.mem.eql(u8, descriptor.name, "Struct")) {
        const size = try number(try field(descriptor.payload, "size"));
        const alignment = try number(try field(descriptor.payload, "alignment"));
        if (alignment == 0 or !std.math.isPowerOfTwo(alignment)) return error.InvalidLayout;
        const members_value = try field(descriptor.payload, "members");
        if (members_value.* != .array) return error.InvalidSchema;
        var end: u32 = 0;
        for (members_value.array.items) |*member| {
            const offset = try number(try field(member, "offset"));
            const member_id = try string(try field(member, "ty"));
            const member_layout = try typeLayout(model, try findType(model, member_id), depth + 1);
            if (offset < end or offset % member_layout.alignment != 0) return error.InvalidLayout;
            end = try checkedAdd(offset, member_layout.size);
            if (end > size) return error.InvalidLayout;
        }
        return .{ .size = size, .alignment = alignment };
    }
    if (std.mem.eql(u8, descriptor.name, "Pointer") or
        std.mem.eql(u8, descriptor.name, "BindingArray") or
        std.mem.eql(u8, descriptor.name, "Sampler") or
        std.mem.eql(u8, descriptor.name, "Image"))
    {
        return error.NoMemoryLayout;
    }
    return error.UnsupportedType;
}

pub fn isOpaque(descriptor_name: []const u8) bool {
    return std.mem.eql(u8, descriptor_name, "Pointer") or
        std.mem.eql(u8, descriptor_name, "BindingArray") or
        std.mem.eql(u8, descriptor_name, "Sampler") or
        std.mem.eql(u8, descriptor_name, "Image");
}
