const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const gpu_buffer = @import("GpuBuffer.zig");

/// The per-attribute data used to derive a vertex-buffer layout and bind slot.
pub const StreamLayout = struct {
    /// Buffer slot, assigned by input order (not by shader location).
    slot: u32,
    /// WGSL shader input location supplied by this stream.
    location: u32,
    /// WebGPU vertex format derived from the shader's element type.
    format: wgpu.VertexFormat,
    /// Physical stride of one element in the backing buffer.
    stride: u64,
    /// Whether the stream advances per vertex or per instance.
    step_mode: wgpu.VertexStepMode,
};

/// Maps supported Zig scalar/vector types to WebGPU vertex formats at comptime.
///
/// Supports `f32`, `i32`, `u32`, and arrays of 2-4 of those scalar types.
/// Other shapes fail compilation rather than producing an invalid layout.
pub fn vertexFormatOf(comptime T: type) wgpu.VertexFormat {
    if (T == f32) return .float32;
    if (T == u32) return .uint32;
    if (T == i32) return .sint32;

    switch (@typeInfo(T)) {
        .array => |array| {
            if (array.len < 2 or array.len > 4) {
                @compileError(std.fmt.comptimePrint(
                    "vertexFormatOf: unsupported array type {s}; vertex vectors must have 2, 3, or 4 components",
                    .{@typeName(T)},
                ));
            }
            if (array.child == f32) {
                return switch (array.len) {
                    2 => .float32x2,
                    3 => .float32x3,
                    4 => .float32x4,
                    else => unreachable,
                };
            }
            if (array.child == u32) {
                return switch (array.len) {
                    2 => .uint32x2,
                    3 => .uint32x3,
                    4 => .uint32x4,
                    else => unreachable,
                };
            }
            if (array.child == i32) {
                return switch (array.len) {
                    2 => .sint32x2,
                    3 => .sint32x3,
                    4 => .sint32x4,
                    else => unreachable,
                };
            }
        },
        else => {},
    }

    @compileError(std.fmt.comptimePrint(
        "vertexFormatOf: unsupported vertex element type {s}; expected f32, i32, u32, or a 2-4 component array of one of those types",
        .{@typeName(T)},
    ));
}

/// Non-owning typed reference to one attribute buffer and its pipeline metadata.
pub fn VertexStream(comptime T: type) type {
    return struct {
        buffer: *gpu_buffer.GpuBuffer(T),
        layout: StreamLayout,

        const Self = @This();

        /// Returns the number of elements currently present in the backing buffer.
        pub fn len(self: *const Self) usize {
            return self.buffer.len();
        }

        /// Appends one value to this stream's CPU-side buffer contents.
        pub fn append(self: *Self, value: T) !void {
            try self.buffer.append(value);
        }

        /// Uploads pending CPU-side changes to this stream's GPU buffer.
        pub fn flush(self: *Self, gctx: *zgpu.GraphicsContext) !void {
            try self.buffer.flush(gctx);
        }

        /// Binds this stream at its assigned slot in the active render pass.
        pub fn bind(
            self: *const Self,
            gctx: *zgpu.GraphicsContext,
            pass: wgpu.RenderPassEncoder,
        ) !void {
            const handle = try self.buffer.handleFor(.vertex);
            const buffer = gctx.lookupResource(handle) orelse return error.BufferNotFound;
            pass.setVertexBuffer(self.layout.slot, buffer, 0, self.buffer.size());
        }
    };
}

/// Builds a shader-specific, non-owning collection of vertex attribute streams.
///
/// `Shader.vertex_inputs` defines the names, element types, locations, and step
/// modes. `init` receives exactly one `*GpuBuffer(ElementType)` for each input.
/// The generated `ContentType` is a struct with those same names and types;
/// `append` distributes each value to its matching buffer. Buffers remain owned
/// by their caller, and the caller must call `flush` before drawing changed data.
pub fn VertexStreams(comptime Shader: type) type {
    if (!@hasDecl(Shader, "vertex_inputs")) {
        @compileError("VertexStreams(Shader): Shader must declare vertex_inputs metadata");
    }
    const inputs = Shader.vertex_inputs;
    if (inputs.len == 0) {
        @compileError("VertexStreams(Shader): Shader.vertex_inputs must contain at least one input");
    }

    const field_names = comptime blk: {
        var result: [inputs.len][]const u8 = undefined;
        for (inputs, 0..) |input, index| result[index] = input.field_name;
        break :blk result;
    };
    const field_types = comptime blk: {
        var result: [inputs.len]type = undefined;
        for (inputs, 0..) |input, index| result[index] = VertexStream(input.element_type);
        break :blk result;
    };
    const field_attrs: [inputs.len]std.lang.Type.Struct.FieldAttributes = @splat(.{});
    const Streams = @Struct(.auto, null, &field_names, &field_types, &field_attrs);
    const content_types = comptime blk: {
        var result: [inputs.len]type = undefined;
        for (inputs, 0..) |input, index| result[index] = input.element_type;
        break :blk result;
    };
    const Content = @Struct(.auto, null, &field_names, &content_types, &field_attrs);
    const buffer_types = comptime blk: {
        var result: [inputs.len]type = undefined;
        for (inputs, 0..) |input, index| result[index] = gpu_buffer.GpuBuffer(input.element_type);
        break :blk result;
    };
    const BufferSet = @Struct(.auto, null, &field_names, &buffer_types, &field_attrs);
    const buffer_ref_types = comptime blk: {
        var result: [inputs.len]type = undefined;
        for (inputs, 0..) |input, index| result[index] = *gpu_buffer.GpuBuffer(input.element_type);
        break :blk result;
    };
    const BufferRefs = @Struct(.auto, null, &field_names, &buffer_ref_types, &field_attrs);

    comptime validateInputs(Shader);
    const attribute_arrays = makeAttributeArrays(Shader);

    return struct {
        streams: Streams,

        const Self = @This();

        pub const vertex_attributes = attribute_arrays;
        /// WebGPU layouts generated from the same input metadata as `bind`.
        pub const vertex_buffer_layouts = makeVertexBufferLayouts(Shader, &vertex_attributes);
        /// Struct shape accepted by `append`, containing one value per input.
        pub const ContentType = Content;
        /// Struct containing one owned `GpuBuffer` per shader input.
        pub const BufferSetType = BufferSet;
        /// Options shared by all buffers created for these vertex inputs.
        pub const CreateOptions = struct {
            allocator: std.mem.Allocator,
            context: *zgpu.GraphicsContext,
            capacity: usize,
        };

        /// Owns the typed buffers allocated by `create`.
        ///
        /// The aggregate itself should stay at a stable address while a view
        /// created by `view` or a `Mesh` initialized from that view is in use.
        pub const Owned = struct {
            buffers: BufferSet,

            /// Creates a non-owning stream view over these owned buffers.
            pub fn view(self: *@This()) !Self {
                var refs: BufferRefs = undefined;
                inline for (inputs) |input| {
                    @field(refs, input.field_name) = &@field(self.buffers, input.field_name);
                }
                return Self.init(refs);
            }

            /// Appends one shader-shaped value to every owned attribute buffer.
            pub fn append(self: *@This(), value: Content) !void {
                var streams = try self.view();
                try streams.append(value);
            }

            /// Uploads dirty ranges from all owned buffers.
            pub fn flush(self: *@This(), gctx: *zgpu.GraphicsContext) !void {
                var streams = try self.view();
                try streams.flush(gctx);
            }

            /// Binds every owned stream to the active render pass.
            pub fn bind(
                self: *@This(),
                gctx: *zgpu.GraphicsContext,
                pass: wgpu.RenderPassEncoder,
            ) !void {
                var streams = try self.view();
                try streams.bind(gctx, pass);
            }

            /// Returns the number of vertex-stepped elements.
            pub fn vertexCount(self: *const @This()) usize {
                inline for (inputs) |input| {
                    if (input.step_mode == .vertex) {
                        return @field(self.buffers, input.field_name).len();
                    }
                }
                return 0;
            }

            /// Returns the number of instance-stepped elements.
            pub fn instanceCount(self: *const @This()) usize {
                inline for (inputs) |input| {
                    if (input.step_mode == .instance) {
                        return @field(self.buffers, input.field_name).len();
                    }
                }
                return 0;
            }

            /// Releases all owned GPU buffers and their CPU-side storage.
            pub fn deinit(self: *@This(), gctx: *zgpu.GraphicsContext) void {
                inline for (inputs) |input| {
                    @field(self.buffers, input.field_name).deinit(gctx);
                }
                self.* = undefined;
            }
        };

        /// Creates a view over the exact buffers requested by the shader.
        ///
        /// Checks compile-time field/type agreement and runtime buffer roles,
        /// step modes, and element counts.
        pub fn init(buffers: anytype) !Self {
            comptime validateBuffers(Shader, @TypeOf(buffers));
            var streams: Streams = undefined;
            var vertex_count: ?usize = null;
            var instance_count: ?usize = null;

            inline for (inputs, 0..) |input, slot| {
                const buffer = @field(buffers, input.field_name);
                try buffer.validateRole(.vertex);
                if (buffer.step_mode != input.step_mode) return error.VertexStepModeMismatch;
                switch (input.step_mode) {
                    .vertex => {
                        if (vertex_count) |count| {
                            if (buffer.len() != count) return error.VertexCountMismatch;
                        } else {
                            vertex_count = buffer.len();
                        }
                    },
                    .instance => {
                        if (instance_count) |count| {
                            if (buffer.len() != count) return error.InstanceCountMismatch;
                        } else {
                            instance_count = buffer.len();
                        }
                    },
                    else => @compileError("VertexStreams(Shader): step_mode must be .vertex or .instance"),
                }

                @field(streams, input.field_name) = .{
                    .buffer = buffer,
                    .layout = .{
                        .slot = @intCast(slot),
                        .location = input.location,
                        .format = vertexFormatOf(input.element_type),
                        .stride = @sizeOf(input.element_type),
                        .step_mode = input.step_mode,
                    },
                };
            }
            return .{ .streams = streams };
        }

        /// Allocates one empty vertex buffer per shader input.
        ///
        /// Every buffer uses the same capacity and allocator/context, while
        /// element type and step mode come from `Shader.vertex_inputs`.
        /// The returned `Owned` value is responsible for releasing the buffers.
        pub fn create(options: CreateOptions) !Owned {
            var buffers: BufferSet = undefined;
            var initialized: [inputs.len]bool = @splat(false);
            errdefer {
                inline for (inputs, 0..) |input, index| {
                    if (initialized[index]) {
                        @field(buffers, input.field_name).deinit(options.context);
                    }
                }
            }

            inline for (inputs, 0..) |input, index| {
                @field(buffers, input.field_name) = try gpu_buffer.GpuBuffer(input.element_type).allocate(.{
                    .allocator = options.allocator,
                    .context = options.context,
                    .capacity = options.capacity,
                    .roles = .{ .vertex = true },
                    .step_mode = input.step_mode,
                });
                initialized[index] = true;
            }

            return .{ .buffers = buffers };
        }

        /// Appends one shader-shaped record to all corresponding attribute buffers.
        ///
        /// Validates stream lengths and reserves CPU capacity across every
        /// buffer before changing any stream. The record is not uploaded until
        /// `flush` is called.
        pub fn append(self: *Self, value: Content) !void {
            var vertex_count: ?usize = null;
            var instance_count: ?usize = null;

            inline for (inputs) |input| {
                const stream = &@field(self.streams, input.field_name);
                try stream.buffer.validateRole(.vertex);
                if (stream.buffer.step_mode != input.step_mode) return error.VertexStepModeMismatch;
                switch (input.step_mode) {
                    .vertex => {
                        if (vertex_count) |count| {
                            if (stream.len() != count) return error.VertexCountMismatch;
                        } else {
                            vertex_count = stream.len();
                        }
                    },
                    .instance => {
                        if (instance_count) |count| {
                            if (stream.len() != count) return error.InstanceCountMismatch;
                        } else {
                            instance_count = stream.len();
                        }
                    },
                    else => @compileError("VertexStreams(Shader): step_mode must be .vertex or .instance"),
                }
                try stream.buffer.prepareAppend();
            }

            inline for (inputs) |input| {
                try @field(self.streams, input.field_name).append(@field(value, input.field_name));
            }
        }

        /// Flushes each stream's dirty range to its GPU buffer.
        pub fn flush(self: *Self, gctx: *zgpu.GraphicsContext) !void {
            inline for (inputs) |input| {
                try @field(self.streams, input.field_name).flush(gctx);
            }
        }

        /// Validates device limits and binds every stream to its assigned slot.
        pub fn bind(
            self: *const Self,
            gctx: *zgpu.GraphicsContext,
            pass: wgpu.RenderPassEncoder,
        ) !void {
            var limits: wgpu.SupportedLimits = .{};
            if (!gctx.device.getLimits(&limits)) return error.DeviceLimitsUnavailable;
            if (inputs.len > limits.limits.max_vertex_buffers) return error.VertexBufferLimitExceeded;
            inline for (inputs) |input| {
                if (input.location >= limits.limits.max_vertex_attributes) return error.VertexAttributeLimitExceeded;
            }

            inline for (inputs) |input| {
                try @field(self.streams, input.field_name).bind(gctx, pass);
            }
        }

        /// Returns the element count of the vertex-stepped streams.
        pub fn vertexCount(self: *const Self) usize {
            inline for (inputs) |input| {
                if (input.step_mode == .vertex) {
                    return @field(self.streams, input.field_name).len();
                }
            }
            return 0;
        }

        /// Returns the element count of the instance-stepped streams.
        pub fn instanceCount(self: *const Self) usize {
            inline for (inputs) |input| {
                if (input.step_mode == .instance) {
                    return @field(self.streams, input.field_name).len();
                }
            }
            return 0;
        }
    };
}

fn validateInputs(comptime Shader: type) void {
    const inputs = Shader.vertex_inputs;
    inline for (inputs, 0..) |input, index| {
        _ = vertexFormatOf(input.element_type);
        if (input.field_name.len == 0) @compileError("VertexStreams(Shader): input field_name cannot be empty");
        if (input.step_mode != .vertex and input.step_mode != .instance) {
            @compileError("VertexStreams(Shader): step_mode must be .vertex or .instance");
        }
        inline for (inputs[0..index]) |previous| {
            if (std.mem.eql(u8, input.field_name, previous.field_name)) {
                @compileError(std.fmt.comptimePrint(
                    "VertexStreams(Shader): duplicate vertex input field '{s}'",
                    .{input.field_name},
                ));
            }
            if (input.location == previous.location) {
                @compileError(std.fmt.comptimePrint(
                    "VertexStreams(Shader): duplicate shader location {d}",
                    .{input.location},
                ));
            }
        }
    }
}

fn validateBuffers(comptime Shader: type, comptime Buffers: type) void {
    const buffer_field_names = switch (@typeInfo(Buffers)) {
        .@"struct" => |structure| structure.field_names,
        else => @compileError("VertexStreams.init: buffers must be a struct literal"),
    };
    const inputs = Shader.vertex_inputs;

    inline for (inputs) |input| {
        if (!@hasField(Buffers, input.field_name)) {
            @compileError(std.fmt.comptimePrint(
                "VertexStreams.init: missing buffer '{s}' (expected *GpuBuffer({s}))",
                .{ input.field_name, @typeName(input.element_type) },
            ));
        }
        const Expected = *gpu_buffer.GpuBuffer(input.element_type);
        const Actual = @FieldType(Buffers, input.field_name);
        if (Actual != Expected) {
            @compileError(std.fmt.comptimePrint(
                "VertexStreams.init: buffer '{s}' has type {s}; expected {s}",
                .{ input.field_name, @typeName(Actual), @typeName(Expected) },
            ));
        }
    }
    inline for (buffer_field_names) |field_name| {
        if (!hasShaderInput(inputs, field_name)) {
            @compileError(std.fmt.comptimePrint(
                "VertexStreams.init: unexpected buffer '{s}'; shader has no input with that field name",
                .{field_name},
            ));
        }
    }
}

fn hasShaderInput(comptime inputs: anytype, comptime name: []const u8) bool {
    inline for (inputs) |input| {
        if (std.mem.eql(u8, input.field_name, name)) return true;
    }
    return false;
}

fn makeAttributeArrays(comptime Shader: type) [Shader.vertex_inputs.len][1]wgpu.VertexAttribute {
    var result: [Shader.vertex_inputs.len][1]wgpu.VertexAttribute = undefined;
    inline for (Shader.vertex_inputs, 0..) |input, slot| {
        result[slot][0] = .{
            .format = vertexFormatOf(input.element_type),
            .offset = 0,
            .shader_location = input.location,
        };
    }
    return result;
}

fn makeVertexBufferLayouts(
    comptime Shader: type,
    comptime attributes: *const [Shader.vertex_inputs.len][1]wgpu.VertexAttribute,
) [Shader.vertex_inputs.len]wgpu.VertexBufferLayout {
    var result: [Shader.vertex_inputs.len]wgpu.VertexBufferLayout = undefined;
    inline for (Shader.vertex_inputs, 0..) |input, slot| {
        result[slot] = .{
            .array_stride = @sizeOf(input.element_type),
            .step_mode = input.step_mode,
            .attribute_count = 1,
            .attributes = &attributes[slot],
        };
    }
    return result;
}

test "vertexFormatOf maps supported scalar and vector types" {
    try std.testing.expectEqual(wgpu.VertexFormat.float32, vertexFormatOf(f32));
    try std.testing.expectEqual(wgpu.VertexFormat.uint32, vertexFormatOf(u32));
    try std.testing.expectEqual(wgpu.VertexFormat.sint32, vertexFormatOf(i32));
    try std.testing.expectEqual(wgpu.VertexFormat.float32x2, vertexFormatOf([2]f32));
    try std.testing.expectEqual(wgpu.VertexFormat.float32x3, vertexFormatOf([3]f32));
    try std.testing.expectEqual(wgpu.VertexFormat.float32x4, vertexFormatOf([4]f32));
    try std.testing.expectEqual(wgpu.VertexFormat.uint32x3, vertexFormatOf([3]u32));
    try std.testing.expectEqual(wgpu.VertexFormat.sint32x4, vertexFormatOf([4]i32));
}

const ThreeInputShader = struct {
    pub const VertexStreamInput = struct {
        field_name: []const u8,
        element_type: type,
        location: u32,
        step_mode: wgpu.VertexStepMode = .vertex,
    };
    pub const vertex_inputs = [_]VertexStreamInput{
        .{ .field_name = "position", .element_type = [3]f32, .location = 0 },
        .{ .field_name = "uv", .element_type = [2]f32, .location = 1 },
        .{ .field_name = "normal", .element_type = [3]f32, .location = 2 },
    };
};

const TwoInputShader = struct {
    pub const VertexStreamInput = ThreeInputShader.VertexStreamInput;
    pub const vertex_inputs = ThreeInputShader.vertex_inputs[0..2].*;
};

const OneInputShader = struct {
    pub const VertexStreamInput = ThreeInputShader.VertexStreamInput;
    pub const vertex_inputs = ThreeInputShader.vertex_inputs[0..1].*;
};

test "owned vertex streams expose one typed buffer for each input" {
    const Owned = VertexStreams(ThreeInputShader).Owned;
    const BufferSet = VertexStreams(ThreeInputShader).BufferSetType;

    try std.testing.expect(@FieldType(Owned, "buffers") == BufferSet);
    try std.testing.expect(@FieldType(BufferSet, "position") == gpu_buffer.GpuBuffer([3]f32));
    try std.testing.expect(@FieldType(BufferSet, "uv") == gpu_buffer.GpuBuffer([2]f32));
    try std.testing.expect(@FieldType(BufferSet, "normal") == gpu_buffer.GpuBuffer([3]f32));
}

fn testGpuBuffer(comptime T: type, allocator: std.mem.Allocator, values: []const T) !gpu_buffer.GpuBuffer(T) {
    var contents: std.ArrayList(T) = .empty;
    try contents.appendSlice(allocator, values);
    return .{
        .buffer_handle = .{},
        .allocator = allocator,
        .contents = contents,
        .roles = .{ .vertex = true },
        .capacity_items = values.len,
        .index_format = null,
        .step_mode = .vertex,
        .allocation_size = values.len * @sizeOf(T),
    };
}

test "one asset creates vertex stream views with shader-specific subsets" {
    const allocator = std.testing.allocator;
    var position = try testGpuBuffer([3]f32, allocator, &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 } });
    defer position.contents.deinit(allocator);
    var uv = try testGpuBuffer([2]f32, allocator, &.{ .{ 0, 0 }, .{ 1, 0 } });
    defer uv.contents.deinit(allocator);
    var normal = try testGpuBuffer([3]f32, allocator, &.{ .{ 0, 0, 1 }, .{ 0, 0, 1 } });
    defer normal.contents.deinit(allocator);

    const all = try VertexStreams(ThreeInputShader).init(.{
        .position = &position,
        .uv = &uv,
        .normal = &normal,
    });
    const uv_depth = try VertexStreams(TwoInputShader).init(.{
        .position = &position,
        .uv = &uv,
    });
    const depth = try VertexStreams(OneInputShader).init(.{
        .position = &position,
    });

    try std.testing.expectEqual(@as(usize, 3), @TypeOf(all.vertex_buffer_layouts).len);
    try std.testing.expectEqual(@as(usize, 2), @TypeOf(uv_depth.vertex_buffer_layouts).len);
    try std.testing.expectEqual(@as(usize, 1), @TypeOf(depth.vertex_buffer_layouts).len);
    try std.testing.expectEqual(@as(usize, 2), all.vertexCount());
    try std.testing.expectEqual(@as(usize, 2), uv_depth.vertexCount());
    try std.testing.expectEqual(@as(usize, 2), depth.vertexCount());
    try std.testing.expect(all.streams.position.buffer == &position);
    try std.testing.expect(all.streams.uv.buffer == &uv);
    try std.testing.expect(all.streams.normal.buffer == &normal);
    try std.testing.expect(uv_depth.streams.position.buffer == &position);
    try std.testing.expect(depth.streams.position.buffer == &position);
}

test "append distributes one typed vertex across buffers and rejects capacity overflow" {
    const allocator = std.testing.allocator;
    var position = try testGpuBuffer([3]f32, allocator, &.{});
    defer position.contents.deinit(allocator);
    position.capacity_items = 1;
    var uv = try testGpuBuffer([2]f32, allocator, &.{});
    defer uv.contents.deinit(allocator);
    uv.capacity_items = 1;
    var normal = try testGpuBuffer([3]f32, allocator, &.{});
    defer normal.contents.deinit(allocator);
    normal.capacity_items = 1;

    var streams = try VertexStreams(ThreeInputShader).init(.{
        .position = &position,
        .uv = &uv,
        .normal = &normal,
    });
    try streams.append(.{
        .position = .{ 1, 2, 3 },
        .uv = .{ 0.25, 0.75 },
        .normal = .{ 0, 0, 1 },
    });

    try std.testing.expectEqual(@as(usize, 1), streams.vertexCount());
    try std.testing.expectEqual([3]f32{ 1, 2, 3 }, position.contents.items[0]);
    try std.testing.expectEqual([2]f32{ 0.25, 0.75 }, uv.contents.items[0]);
    try std.testing.expectEqual([3]f32{ 0, 0, 1 }, normal.contents.items[0]);
    try std.testing.expectEqual(@as(?usize, 0), position.dirty_start);
    try std.testing.expectEqual(@as(?usize, 0), uv.dirty_start);
    try std.testing.expectEqual(@as(?usize, 0), normal.dirty_start);

    try std.testing.expectError(error.CapacityExceeded, streams.append(.{
        .position = .{ 4, 5, 6 },
        .uv = .{ 0.5, 0.5 },
        .normal = .{ 1, 0, 0 },
    }));
    try std.testing.expectEqual(@as(usize, 1), position.len());
    try std.testing.expectEqual(@as(usize, 1), uv.len());
    try std.testing.expectEqual(@as(usize, 1), normal.len());
}

test "vertex stream initialization validates roles and element counts" {
    const allocator = std.testing.allocator;
    var position = try testGpuBuffer([3]f32, allocator, &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 } });
    defer position.contents.deinit(allocator);
    var uv = try testGpuBuffer([2]f32, allocator, &.{.{ 0, 0 }});
    defer uv.contents.deinit(allocator);
    var normal = try testGpuBuffer([3]f32, allocator, &.{ .{ 0, 0, 1 }, .{ 0, 0, 1 } });
    defer normal.contents.deinit(allocator);

    try std.testing.expectError(error.VertexCountMismatch, VertexStreams(ThreeInputShader).init(.{
        .position = &position,
        .uv = &uv,
        .normal = &normal,
    }));

    position.roles = .{};
    try std.testing.expectError(error.BufferRoleMismatch, VertexStreams(OneInputShader).init(.{
        .position = &position,
    }));
}

// Compile-time failures:
// VertexStreams(ThreeInputShader).init(.{ .position = &position, .uv = &uv })
//   -> missing buffer 'normal'.
// VertexStreams(OneInputShader).init(.{ .position = &position, .normal = &normal })
//   -> unexpected buffer 'normal'.
// var wrong_uv: GpuBuffer([3]f32) = undefined;
// VertexStreams(ThreeInputShader).init(.{ .position = &position, .uv = &wrong_uv, .normal = &normal })
//   -> buffer 'uv' expects *GpuBuffer([2]f32), received *GpuBuffer([3]f32).
