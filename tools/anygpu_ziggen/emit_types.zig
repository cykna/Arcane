const std = @import("std");
const schema = @import("schema.zig");
const layout = @import("layout.zig");
const identifiers = @import("identifiers.zig");
const common = @import("emit_common.zig");
const Writer = std.Io.Writer;
const Model = schema.Model;
const Value = schema.Value;
const field = schema.field;
const string = schema.string;
const number = schema.number;
const optionalU32 = schema.optionalU32;
const tagged = schema.tagged;
const writeZigString = common.writeZigString;
const writeOptionalU32 = common.writeOptionalU32;
const typeLayout = layout.typeLayout;
const findTypeReference = layout.findTypeReference;
const scalarType = layout.scalarType;
const scalarName = layout.scalarName;
const scalarSize = layout.scalarSize;
const checkedMul = layout.checkedMul;
const checkedAdd = layout.checkedAdd;
const vectorAlignment = layout.vectorAlignment;
const roundUp = layout.roundUp;
const zigIdentifier = identifiers.zigIdentifier;
const isOpaque = layout.isOpaque;
const stringExists = identifiers.stringExists;

pub fn emit(w: *Writer, model: *const Model) !void {
    for (model.types, 0..) |ty, index| {
        if (!shouldEmit(model, index)) continue;
        const descriptor = try tagged(ty.descriptor);
        if (isSharedType(descriptor.name)) continue;
        try writeTypeDefinition(w, model, index);
    }
    try w.writeByte('\n');
    for (model.types, 0..) |ty, index| {
        if (!shouldEmit(model, index)) continue;
        const descriptor = try tagged(ty.descriptor);
        if (isSharedType(descriptor.name)) continue;
        if (std.mem.eql(u8, descriptor.name, "Struct")) continue;
        try w.writeAll("pub const ");
        try w.writeAll(ty.alias);
        try w.writeAll(" = ");
        try writeTypeRef(w, model, index);
        try w.writeAll(";\n");
    }
    if (model.emit_mode == .linked_module) try emitCanonicalAliases(w, model);
    try w.writeByte('\n');
    try writeTypeLayouts(w, model);
}

pub fn shouldEmit(model: *const Model, index: usize) bool {
    const ty = model.types[index];
    return switch (model.emit_mode) {
        .legacy => index >= model.shared_count,
        .linked_module => !ty.is_canonical and
            std.mem.eql(u8, ty.owner_module orelse "", model.current_module orelse ""),
        .linked_canonical => ty.is_canonical and !ty.is_shared,
    };
}

fn emitCanonicalAliases(w: *Writer, model: *const Model) !void {
    var emitted: [][]const u8 = &.{};
    for (model.types) |ty| {
        if (!ty.is_canonical or ty.identity_name == null) continue;
        const raw_qualified = try replaceSeparators(model.allocator, ty.identity_module_path.?, "::", "_");
        const qualified = try std.fmt.allocPrint(model.allocator, "{s}_{s}", .{ raw_qualified, ty.identity_name.? });
        const legacy_alias = try zigIdentifier(model.allocator, qualified, 0);
        const alias = try uniqueCanonicalAlias(model, &emitted, legacy_alias, ty.source_id);
        try emitCanonicalAlias(w, alias, ty.alias);
        emitted = try appendName(model.allocator, emitted, alias);

        if (std.mem.eql(u8, ty.alias, ty.identity_name.?)) {
            const short_alias = try uniqueCanonicalAlias(model, &emitted, ty.identity_name.?, ty.source_id);
            if (std.mem.eql(u8, short_alias, ty.identity_name.?)) {
                try emitCanonicalAlias(w, short_alias, ty.alias);
                emitted = try appendName(model.allocator, emitted, short_alias);
            }
        }
    }
}

fn uniqueCanonicalAlias(model: *const Model, emitted: *const [][]const u8, raw: []const u8, id: []const u8) ![]const u8 {
    var alias = raw;
    for (model.types) |other| {
        if (!other.is_canonical and
            std.mem.eql(u8, other.owner_module orelse "", model.current_module orelse "") and
            std.mem.eql(u8, alias, other.alias))
        {
            alias = try std.fmt.allocPrint(model.allocator, "{s}_canonical_{s}", .{ raw, id });
            break;
        }
    }
    if (identifiers.stringExists(emitted.*, alias)) {
        alias = try std.fmt.allocPrint(model.allocator, "{s}_canonical_{s}", .{ raw, id });
    }
    if (identifiers.stringExists(emitted.*, alias)) return error.AmbiguousCanonicalName;
    return alias;
}

fn emitCanonicalAlias(w: *Writer, alias: []const u8, target: []const u8) !void {
    try w.writeAll("pub const ");
    try w.writeAll(alias);
    try w.writeAll(" = canonical.");
    try w.writeAll(target);
    try w.writeAll(";\n");
}

fn appendName(allocator: std.mem.Allocator, names: [][]const u8, name: []const u8) ![][]const u8 {
    const expanded = try allocator.alloc([]const u8, names.len + 1);
    @memcpy(expanded[0..names.len], names);
    expanded[names.len] = name;
    return expanded;
}

fn replaceSeparators(allocator: std.mem.Allocator, source: []const u8, separator: []const u8, replacement: []const u8) ![]const u8 {
    var output: Writer.Allocating = .init(allocator);
    const writer = &output.writer;
    var index: usize = 0;
    while (index < source.len) {
        if (std.mem.startsWith(u8, source[index..], separator)) {
            try writer.writeAll(replacement);
            index += separator.len;
        } else {
            try writer.writeByte(source[index]);
            index += 1;
        }
    }
    return try output.toOwnedSlice();
}

fn isSharedType(descriptor_name: []const u8) bool {
    return std.mem.eql(u8, descriptor_name, "Scalar") or
        std.mem.eql(u8, descriptor_name, "Atomic") or
        std.mem.eql(u8, descriptor_name, "Vector");
}

fn writeAlign(w: *Writer, alignment: u32) !void {
    if (alignment > 1) try w.print(" align({d})", .{alignment});
}

fn writeTypeName(w: *Writer, index: usize) !void {
    try w.print("Type_{d}", .{index});
}

fn writeDefinitionName(w: *Writer, model: *const Model, index: usize, descriptor_name: []const u8) !void {
    if (std.mem.eql(u8, descriptor_name, "Struct")) {
        try w.writeAll(model.types[index].alias);
    } else {
        try writeTypeName(w, index);
    }
}

pub fn writeTypeRef(w: *Writer, model: *const Model, index: usize) !void {
    const ty = model.types[index];
    const descriptor = try tagged(model.types[index].descriptor);
    if (model.emit_mode == .linked_module and ty.is_canonical and !ty.is_shared) {
        try w.writeAll("canonical.");
        try w.writeAll(ty.alias);
        return;
    }
    if (std.mem.eql(u8, descriptor.name, "Scalar") or std.mem.eql(u8, descriptor.name, "Atomic")) {
        if (model.types[index].is_shared) {
            try w.writeAll("shared.Wgsl");
            if (std.mem.eql(u8, descriptor.name, "Atomic")) try w.writeAll("Atomic");
            try w.writeAll(try scalarName(try field(descriptor.payload, "scalar")));
            return;
        }
        try w.writeAll(try scalarType(try field(descriptor.payload, "scalar")));
        return;
    }
    if (std.mem.eql(u8, descriptor.name, "Vector")) {
        const length = try number(try field(descriptor.payload, "length"));
        if (length < 2 or length > 4) return error.UnsupportedType;
        const scalar_name = try scalarName(try field(descriptor.payload, "scalar"));
        try w.print("shared.WgslVec{d}{s}", .{ length, scalar_name });
        return;
    }
    if (std.mem.eql(u8, descriptor.name, "Matrix") and model.types[index].is_shared) {
        const columns = try number(try field(descriptor.payload, "columns"));
        const rows = try number(try field(descriptor.payload, "rows"));
        const scalar_name = try scalarName(try field(descriptor.payload, "scalar"));
        try w.print("shared.WgslMat{d}x{d}{s}", .{ columns, rows, scalar_name });
        return;
    }
    if (std.mem.eql(u8, descriptor.name, "Struct")) {
        try w.writeAll(model.types[index].alias);
        return;
    }
    try writeTypeName(w, index);
}

fn writeScalarName(w: *Writer, scalar: *const Value) !void {
    try w.writeAll(try scalarType(scalar));
}

fn writePaddingField(w: *Writer, index: usize, count: u32) !void {
    if (count == 0) return;
    try w.print("    _padding_{d}: [{d}]u8,\n", .{ index, count });
}

fn writeZeroBytes(w: *Writer, count: u32) !void {
    try w.writeAll(".{ ");
    for (0..count) |index| {
        if (index != 0) try w.writeAll(", ");
        try w.writeByte('0');
    }
    try w.writeAll(" }");
}

fn writeTypeDefinition(w: *Writer, model: *const Model, index: usize) !void {
    const ty = model.types[index];
    const descriptor = try tagged(ty.descriptor);
    if (std.mem.eql(u8, descriptor.name, "Scalar")) {
        return error.UnexpectedSharedType;
    }
    if (std.mem.eql(u8, descriptor.name, "Atomic")) {
        return error.UnexpectedSharedType;
    }
    if (std.mem.eql(u8, descriptor.name, "Vector")) {
        return error.UnexpectedSharedType;
    }
    try w.writeAll("pub const ");
    try writeDefinitionName(w, model, index, descriptor.name);
    try w.writeAll(" = ");
    if (std.mem.eql(u8, descriptor.name, "Matrix")) {
        const columns = try number(try field(descriptor.payload, "columns"));
        const rows = try number(try field(descriptor.payload, "rows"));
        const scalar_size = try scalarSize(try field(descriptor.payload, "scalar"));
        const column_size = try checkedMul(rows, scalar_size);
        const alignment = try vectorAlignment(rows, scalar_size);
        const stride = try roundUp(column_size, alignment);
        try w.print("extern struct {{\n    _alignment: [0]u8 align({d}) = .{{}},\n    columns: [{d}]Type_{d}Column,\n}};\n", .{ alignment, columns, index });
        try w.print("const Type_{d}Column = extern struct {{\n    _alignment: [0]u8 align({d}) = .{{}},\n    value: ", .{ index, alignment });
        try w.print("shared.WgslVec{d}{s} align({d}),\n", .{ rows, try scalarType(try field(descriptor.payload, "scalar")), alignment });
        try writePaddingField(w, 0, stride - column_size);
        try w.writeAll("};\n");
        return;
    }
    if (std.mem.eql(u8, descriptor.name, "Array")) {
        const base_index = try findTypeReference(model, try field(descriptor.payload, "base"));
        const base_layout = try typeLayout(model, base_index, 0);
        const stride = try number(try field(descriptor.payload, "stride"));
        const count = try optionalU32(try field(descriptor.payload, "size"));
        if (stride > base_layout.size) {
            try w.print("const Type_{d}Element = extern struct {{\n", .{index});
            try w.print("    _alignment: [0]u8 align({d}) = .{{}},\n", .{base_layout.alignment});
            try w.writeAll("    value: ");
            try writeTypeRef(w, model, base_index);
            try writeAlign(w, base_layout.alignment);
            try w.writeAll(",\n");
            try writePaddingField(w, 0, stride - base_layout.size);
            try w.writeAll("};\n");
        }
        try w.print("extern struct {{\n    _alignment: [0]u8 align({d}) = .{{}},\n    items: [", .{base_layout.alignment});
        if (count) |size| {
            try w.print("{d}", .{size});
        } else {
            try w.writeByte('0');
        }
        try w.writeAll("]");
        if (stride > base_layout.size) {
            try w.print("Type_{d}Element", .{index});
        } else {
            try writeTypeRef(w, model, base_index);
        }
        try w.writeAll(",\n};\n");
        return;
    }
    if (std.mem.eql(u8, descriptor.name, "Struct")) {
        const alignment = try number(try field(descriptor.payload, "alignment"));
        const size = try number(try field(descriptor.payload, "size"));
        const members_value = try field(descriptor.payload, "members");
        try w.writeAll("extern struct {\n");
        if (size % alignment == 0) try w.print("    _alignment: [0]u8 align({d})=.{{}},\n", .{alignment});
        const emitted_names = try model.allocator.alloc([]const u8, members_value.array.items.len);
        var cursor: u32 = 0;
        var padding_index: usize = 0;
        for (members_value.array.items, 0..) |*member, member_index| {
            const offset = try number(try field(member, "offset"));
            const member_type = try findTypeReference(model, try field(member, "ty"));
            const member_layout = try typeLayout(model, member_type, 0);
            const member_name_value = try string(try field(member, "name"));
            const sanitized = try zigIdentifier(model.allocator, if (member_name_value.len == 0) "member" else member_name_value, member_index);
            var field_name = sanitized;
            var collision_suffix = member_index;
            while (std.mem.eql(u8, field_name, "init") or
                std.mem.eql(u8, field_name, "_alignment") or
                std.mem.startsWith(u8, field_name, "_padding_") or
                stringExists(emitted_names[0..member_index], field_name))
            {
                field_name = try std.fmt.allocPrint(model.allocator, "{s}_field_{d}", .{ sanitized, collision_suffix });
                collision_suffix += 1;
            }
            emitted_names[member_index] = field_name;
            if (offset > cursor) {
                try writePaddingField(w, padding_index, offset - cursor);
                padding_index += 1;
            }
            try w.print("    {s}: ", .{field_name});
            try writeMemberTypeRef(w, model, index, member_type);
            try writeAlign(w, member_layout.alignment);
            try w.writeAll(",\n");
            cursor = try checkedAdd(offset, member_layout.size);
        }
        try writePaddingField(w, padding_index, size - cursor);
        try w.writeAll("\n    pub fn init(");
        for (members_value.array.items, 0..) |*member, member_index| {
            if (member_index != 0) try w.writeAll(", ");
            try w.print("{s}: ", .{emitted_names[member_index]});
            const member_type = try findTypeReference(model, try field(member, "ty"));
            try writeMemberTypeRef(w, model, index, member_type);
        }
        try w.writeAll(") @This() {\n        return .{\n");
        if (size % alignment == 0) {
            try w.writeAll("            ._alignment = .{},\n");
        }
        cursor = 0;
        padding_index = 0;
        for (members_value.array.items, 0..) |*member, member_index| {
            const offset = try number(try field(member, "offset"));
            const member_type = try findTypeReference(model, try field(member, "ty"));
            const member_layout = try typeLayout(model, member_type, 0);
            if (offset > cursor) {
                try w.print("            ._padding_{d} = ", .{padding_index});
                try writeZeroBytes(w, offset - cursor);
                try w.writeAll(",\n");
                padding_index += 1;
            }
            try w.print("            .{s} = {s},\n", .{ emitted_names[member_index], emitted_names[member_index] });
            cursor = try checkedAdd(offset, member_layout.size);
        }
        if (size > cursor) {
            try w.print("            ._padding_{d} = ", .{padding_index});
            try writeZeroBytes(w, size - cursor);
            try w.writeAll(",\n");
        }
        try w.writeAll("        };\n    }\n");
        try w.writeAll("};\n");
        return;
    }
    if (isOpaque(descriptor.name)) {
        try w.writeAll("opaque {};\n");
        return;
    }
    return error.UnsupportedType;
}

fn writeMemberTypeRef(w: *Writer, model: *const Model, parent: usize, child: usize) anyerror!void {
    if (model.emit_mode == .linked_canonical and
        model.types[parent].is_canonical and
        !model.types[child].is_canonical)
    {
        return writeInlineTypeRef(w, model, child, 0);
    }
    return writeTypeRef(w, model, child);
}

fn writeInlineTypeRef(w: *Writer, model: *const Model, index: usize, depth: usize) anyerror!void {
    if (depth > model.types.len) return error.InvalidLayout;
    const ty = model.types[index];
    if (ty.is_canonical) return writeTypeRef(w, model, index);
    const descriptor = try tagged(ty.descriptor);
    if (std.mem.eql(u8, descriptor.name, "Array")) {
        const base_index = try findTypeReference(model, try field(descriptor.payload, "base"));
        const base_layout = try typeLayout(model, base_index, depth + 1);
        const stride = try number(try field(descriptor.payload, "stride"));
        const count = try optionalU32(try field(descriptor.payload, "size"));
        try w.writeByte('[');
        if (count) |size| {
            try w.print("{d}", .{size});
        } else {
            try w.writeByte('0');
        }
        try w.writeByte(']');
        if (stride <= base_layout.size) {
            return writeInlineTypeRef(w, model, base_index, depth + 1);
        }
        try w.writeAll("extern struct { _alignment: [0]u8 align(");
        try w.print("{d}", .{base_layout.alignment});
        try w.writeAll(") = .{}, value: ");
        try writeInlineTypeRef(w, model, base_index, depth + 1);
        try w.writeAll(" align(");
        try w.print("{d}", .{base_layout.alignment});
        try w.writeAll("), _padding: [");
        try w.print("{d}", .{stride - base_layout.size});
        try w.writeAll("]u8 }");
        return;
    }
    if (std.mem.eql(u8, descriptor.name, "Struct")) {
        const size = try number(try field(descriptor.payload, "size"));
        const alignment = try number(try field(descriptor.payload, "alignment"));
        const members = try field(descriptor.payload, "members");
        if (members.* != .array) return error.InvalidSchema;
        try w.writeAll("extern struct { ");
        if (size % alignment == 0) {
            try w.writeAll("_alignment: [0]u8 align(");
            try w.print("{d}", .{alignment});
            try w.writeAll(") = .{}, ");
        }
        var cursor: u32 = 0;
        for (members.array.items, 0..) |*member, member_index| {
            const offset = try number(try field(member, "offset"));
            const member_type = try findTypeReference(model, try field(member, "ty"));
            const member_layout = try typeLayout(model, member_type, depth + 1);
            if (offset > cursor) {
                try w.writeAll("_padding_");
                try w.print("{d}: [{d}]u8, ", .{ member_index, offset - cursor });
            }
            try w.writeAll("member_");
            try w.print("{d}: ", .{member_index});
            try writeInlineTypeRef(w, model, member_type, depth + 1);
            try writeAlign(w, member_layout.alignment);
            try w.writeAll(", ");
            cursor = try checkedAdd(offset, member_layout.size);
        }
        if (size > cursor) {
            try w.print("_padding_{d}: [{d}]u8, ", .{ members.array.items.len, size - cursor });
        }
        try w.writeByte('}');
        return;
    }
    return writeTypeRef(w, model, index);
}

fn writeTypeLayouts(w: *Writer, model: *const Model) !void {
    try w.writeAll("pub const type_layouts = [_]shared.WgslTypeLayout{");
    try w.writeByte('\n');
    for (model.types, 0..) |ty, index| {
        if (!shouldEmit(model, index)) continue;
        const descriptor = try tagged(ty.descriptor);
        const is_opaque = isOpaque(descriptor.name);
        const type_layout = if (is_opaque) null else try typeLayout(model, index, 0);
        const stride = if (std.mem.eql(u8, descriptor.name, "Array"))
            try number(try field(descriptor.payload, "stride"))
        else
            null;
        const length = if (std.mem.eql(u8, descriptor.name, "Array"))
            try optionalU32(try field(descriptor.payload, "size"))
        else
            null;
        try w.writeAll("    .{ .id = ");
        try writeZigString(w, ty.source_id);
        try w.writeAll(", .name = ");
        try writeZigString(w, ty.name);
        try w.writeAll(", .size = ");
        try writeOptionalU32(w, if (std.mem.eql(u8, descriptor.name, "Array") and length == null) null else if (type_layout) |value| value.size else null);
        try w.writeAll(", .alignment = ");
        try writeOptionalU32(w, if (type_layout) |value| value.alignment else null);
        try w.writeAll(", .array_stride = ");
        try writeOptionalU32(w, stride);
        try w.writeAll(", .array_length = ");
        try writeOptionalU32(w, length);
        try w.writeAll(" },\n");
    }
    try w.writeAll("};\n\n");
}
