const std = @import("std");
const Transform = @import("../../math/Transform.zig");
const zmath = @import("zmath");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const gpu_buffer = @import("../../core/GpuBuffer.zig");

/// Perspective camera state and matrices, independent of any GPU resource.
///
/// Each value is an independent camera, so a scene can own multiple cameras
/// with different poses, projections, and viewport aspect ratios.
pub const GpuCamera = struct {
    position: [3]f32,
    rotation: zmath.Quat,
    vertical_fov_radians: f32,
    aspect_ratio: f32,
    near_plane: f32,
    far_plane: f32,

    /// Matrices use zmath's row-vector convention. The matching uniform
    /// representation stores those rows as WGSL matrix columns.
    pub const Matrices = struct {
        view: zmath.Mat,
        projection: zmath.Mat,
        view_projection: zmath.Mat,
        inverse_view_projection: zmath.Mat,

        /// Packs the matrices into the WGSL GpuCamera uniform layout used by
        /// `shaders/wesl/camera.wesl`.
        pub fn uniformData(self: Matrices) CameraUniform {
            return .{
                .view = gpuMat4(self.view),
                .projection = gpuMat4(self.projection),
                .view_projection = gpuMat4(self.view_projection),
                .inverse_view_projection = gpuMat4(self.inverse_view_projection),
            };
        }
    };

    /// Host-shareable representation of the WGSL camera uniform block.
    pub const CameraUniform = extern struct {
        view: GpuMat4 align(16),
        projection: GpuMat4 align(16),
        view_projection: GpuMat4 align(16),
        inverse_view_projection: GpuMat4 align(16),
    };

    /// One WGSL `mat4x4<f32>` stored as four 16-byte columns.
    pub const GpuMat4 = extern struct {
        columns: [4]GpuVec4 align(16),
    };

    /// One host-shareable WGSL `vec4<f32>`.
    pub const GpuVec4 = extern struct {
        x: f32,
        y: f32,
        z: f32,
        w: f32,
    };

    /// Parameters used to create a perspective camera.
    pub const CreateOptions = struct {
        position: [3]f32 = .{ 0, 0, 0 },
        rotation: zmath.Quat = zmath.qidentity(),
        vertical_fov_radians: f32,
        aspect_ratio: f32,
        near_plane: f32 = 0.1,
        far_plane: f32 = 1000,
    };

    /// Shared bind-group layout for camera uniforms in a pipeline.
    ///
    /// Create this once per compatible pipeline and reuse it for any number of
    /// `GpuBinding` camera instances.
    pub const BindingLayout = struct {
        handle: zgpu.BindGroupLayoutHandle,
        group_index: u32,
        binding_index: u32,

        /// Obtains the camera group layout from an auto-layout render pipeline.
        pub fn create(
            gctx: *zgpu.GraphicsContext,
            pipeline: zgpu.RenderPipelineHandle,
            group_index: u32,
            binding_index: u32,
        ) BindingLayout {
            return .{
                .handle = gctx.createBindGroupLayoutAuto(pipeline, group_index),
                .group_index = group_index,
                .binding_index = binding_index,
            };
        }

        /// Releases the shared bind-group layout.
        pub fn deinit(self: *BindingLayout, gctx: *zgpu.GraphicsContext) void {
            gctx.releaseResource(self.handle);
            self.* = undefined;
        }
    };

    /// GPU uniform buffer and bind group for one camera instance.
    ///
    /// Multiple instances can share a `BindingLayout`, while retaining separate
    /// camera matrices and GPU resources.
    pub const GpuBinding = struct {
        uniform_buffer: gpu_buffer.GpuBuffer(CameraUniform),
        bind_group: zgpu.BindGroupHandle,
        group_index: u32,

        /// Allocates and initializes the camera uniform buffer and bind group.
        pub fn create(
            gctx: *zgpu.GraphicsContext,
            allocator: std.mem.Allocator,
            layout: *BindingLayout,
            camera: GpuCamera,
        ) !GpuBinding {
            var uniform_buffer = try gpu_buffer.GpuBuffer(CameraUniform).allocate(.{
                .allocator = allocator,
                .context = gctx,
                .capacity = 1,
                .roles = .{ .uniform = true },
            });
            errdefer uniform_buffer.deinit(gctx);

            try uniform_buffer.append(camera.matrices().uniformData());
            try uniform_buffer.flush(gctx);

            const bind_group = gctx.createBindGroup(layout.handle, &.{
                .{
                    .binding = layout.binding_index,
                    .buffer_handle = uniform_buffer.buffer_handle,
                    .offset = 0,
                    .size = @sizeOf(CameraUniform),
                },
            });
            return .{
                .uniform_buffer = uniform_buffer,
                .bind_group = bind_group,
                .group_index = layout.group_index,
            };
        }

        /// Uploads matrices after the camera pose or projection has changed.
        pub fn update(self: *GpuBinding, gctx: *zgpu.GraphicsContext, camera: *GpuCamera) !void {
            try self.uniform_buffer.set(0, camera.matrices().uniformData());
            try self.uniform_buffer.flush(gctx);
        }

        /// Binds this camera's group to the active render pass.
        pub fn bind(self: *const GpuBinding, gctx: *zgpu.GraphicsContext, pass: wgpu.RenderPassEncoder) !void {
            const group = gctx.lookupResource(self.bind_group) orelse return error.CameraBindGroupNotFound;
            pass.setBindGroup(self.group_index, group, null);
        }

        /// Releases this camera's bind group and uniform buffer.
        pub fn deinit(self: *GpuBinding, gctx: *zgpu.GraphicsContext) void {
            gctx.releaseResource(self.bind_group);
            self.uniform_buffer.deinit(gctx);
            self.* = undefined;
        }
    };

    /// Creates a right-handed perspective camera looking toward `target`.
    pub fn init(options: CreateOptions) !GpuCamera {
        var camera: GpuCamera = .{
            .position = options.position,
            .rotation = options.rotation,
            .vertical_fov_radians = options.vertical_fov_radians,
            .aspect_ratio = options.aspect_ratio,
            .near_plane = options.near_plane,
            .far_plane = options.far_plane,
        };
        try camera.validate();
        return camera;
    }

    /// Changes the camera pose after checking it remains geometrically valid.
    pub fn setPose(self: *GpuCamera, position: [3]f32, rotation: zmath.Quat) !void {
        const old_position = self.position;
        const old_rotation = self.rotation;
        self.position = position;
        self.rotation = rotation;

        self.validate() catch |err| {
            self.position = old_position;
            self.rotation = old_rotation;
            return err;
        };
    }

    /// Calculates view, WebGPU-depth perspective, view-projection, and inverse matrices.
    pub fn matrices(self: *const GpuCamera) Matrices {
        const view = zmath.mul(zmath.translationV(-zmath.loadArr3(self.position)), zmath.quatToMat(zmath.conjugate(self.rotation)));
        const projection = zmath.perspectiveFovRh(
            self.vertical_fov_radians,
            self.aspect_ratio,
            self.near_plane,
            self.far_plane,
        );
        const view_projection = zmath.mul(view, projection);
        return .{
            .view = view,
            .projection = projection,
            .view_projection = view_projection,
            .inverse_view_projection = zmath.inverse(view_projection),
        };
    }

    fn validate(self: *const GpuCamera) !void {
        if (!finite3(self.position)) return error.NonFiniteCameraVector;
        _ = try Transform.normalizedRotation(self.rotation);

        if (!std.math.isFinite(self.vertical_fov_radians) or
            self.vertical_fov_radians <= 0 or
            self.vertical_fov_radians >= std.math.pi)
        {
            return error.InvalidFieldOfView;
        }
        if (!std.math.isFinite(self.aspect_ratio) or self.aspect_ratio <= 0) {
            return error.InvalidAspectRatio;
        }
        if (!std.math.isFinite(self.near_plane) or
            !std.math.isFinite(self.far_plane) or
            self.near_plane <= 0 or
            self.far_plane <= self.near_plane)
        {
            return error.InvalidClipPlanes;
        }
    }
};

fn gpuMat4(matrix: zmath.Mat) GpuCamera.GpuMat4 {
    var result: GpuCamera.GpuMat4 = undefined;
    for (matrix, 0..) |column, index| {
        result.columns[index] = .{
            .x = column[0],
            .y = column[1],
            .z = column[2],
            .w = column[3],
        };
    }
    return result;
}

fn finite3(value: [3]f32) bool {
    for (value) |component| {
        if (!std.math.isFinite(component)) return false;
    }
    return true;
}

fn subtract(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn lengthSquared(value: [3]f32) f32 {
    return value[0] * value[0] + value[1] * value[1] + value[2] * value[2];
}

fn distanceSquared(a: [3]f32, b: [3]f32) f32 {
    return lengthSquared(subtract(a, b));
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

test "camera builds right-handed view projection and WGSL uniform data" {
    const camera = try GpuCamera.init(.{
        .position = .{ 0, 0, 0 },
        .vertical_fov_radians = @as(f32, std.math.pi) / 2.0,
        .aspect_ratio = 1,
        .near_plane = 0.1,
        .far_plane = 100,
    });
    const matrices = camera.matrices();

    const near_clip = zmath.mul(zmath.f32x4(0, 0, -0.1, 1), matrices.view_projection);
    const far_clip = zmath.mul(zmath.f32x4(0, 0, -100, 1), matrices.view_projection);
    try std.testing.expectApproxEqAbs(@as(f32, 0), near_clip[2] / near_clip[3], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), far_clip[2] / far_clip[3], 0.0001);

    const uniform = matrices.uniformData();
    try std.testing.expectEqual(@as(usize, 256), @sizeOf(GpuCamera.CameraUniform));
    try std.testing.expectEqual(@as(usize, 16), @alignOf(GpuCamera.CameraUniform));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(GpuCamera.CameraUniform, "view"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(GpuCamera.CameraUniform, "projection"));
    try std.testing.expectEqual(@as(usize, 128), @offsetOf(GpuCamera.CameraUniform, "view_projection"));
    try std.testing.expectEqual(@as(usize, 192), @offsetOf(GpuCamera.CameraUniform, "inverse_view_projection"));
    try std.testing.expectEqual(matrices.view_projection[0][0], uniform.view_projection.columns[0].x);
    try std.testing.expectEqual(matrices.view_projection[0][1], uniform.view_projection.columns[0].y);

    const world = zmath.f32x4(0.25, -0.5, 0, 1);
    const expected = zmath.mul(world, matrices.view_projection);
    const columns = uniform.view_projection.columns;
    const shader_result = [4]f32{
        columns[0].x * world[0] + columns[1].x * world[1] + columns[2].x * world[2] + columns[3].x * world[3],
        columns[0].y * world[0] + columns[1].y * world[1] + columns[2].y * world[2] + columns[3].y * world[3],
        columns[0].z * world[0] + columns[1].z * world[1] + columns[2].z * world[2] + columns[3].z * world[3],
        columns[0].w * world[0] + columns[1].w * world[1] + columns[2].w * world[2] + columns[3].w * world[3],
    };
    inline for (0..4) |index| {
        try std.testing.expectApproxEqAbs(expected[index], shader_result[index], 0.0001);
    }
}

test "camera viewport and pose changes are independent and validated" {
    var first = try GpuCamera.init(.{
        .vertical_fov_radians = @as(f32, std.math.pi) / 3.0,
        .aspect_ratio = 1,
    });
    const second = try GpuCamera.init(.{
        .position = .{ 2, 0, 0 },
        .vertical_fov_radians = @as(f32, std.math.pi) / 4.0,
        .aspect_ratio = 2,
    });

    try first.setViewport(1600, 900);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0 / 9.0), first.aspect_ratio, 0.0001);
    try std.testing.expectEqual(@as(f32, 2), second.aspect_ratio);
    try std.testing.expectError(error.InvalidViewport, first.setViewport(0, 480));

    const old_position = first.position;
    try std.testing.expectError(
        error.InvalidCameraDirection,
        first.setPose(.{ 1, 2, 3 }, .{ 1, 2, 3 }, .{ 0, 1, 0 }),
    );
    try std.testing.expectEqual(old_position, first.position);
}

test "camera rejects invalid projection parameters" {
    try std.testing.expectError(error.InvalidAspectRatio, GpuCamera.init(.{
        .vertical_fov_radians = 1,
        .aspect_ratio = 0,
    }));
    try std.testing.expectError(error.InvalidFieldOfView, GpuCamera.init(.{
        .vertical_fov_radians = 0,
        .aspect_ratio = 1,
    }));
    try std.testing.expectError(error.InvalidClipPlanes, GpuCamera.init(.{
        .vertical_fov_radians = 1,
        .aspect_ratio = 1,
        .near_plane = 10,
        .far_plane = 1,
    }));
}
