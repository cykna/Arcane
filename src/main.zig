const ShaderContent = @import("libraries/ecs/Shaders.zig").ShaderContent;
const Material = @import("./libraries/objects/Material.zig");

const Buffers = @import("libraries/core/GpuBuffer.zig");
const RenderingContext = @import("libraries/core/RenderingContext.zig").RenderingContext;
const ArcaneEcs = @import("libraries/ecs/Main.zig");
const World = ArcaneEcs.World;

const Transform = @import("libraries/math/Transform.zig").Transform;
const std = @import("std");
const zmath = @import("zmath");
const zgpu = @import("zgpu");
const glfw = @import("zglfw");
const streams = @import("libraries/core/VertexStreams.zig");
const mesh = @import("libraries/objects/Mesh.zig");
const InstanceBuffer = @import("libraries/objects/InstanceBuffer.zig").InstanceBuffer;
const Scene = @import("libraries/ecs/Scene.zig").Scene;
const triangle = @import("shaders/triangle.zig");
const Camera = @import("libraries/objects/cameras/Camera.zig").GpuCamera;
const PerspectiveCamera = @import("libraries/objects/cameras/PerspectiveCamera.zig").PerspectiveCamera;
const Arcane = @import("windowing/Window.zig");
const Io = std.Io;

const arcane = @import("arcane");
const TriangleStreams = streams.VertexStreams(triangle);

const Player = struct { health: f32, transform: @import("libraries/math/Transform.zig").Transform };

fn create_triangle(rendering_context: RenderingContext) !TriangleStreams.Owned {
    var vertex_streams = try TriangleStreams.create(.{
        .rendering_context = rendering_context,
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
    try vertex_streams.flush(rendering_context);
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
        try world.insertGlobal(Scene{ .pool = .{ .rendering_context = window.renderingContext() } });
    }

    defer world.destroyGlobal(Scene);
    defer world.destroyGlobal(Arcane.Window);

    if (world.getGlobals(.{ Arcane.Window, Scene })) |window_scene| {
        var window, var scene = window_scene;
        const rendering_context = window.renderingContext();

        defer scene.pool.endInstances(triangle);
        _ = try scene.pool.initialize(triangle);

        var camera = try PerspectiveCamera.init(rendering_context);
        _ = try world.insert(camera);
        defer camera.deinit(rendering_context);

        const triangleMaterial = Material.Material(triangle);
        var buffer = try Buffers.GpuBuffer(triangle.package_globals_MeshData).unit(.{ .rendering_context = rendering_context, .roles = .{ .storage = true }, .content = .{ .model = Transform.identity().toWGslMat4x4(), .normal_matrix = Transform.identity().toWGslMat4x4() } });
        defer buffer.deinit(rendering_context);
        var vertex_streams = try create_triangle(rendering_context);
        defer vertex_streams.deinit(rendering_context);

        var content = ShaderContent(triangle){ .material = triangleMaterial{
            .binds = .{ .group0 = .{ .camera = &camera.uniform_buffer }, .group1 = .{ .instances = &buffer } },
        }, .mesh = mesh.Mesh(triangle).init(try vertex_streams.view()) };
        defer content.material.deinit(rendering_context);
        try content.material.prepare(rendering_context);

        while (!window.shouldClose()) {
            glfw.pollEvents();
            const processing = window.startProcessing();
            {
                var q, _ = try world.query(PerspectiveCamera, World.Loaders.Null, World.Mutabilities.mut);
                while (q.nextItems(.{.transform})) |item| {
                    var transform = item[0];

                    transform.position[2] += 0.01;
                    if (processing.resize and processing.width > 0 and processing.height > 0) {
                        try PerspectiveCamera.setViewport(
                            &q,
                            @intFromFloat(processing.width),
                            @intFromFloat(processing.height),
                        );
                    }
                    try PerspectiveCamera.update(&q, rendering_context);
                }
            }

            const pass = processing.startRenderization(zmath.f32x4(0.0, 0.0, 0.0, 1.0));

            defer window.finishProcessing(processing);
            defer pass.end();

            try scene.prepareFor(triangle, pass);
            try content.draw(rendering_context, pass);
        }
    }
}

test {
    _ = @import("material_test.zig");
}
