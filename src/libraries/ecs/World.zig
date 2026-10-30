const std = @import("std");

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

pub const World = struct {
    const PhantomMultiArrayList = struct {
        _: [*]align(1) u8,
        __: usize,
        ___: usize,
    };

    const Global = struct {
        ptr: *anyopaque,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    globals: std.array_hash_map.Auto(TypeId, Global) = .empty,
    storage: std.ArrayList(PhantomMultiArrayList) = .empty,
    types: std.array_hash_map.Auto(TypeId, u32) = .empty,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn insertGlobal(self: *Self, value: anytype) !void {
        const T = @TypeOf(value);
        const ptr = try self.allocator.create(T);
        errdefer self.allocator.destroy(ptr);
        ptr.* = value;

        const Impl = struct {
            fn destroy(p: *anyopaque, a: std.mem.Allocator) void {
                const typed: *T = @ptrCast(@alignCast(p));
                a.destroy(typed);
            }
        };
        try self.globals.put(self.allocator, typeId(T), .{ .ptr = ptr, .destroy = &Impl.destroy });
    }

    pub fn getGlobal(self: *Self, comptime T: type) ?*T {
        const p = self.globals.get(typeId(T)) orelse return null;
        return @ptrCast(@alignCast(p.ptr));
    }

    pub fn storageOf(self: *Self, comptime T: type) !*std.MultiArrayList(T) {
        const t = typeId(T);
        if (self.types.get(t)) |index| {
            return @ptrCast(&self.storage.items[index]);
        } else {
            const index = self.storage.items.len;
            const array = try std.MultiArrayList(T).initCapacity(self.allocator, 0);
            try self.storage.append(self.allocator, @as(*const PhantomMultiArrayList, @ptrCast(&array)).*);
            try self.types.put(self.allocator, t, @intCast(index));
            return @ptrCast(&self.storage.items[index]);
        }
    }

    pub fn read(self: *Self, comptime T: type, entity: EntityId(T)) !?T {
        const storage = try self.storageOf(T);
        if (entity.index > storage.len) return null;
        return storage.get(entity.index);
    }

    pub fn insert(self: *Self, value: anytype) !EntityId(@TypeOf(value)) {
        const storage = try self.storageOf(@TypeOf(value));
        const index = storage.len;
        try storage.append(self.allocator, value);
        return EntityId(@TypeOf(value)){ .index = index };
    }

    pub fn deinit(self: *Self) void {
        self.types.deinit(self.allocator);
        self.storage.deinit(self.allocator);
        {
            var it = self.globals.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.destroy(entry.value_ptr.ptr, self.allocator);
            }
        }
        self.globals.deinit(self.allocator);
    }

    pub fn QueryCursor(comptime T: type) type {
        return struct {
            list: *std.MultiArrayList(T),
            index: usize = 0,
            const Field = std.meta.FieldEnum(T);

            pub fn next(self: *@This()) ?void {
                if (self.index > self.list.len) {
                    return null;
                } else {
                    return;
                }
            }

            pub fn get(self: @This(), comptime f: Field) *@FieldType(T, @tagName(f)) {
                return &self.list.items(f)[self.index];
            }

            pub fn items(self: @This(), comptime f: Field) []@FieldType(T, @tagName(f)) {
                return self.list.items(f);
            }
        };
    }

    pub fn query(self: *Self, comptime T: type, comptime Condition: type) !struct { QueryCursor(T), Condition.Output } {
        const s = try self.storageOf(T);
        return .{ QueryCursor(T){ .list = s }, Condition.fetch(self) };
    }
};
