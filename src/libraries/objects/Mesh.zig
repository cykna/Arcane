const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const vertex_streams = @import("../core/VertexStreams.zig");

/// Shader-specific mesh view that groups vertex streams without owning buffers.
///
/// The buffer owner must outlive the mesh. Use `VertexStreams(Shader)` to
/// create and populate streams; this wrapper delegates binding and count queries
/// while leaving index-buffer ownership outside the vertex-stream abstraction.
pub fn Mesh(comptime Shader: type) type {
    const Streams = vertex_streams.VertexStreams(Shader);

    return struct {
        vertex_streams: Streams,

        const Self = @This();

        /// Wraps an already validated stream view.
        pub fn init(streams: Streams) Self {
            return .{ .vertex_streams = streams };
        }

        /// Binds the mesh's vertex streams to the active render pass.
        pub fn bind(
            self: *const Self,
            gctx: *zgpu.GraphicsContext,
            pass: wgpu.RenderPassEncoder,
        ) !void {
            try self.vertex_streams.bind(gctx, pass);
        }

        /// Returns the current number of vertex-stepped elements.
        pub fn vertexCount(self: *const Self) usize {
            return self.vertex_streams.vertexCount();
        }

        /// Returns the current number of instance-stepped elements.
        pub fn instanceCount(self: *const Self) usize {
            return self.vertex_streams.instanceCount();
        }

        pub fn draw(self: *const Self, pass: zgpu.wgpu.RenderPassEncoder) void {
            const instanceQuantity = if (self.instanceCount() == 0) 1 else self.instanceCount();
            pass.draw(@intCast(self.vertexCount()), @intCast(instanceQuantity), 0, 0);
        }
    };
}
