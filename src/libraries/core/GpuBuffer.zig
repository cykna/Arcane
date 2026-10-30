const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

/// GPU buffer with a typed CPU-side mirror, fixed capacity, and dirty-range uploads.
///
/// Mutations update `contents`; call `flush` before using the GPU resource to
/// upload those changes. The buffer owns its CPU allocation and GPU handle, and
/// must be released with `deinit` while its `GraphicsContext` is alive.
pub const Role = enum {
    /// Enables use as a vertex buffer.
    vertex,
    /// Enables use as an index buffer.
    index,
    /// Enables uniform-buffer use.
    uniform,
    /// Enables storage-buffer use.
    storage,
    /// Enables indirect-buffer use.
    indirect,
};

/// Set of WebGPU usages requested when a `GpuBuffer(T)` is allocated.
pub const Roles = packed struct(u5) {
    vertex: bool = false,
    index: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
};
pub const CreateDescriptor = struct {
    capacity: usize,
    allocator: std.mem.Allocator,
    context: *zgpu.GraphicsContext,
    roles: Roles,
    step_mode: wgpu.VertexStepMode = .vertex,
    index_format: ?wgpu.IndexFormat = null,
};
/// Creates a fixed-capacity GPU buffer whose elements have the compile-time type `T`.
///
/// The CPU mirror stores complete `T` values, so `T` should match the intended
/// GPU representation. For WGSL vertex inputs, prefer `VertexStreams` to map
/// one typed buffer per shader attribute.
pub fn GpuBuffer(comptime T: type) type {
    if (@sizeOf(T) == 0) @compileError("GpuBuffer element types must have a non-zero size");

    return struct {
        buffer_handle: zgpu.BufferHandle,
        allocator: std.mem.Allocator,
        contents: std.ArrayList(T),
        roles: Roles,
        capacity_items: usize,
        index_format: ?wgpu.IndexFormat,
        step_mode: wgpu.VertexStepMode,
        allocation_size: usize,
        dirty_start: ?usize = null,
        dirty_end: usize = 0,

        const Self = @This();

        /// Parameters for allocating the CPU mirror and GPU buffer.
        /// Allocates a buffer with the requested capacity and usage roles.
        ///
        /// Returns errors for invalid role/index-format combinations, overflow,
        /// or CPU allocation failure.
        pub fn allocate(descriptor: CreateDescriptor) !Self {
            try validateOptions(T, descriptor.roles, descriptor.index_format, descriptor.step_mode);
            const size_result = @mulWithOverflow(descriptor.capacity, @sizeOf(T));
            if (size_result[1] != 0) return error.CapacityOverflow;
            const padded_result = @addWithOverflow(size_result[0], 3);
            if (padded_result[1] != 0) return error.CapacityOverflow;
            const allocation_size = padded_result[0] & ~@as(usize, 3);

            var contents = try std.ArrayList(T).initCapacity(descriptor.allocator, descriptor.capacity);
            errdefer contents.deinit(descriptor.allocator);

            const buffer_handle = descriptor.context.createBuffer(.{
                .size = @intCast(allocation_size),
                .usage = usageForRoles(descriptor.roles),
            });

            return .{
                .buffer_handle = buffer_handle,
                .allocator = descriptor.allocator,
                .contents = contents,
                .roles = descriptor.roles,
                .capacity_items = descriptor.capacity,
                .index_format = descriptor.index_format,
                .step_mode = descriptor.step_mode,
                .allocation_size = allocation_size,
            };
        }

        /// Releases the GPU resource and CPU-side contents.
        pub fn deinit(self: *Self, context: *zgpu.GraphicsContext) void {
            context.releaseResource(self.buffer_handle);
            self.contents.deinit(self.allocator);
            self.* = undefined;
        }

        /// Appends one element to the CPU mirror and marks its byte range dirty.
        pub fn append(self: *Self, value: T) !void {
            if (self.contents.items.len >= self.capacity_items) return error.CapacityExceeded;
            const index = self.contents.items.len;
            try self.contents.append(self.allocator, value);
            self.markDirty(index, 1);
        }

        /// Checks capacity and reserves CPU-list capacity for one subsequent append.
        ///
        /// This is useful when coordinating a multi-buffer append: reserve all
        /// participating buffers before mutating any of them.
        pub fn prepareAppend(self: *Self) !void {
            if (self.contents.items.len >= self.capacity_items) return error.CapacityExceeded;
            try self.contents.ensureUnusedCapacity(self.allocator, 1);
        }

        /// Appends a slice if it fits and marks the appended range dirty.
        pub fn appendSlice(self: *Self, values: []const T) !void {
            if (values.len > self.capacity_items - self.contents.items.len) return error.CapacityExceeded;
            if (values.len == 0) return;
            const first = self.contents.items.len;
            try self.contents.appendSlice(self.allocator, values);
            self.markDirty(first, values.len);
        }

        /// Replaces an existing element and marks its byte range dirty.
        pub fn set(self: *Self, index: usize, value: T) !void {
            if (index >= self.contents.items.len) return error.IndexOutOfBounds;
            self.contents.items[index] = value;
            self.markDirty(index, 1);
        }

        /// Replaces an in-bounds range of elements and marks it dirty.
        pub fn update(self: *Self, first: usize, values: []const T) !void {
            if (first > self.contents.items.len or values.len > self.contents.items.len - first) {
                return error.RangeOutOfBounds;
            }
            if (values.len == 0) return;
            @memcpy(self.contents.items[first .. first + values.len], values);
            self.markDirty(first, values.len);
        }

        /// Changes the logical element count without exceeding the fixed capacity.
        ///
        /// Newly added elements are filled with `fill_value`; shrinking does not
        /// change the allocated GPU capacity.
        pub fn resize(self: *Self, new_len: usize, fill_value: T) !void {
            if (new_len > self.capacity_items) return error.CapacityExceeded;
            const old_len = self.contents.items.len;
            if (new_len < old_len) {
                self.contents.items.len = new_len;
            } else if (new_len > old_len) {
                const additional = new_len - old_len;
                try self.contents.ensureUnusedCapacity(self.allocator, additional);
                for (0..additional) |_| try self.contents.append(self.allocator, fill_value);
                self.markDirty(old_len, additional);
            }
        }

        /// Removes all logical elements while retaining allocated CPU capacity.
        pub fn clear(self: *Self) void {
            self.contents.clearRetainingCapacity();
            self.dirty_start = null;
            self.dirty_end = 0;
        }

        /// Uploads the dirty byte range from the CPU mirror to the GPU buffer.
        ///
        /// No work is done when no modifications are pending.
        pub fn flush(self: *Self, context: *zgpu.GraphicsContext) !void {
            const start_dirty = self.dirty_start orelse return;
            const logical_size = self.size();
            const aligned_start = start_dirty & ~@as(usize, 3);
            const end_result = @addWithOverflow(self.dirty_end, 3);
            if (end_result[1] != 0) return error.CapacityOverflow;
            const aligned_end = @min(end_result[0] & ~@as(usize, 3), self.allocation_size);
            if (aligned_end <= aligned_start) {
                self.dirty_start = null;
                self.dirty_end = 0;
                return;
            }

            const gpu_buffer = context.lookupResource(self.buffer_handle) orelse return error.BufferNotFound;
            const upload = try self.allocator.alloc(u8, aligned_end - aligned_start);
            defer self.allocator.free(upload);
            @memset(upload, 0);

            const copy_end = @min(aligned_end, logical_size);
            if (copy_end > aligned_start) {
                const contents_bytes = std.mem.sliceAsBytes(self.contents.items);
                @memcpy(upload[0 .. copy_end - aligned_start], contents_bytes[aligned_start..copy_end]);
            }
            context.queue.writeBuffer(gpu_buffer, aligned_start, u8, upload);
            self.dirty_start = null;
            self.dirty_end = 0;
        }

        /// Returns an error if this buffer was not allocated for `role`.
        pub fn validateRole(self: *const Self, role: Role) !void {
            try checkRole(self.roles, role);
        }

        /// Validates `role` and returns the associated resource handle.
        pub fn handleFor(self: *const Self, role: Role) !zgpu.BufferHandle {
            try self.validateRole(role);
            return self.buffer_handle;
        }

        /// Binds this buffer to a vertex slot for the current render pass.
        pub fn bindVertexBuffer(
            self: *const Self,
            context: *zgpu.GraphicsContext,
            pass: wgpu.RenderPassEncoder,
            slot: u32,
        ) !void {
            const handle = try self.handleFor(.vertex);
            const gpu_buffer = context.lookupResource(handle) orelse return error.BufferNotFound;
            pass.setVertexBuffer(slot, gpu_buffer, 0, self.size());
        }

        /// Binds this buffer as an index buffer using its configured index format.
        pub fn bindIndexBuffer(
            self: *const Self,
            context: *zgpu.GraphicsContext,
            pass: wgpu.RenderPassEncoder,
        ) !void {
            const handle = try self.handleFor(.index);
            const gpu_buffer = context.lookupResource(handle) orelse return error.BufferNotFound;
            pass.setIndexBuffer(gpu_buffer, self.index_format.?, 0, self.size());
        }

        /// Returns the number of initialized elements in the CPU mirror.
        pub fn len(self: *const Self) usize {
            return self.contents.items.len;
        }

        /// Returns the fixed element capacity chosen at allocation time.
        pub fn capacity(self: *const Self) usize {
            return self.capacity_items;
        }

        /// Returns the logical byte size (`len() * @sizeOf(T)`), not capacity.
        pub fn size(self: *const Self) usize {
            return self.contents.items.len * @sizeOf(T);
        }

        /// Returns the configured vertex/instance step mode after checking the role.
        pub fn vertexStepMode(self: *const Self) !wgpu.VertexStepMode {
            try self.validateRole(.vertex);
            return self.step_mode;
        }

        fn markDirty(self: *Self, first: usize, count: usize) void {
            if (count == 0) return;
            const start = first * @sizeOf(T);
            const end = (first + count) * @sizeOf(T);
            self.dirty_start = if (self.dirty_start) |current| @min(current, start) else start;
            self.dirty_end = @max(self.dirty_end, end);
        }
    };
}

fn checkRole(roles: Roles, role: Role) !void {
    const has_role = switch (role) {
        .vertex => roles.vertex,
        .index => roles.index,
        .uniform => roles.uniform,
        .storage => roles.storage,
        .indirect => roles.indirect,
    };
    if (!has_role) return error.BufferRoleMismatch;
}

fn validateOptions(
    comptime T: type,
    roles: Roles,
    index_format: ?wgpu.IndexFormat,
    step_mode: wgpu.VertexStepMode,
) !void {
    if (@as(u5, @bitCast(roles)) == 0) return error.NoBufferRoles;
    if (!roles.vertex and step_mode == .instance) return error.StepModeWithoutVertexRole;
    if (roles.index) {
        const format = index_format orelse return error.MissingIndexFormat;
        if (format == .uint16 and T != u16) return error.IndexTypeMismatch;
        if (format == .uint32 and T != u32) return error.IndexTypeMismatch;
        if (format != .uint16 and format != .uint32) return error.UnsupportedIndexFormat;
    } else if (index_format != null) {
        return error.IndexFormatWithoutIndexRole;
    }
}

fn usageForRoles(roles: Roles) wgpu.BufferUsage {
    return .{
        .vertex = roles.vertex,
        .index = roles.index,
        .uniform = roles.uniform,
        .storage = roles.storage,
        .indirect = roles.indirect,
        .copy_dst = true,
    };
}

test "buffer roles map to WebGPU usage flags and reject invalid bindings" {
    const usage = usageForRoles(.{ .vertex = true, .storage = true });
    try std.testing.expect(usage.vertex);
    try std.testing.expect(usage.storage);
    try std.testing.expect(usage.copy_dst);
    try std.testing.expect(!usage.index);
    try std.testing.expectError(error.BufferRoleMismatch, checkRole(.{ .index = true }, .vertex));
    try checkRole(.{ .vertex = true, .storage = true }, .vertex);
    try checkRole(.{ .vertex = true, .storage = true }, .storage);
}

test "index buffers require a matching integer element type" {
    try validateOptions(u16, .{ .index = true }, .uint16, .vertex);
    try validateOptions(u32, .{ .index = true }, .uint32, .vertex);
    try std.testing.expectError(error.IndexTypeMismatch, validateOptions(u32, .{ .index = true }, .uint16, .vertex));
    try std.testing.expectError(error.MissingIndexFormat, validateOptions(u32, .{ .index = true }, null, .vertex));
    try std.testing.expectError(error.IndexFormatWithoutIndexRole, validateOptions(u32, .{ .vertex = true }, .uint32, .vertex));
    try std.testing.expectError(error.StepModeWithoutVertexRole, validateOptions(u32, .{ .storage = true }, null, .instance));
}

test "buffer mutations enforce capacity and mark changed content dirty" {
    const Buffer = GpuBuffer(u32);
    var contents = try std.ArrayList(u32).initCapacity(std.testing.allocator, 2);
    defer contents.deinit(std.testing.allocator);
    var buffer = Buffer{
        .buffer_handle = undefined,
        .allocator = std.testing.allocator,
        .contents = contents,
        .roles = .{ .vertex = true },
        .capacity_items = 2,
        .index_format = null,
        .step_mode = .vertex,
        .allocation_size = 8,
    };

    try buffer.append(10);
    try buffer.append(20);
    try std.testing.expectError(error.CapacityExceeded, buffer.append(30));
    try std.testing.expectEqual(@as(usize, 2), buffer.len());
    try std.testing.expectEqual(@as(usize, 8), buffer.size());
    try std.testing.expectEqual(@as(?usize, 0), buffer.dirty_start);
    try std.testing.expectEqual(@as(usize, 8), buffer.dirty_end);

    try buffer.set(1, 25);
    try std.testing.expectEqual(@as(u32, 25), buffer.contents.items[1]);
    try std.testing.expectError(error.IndexOutOfBounds, buffer.set(2, 30));
    try buffer.resize(1, 0);
    try std.testing.expectEqual(@as(usize, 1), buffer.len());
    try buffer.clear();
    try std.testing.expectEqual(@as(usize, 0), buffer.len());
}
