const std = @import("std");
const zgpu = @import("zgpu");
const Buffers = @import("../core/GpuBuffer.zig");
const RenderingContext = @import("../core/RenderingContext.zig").RenderingContext;
const VertexStreams = @import("../core/VertexStreams.zig").VertexStreams;

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
            const Element = binding.ty orelse @compileError("buffer binding is missing its element type");
            member_names[member_idx] = binding.slot_name;
            member_types[member_idx] = *Buffers.GpuBuffer(Element);
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
        cached_groups: [T.group_indices.len]zgpu.BindGroupHandle = @splat(.{}),
        groups_ready: bool = false,

        const Self = @This();

        pub fn initPipeline(rendering_context: RenderingContext, source: [:0]const u8) zgpu.RenderPipelineHandle {
            const layout = T.Pipeline.createPipelineLayout(rendering_context.context);
            defer rendering_context.context.releaseResource(layout);
            return T.Pipeline.createWithVertexLayoutsAndLayout(
                rendering_context.context,
                source,
                &VertexStreams(T).vertex_buffer_layouts,
                layout,
            );
        }

        /// Creates and caches bind groups after material resources are set up.
        /// Call invalidateBindings after replacing any bound GPU resource.
        pub fn prepare(self: *Self, rendering_context: RenderingContext) !void {
            self.invalidateBindings(rendering_context);
            var prepared: usize = 0;
            errdefer inline for (T.group_indices, 0..) |_, group_pos| {
                if (prepared > group_pos) rendering_context.context.releaseResource(self.cached_groups[group_pos]);
                self.cached_groups[group_pos] = .{};
            };
            inline for (T.group_indices, 0..) |group_index, group_pos| {
                self.cached_groups[group_pos] = try createGroup(T, self, rendering_context, group_index, group_pos);
                prepared += 1;
            }
            self.groups_ready = true;
        }

        /// Releases cached groups. Prepare again before rendering.
        pub fn invalidateBindings(self: *Self, rendering_context: RenderingContext) void {
            if (self.groups_ready) {
                inline for (T.group_indices, 0..) |_, group_pos| {
                    rendering_context.context.releaseResource(self.cached_groups[group_pos]);
                    self.cached_groups[group_pos] = .{};
                }
            }
            self.groups_ready = false;
        }

        /// Binds previously prepared groups without creating GPU resources.
        pub fn bind(self: *const Self, rendering_context: RenderingContext, pass: zgpu.wgpu.RenderPassEncoder) !void {
            if (!self.groups_ready) return error.MaterialBindingsNotPrepared;
            inline for (T.group_indices, 0..) |group_index, group_pos| {
                const group = rendering_context.context.lookupResource(self.cached_groups[group_pos]) orelse return error.MaterialBindGroupNotFound;
                pass.setBindGroup(group_index, group, null);
            }
        }

        /// Releases cached groups. Bound buffers are borrowed and remain owned by the caller.
        pub fn deinit(self: *Self, rendering_context: RenderingContext) void {
            self.invalidateBindings(rendering_context);
            self.* = undefined;
        }
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

fn createGroup(
    comptime Shader: type,
    self: anytype,
    rendering_context: RenderingContext,
    comptime group_index: u32,
    comptime group_pos: usize,
) !zgpu.BindGroupHandle {
    const entries_count = comptime groupEntriesCount(Shader, group_pos);
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
            const slot_buffer = @field(@field(self.binds, group_name), metadata.slot_name);
            layout_entries[entry_index] = Shader.materialBindGroupLayoutEntry(metadata);
            bind_entries[entry_index] = .{
                .binding = metadata.binding,
                .buffer_handle = slot_buffer.buffer_handle,
                .offset = 0,
                .size = slot_buffer.bindingSize(),
            };
            entry_index += 1;
        }
    }
    const layout = rendering_context.context.createBindGroupLayout(&layout_entries);
    defer rendering_context.context.releaseResource(layout);
    return rendering_context.context.createBindGroup(layout, &bind_entries);
}

fn groupEntriesCount(comptime Shader: type, comptime group_pos: usize) comptime_int {
    const group_index = Shader.group_indices[group_pos];
    comptime var count: comptime_int = 0;
    inline for (Shader.group_bindings[group_pos]) |metadata| {
        if (metadata.group != null and metadata.group.? == group_index) count += 1;
    }
    return count;
}
