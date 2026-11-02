const zgpu = @import("zgpu");
const zmath = @import("zmath");
const std = @import("std");

pub const Empty = struct {};

/// Per-frame swapchain image and command encoder returned by `startProcessing`.
pub fn ArcaneWindowProcessingState(comptime State: type) type {
    return struct {
        width: f32,
        height: f32,
        resize: bool,
        encoder: zgpu.wgpu.CommandEncoder,
        view: zgpu.wgpu.TextureView,
        _state: State = .{},

        /// Begins a render pass that clears the current swapchain image.
        pub fn startRenderization(self: *const ArcaneWindowProcessingState(Empty), background: zmath.F32x4) zgpu.wgpu.RenderPassEncoder {
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
        pub fn destroy(self: *const ArcaneWindowProcessingState(Empty)) void {
            self.encoder.release();
            self.view.release();
        }
    };
}
