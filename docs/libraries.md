# Library guide

The reusable code in `src/libraries/` currently contains two vertex-data paths:

- `GpuBuffer(T)` is the low-level, fixed-capacity GPU buffer. It owns its GPU
  resource and CPU-side mirror.
- `VertexStreams(Shader)` derives one `GpuBuffer` per shader vertex input
  (structure-of-arrays / SoA) from `Shader.vertex_inputs`. Its `create` method
  returns an owning aggregate; `init` creates a non-owning view over external
  buffers.
- `Mesh(Shader)` is a small non-owning wrapper around a `VertexStreams(Shader)`
  value. It delegates stream binding and vertex/instance counts. Index buffers
  are not part of this type.
- `Camera` stores an independent perspective-camera pose and projection. Its
  `GpuBinding` holds one camera's uniform buffer and bind group; camera instances
  can share a `BindingLayout` obtained from a compatible render pipeline.
- `GeometryBuffer(T)` is a separate interleaved-vertex abstraction, with an
  optional `u32` index buffer. It validates a caller-supplied layout against a
  shader interface. It does not use the SoA stream API.
- `HeterogeneousContainer` is an experimental compile-time utility. Its current
  `append` signature check and call shape are inconsistent; avoid depending on
  it as a general container adapter until that contract is resolved.

## Shader-driven SoA streams

Generated shader modules provide `vertex_inputs` metadata. Each input names a
field, its Zig element type, shader location, and vertex/instance step mode.
`VertexStreams(Shader)` uses that one list to generate its typed `ContentType`,
per-input fields, vertex attributes, and pipeline buffer layouts. Buffer slots
follow input-list order; shader locations are kept separately in the attributes.

`VertexStreams(Shader).create` is the owning convenience API. It allocates one
buffer per shader input using a shared capacity, allocator, and graphics
context; each buffer's element type and step mode are derived from the shader.
The returned owner exposes typed buffers through `.buffers`, and releases all
of them with one `deinit` call:

```zig
const streams_lib = @import("libraries/core/VertexStreams.zig");
const mesh_lib = @import("libraries/objects/Mesh.zig");
const shader = @import("shaders/triangle.zig");
const TriangleStreams = streams_lib.VertexStreams(shader);
const TriangleMesh = mesh_lib.Mesh(shader);

var owned = try TriangleStreams.create(.{
    .allocator = allocator,
    .context = gctx,
    .capacity = 3,
});
defer owned.deinit(gctx);

try owned.append(.{
    .position = .{ 0, 0, 0 },
    .color = .{ 1, 1, 1, 1 },
});
try owned.flush(gctx);
const mesh = TriangleMesh.init(try owned.view());
```

Pass `&TriangleStreams.vertex_buffer_layouts` when creating the render pipeline.
After binding that pipeline, `try mesh.bind(gctx, pass)` binds the stream buffers.
`mesh.vertexCount()` reports the vertex-stepped count for the draw call.
Appending changes the CPU mirrors and marks them dirty; `flush(gctx)` must run
before drawing for those updates to reach the GPU. Capacity is fixed at creation,
so append operations return `error.CapacityExceeded` when full. Keep `owned` at a
stable address while a view or mesh created from `owned.view()` is in use, since
those views contain pointers to its buffers.

For externally managed buffers or sharing buffers across multiple shaders,
`VertexStreams.init` remains available as a non-owning view constructor. It
requires exactly one pointer to `GpuBuffer(ElementType)` for each shader input.
Missing, extra, or mismatched fields are compile-time errors. It checks vertex
usage, step mode, and equal element counts among streams with the same step
mode. `bind` checks relevant device limits and reports missing GPU resources.
The view and `Mesh` do not allocate, free, or resize buffers.

## Cameras

`Camera` is CPU-side state and can be created once per view or player. It
calculates right-handed view and projection matrices using WebGPU's depth range,
updates aspect ratio from framebuffer dimensions, and packs them into the
256-byte WGSL camera uniform declared by `shaders/wesl/camera.wesl`.

The renderer currently uses an automatically laid-out camera group at group 0,
binding 0. Obtain that layout from the render pipeline, then create one
`Camera.GpuBinding` per camera. Layout ownership is shared; each GPU binding
owns a separate uniform buffer and bind group. Update a binding after changing
that camera's pose/projection, bind it before drawing, and release camera
bindings before releasing the shared layout:

```zig
const Camera = @import("libraries/objects/Camera.zig").Camera;

var camera = try Camera.init(.{
    .position = .{ 0, 0, 2 },
    .target = .{ 0, 0, 0 },
    .vertical_fov_radians = @as(f32, std.math.pi) / 3.0,
    .aspect_ratio = 16.0 / 9.0,
});
var layout = Camera.BindingLayout.create(gctx, pipeline, 0, 0);
defer layout.deinit(gctx);
var camera_binding = try Camera.GpuBinding.create(gctx, allocator, &layout, camera);
defer camera_binding.deinit(gctx);
```

For split-screen or render-to-texture work, create more `Camera` and
`Camera.GpuBinding` values using the same compatible layout, then bind the
desired camera for each render pass. This implementation supplies camera
matrices only; per-object model matrices and a general draw-item/material
system are separate future concerns.

## Low-level GPU buffers

Use `GpuBuffer(T).allocate` when a caller needs explicit control over a buffer's
contents, usage roles, and capacity. CPU mutations (`append`, `appendSlice`,
`set`, `update`, `resize`, and `clear`) update the CPU mirror; `flush` uploads
the accumulated dirty range. `bindVertexBuffer` and `bindIndexBuffer` are
convenience methods for binding a single resource. The caller must call
`deinit(context)` exactly once for each successfully allocated buffer.

`Roles` determine the WebGPU usage flags at creation. Index buffers require an
explicit `.uint16` or `.uint32` format matching `T`. There is no automatic
capacity growth or GPU-resource replacement.

## Interleaved geometry

Use `GeometryBuffer(T)` when one `T` value represents an entire interleaved
vertex. Supply a comptime `VertexLayout` with a stride and attribute offsets,
and a shader interface declaring `VertexInput` and `vertex_attributes`.
Creation validates field existence, offsets, formats, and shader locations.
An index buffer is optional and stores `u32`; `appendIndex` checks that the
referenced vertex already exists. Call `flush` after CPU-side edits and before
rendering.

This API intentionally remains distinct from `VertexStreams(Shader)`: SoA
streams each have their own buffer and zero attribute offset, while
`GeometryBuffer(T)` describes several attributes inside each interleaved item.

## Window sample and validation

`src/main.zig` is the GLFW/zgpu sample application. `Window` owns its
window and graphics context; its frame helpers acquire the swapchain image,
record a render pass, submit commands, and present. The sample demonstrates the
generated triangle pipeline together with `GpuBuffer`, `VertexStreams`, and
`Mesh`.

Run `zig build` to compile the application and `zig build test` to run the
library and generator tests. Zig source APIs have inline documentation comments
so their public declarations also appear in generated Zig documentation.
