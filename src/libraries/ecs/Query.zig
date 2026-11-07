const std = @import("std");
const Reflect = @import("../reflects/Reflect.zig").Reflect;
const World = @import("World.zig").World;

///A query that happens with imutable data
pub const Imut = struct {};

///A query that happens with mutable data
pub const Mut = struct {};

///A query that happens with multi thread shared data
pub const Shared = struct {};

pub fn QueryCursor(comptime T: type, comptime Mutability: type) type {
    const Field = std.meta.FieldEnum(T);

    const Entities = switch (Mutability) {
        Imut => *const std.MultiArrayList(T),
        Mut, Shared => *std.MultiArrayList(T),
        else => @compileError("Query cursor only works with Imut, Mut and Shared"),
    };

    return struct {
        list: Entities,
        index: usize = 0,

        const ContentType = Reflect.Ptr(Entities);
        const Self = @This();
        fn NextItemsType(comptime fields: anytype) type {
            comptime var types: [fields.len]type = undefined;

            inline for (fields, 0..) |field, i| {
                types[i] = ContentType
                    .follow(@FieldType(T, @tagName(field)))
                    .raw();
            }

            return @Tuple(&types);
        }

        pub fn nextItems(self: *Self, comptime fields: anytype) ?NextItemsType(fields) {
            if (self.index >= self.list.len) return null;

            var result: NextItemsType(fields) = undefined;

            inline for (fields, 0..) |field, i| {
                result[i] = &self.list.items(field)[self.index];
            }

            self.index += 1;
            return result;
        }

        ///Gets the current content of the cursor.
        pub fn get(self: *Self, comptime f: Field) ContentType.follow(@FieldType(T, @tagName(f))).raw() {
            std.debug.assert(self.index > 0);
            return &self.list.items(f)[if (self.index == 0) 0 else self.index - 1];
        }

        pub fn items(self: Self, comptime f: Field) []@FieldType(T, @tagName(f)) {
            return self.list.items(f);
        }
    };
}

pub fn Resource(comptime P: type) type {
    return struct {
        pub const Output = *P;
        pub fn fetch(world: *World) Output {
            return world.getGlobal(P) orelse
                @panic("Global " ++ @typeName(P) ++ " not registered");
        }
    };
}

/// Join(Single(*A)) ou Join(.{ Single(*A), Single(*B) })
pub fn Join(comptime fs: anytype) type {
    const list = if (@TypeOf(fs) == type) .{fs} else fs;
    if (list.len == 1) return list[0];

    comptime var items: [list.len]type = undefined;
    inline for (list, 0..) |F, i| items[i] = F.Output;
    const Tup = std.meta.Tuple(&items);

    return struct {
        pub const Output = Tup;
        pub fn fetch(world: *World) Output {
            var out: Output = undefined;
            inline for (list, 0..) |F, i| out[i] = F.fetch(world);
            return out;
        }
    };
}

pub const Null = struct {
    pub const Output = void;
    pub fn fetch(_: *World) Output {}
};
