const Buffers = @import("../../core/GpuBuffer.zig");
const RenderingContext = @import("../../core/RenderingContext.zig").RenderingContext;
const World = @import("../../ecs/World.zig").World;
const zmath = @import("zmath");
const std = @import("std");
const Transform = @import("../../math/Transform.zig").Transform;
const Camera = @import("./Camera.zig").GpuCamera;
const GpuCamera = Camera;
pub const PerspectiveCamera = struct {
    camera: Camera,
    uniform_buffer: Buffers.GpuBuffer(Camera.CameraUniform),
    transform: Transform,

    const Self = @This();
    const CreateCameraOptions = struct {
        transform: Transform = .{ .position = zmath.f32x4s(0.0), .rotation = zmath.f32x4(0.0, 0.0, 0.0, 1.0), .scale = zmath.f32x4s(1.0) },
        fov: f32 = 90.0,
    };
    pub fn init(rendering_context: RenderingContext) !Self {
        return initWithOptions(rendering_context, .{});
    }

    pub fn initWithOptions(rendering_context: RenderingContext, options: CreateCameraOptions) !Self {
        const camera = camera: {
            var position: [3]f32 = undefined;
            zmath.storeArr3(&position, options.transform.position);
            const camera = try Camera.init(.{ .position = position, .vertical_fov_radians = options.fov * std.math.pi / 180, .aspect_ratio = 16.0 / 9.0 });
            break :camera camera;
        };
        var buffer = try Buffers.GpuBuffer(Camera.CameraUniform).allocate(.{
            .rendering_context = rendering_context,
            .capacity = 1,
            .roles = .{ .uniform = true },
        });
        errdefer buffer.deinit(rendering_context);
        try buffer.append(camera.matrices().uniformData());
        try buffer.flush(rendering_context);

        return Self{ .transform = options.transform, .camera = camera, .uniform_buffer = buffer };
    }

    pub fn deinit(self: *Self, rendering_context: RenderingContext) void {
        self.uniform_buffer.deinit(rendering_context);
        self.* = undefined;
    }

    /// Updates the camera aspect ratio from framebuffer pixel dimensions.
    ///
    /// A zero-sized viewport is rejected, which can occur while a window is
    /// minimized; callers should skip rendering until it has nonzero dimensions.
    pub fn setViewport(self: *World.QueryCursor(Self, World.Mutabilities.mut), width: u32, height: u32) !void {
        if (width == 0 or height == 0) return error.InvalidViewport;
        self.get(.camera).aspect_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    }

    /// Direção para onde a câmera olha (-Z local).
    pub fn forward(self: *const Self) [3]f32 {
        return self.rotateLocal(.{ 0, 0, -1 });
    }
    pub fn backward(self: *const Self) [3]f32 {
        return self.rotateLocal(.{ 0, 0, 1 });
    }

    pub fn right(self: *const Self) [3]f32 {
        return self.rotateLocal(.{ 1, 0, 0 });
    }

    pub fn left(self: *const Self) [3]f32 {
        return self.rotateLocal(.{ -1, 0, 0 });
    }

    pub fn upDirection(self: *const Self) [3]f32 {
        return self.rotateLocal(.{ 0, 1, 0 });
    }

    pub fn downDirection(self: *const Self) [3]f32 {
        return self.rotateLocal(.{ 0, -1, 0 });
    }

    fn rotateLocal(self: *const Self, v: [3]f32) [3]f32 {
        const q = zmath.loadArr4(self.transform.rotation);
        var out: [3]f32 = undefined;
        zmath.storeArr3(&out, zmath.rotate(q, zmath.loadArr3(v)));
        return out;
    }

    pub fn getUniform(self: World.QueryCursor(Self)) Camera.CameraUniform {
        return self.get(.camera).matrices().uniformData();
    }

    pub fn update(self: *World.QueryCursor(Self, World.Mutabilities.mut), rendering_context: RenderingContext) !void {
        zmath.storeArr3(&self.get(.camera).position, self.get(.transform).position);
        self.get(.camera).rotation = self.get(.transform).rotation;
        const uniform = self.get(.camera).matrices().uniformData();
        try self.get(.uniform_buffer).set(0, uniform);
        try self.get(.uniform_buffer).flush(rendering_context);
    }
};
