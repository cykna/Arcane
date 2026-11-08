const std = @import("std");
const arcaneecs = @import("./Main.zig");
const TypeId = arcaneecs.TypeId;
const typeId = arcaneecs.typeId;
const EntityId = arcaneecs.EntityId;

pub fn TypeArray(comptime T: type) type {
    return struct {
        const Self = @This();

        map: std.array_hash_map.Auto(TypeId, u32) = .empty,
        values: std.ArrayList(T) = .empty,

        pub fn get(self: *Self, comptime U: type) ?*T {
            const index = self.map.get(typeId(U)) orelse return null;
            return &self.values.items[index];
        }

        /// Returns the current inline value index for a compile-time type key.
        /// The index remains valid while this key stays in the map, even if
        /// `values` reallocates; pointers to the corresponding value do not.
        pub fn indexOf(self: *const Self, comptime U: type) ?usize {
            const index = self.map.get(typeId(U)) orelse return null;
            return index;
        }

        pub fn getOrPut(
            self: *Self,
            allocator: std.mem.Allocator,
            comptime U: type,
            value: T,
        ) !*T {
            const id = typeId(U);

            if (self.map.get(id)) |index| {
                return &self.values.items[index];
            }

            const index = self.values.items.len;

            try self.values.append(allocator, value);
            errdefer _ = self.values.pop();

            try self.map.put(allocator, id, @intCast(index));

            return &self.values.items[index];
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.map.deinit(allocator);
            self.values.deinit(allocator);
        }
    };
}
