pub const World = @import("World.zig").World;
pub const Queries = @import("Queries.zig");
pub const TypeId = *const struct { _: u8 };
pub const OpaqueEntityId = struct { id: TypeId, index: usize };
pub fn EntityId(comptime T: type) type {
    return struct {
        index: usize,
        pub fn toOpaque(self: *const @This()) OpaqueEntityId {
            return OpaqueEntityId{ .id = typeId(T), .index = self.index };
        }
    };
}

pub inline fn typeId(comptime T: type) TypeId {
    return &struct {
        comptime {
            _ = T;
        }
        var id: @typeInfo(TypeId).pointer.child = undefined;
    }.id;
}
