const std = @import("std");
const schema = @import("schema.zig");
const layout = @import("layout.zig");
const Model = schema.Model;
const Writer = std.Io.Writer;
const field = schema.field;
const number = schema.number;
const tagged = schema.tagged;
const scalarType = layout.scalarType;
const scalarName = layout.scalarName;
const scalarSize = layout.scalarSize;
const checkedMul = layout.checkedMul;
const vectorAlignment = layout.vectorAlignment;
const roundUp = layout.roundUp;

pub fn emit(w: *Writer, model: *const Model, allocator: std.mem.Allocator, seen: *[][]const u8) !void {
    for (0..4) |pass| {
        for (model.types) |ty| {
            const descriptor = try tagged(ty.descriptor);
            const is_scalar = std.mem.eql(u8, descriptor.name, "Scalar");
            const is_atomic = std.mem.eql(u8, descriptor.name, "Atomic");
            const is_vector = std.mem.eql(u8, descriptor.name, "Vector");
            const is_matrix = std.mem.eql(u8, descriptor.name, "Matrix");
            const should_emit = switch (pass) {
                0 => (is_scalar or is_atomic) and ty.is_shared,
                1 => is_vector,
                2 => is_matrix,
                3 => is_matrix and ty.is_shared,
                else => unreachable,
            };
            if (!should_emit) continue;

            if (pass == 2) {
                const rows = try number(try field(descriptor.payload, "rows"));
                const scalar = try field(descriptor.payload, "scalar");
                const scalar_name = try scalarName(scalar);
                const scalar_type = try scalarType(scalar);
                const vector_name = try std.fmt.allocPrint(allocator, "WgslVec{d}{s}", .{ rows, scalar_name });
                if (try markSeen(allocator, seen, vector_name)) {
                    try w.print("pub const {s} = Vec{d}{s};\n", .{ vector_name, rows, scalar_type });
                }
                continue;
            }

            const generated_name = try sharedTypeName(allocator, descriptor.name, descriptor.payload);
            if (!try markSeen(allocator, seen, generated_name)) continue;
            if (is_scalar or is_atomic) {
                try w.writeAll("pub const ");
                try w.writeAll(generated_name);
                try w.writeAll(" = ");
                try w.writeAll(try scalarType(try field(descriptor.payload, "scalar")));
                try w.writeAll(";\n");
                const size = try scalarSize(try field(descriptor.payload, "scalar"));
                try writeLayoutAssertions(w, generated_name, size, size);
            } else if (is_vector) {
                const length = try number(try field(descriptor.payload, "length"));
                const scalar = try field(descriptor.payload, "scalar");
                const scalar_name = try scalarType(scalar);
                try w.print("pub const {s} = Vec{d}{s};\n", .{ generated_name, length, scalar_name });
                try writeLayoutAssertions(w, generated_name, try checkedMul(length, try scalarSize(scalar)), null);
            } else {
                try emitMatrix(w, generated_name, descriptor.payload);
            }
        }
    }
}

fn writeLayoutAssertions(w: *Writer, name: []const u8, size: u32, alignment: ?u32) !void {
    try w.print("comptime {{\n    if (@sizeOf({s}) != {d}) @compileError(\"anygpu shared type size mismatch\");\n", .{ name, size });
    if (alignment) |value| try w.print("    if (@alignOf({s}) != {d}) @compileError(\"anygpu shared type alignment mismatch\");\n", .{ name, value });
    try w.writeAll("}\n");
}

fn sharedTypeName(allocator: std.mem.Allocator, descriptor_name: []const u8, payload: *const schema.Value) ![]const u8 {
    if (std.mem.eql(u8, descriptor_name, "Scalar")) {
        return try std.fmt.allocPrint(allocator, "Wgsl{s}", .{try scalarName(try field(payload, "scalar"))});
    }
    if (std.mem.eql(u8, descriptor_name, "Atomic")) {
        return try std.fmt.allocPrint(allocator, "WgslAtomic{s}", .{try scalarName(try field(payload, "scalar"))});
    }
    if (std.mem.eql(u8, descriptor_name, "Vector")) {
        const length = try number(try field(payload, "length"));
        if (length < 2 or length > 4) return error.UnsupportedType;
        return try std.fmt.allocPrint(allocator, "WgslVec{d}{s}", .{ length, try scalarName(try field(payload, "scalar")) });
    }
    if (std.mem.eql(u8, descriptor_name, "Matrix")) {
        const columns = try number(try field(payload, "columns"));
        const rows = try number(try field(payload, "rows"));
        if (columns < 2 or columns > 4 or rows < 2 or rows > 4) return error.UnsupportedType;
        return try std.fmt.allocPrint(allocator, "WgslMat{d}x{d}{s}", .{ columns, rows, try scalarName(try field(payload, "scalar")) });
    }
    return error.UnsupportedType;
}

fn markSeen(allocator: std.mem.Allocator, seen: *[][]const u8, name: []const u8) !bool {
    for (seen.*) |previous| {
        if (std.mem.eql(u8, previous, name)) return false;
    }
    const expanded = try allocator.alloc([]const u8, seen.len + 1);
    @memcpy(expanded[0..seen.len], seen.*);
    expanded[seen.len] = name;
    seen.* = expanded;
    return true;
}

fn emitMatrix(w: *Writer, name: []const u8, payload: *const schema.Value) !void {
    const columns = try number(try field(payload, "columns"));
    const rows = try number(try field(payload, "rows"));
    const scalar = try field(payload, "scalar");
    const scalar_name = try scalarName(scalar);
    const scalar_size = try scalarSize(scalar);
    const column_size = try checkedMul(rows, scalar_size);
    const alignment = try vectorAlignment(rows, scalar_size);
    const stride = try roundUp(column_size, alignment);
    const size = try checkedMul(columns, stride);
    try w.print(
        \\pub const {s} = extern struct {{
        \\    _alignment: [0]u8 align({d}),
        \\    columns: [{d}]{s}Column,
        \\}};
        \\const {s}Column = extern struct {{
        \\    _alignment: [0]u8 align({d}),
        \\    value: WgslVec{d}{s} align({d}),
    , .{ name, alignment, columns, name, name, alignment, rows, scalar_name, alignment });
    if (stride > column_size) try w.print("    _padding_0: [{d}]u8,\n", .{stride - column_size});
    try w.writeAll("};\n");
    try w.print(
        \\comptime {{
        \\    if (@sizeOf({s}) != {d}) @compileError("anygpu shared matrix size mismatch");
        \\    if (@alignOf({s}) != {d}) @compileError("anygpu shared matrix alignment mismatch");
        \\}}
        \\
    , .{ name, size, name, alignment });
}
