const std = @import("std");
const StructReflector = struct {
    t: type,
    const Self = @This();
    pub const StructField = struct { name: []const u8, ty: type, attr: std.lang.Type.Struct.FieldAttributes };

    pub fn fromFields(comptime fields: []const StructField, tuple: bool) Self {
        const names, const types, const attrs = names: {
            var names: [fields.len][]const u8 = undefined;
            var tys: [fields.len]type = undefined;
            var attrs: [fields.len]std.lang.Type.Struct.FieldAttributes = undefined;
            inline for (fields, 0..) |field, i| {
                names[i] = field.name;
                tys[i] = field.ty;
                attrs[i] = .{ .@"align" = field.attr.@"align" };
            }
            break :names .{ &names, &tys, &attrs };
        };
        if (tuple) {
            return Self{ .t = @Tuple(types) };
        } else {
            return Self{ .t = @Struct(.auto, null, names, types, attrs) };
        }
    }

    pub fn structInfo(comptime self: Self) std.lang.Type.Struct {
        return @typeInfo(self.t).@"struct";
    }
    pub fn isTuple(comptime self: Self) bool {
        return self.structInfo().is_tuple;
    }
    pub fn raw(comptime self: Self) type {
        return self.t;
    }

    pub fn getFields(comptime self: Self) [self.structInfo().field_names.len]StructField {
        const info = self.structInfo();
        var out: [info.field_names.len]StructField = undefined;
        inline for (info.field_attrs, info.field_names, info.field_types, 0..) |attr, name, ty, i| {
            out[i] = .{
                .name = name,
                .ty = ty,
                .attr = attr,
            };
        }
        return out;
    }

    ///Maps all the fields of this struct with the given `f`
    pub fn mapFields(comptime self: Self, f: fn (comptime T: type) type) Self {
        const fields = self.getFields();
        var mapped = fields;
        for (fields, 0..) |field, i| {
            mapped[i].ty = f(field.ty);
        }
        return Self.fromFields(&mapped, self.isTuple());
    }

    pub fn rename(comptime self: Self, field_name: []const u8, target_name: []const u8) Self {
        const selft = self.structInfo();
        checkExistance: {
            inline for (selft.field_names) |name| {
                if (std.mem.eql(u8, name, field_name)) {
                    break :checkExistance;
                }
            }
            return self;
        }

        const field_names, const field_types, const attrs = names: {
            var names: [selft.field_names.len][]const u8 = undefined;
            var tys: [selft.field_names.len]type = undefined;
            var attrs: [selft.field_attrs.len]std.lang.Type.Struct.FieldAttributes = undefined;
            inline for (selft.field_names, selft.field_types, selft.field_attrs, 0..) |name, ty, attr, i| {
                names[i] = if (std.mem.eql(u8, name, field_name)) {
                    target_name;
                } else {
                    name;
                };

                tys[i] = ty;
                attrs[i] = attr;
            }
            break :names .{ names, tys, attrs };
        };

        return Self{ .t = @Struct(.auto, null, &field_names, &field_types, &attrs) };
    }

    ///Removes all the fields with the given `fieldNames` of this struct.
    ///Hint: `fieldNames` is an array of strings
    pub fn withoutFields(comptime self: Self, fieldNames: anytype) Self {
        var this = self;
        for (fieldNames) |field| {
            this = this.without(field);
        }
        return this;
    }

    pub fn without(comptime self: Self, field_name: []const u8) Self {
        const selft = self.structInfo();
        checkExistance: {
            inline for (selft.field_names) |name| {
                if (std.mem.eql(u8, name, field_name)) {
                    break :checkExistance;
                }
            }
            @compileError(std.fmt.comptimePrint("Cannot remove field '{s}' since it does not exist", .{field_name}));
        }

        const field_names, const field_types, const attrs = names: {
            var names: [selft.field_names.len - 1][]const u8 = undefined;
            var tys: [selft.field_names.len - 1]type = undefined;
            var attrs: [selft.field_attrs.len - 1]std.lang.Type.Struct.FieldAttributes = undefined;
            var i = 0;
            inline for (selft.field_names, selft.field_types, selft.field_attrs) |name, ty, attr| {
                if (std.mem.eql(u8, name, field_name)) continue;
                names[i] = name;
                tys[i] = ty;
                attrs[i] = attr;
                i += 1;
            }
            break :names .{ names, tys, attrs };
        };

        return Self{ .t = @Struct(.auto, null, &field_names, &field_types, &attrs) };
    }

    pub fn join(comptime self: Self, comptime B: type) Self {
        const bself = StructReflect(B);
        const selft = self.structInfo();
        const Bt = bself.structInfo();
        const names = selft.field_names ++ Bt.field_names;
        const types = selft.field_types ++ Bt.field_types;
        const attrs = selft.field_attrs ++ Bt.field_attrs;

        return Self{ .t = @Struct(
            selft.layout,
            selft.backing_integer,
            names,
            types,
            attrs,
        ) };
    }
};

const PointerReflector = struct {
    p: type,
    const Self = @This();
    pub fn ptrInfo(comptime self: Self) std.lang.Type.Pointer {
        return @typeInfo(self.p).pointer;
    }
    pub fn isImutable(comptime self: Self) bool {
        const info = self.ptrInfo();
        return info.attrs.@"const";
    }
    ///Makes a new pointer for the given `K` with all the information of this pointer
    pub fn follow(comptime self: Self, comptime K: type) PointerReflector {
        const info = self.ptrInfo();
        const kinfo = Reflect.Ptr(*const K).ptrInfo();
        return PointerReflector{ .p = @Pointer(info.size, info.attrs, K, kinfo.sentinel()) };
    }
    pub fn raw(comptime self: Self) type {
        return self.p;
    }
};

pub fn StructReflect(comptime T: anytype) StructReflector {
    return Reflect.Struct(T);
}
pub fn TupleReflect(comptime T: anytype) StructReflector {
    return Reflect.Tuple(T);
}

pub const Reflect = struct {
    pub fn Struct(comptime T: anytype) StructReflector {
        const s = @typeInfo(@TypeOf(T));

        if (s != .@"struct") @compileError("Reflect.Struct only accepts struct types");
        if (s.@"struct".is_tuple) @compileError("Reflect.Struct only accepts struct types");
        return StructReflector{ .t = @TypeOf(T) };
    }
    pub fn Ptr(comptime T: type) PointerReflector {
        const s = @typeInfo(T);
        if (s != .pointer) @compileError("Reflect.Ptr only accepts pointer types");
        return PointerReflector{ .p = T };
    }

    pub fn Tuple(comptime T: anytype) StructReflector {
        const s = @typeInfo(@TypeOf(T));
        if (s == .@"struct" and s.@"struct".is_tuple) {
            return StructReflector{ .t = @TypeOf(T) };
        } else @compileError("Reflect.TUple only accepts tuple types");
    }
};
