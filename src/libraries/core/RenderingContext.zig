const std = @import("std");
const zgpu = @import("zgpu");

/// Bundles the GPU context with the allocator used to create rendering resources.
pub const RenderingContext = struct {
    context: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
};
