const std = @import("std");
const Material = @import("libraries/objects/Material.zig");
const Buffers = @import("libraries/core/GpuBuffer.zig");
const triangle = @import("shaders/triangle.zig");
const shared = @import("shaders/shared.zig");

const multi_buffer_shader = struct {
    pub const BindingMetadata = shared.Binding;
    pub const bindings = [_]shared.Binding{
        .{
            .group = 0,
            .binding = 0,
            .name = "camera",
            .slot_name = "camera",
            .kind = .buffer,
            .address_space = .uniform,
            .access = .read,
            .visibility = .{ .vertex = true },
            .count = null,
            .resource_type = .uniform,
            .read_only = null,
            .sampler_type = null,
            .sample_type = null,
            .filterable = null,
            .view_dimension = null,
            .multisampled = null,
            .storage_access = null,
            .format = null,
            .has_dynamic_offset = false,
            .min_binding_size = 4,
            .array_stride = null,
            .array_length = null,
            .runtime_sized_array = false,
            .ty = u32,
        },
        .{
            .group = 0,
            .binding = 1,
            .name = "items",
            .slot_name = "items",
            .kind = .buffer,
            .address_space = .storage,
            .access = .read,
            .visibility = .{ .vertex = true },
            .count = null,
            .resource_type = .storage,
            .read_only = .load,
            .sampler_type = null,
            .sample_type = null,
            .filterable = null,
            .view_dimension = null,
            .multisampled = null,
            .storage_access = null,
            .format = null,
            .has_dynamic_offset = false,
            .min_binding_size = 4,
            .array_stride = 4,
            .array_length = null,
            .runtime_sized_array = true,
            .ty = u32,
        },
        .{
            .group = 0,
            .binding = 2,
            .name = "history",
            .slot_name = "history",
            .kind = .buffer,
            .address_space = .storage,
            .access = .read_write,
            .visibility = .{ .vertex = true },
            .count = null,
            .resource_type = .storage,
            .read_only = .load_store,
            .sampler_type = null,
            .sample_type = null,
            .filterable = null,
            .view_dimension = null,
            .multisampled = null,
            .storage_access = null,
            .format = null,
            .has_dynamic_offset = false,
            .min_binding_size = 4,
            .array_stride = 4,
            .array_length = null,
            .runtime_sized_array = true,
            .ty = u32,
        },
        .{
            .group = 0,
            .binding = 3,
            .name = "output",
            .slot_name = "output",
            .kind = .buffer,
            .address_space = .storage,
            .access = .read_write,
            .visibility = .{ .vertex = true },
            .count = null,
            .resource_type = .storage,
            .read_only = .load_store,
            .sampler_type = null,
            .sample_type = null,
            .filterable = null,
            .view_dimension = null,
            .multisampled = null,
            .storage_access = null,
            .format = null,
            .has_dynamic_offset = false,
            .min_binding_size = 4,
            .array_stride = 4,
            .array_length = null,
            .runtime_sized_array = true,
            .ty = u32,
        },
    };
    pub const MaterialGroup = enum(u32) { group0 = 0 };
    pub const MaterialSlots = struct {
        pub const group0 = enum(u32) { camera = 0, items = 1, history = 2, output = 3 };
    };
    pub const group_indices = [_]u32{0};
    pub const group_bindings = [_][]const shared.Binding{bindings[0..4]};

    pub fn materialBindGroupLayoutEntry(binding: shared.Binding) @TypeOf(shared.toBindGroupLayoutEntry(binding, null)) {
        return shared.toBindGroupLayoutEntry(binding, null);
    }
};

test "Material slot types preserve buffer roles and element identity" {
    const M = Material.Material(triangle);
    const CameraReturn = @TypeOf(M.initBinding(.group0, .camera, .{
        .allocator = undefined,
        .context = undefined,
        .capacity = 1,
    }));
    const InstancesReturn = @TypeOf(M.initBinding(.group1, .instances, .{
        .allocator = undefined,
        .context = undefined,
        .capacity = 1,
    }));
    const camera_type = @typeInfo(CameraReturn).error_union.payload;
    const instances_type = @typeInfo(InstancesReturn).error_union.payload;

    try std.testing.expect(camera_type != instances_type);
    try std.testing.expectEqual(Buffers.MaterialBufferRole.uniform, camera_type.buffer_role);
    try std.testing.expectEqual(Buffers.MaterialBufferRole.storage_read_only, instances_type.buffer_role);
    try std.testing.expect(@TypeOf(@as(M, undefined).binds.group0.camera) == camera_type);
    try std.testing.expect(@TypeOf(@as(M, undefined).binds.group1.instances) == instances_type);

    const camera_layout = triangle.materialBindGroupLayoutEntry(triangle.bindings[0]);
    const storage_layout = triangle.materialBindGroupLayoutEntry(triangle.bindings[1]);
    try std.testing.expectEqual(.uniform, camera_layout.buffer.binding_type);
    try std.testing.expectEqual(.read_only_storage, storage_layout.buffer.binding_type);
    try std.testing.expect(triangle.bindings[1].runtime_sized_array);
    try std.testing.expectEqual(@as(?u32, 128), triangle.bindings[1].array_stride);
}

test "Material assembles one group from multiple typed slots" {
    const M = Material.Material(multi_buffer_shader);
    const CameraReturn = @TypeOf(M.initBinding(.group0, .camera, .{
        .allocator = undefined,
        .context = undefined,
        .capacity = 1,
    }));
    const ItemsReturn = @TypeOf(M.initBinding(.group0, .items, .{
        .allocator = undefined,
        .context = undefined,
        .capacity = 4,
    }));
    const HistoryReturn = @TypeOf(M.initBinding(.group0, .history, .{
        .allocator = undefined,
        .context = undefined,
        .capacity = 4,
    }));
    const OutputReturn = @TypeOf(M.initBinding(.group0, .output, .{
        .allocator = undefined,
        .context = undefined,
        .capacity = 4,
    }));
    const camera_type = @typeInfo(CameraReturn).error_union.payload;
    const items_type = @typeInfo(ItemsReturn).error_union.payload;
    const history_type = @typeInfo(HistoryReturn).error_union.payload;
    const output_type = @typeInfo(OutputReturn).error_union.payload;

    try std.testing.expect(camera_type != items_type);
    try std.testing.expect(items_type != history_type);
    try std.testing.expect(history_type != output_type);
    try std.testing.expectEqual(Buffers.MaterialBufferRole.uniform, camera_type.buffer_role);
    try std.testing.expectEqual(Buffers.MaterialBufferRole.storage_read_only, items_type.buffer_role);
    try std.testing.expectEqual(Buffers.MaterialBufferRole.storage_read_write, history_type.buffer_role);
    try std.testing.expectEqual(Buffers.MaterialBufferRole.storage_read_write, output_type.buffer_role);
    try std.testing.expectEqual(@as(usize, 4), multi_buffer_shader.group_bindings[0].len);
    try std.testing.expect(@TypeOf(@as(M, undefined).binds.group0.camera) == camera_type);
    try std.testing.expect(@TypeOf(@as(M, undefined).binds.group0.items) == items_type);
    try std.testing.expect(@TypeOf(@as(M, undefined).binds.group0.history) == history_type);
    try std.testing.expect(@TypeOf(@as(M, undefined).binds.group0.output) == output_type);

    comptime {
        const bind_fn = M.bind;
        _ = bind_fn;
    }
}
