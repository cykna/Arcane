const Queries = @import("libraries/ecs/queries.zig");
const World = @import("libraries/ecs/World.zig").World;
const Transform = @import("libraries/math/Transform.zig").Transform;
const std = @import("std");
const zmath = @import("zmath");
const zgpu = @import("zgpu");
const glfw = @import("zglfw");
const streams = @import("libraries/core/VertexStreams.zig");
const mesh = @import("libraries/objects/Mesh.zig");
const triangle = @import("shaders/triangle.zig");
const Camera = @import("libraries/objects/cameras/Camera.zig").GpuCamera;
const PerspectiveCamera = @import("libraries/objects/cameras/PerspectiveCamera.zig").PerspectiveCamera;
const Arcane = @import("windowing/Window.zig");
const Io = std.Io;

const arcane = @import("arcane");
const TriangleStreams = streams.VertexStreams(triangle);
const TriangleMesh = mesh.Mesh(triangle);

comptime {
    if (@sizeOf(Camera.CameraUniform) != @sizeOf(triangle.package_camera_Camera)) {
        @compileError("camera uniform size does not match the generated triangle shader binding");
    }
    if (@alignOf(Camera.CameraUniform) != @alignOf(triangle.package_camera_Camera)) {
        @compileError("camera uniform alignment does not match the generated triangle shader binding");
    }
    if (@offsetOf(Camera.CameraUniform, "view") != @offsetOf(triangle.package_camera_Camera, "view") or
        @offsetOf(Camera.CameraUniform, "projection") != @offsetOf(triangle.package_camera_Camera, "projection") or
        @offsetOf(Camera.CameraUniform, "view_projection") != @offsetOf(triangle.package_camera_Camera, "view_projection") or
        @offsetOf(Camera.CameraUniform, "inverse_view_projection") != @offsetOf(triangle.package_camera_Camera, "inverse_view_projection"))
    {
        @compileError("camera uniform field offsets do not match the generated triangle shader binding");
    }
}

test {
    _ = Camera;
}

const Player = struct { health: f32, transform: @import("libraries/math/Transform.zig").Transform };

fn create_triangle(window: *Arcane.Window) !TriangleStreams.Owned {
    var vertex_streams = try TriangleStreams.create(.{
        .allocator = window.allocator,
        .context = window.context,
        .capacity = 3,
    });
    try vertex_streams.append(.{
        .position = .{ 0.5, 0.0, 0.0 },
        .color = .{ 1.0, 1.0, 1.0, 1.0 },
    });
    try vertex_streams.append(.{
        .position = .{ -0.5, 0.0, 0.0 },
        .color = .{ 0.0, 1.0, 1.0, 1.0 },
    });
    try vertex_streams.append(.{
        .position = .{ 0.0, 0.5, 0.0 },
        .color = .{ 0.0, 0.0, 1.0, 1.0 },
    });
    try vertex_streams.flush(window.context);
    return vertex_streams;
}

/// Runs the triangle sample using generated shader bindings and SoA vertex streams.
pub fn main(_: std.process.Init) !void {
    var world: World = World{ .allocator = std.heap.page_allocator };
    defer world.deinit();
    {
        if (glfw.platformSupported(.wayland)) {
            try glfw.initHint(.platform, glfw.Platform.wayland);
        }
        std.debug.print("", .{});
    }
    try Arcane.init();
    defer Arcane.terminate();

    {
        var window: Arcane.Window = undefined;
        try Arcane.Window.create(&window, .{
            .allocator = std.heap.page_allocator,
            .width = 720,
            .height = 480,
            .name = "Suamae cadela",
        });
        try world.insertGlobal(window);
    }
    defer {
        if (world.getGlobal(Arcane.Window)) |w| {
            w.destroy();
        }
    }
    if (world.getGlobal(Arcane.Window)) |window| {
        const render_pipeline = triangle.Pipeline.createWithVertexLayouts(
            window.context,
            @embedFile("shaders/wgsl/triangle.wgsl"),
            &TriangleStreams.vertex_buffer_layouts,
        );
        defer triangle.Pipeline.destroy(window.context, render_pipeline);

        var camera = try PerspectiveCamera.init(.{ .context = window.context, .pipeline = render_pipeline, .allocator = window.allocator });
        _ = try world.insert(camera);
        defer camera.deinit(window.context);

        var vertex_streams = try create_triangle(window);
        defer vertex_streams.deinit(window.context);

        const triangle_mesh = TriangleMesh.init(try vertex_streams.view());
        while (!window.shouldClose()) {
            glfw.pollEvents();
            const processing = window.startProcessing();
            {
                var q: World.QueryCursor(PerspectiveCamera), const w = try world.query(PerspectiveCamera, Queries.Join(Queries.Resource(Arcane.Window)));

                for (q.items(.transform)) |*transform| {
                    transform.position[2] += 0.01;

                    if (processing.resize and processing.width > 0 and processing.height > 0) {
                        try PerspectiveCamera.setViewport(
                            q,
                            @intFromFloat(processing.width),
                            @intFromFloat(processing.height),
                        );
                    }
                    q.next() orelse {
                        std.debug.print("Weird shouldnt break", .{});
                        break;
                    };
                    try PerspectiveCamera.update(q, w.context);
                }
            }

            const pass = processing.startRenderization(zmath.f32x4(0.0, 0.0, 0.0, 1.0));

            defer window.finishProcessing(processing);
            defer pass.end();

            try triangle.Pipeline.bind(window.context, pass, render_pipeline);
            try camera.bind(window.context, pass);
            try triangle_mesh.bind(window.context, pass);
            triangle_mesh.draw(pass);
        }
    }
}
