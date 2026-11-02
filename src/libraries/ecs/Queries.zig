const World = @import("World.zig").World;
const std = @import("std");
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
