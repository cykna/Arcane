const World = @import("../../ecs/World.zig").World;
const zmath = @import("zmath");
const std = @import("std");
const zgpu = @import("zgpu");
const Transform = @import("../../math/Transform.zig").Transform;
const Camera = @import("./Camera.zig").GpuCamera;
const GpuCamera = Camera;
pub const PerspectiveCamera = struct {
    camera: Camera,
    binding: Camera.GpuBinding,
    transform: Transform,

    const Self = @This();
    const CreateCameraOptions = struct {
        context: *zgpu.GraphicsContext,
        pipeline: zgpu.RenderPipelineHandle,
        allocator: std.mem.Allocator,
        group_index: u32 = 0,
        binding_index: u32 = 0,
        transform: Transform = .{ .position = zmath.f32x4s(0.0), .rotation = zmath.f32x4(0.0, 0.0, 0.0, 1.0), .scale = zmath.f32x4s(1.0) },
        fov: f32 = 90.0,
    };
    pub fn init(options: CreateCameraOptions) !Self {
        const camera = camera: {
            var position: [3]f32 = undefined;
            zmath.storeArr3(&position, options.transform.position);
            const camera = try Camera.init(.{ .position = position, .vertical_fov_radians = options.fov * std.math.pi / 180, .aspect_ratio = 16.0 / 9.0 });
            break :camera camera;
        };
        var layout = Camera.BindingLayout.create(options.context, options.pipeline, options.group_index, options.binding_index);
        defer layout.deinit(options.context);
        const binding = try Camera.GpuBinding.create(options.context, options.allocator, &layout, camera);

        return Self{ .transform = options.transform, .camera = camera, .binding = binding };
    }

    pub fn deinit(self: *Self, ctx: *zgpu.GraphicsContext) void {
        self.binding.deinit(ctx);
    }

    /// Updates the camera aspect ratio from framebuffer pixel dimensions.
    ///
    /// A zero-sized viewport is rejected, which can occur while a window is
    /// minimized; callers should skip rendering until it has nonzero dimensions.
    pub fn setViewport(self: World.QueryCursor(Self), width: u32, height: u32) !void {
        if (width == 0 or height == 0) return error.InvalidViewport;
        self.get(.camera).aspect_ratio = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    }

    /// Binds this camera's group to the active render pass.
    pub fn bind(self: *const Self, ctx: *zgpu.GraphicsContext, pass: zgpu.wgpu.RenderPassEncoder) !void {
        const group = ctx.lookupResource(self.binding.bind_group) orelse return error.CameraBindGroupNotFound;
        pass.setBindGroup(self.binding.group_index, group, null);
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

    pub fn update(self: World.QueryCursor(Self), ctx: *zgpu.GraphicsContext) !void {
        zmath.storeArr3(&self.get(.camera).position, self.get(.transform).position);
        self.get(.camera).rotation = self.get(.transform).rotation;
        try self.get(.binding).update(ctx, self.get(.camera));
    }
};
