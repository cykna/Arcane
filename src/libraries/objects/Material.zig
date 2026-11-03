const std = @import("std");
const zgpu = @import("zgpu");
const Buffers = @import("../core/GpuBuffer.zig");

/// Buffer allocation settings for a generated shader slot.
///
/// Uniform slots accept capacity 1. Storage runtime arrays use capacity as the
/// number of reflected element values; fixed arrays require their reflected
/// length, and a non-array storage value accepts capacity 1.
pub const InitBindingOptions = struct {
    allocator: std.mem.Allocator,
    context: *zgpu.GraphicsContext,
    capacity: usize,
};

pub fn MaterialOptions(comptime T: type) type {
    var material_group_count: usize = 0;
    for (T.group_bindings) |group_bindings| {
        for (group_bindings) |binding| {
            if (binding.kind == .buffer) {
                material_group_count += 1;
                break;
            }
        }
    }
    var group_names: [material_group_count][]const u8 = undefined;
    var group_types: [material_group_count]type = undefined;
    var group_attrs: [material_group_count]std.lang.Type.Struct.FieldAttributes = @splat(.{});
    var material_group_index: usize = 0;

    for (T.group_indices, 0..) |group_index, group_pos| {
        var buffer_count: usize = 0;
        for (T.group_bindings[group_pos]) |binding| {
            if (binding.kind == .buffer) buffer_count += 1;
        }
        if (buffer_count == 0) continue;

        group_names[material_group_index] = std.fmt.comptimePrint("group{d}", .{group_index});
        var member_names: [buffer_count][]const u8 = undefined;
        var member_types: [buffer_count]type = undefined;
        var member_attrs: [buffer_count]std.lang.Type.Struct.FieldAttributes = @splat(.{});
        var member_idx: usize = 0;
        for (T.group_bindings[group_pos]) |binding| {
            if (binding.kind != .buffer) continue;
            member_names[member_idx] = binding.slot_name;
            member_types[member_idx] = slotBindingType(T, binding);
            member_idx += 1;
        }
        group_types[material_group_index] = @Struct(.auto, null, &member_names, &member_types, &member_attrs);
        material_group_index += 1;
    }

    return @Struct(.auto, null, &group_names, &group_types, &group_attrs);
}

pub fn Material(comptime T: type) type {
    const Options = MaterialOptions(T);
    return struct {
        binds: Options,

        const Self = @This();

        /// Creates the buffer for one generated shader slot. Its Zig element
        /// type, usage flags, and array stride come from anygpu metadata.
        /// The group and slot must be compile-time enum literals; non-buffer
        /// resources and binding arrays are rejected at compile time.
        ///
        /// Uniform buffers are single-value allocations. For storage buffers,
        /// capacity is the number of array elements when WGSL declares an
        /// array; non-array storage values have capacity 1. Bind-group creation
        /// is deferred until `bind`, after all group slots are present.
        pub fn initBinding(
            comptime group: T.MaterialGroup,
            comptime slot: @field(T.MaterialSlots, @tagName(group)),
            options: InitBindingOptions,
        ) !slotBindingType(T, bindingForSlot(T, @backingInt(group), @backingInt(slot))) {
            const metadata = bindingForSlot(T, @backingInt(group), @backingInt(slot));
            const role = bufferRole(metadata);
            const Element = metadata.ty orelse @compileError(slotError(T, metadata, "does not have a buffer element type"));
            if (metadata.count != null) @compileError(slotError(T, metadata, "is a binding array, which Material.initBinding does not support"));
            if (metadata.resource_type == .uniform and metadata.array_stride != null) {
                @compileError(slotError(T, metadata, "is a uniform array; initBinding requires one non-array uniform value"));
            }
            try validateCapacity(metadata, options.capacity);

            const element_stride = metadata.array_stride orelse @sizeOf(Element);
            if (element_stride < @sizeOf(Element)) {
                @compileError(slotError(T, metadata, "has an array stride smaller than its Zig element type"));
            }
            const buffer = try Buffers.GpuBuffer(Element).allocate(.{
                .allocator = options.allocator,
                .context = options.context,
                .capacity = options.capacity,
                .roles = Buffers.rolesForMaterialBinding(role),
                .element_stride = if (metadata.array_stride) |stride| @intCast(stride) else null,
            });
            return .{ .buffer = buffer };
        }

        /// Assembles one bind group per shader group for this render pass.
        pub fn bind(self: *const Self, context: *zgpu.GraphicsContext, pass: zgpu.wgpu.RenderPassEncoder) !void {
            inline for (T.group_indices, 0..) |group_index, group_pos| {
                const handle = try createGroup(T, self, context, group_index, group_pos);
                defer context.releaseResource(handle);
                const group = context.lookupResource(handle) orelse return error.MaterialBindGroupNotFound;
                pass.setBindGroup(group_index, group, null);
            }
        }
    };
}

fn slotBindingType(comptime T: type, comptime metadata: anytype) type {
    if (metadata.kind != .buffer) {
        @compileError(slotError(T, metadata, "is not a buffer"));
    }
    const Element = metadata.ty orelse @compileError(slotError(T, metadata, "does not have a buffer element type"));
    return Buffers.MaterialBufferBinding(
        Element,
        T,
        metadata.group orelse @compileError("Material buffer slots must belong to a bind group"),
        metadata.binding,
        bufferRole(metadata),
    );
}

fn bufferRole(metadata: anytype) Buffers.MaterialBufferRole {
    if (metadata.resource_type == null) @compileError("anygpu buffer metadata is missing the resource type");
    return switch (metadata.resource_type.?) {
        .uniform => .uniform,
        .storage => switch (metadata.read_only orelse @compileError("anygpu storage metadata is missing access")) {
            .load => .storage_read_only,
            .store, .load_store => .storage_read_write,
            .atomic => .storage_atomic,
        },
    };
}

fn bindingForSlot(comptime T: type, comptime group: u32, comptime binding_index: u32) T.BindingMetadata {
    inline for (T.bindings) |binding| {
        if (binding.group != null and binding.group.? == group and binding.binding == binding_index) {
            return binding;
        }
    }
    @compileError(std.fmt.comptimePrint(
        "Material({s}): unknown group{d} binding index {d}",
        .{ @typeName(T), group, binding_index },
    ));
}

fn slotError(comptime T: type, metadata: anytype, comptime reason: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        "Material({s}): group{d} slot `{s}` {s}",
        .{ @typeName(T), metadata.group orelse 0, metadata.name, reason },
    );
}

fn validateCapacity(metadata: anytype, capacity: usize) !void {
    if (capacity == 0) return error.ZeroBufferCapacity;
    if (metadata.resource_type == .uniform) {
        if (capacity != 1) return error.UniformCapacityMustBeOne;
        return;
    }
    if (metadata.runtime_sized_array) return;
    const expected = metadata.array_length orelse 1;
    if (capacity != expected) return error.BufferCapacityDoesNotMatchShaderArray;
}

fn createGroup(
    comptime Shader: type,
    self: anytype,
    context: *zgpu.GraphicsContext,
    comptime group_index: u32,
    comptime group_pos: usize,
) !zgpu.BindGroupHandle {
    const entries_count = groupEntriesCount(Shader, group_pos);
    var layout_entries: [entries_count]zgpu.wgpu.BindGroupLayoutEntry = undefined;
    var bind_entries: [entries_count]zgpu.BindGroupEntryInfo = undefined;
    comptime var entry_index: usize = 0;
    inline for (Shader.bindings) |metadata| {
        if (metadata.group != null and metadata.group.? == group_index) {
            if (metadata.kind != .buffer) {
                @compileError(slotError(Shader, metadata, "is not a buffer; this Material bind-group path supports buffer slots only"));
            }
            if (metadata.count != null) {
                @compileError(slotError(Shader, metadata, "is a binding array, which Material does not support"));
            }
            const group_name = std.fmt.comptimePrint("group{d}", .{group_index});
            const slot_binding = &@field(@field(self.binds, group_name), metadata.slot_name);
            layout_entries[entry_index] = Shader.materialBindGroupLayoutEntry(metadata);
            bind_entries[entry_index] = .{
                .binding = metadata.binding,
                .buffer_handle = slot_binding.buffer.buffer_handle,
                .offset = 0,
                .size = slot_binding.buffer.bindingSize(),
            };
            entry_index += 1;
        }
    }
    const layout = context.createBindGroupLayout(&layout_entries);
    defer context.releaseResource(layout);
    return context.createBindGroup(layout, &bind_entries);
}

fn groupEntriesCount(comptime Shader: type, comptime group_pos: usize) usize {
    const group_index = Shader.group_indices[group_pos];
    var count: usize = 0;
    for (Shader.group_bindings[group_pos]) |metadata| {
        if (metadata.group != null and metadata.group.? == group_index) count += 1;
    }
    return count;
}
