const StructReflect = @import("../reflects/Reflect.zig").StructReflect;
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

pub const MaterialBufferRole = enum {
    uniform,
    storage_read_only,
    storage_read_write,
    storage_atomic,
};

pub fn BufferBinding(comptime T: type) type {
    return struct {
        buffer: GpuBuffer(T),
        group: zgpu.BindGroupHandle,
        index: u32,
        const Self = @This();
        const CreateBindingOptions = struct {
            buffer: GpuBuffer(T),
            context: *zgpu.GraphicsContext,
            pipeline: zgpu.RenderPipelineHandle,
            allocator: std.mem.Allocator,
            group_index: u32 = 0,
            binding_index: u32 = 0,
        };
        pub fn init(options: CreateBindingOptions) Self {
            const layout = options.context.createBindGroupLayoutAuto(options.pipeline, options.group_index);
            defer options.context.releaseResource(layout);

            const bind_group = options.context.createBindGroup(layout, &.{
                .{
                    .binding = options.binding_index,
                    .buffer_handle = options.buffer.buffer_handle,
                    .offset = 0,
                    .size = @sizeOf(T),
                },
            });
            return Self{ .buffer = options.buffer, .group = bind_group, .index = options.group_index };
        }

        /// Binds this camera's group to the active render pass.
        pub fn bind(self: *const Self, gctx: *zgpu.GraphicsContext, pass: wgpu.RenderPassEncoder, index: usize) !void {
            const group = gctx.lookupResource(self.group) orelse return error.CameraBindGroupNotFound;
            pass.setBindGroup(@intCast(index), group, null);
        }
        /// Uploads matrices after the camera pose or projection has changed.
        pub fn update(self: *Self, gctx: *zgpu.GraphicsContext, index: usize, data: T) !void {
            try self.buffer.set(index, data);
            try self.buffer.flush(gctx);
        }

        /// Releases this camera's bind group and uniform buffer.
        pub fn deinit(self: *Self, gctx: *zgpu.GraphicsContext) void {
            gctx.releaseResource(self.group);
            self.buffer.deinit(gctx);
            self.* = undefined;
        }
    };
}

/// Creates a fixed-capacity GPU buffer whose elements have the compile-time type `T`.
///
/// The CPU mirror stores complete `T` values, so `T` should match the intended
/// GPU representation. For WGSL vertex inputs, prefer `VertexStreams` to map
/// one typed buffer per shader attribute.
pub fn GpuBuffer(comptime T: type) type {
    if (@sizeOf(T) == 0) @compileError(std.fmt.comptimePrint("GpuBuffer element types must have a non-zero size. Instead, {any} doesn't", .{@typeName(T)}));

    return struct {
        buffer_handle: zgpu.BufferHandle,
        allocator: std.mem.Allocator,
        contents: std.ArrayList(T),
        roles: Roles,
        capacity_items: usize,
        index_format: ?wgpu.IndexFormat,
        step_mode: wgpu.VertexStepMode,
        allocation_size: usize,
        element_stride: usize = @sizeOf(T),
        dirty_start: ?usize = null,
        dirty_end: usize = 0,

        const Self = @This();

        pub const CreateDescriptor = struct {
            capacity: usize,
            allocator: std.mem.Allocator,
            context: *zgpu.GraphicsContext,
            roles: Roles,
            element_stride: ?usize = null,
            step_mode: wgpu.VertexStepMode = .vertex,
            index_format: ?wgpu.IndexFormat = null,
        };
        /// Parameters for allocating the CPU mirror and GPU buffer.
        /// Allocates a buffer with the requested capacity and usage roles.
        ///
        /// Returns errors for invalid role/index-format combinations, overflow,
        /// or CPU allocation failure.
        pub fn allocate(descriptor: CreateDescriptor) !Self {
            try validateOptions(T, descriptor.roles, descriptor.index_format, descriptor.step_mode);
            const element_stride = descriptor.element_stride orelse @sizeOf(T);
            if (element_stride < @sizeOf(T)) return error.InvalidElementStride;
            const size_result = @mulWithOverflow(descriptor.capacity, element_stride);
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
                .element_stride = element_stride,
            };
        }

        /// Grows GPU and CPU capacity while preserving initialized elements.
        /// Existing bind groups referencing this buffer must be rebuilt after
        /// growth because the underlying GPU handle changes.
        pub fn reserve(self: *Self, context: *zgpu.GraphicsContext, new_capacity: usize) !void {
            if (new_capacity <= self.capacity_items) return;
            const grown = @max(new_capacity, self.capacity_items +| @max(self.capacity_items, 1));
            const size_result = @mulWithOverflow(grown, self.element_stride);
            if (size_result[1] != 0) return error.CapacityOverflow;
            const padded_result = @addWithOverflow(size_result[0], 3);
            if (padded_result[1] != 0) return error.CapacityOverflow;
            const allocation_size = padded_result[0] & ~@as(usize, 3);
            try self.contents.ensureTotalCapacity(self.allocator, grown);
            const new_handle = context.createBuffer(.{
                .size = @intCast(allocation_size),
                .usage = usageForRoles(self.roles),
            });
            const old_handle = self.buffer_handle;
            const old_capacity = self.capacity_items;
            const old_allocation_size = self.allocation_size;
            const old_dirty_start = self.dirty_start;
            const old_dirty_end = self.dirty_end;
            self.buffer_handle = new_handle;
            self.capacity_items = grown;
            self.allocation_size = allocation_size;
            if (self.contents.items.len != 0) {
                self.dirty_start = 0;
                self.dirty_end = self.size();
                self.flush(context) catch |err| {
                    self.buffer_handle = old_handle;
                    self.capacity_items = old_capacity;
                    self.allocation_size = old_allocation_size;
                    self.dirty_start = old_dirty_start;
                    self.dirty_end = old_dirty_end;
                    context.releaseResource(new_handle);
                    return err;
                };
            }
            context.releaseResource(old_handle);
        }

        /// Appends an element, growing the GPU allocation when needed.
        pub fn appendGrowing(self: *Self, context: *zgpu.GraphicsContext, value: T) !void {
            if (self.contents.items.len == self.capacity_items) {
                const needed = try std.math.add(usize, self.contents.items.len, 1);
                try self.reserve(context, needed);
            }
            try self.append(value);
        }

        const UnitBufferDescriptor = struct { allocator: std.mem.Allocator, context: *zgpu.GraphicsContext, roles: Roles, element_stride: ?usize = null, step_mode: wgpu.VertexStepMode = .vertex, index_format: ?wgpu.IndexFormat = null, content: T };
        pub fn unit(descriptor: UnitBufferDescriptor) !Self {
            var buffer = try Self.allocate(.{ .allocator = descriptor.allocator, .context = descriptor.context, .roles = descriptor.roles, .capacity = 1, .step_mode = descriptor.step_mode, .element_stride = descriptor.element_stride, .index_format = descriptor.index_format });
            try buffer.append(descriptor.content);
            try buffer.flush(descriptor.context);
            return buffer;
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
                if (self.element_stride == @sizeOf(T)) {
                    @memcpy(upload[0 .. copy_end - aligned_start], contents_bytes[aligned_start..copy_end]);
                } else {
                    for (self.contents.items, 0..) |_, item_index| {
                        const item_start = item_index * self.element_stride;
                        const item_end = item_start + @sizeOf(T);
                        const copy_start = @max(item_start, aligned_start);
                        const copy_stop = @min(item_end, copy_end);
                        if (copy_start >= copy_stop) continue;
                        const upload_start = copy_start - aligned_start;
                        const source_start = item_index * @sizeOf(T) + copy_start - item_start;
                        @memcpy(
                            upload[upload_start .. upload_start + copy_stop - copy_start],
                            contents_bytes[source_start .. source_start + copy_stop - copy_start],
                        );
                    }
                }
            }
            context.queue.writeBuffer(gpu_buffer, aligned_start, u8, upload);
            self.dirty_start = null;
            self.dirty_end = 0;
        }

        /// Returns an error if this buffer was not allocated for `role`.
        pub fn validateRole(self: *const Self, role: Role) !void {
            const has_role = switch (role) {
                .vertex => self.roles.vertex,
                .index => self.roles.index,
                .uniform => self.roles.uniform,
                .storage => self.roles.storage,
                .indirect => self.roles.indirect,
            };
            if (!has_role) return error.BufferRoleMismatch;
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

        /// Returns the logical byte size (`len() * element_stride`), not capacity.
        pub fn size(self: *const Self) usize {
            return self.contents.items.len * self.element_stride;
        }

        /// Returns the full allocated range used when creating a bind group.
        pub fn bindingSize(self: *const Self) usize {
            return self.allocation_size;
        }

        /// Returns the configured vertex/instance step mode after checking the role.
        pub fn vertexStepMode(self: *const Self) !wgpu.VertexStepMode {
            try self.validateRole(.vertex);
            return self.step_mode;
        }

        fn markDirty(self: *Self, first: usize, count: usize) void {
            if (count == 0) return;
            const start = first * self.element_stride;
            const end = (first + count) * self.element_stride;
            self.dirty_start = if (self.dirty_start) |current| @min(current, start) else start;
            self.dirty_end = @max(self.dirty_end, end);
        }
        fn AsBindingDescriptor(comptime Shader: type, comptime Group: Shader.MaterialGroup) type {
            const Original = BufferBinding(T).CreateBindingOptions;
            const Slot = @field(Shader.MaterialSlots, @tagName(Group));
            return StructReflect(Original).withoutFields(.{ "buffer", "group_index", "binding_index" }).join(struct { slot: Slot }).raw();
        }
        pub fn asBinding(self: Self, comptime S: type, comptime Group: S.MaterialGroup, config: AsBindingDescriptor(S, Group)) !BufferBinding(T) {
            const group = @backingInt(Group);
            const slot = @backingInt(config.slot);

            return BufferBinding(T).init(.{
                .allocator = config.allocator,
                .context = config.context,
                .buffer = self,
                .pipeline = config.pipeline,
                .binding_index = slot,
                .group_index = group,
            });
        }
    };
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
        .element_stride = @sizeOf(u32),
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
    buffer.clear();
    try std.testing.expectEqual(@as(usize, 0), buffer.len());
}

test "padded array stride controls buffer allocation and dirty byte ranges" {
    const Element = [3]f32;
    const Buffer = GpuBuffer(Element);
    var contents = try std.ArrayList(Element).initCapacity(std.testing.allocator, 2);
    defer contents.deinit(std.testing.allocator);
    var buffer = Buffer{
        .buffer_handle = undefined,
        .allocator = std.testing.allocator,
        .contents = contents,
        .roles = .{ .storage = true },
        .capacity_items = 2,
        .index_format = null,
        .step_mode = .vertex,
        .allocation_size = 32,
        .element_stride = 16,
    };

    try buffer.append(.{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 16), buffer.size());
    try std.testing.expectEqual(@as(usize, 32), buffer.bindingSize());
    try std.testing.expectEqual(@as(?usize, 0), buffer.dirty_start);
    try std.testing.expectEqual(@as(usize, 16), buffer.dirty_end);
}
