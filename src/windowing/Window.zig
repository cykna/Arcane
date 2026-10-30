const zmath = @import("zmath");
const glfw = @import("zglfw");
const zgpu = @import("zgpu");
const std = @import("std");

/// Owns the GLFW window and zgpu context used by the sample renderer.
pub const Window = struct {
    window: *glfw.Window,
    context: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
    resize: bool,
    const Self = @This();

    /// Arguments used to create a window and its graphics context.
    pub const CreateWindowOption = struct { width: u32, height: u32, name: [:0]const u8, allocator: std.mem.Allocator };

    /// Creates a window and its associated GPU context.
    pub fn create(self: *Self, option: CreateWindowOption) !void {
        const window = try glfw.Window.create(@intCast(option.width), @intCast(option.height), option.name, null, null);

        self.* = Self{
            .resize = false,
            .window = window,
            .context = try zgpu.GraphicsContext.create(option.allocator, .{
                .window = window,
                .fn_getTime = @ptrCast(&glfw.getTime),
                .fn_getFramebufferSize = @ptrCast(&glfw.Window.getFramebufferSize),
                .fn_getX11Display = @ptrCast(&glfw.getX11Display),
                .fn_getX11Window = @ptrCast(&glfw.getX11Window),
                .fn_getWaylandDisplay = @ptrCast(&glfw.getWaylandDisplay),
                .fn_getWaylandSurface = @ptrCast(&glfw.getWaylandWindow),
            }, .{}),
            .allocator = option.allocator,
        };
        _ = self.window.setFramebufferSizeCallback(onResize);
        self.setup();
    }

    fn setup(self: *Self) void {
        self.window.setUserPointer(self);
    }

    /// Destroys the window and GPU context.
    pub fn destroy(self: *const Self) void {
        self.window.destroy();
        self.context.destroy(self.allocator);
    }

    /// Recreates the swapchain using the window's current framebuffer size.
    pub fn resizeSwapchain(self: *Self) void {
        const x, const y = self.window.getFramebufferSize();
        self.context.swapchain_descriptor.width = @intCast(x);
        self.context.swapchain_descriptor.height = @intCast(y);

        const old = self.context.swapchain;

        self.context.swapchain = self.context.device.createSwapChain(self.context.surface, self.context.swapchain_descriptor);
        old.release();
    }
    /// Per-frame swapchain image and command encoder returned by `startProcessing`.
    pub const ArcaneWindowProcessingState = struct {
        width: f32,
        height: f32,
        resize: bool,
        encoder: zgpu.wgpu.CommandEncoder,
        view: zgpu.wgpu.TextureView,
        /// Begins a render pass that clears the current swapchain image.
        pub fn startRenderization(self: *const ArcaneWindowProcessingState, background: zmath.F32x4) zgpu.wgpu.RenderPassEncoder {
            const attachments = [_]zgpu.wgpu.RenderPassColorAttachment{.{
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{
                    .r = background[0],
                    .g = background[1],
                    .b = background[2],
                    .a = background[3],
                },
                .view = self.view,
            }};
            const pass = self.encoder.beginRenderPass(.{ .color_attachments = &attachments, .color_attachment_count = attachments.len });
            if (self.resize) {
                std.debug.print("Setting viewport to 0x0 by {}x{} by 0x1\n", .{ self.width, self.height });
                pass.setViewport(0.0, 0.0, self.width, self.height, 0.0, 1.0);
            }
            return pass;
        }

        /// Releases the command encoder and current swapchain texture view.
        pub fn destroy(self: *const ArcaneWindowProcessingState) void {
            self.encoder.release();
            self.view.release();
        }
    };

    /// Acquires the current swapchain image and creates a command encoder.
    pub fn startProcessing(self: *Self) ArcaneWindowProcessingState {
        const resize = self.resize;
        if (self.resize) {
            self.resizeSwapchain();
        }
        const encoder = self.context.device.createCommandEncoder(.{});
        const back_buffer_view = self.context.swapchain.getCurrentTextureView();
        return ArcaneWindowProcessingState{
            .encoder = encoder,
            .view = back_buffer_view,
            .resize = resize,
            .width = @floatFromInt(self.context.swapchain_descriptor.width),
            .height = @floatFromInt(self.context.swapchain_descriptor.height),
        };
    }

    /// Submits commands recorded during this frame and presents the image.
    pub fn finishProcessing(self: *Self, state: ArcaneWindowProcessingState) void {
        defer state.destroy();
        const cmd_buffer = state.encoder.finish(.{});
        self.context.submit(&.{cmd_buffer});
        _ = self.context.present();
        if (self.resize) {
            self.resize = false;
        }
    }

    /// Reports whether GLFW has requested that the window close.
    pub fn shouldClose(self: *const Self) bool {
        return self.window.shouldClose();
    }
};

/// Initializes GLFW and configures it for a no-client-API graphics window.
pub fn init() !void {
    try glfw.init();
    glfw.windowHint(.visible, true);
    glfw.windowHint(.client_api, .no_api);
}

/// Shuts down GLFW after all windows have been destroyed.
pub fn terminate() void {
    glfw.terminate();
}

/// GLFW framebuffer-size callback; marks the window for swapchain resizing.
pub fn onResize(window: *glfw.Window, _: c_int, _: c_int) callconv(.c) void {
    var win = window.getUserPointer(Window) orelse return;
    win.resize = true;
}
