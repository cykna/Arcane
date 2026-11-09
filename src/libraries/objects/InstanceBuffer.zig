const std = @import("std");
const Buffers = @import("../core/GpuBuffer.zig");
const RenderingContext = @import("../core/RenderingContext.zig").RenderingContext;

/// Shader-specific instance records backed by one growable storage buffer.
/// The buffer owns GPU storage and its CPU mirror; records are appended in
/// bulk, never allocated as individual engine objects.
pub fn InstanceBuffer(comptime InstanceData: type) type {
    return struct {
        buffer: Buffers.GpuBuffer(InstanceData),
        rendering_context: RenderingContext,

        const Self = @This();

        pub fn init(options: struct {
            rendering_context: RenderingContext,
            initial_capacity: usize = 0,
            element_stride: ?usize = null,
        }) !Self {
            return .{
                .buffer = try Buffers.GpuBuffer(InstanceData).allocate(.{
                    .rendering_context = options.rendering_context,
                    .capacity = @max(options.initial_capacity, 1),
                    .roles = .{ .storage = true },
                    .element_stride = options.element_stride,
                }),
                .rendering_context = options.rendering_context,
            };
        }

        pub fn append(self: *Self, data: InstanceData) !void {
            try self.buffer.appendGrowing(self.rendering_context, data);
        }

        pub fn appendSlice(self: *Self, data: []const InstanceData) !void {
            const needed = try std.math.add(usize, self.buffer.len(), data.len);
            if (needed > self.buffer.capacity()) try self.buffer.reserve(self.rendering_context, needed);
            try self.buffer.appendSlice(data);
        }

        pub fn flush(self: *Self) !void {
            try self.buffer.flush(self.rendering_context);
        }

        pub fn count(self: *const Self) usize {
            return self.buffer.len();
        }

        /// Returns the backing GPU buffer for generated-binding integration.
        /// Callers create/cache bind groups using the binding metadata for their
        /// shader, then rebuild that group after reserve changes the handle.
        pub fn gpuBuffer(self: *Self) *Buffers.GpuBuffer(InstanceData) {
            return &self.buffer;
        }

        pub fn deinit(self: *Self) void {
            self.buffer.deinit(self.rendering_context);
            self.* = undefined;
        }
    };
}

test "instance buffer preserves shader-specific element type" {
    const ModelData = struct { model: [16]f32 };
    const TintedData = struct { model: [16]f32, tint: [4]f32 };
    const A = InstanceBuffer(ModelData);
    const B = InstanceBuffer(TintedData);
    try std.testing.expect(A != B);
    try std.testing.expect(@FieldType(A, "buffer") == Buffers.GpuBuffer(ModelData));
}
