const Query = @import("./Query.zig");
const TypeArray = @import("./TypeArray.zig").TypeArray;
const std = @import("std");
const arcaneecs = @import("./Main.zig");
const TypeId = arcaneecs.TypeId;
const typeId = arcaneecs.typeId;
const EntityId = arcaneecs.EntityId;

pub const World = struct {
    pub const Mutabilities = struct {
        pub const imut = Query.Imut;
        pub const mut = Query.Mut;
    };
    pub const QueryCursor = Query.QueryCursor;
    pub const Loaders = struct {
        pub const Null = Query.Null;
        pub const Global = Query.Resource;
        pub const Join = Query.Join;
    };

    const PhantomMultiArrayList = struct {
        _: [*]align(1) u8,
        __: usize,
        ___: usize,
    };

    const Callback = *const fn (*World) anyerror!void;

    const Global = struct {
        ptr: *anyopaque,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    globals: std.array_hash_map.Auto(TypeId, Global) = .empty,
    storage: TypeArray(PhantomMultiArrayList) = .{},
    callbacks: TypeArray(std.ArrayList(Callback)) = .{},
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn destroyGlobal(self: *Self, comptime T: type) void {
        if (self.globals.get(typeId(T))) |global| {
            global.destroy(global.ptr, self.allocator);
        }
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
        const array = try std.MultiArrayList(T).initCapacity(self.allocator, 0);
        const arraylist = try self.storage.getOrPut(self.allocator, T, @as(*const PhantomMultiArrayList, @ptrCast(&array)).*);
        return @ptrCast(arraylist);
    }

    pub fn callbacksOf(self: *Self, comptime T: type) !*std.ArrayList(Callback) {
        const callbacks = try std.ArrayList(Callback).initCapacity(self.allocator, 0);
        const callbacklist = try self.callbacks.getOrPut(self.allocator, T, callbacks);
        return callbacklist;
    }

    pub fn addCallbackFor(self: *Self, comptime T: type, callback: Callback) !void {
        const storage = try self.callbacksOf(T);
        storage.append(self.allocator, callback);
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
        self.storage.deinit(self.allocator);
        self.callbacks.deinit(self.allocator);

        {
            var it = self.globals.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.destroy(entry.value_ptr.ptr, self.allocator);
            }
        }
        self.globals.deinit(self.allocator);
    }

    pub fn query(self: *Self, comptime T: type, comptime Condition: type, comptime Mutability: type) !struct { Query.QueryCursor(T, Mutability), Condition.Output } {
        const s = try self.storageOf(T);
        return .{ Query.QueryCursor(T, Mutability){ .list = s }, Condition.fetch(self) };
    }
};
