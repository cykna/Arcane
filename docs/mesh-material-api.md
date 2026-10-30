# Mesh and material API: design prototype

## Status and scope

This document proposes an API for composing and rendering meshes with the
current Zig 0.17.0 and `zgpu` dependency. It is an architectural prototype,
not an implementation of meshes, materials, uploads, batching, or a renderer.
Code labeled **API sketch** shows intended Zig syntax and type relationships;
it uses proposed types and functions that do not exist yet. Sections labeled
**Pseudocode** omit backend and error-handling details.

The design is for assets such as weapons and characters whose parts can be
replaced independently and can use different geometry, materials, shaders,
textures, and render state. It takes inspiration from the ergonomic composition
of Bevy and Three.js without adopting their ECS or object model.

## What exists today

The application targets Zig 0.17.0 (`build.zig.zon` sets
`minimum_zig_version = "0.17.0"`; the inspected compiler reports `0.17.0`).
The rendering dependency is `zgpu` 0.12.0-dev, backed by WebGPU/Dawn.

The application currently has:

- `ArcaneWindow` in `src/main.zig`, which owns a `zgpu.GraphicsContext` and
  begins and submits a render pass.
- Generated `src/shaders/triangle.zig`, which defines WGSL interface structs
  and a helper that creates a render-pipeline handle with reflected vertex
  buffer layouts, binds it to a pass, and releases it.
- `GpuBuffer(T)` in `src/libraries/gpubuffer.zig`, which creates a GPU buffer
  with usage roles selected at construction, tracks CPU-side changes, uploads
  dirty data, and validates vertex/index binding roles.
- `GeometryBuffer(T)` in `src/libraries/geometry_buffer.zig`, which composes a
  typed vertex buffer with an optional `u32` index buffer and an explicit
  physical vertex layout. Its creation validates field names, Zig offsets,
  field types, formats, stride, and unique shader locations at compile time;
  it can also validate a declared shader interface against those locations
  and formats.
- The `zgpu.GraphicsContext` resource API: `createBuffer`,
  `createBindGroupLayout`, `createBindGroup`, `createPipelineLayout`,
  `createRenderPipeline`, `lookupResource`, and `releaseResource`. Its GPU
  resources use typed handles such as `BufferHandle` and
  `RenderPipelineHandle`.
- The lower-level `zgpu.wgpu` API for vertex buffer layouts and attributes,
  render-pipeline descriptors, bind groups, render-pass commands, and buffer
  writes.

There is **not yet** a mesh asset, material abstraction, texture/material
cache, general draw queue, or batching system. The triangle now has a working
vertex upload and binding path through `GeometryBuffer`; it still submits its
draw manually and has no material/mesh ownership layer.

The existing anygpu JSON now exposes logical vertex inputs as well as a
default WebGPU vertex-buffer layout. These are not interchangeable with a
geometry's physical layout: `GeometryBuffer` still requires an explicit Zig
layout tying each physical field to its shader location and format. The
triangle currently declares its shader interface explicitly in Zig and checks
it against the geometry layout at compile time; material integration can later
make generated shader metadata provide that interface automatically.

## Design summary

Use three layers with different responsibilities:

1. **Typed authoring layer:** CPU geometry, shader/material types, and typed
   parts. Generic Zig APIs validate contracts while a material is attached to
   geometry.
2. **Runtime asset layer:** GPU handles and ordinary runtime data. It supports
   heterogeneous parts, named weapon/character slots, replacement, and
   rendering without making every runtime object a unique generic type.
3. **Renderer/backend layer:** translates runtime items into `zgpu` handles,
   bind groups, pipeline state, and render-pass commands.

Geometry does not own or select a material. A mesh is a composition of
independently rendered **parts**; a one-part mesh is the simple case. A part
references geometry and a material and may select a transform, draw range, or
pipeline/render-state variant. The mesh/asset groups parts for authoring and
replacement, but is not assumed to be one GPU draw call.

## Responsibilities and relationships

### Vertex data and geometry

Geometry describes the physical bytes available to a vertex shader:

- A vertex record type and vertex-buffer stride.
- An explicit mapping from shader locations to GPU formats and byte offsets.
- Vertex data and optional index data.
- Optionally, bounds and named subranges in a later phase.

The shader's *logical interface* is the set of locations and expected value
formats. The geometry's *physical layout* says where those values reside in
one or more buffers. The GPU pipeline's `VertexBufferLayout` and
`VertexAttribute` descriptors encode that physical layout for WebGPU. These
are related, but must not be conflated.

For example, the generated `VertexInput` for a WGSL struct may include
WGSL-compatible padding and member alignment. That makes it useful as an
interface/layout representation, but it does not guarantee that the data
should be stored in that exact arrangement in a vertex buffer. A vertex buffer
can pack `vec3<f32>` at byte 0 and `vec4<f32>` at byte 12 with a 28-byte
stride, even if a WGSL host-shareable struct has a different member offset.
The physical vertex layout must match the chosen uploaded bytes and pipeline
attributes.

### Shader interface and material

A shader module supplies logical interface metadata and pipeline creation.
A material supplies the values and resources used with that shader:

- A pipeline or pipeline-variant selection.
- Textures, samplers, uniform data, and other binding resources.
- Blend/depth/rasterization policy, or a selection among pipelines with those
  states baked in.

The shader interface should expose explicit metadata such as
`VertexRequirements`, binding declarations, and supported material parameters.
The material's public type can associate this metadata with values and GPU
handles. Shader code and material parameters are related but distinct: changing
a texture or uniform should not require uploading geometry again.

Render state belongs primarily to a **pipeline variant**, because WebGPU
pipeline state such as blend, depth, and primitive state is specified when the
pipeline is created. A material may choose a variant, and a part may override
that choice only when the renderer can resolve the override to a compatible
variant. Geometry should not contain render state.

Wireframe is not guaranteed by the current WebGPU abstraction/backend.
Represent it as a requested mode, then either choose a supported feature/pipeline
variant or return an explicit unsupported-mode error. Do not silently claim
wireframe while rendering filled triangles.

### Mesh and part composition

A mesh asset is a set of named or indexed part slots, each with its own
geometry/material association. A fixed Zig struct is useful for known,
semantically named slots (weapon receiver, barrel, magazine). A runtime list
is useful for content assembled from files or user customization. Support both:
typed structs at the authoring boundary, runtime part records in the renderer.

Each part can change independently. Replacing a barrel updates one slot; it
does not recreate receiver buffers or unrelated materials. A material swap
does not upload geometry. A geometry replacement can retain the existing
material if its vertex contract still matches.

## Proposed Zig type relationships

The following sketch uses Zig 0.17.0 language constructs such as `anytype`,
`@TypeOf`, `@hasDecl`, `@sizeOf`, and `@offsetOf`. The types are proposals; this
is not code that currently compiles against the repository.

### Explicit geometry layout

```zig
const wgpu = @import("zgpu").wgpu;

pub const VertexAttribute = struct {
    location: u32,
    format: wgpu.VertexFormat,
    offset: u64,
};

pub const VertexLayout = struct {
    stride: u64,
    attributes: []const VertexAttribute,
};

pub fn Geometry(comptime Vertex: type, comptime layout: VertexLayout) type {
    return struct {
        pub const VertexType = Vertex;
        pub const vertex_layout = layout;

        vertices: []const Vertex,
        indices: []const u32,
    };
}

const Vertex = extern struct {
    position: [3]f32,
    color: [4]f32,
};

const VertexGeometry = Geometry(Vertex, .{
    .stride = @sizeOf(Vertex),
    .attributes = &.{
        .{
            .location = 0,
            .format = .float32x3,
            .offset = @offsetOf(Vertex, "position"),
        },
        .{
            .location = 1,
            .format = .float32x4,
            .offset = @offsetOf(Vertex, "color"),
        },
    },
});
```

In this example, the physical offsets and stride come from the actual Zig
vertex record, while the locations/formats express how the shader consumes
those bytes. The layout is explicit and compile-time-known. A later helper can
derive offsets from fields, but should not infer shader locations from field
names.

### Shader metadata and structural compatibility

Do not require nominal type equality between a generated `VertexInput` struct
and a user's vertex record. Two structurally identical Zig structs can still
be different types, and a physical vertex record often has a different shape
from a WGSL interface struct. Instead, compare explicit location/format
metadata.

**API sketch:**

```zig
pub const VertexRequirement = struct {
    location: u32,
    format: wgpu.VertexFormat,
};

pub const TriangleMaterial = struct {
    pub const ShaderInterface = struct {
        pub const vertex_attributes = [_]VertexRequirement{
            .{ .location = 0, .format = .float32x3 },
            .{ .location = 1, .format = .float32x4 },
        };
    };

    pub const Parameters = struct {
        tint: [4]f32 = .{ 1, 1, 1, 1 },
    };

    pipeline: zgpu.RenderPipelineHandle,
    parameters: Parameters,
};

pub fn validateVertexContract(
    comptime GeometryType: type,
    comptime MaterialType: type,
) void {
    if (!@hasDecl(MaterialType, "ShaderInterface"))
        @compileError("material must declare ShaderInterface");
    if (!@hasDecl(GeometryType, "vertex_layout"))
        @compileError("geometry must declare vertex_layout");

    inline for (MaterialType.ShaderInterface.vertex_attributes) |required| {
        var found = false;
        inline for (GeometryType.vertex_layout.attributes) |provided| {
            if (provided.location == required.location) {
                if (provided.format != required.format)
                    @compileError("vertex attribute format does not match shader");
                found = true;
            }
        }
        if (!found)
            @compileError("geometry is missing a shader vertex attribute");
    }
}
```

The example checks required locations and formats. Production validation
should additionally reject duplicate locations, validate stride/offset bounds
and alignment, and account for multiple vertex buffers/step modes. If the
shader interface cannot be represented as compile-time Zig declarations, the
same checks must run during asset or pipeline creation and report a runtime
error.

`@hasDecl` is suitable for validating that a type namespace provides the
required declarations; it is not a substitute for checking their contents.
`@TypeOf(material)` gives the concrete material type without asking callers to
repeat it. `@offsetOf` is valid for a known struct field, but still does not
reveal which shader location that field is meant to feed.

### Attach without repeating type arguments

The attach function can infer the concrete geometry and material types. The
returned part remains statically typed during construction:

```zig
pub fn TypedPart(comptime GeometryType: type, comptime MaterialType: type) type {
    return struct {
        geometry: GeometryType,
        material: MaterialType,
        transform: Transform = .identity,
        state: PartState = .{},
    };
}

pub const MeshPart = struct {
    pub fn attach(geometry: anytype, material: anytype) TypedPart(
        @TypeOf(geometry),
        @TypeOf(material),
    ) {
        comptime validateVertexContract(@TypeOf(geometry), @TypeOf(material));
        return .{
            .geometry = geometry,
            .material = material,
        };
    }
};

const part = MeshPart.attach(vertex_geometry, material);
```

This shows compile-time compatibility validation and inferred types. A real
constructor that uploads data or allocates GPU resources should return an
error union; resource creation can fail at runtime. The typed part can be
converted to a compact runtime handle after upload/registration.

## Per-part render configuration

Different body/weapon parts should be allowed to reference entirely different
material types during authoring. A character can consequently combine an
opaque skin shader, an armor shader, and a transparent equipment shader without
trying to force all parts through one material type.

Keep the per-part state small and semantic:

```zig
pub const PartState = struct {
    visible: bool = true,
    wireframe: bool = false,
};

pub const Transform = struct {
    // Illustrative representation; choose a project-wide math type later.
    translation: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    scale: [3]f32 = .{ 1, 1, 1 },

    pub const identity: Transform = .{};
};
```

`PartState.wireframe` is a request, not a promise of backend support. Blend
mode and depth-write behavior should generally select a material/pipeline
variant rather than override incompatible state after pipeline creation.
Transparent parts are submitted to a transparent queue and sorted by the
renderer; opaque parts can be grouped by compatible state.

## Named customization and runtime heterogeneity

Use a named struct when the slots are known to the game code. The values in
these fields can be runtime handles, so replacing a part does not require
recompiling the mesh type.

```zig
pub const Weapon = struct {
    receiver: RuntimePart,
    barrel: RuntimePart,
    magazine: RuntimePart,
    stock: ?RuntimePart = null,
    sight: ?RuntimePart = null,
    suppressor: ?RuntimePart = null,

    pub fn replaceBarrel(self: *Weapon, replacement: RuntimePart) RuntimePart {
        const old = self.barrel;
        self.barrel = replacement;
        return old;
    }
};
```

Illustrative authoring API:

```zig
const weapon = Weapon{
    .receiver = try upload(MeshPart.attach(receiver_geometry, receiver_material)),
    .barrel = try upload(MeshPart.attach(barrel_geometry, barrel_material)),
    .magazine = try upload(MeshPart.attach(magazine_geometry, magazine_material)),
    .sight = try upload(MeshPart.attach(sight_geometry, optic_material)),
};

const old_barrel = weapon.replaceBarrel(try upload(
    MeshPart.attach(suppressed_barrel_geometry, barrel_material),
));
defer release(old_barrel);

try renderer.submitWeapon(weapon, weapon_transform);
```

`upload`, `release`, `RuntimePart`, and `renderer` are proposed interfaces, not
existing project APIs. A dynamic asset loader can instead build a slice of
`RuntimePart` records. Named structs are ideal for source-level ergonomics;
slices/maps are better for unknown or data-driven slot counts. These should be
two views over the same runtime part representation, not competing renderer
models.

### Character with heterogeneous parts

```zig
const character = Character{
    .head = try upload(MeshPart.attach(head_geometry, skin_material)),
    .torso = try upload(MeshPart.attach(torso_geometry, armor_material)),
    .legs = try upload(MeshPart.attach(leg_geometry, debug_material)),
    .equipment = try upload(MeshPart.attach(pack_geometry, transparent_material)),
};
```

The debug material can select a wireframe pipeline when supported; the
equipment material can select alpha blending and the transparent queue. The
torso can use a separate shader and binding layout. No geometry type needs to
know which material it will be paired with.

## End-to-end authoring flow

This sketch shows the intended progression from vertex data to a submitted
runtime asset. Material construction and upload are proposals; adapt them to
the eventual error/ownership API.

```zig
const vertices = [_]Vertex{
    .{ .position = .{ 0, 0, 0 }, .color = .{ 1, 0, 0, 1 } },
    .{ .position = .{ 1, 0, 0 }, .color = .{ 0, 1, 0, 1 } },
    .{ .position = .{ 0, 1, 0 }, .color = .{ 0, 0, 1, 1 } },
};
const indices = [_]u32{ 0, 1, 2 };
const geometry = VertexGeometry{
    .vertices = &vertices,
    .indices = &indices,
};

const material = try TriangleMaterial.create(gctx, .{
    .tint = .{ 1, 1, 1, 1 },
});

const typed_part = MeshPart.attach(geometry, material);
const part = try renderer.uploadPart(typed_part);
try renderer.submit(part, .identity);

// Later, replace just this part's geometry/material and release the old
// runtime part when no submitted frame can still reference it.
```

The geometry record says locations 0 and 1 are `float32x3` and `float32x4`;
the shader interface must state the same requirements. The material owns or
references GPU material resources, and the renderer turns the typed part into
a runtime draw item. Rendering should not require the caller to manually
construct a bind group for each draw once material bindings are implemented.

## Runtime representation and resource ownership

Generics are valuable at API boundaries but should not dictate the renderer's
storage layout. `TypedPart(GeometryType, MaterialType)` is useful for compile-
time validation and ergonomics. A renderer with arbitrary assets should store
compact, type-erased records such as:

```zig
pub const RuntimePart = struct {
    geometry: GeometryHandle,
    material: MaterialHandle,
    transform: Transform,
    index_start: u32 = 0,
    index_count: u32,
    state: PartState = .{},
};
```

These handle types and the struct are proposed. Internally, geometry records
would refer to vertex/index buffer handles plus layout and counts; material
records would refer to pipeline/material bind-group handles, parameters, and a
pipeline key. The render queue can resolve handles through an asset/resource
store and issue `setPipeline`, `setBindGroup`, `setVertexBuffer`, and indexed
draw operations.

Ownership should be explicit:

- CPU geometry input slices are borrowed only during upload unless the asset
  explicitly owns a copy.
- Uploaded vertex/index buffers are owned by a geometry asset or shared
  geometry cache.
- Material assets own/reference their uniform buffers, textures, samplers, and
  bind groups. Shared textures/materials use reference-counted or central
  asset-store lifetime, not implicit copies of GPU objects.
- Pipeline/layout handles are cached and released by a renderer or pipeline
  cache; a part should not destroy a pipeline shared by other parts.
- Replacing a component releases only its old owned resources, after submitted
  work no longer references them. Resource lifetime must account for in-flight
  frames.

This can be built on `zgpu.GraphicsContext`'s existing typed handles and
`create*`/`lookupResource`/`releaseResource` methods. The project does not yet
define the ownership wrapper, asset store, or deferred-release policy.

## Runtime rendering and performance

One part generally means one draw item, but not necessarily one draw call:
compatible items can be batched or instanced. Initially, favor correct,
independent draws. Add batching only after the runtime records expose stable
keys for geometry, material, pipeline variant, and pass.

An opaque queue can sort/group by pipeline and material to reduce state
changes. A transparent queue usually needs back-to-front ordering, limiting
reordering and batching. Per-part different shaders/materials naturally incur
state changes; this is the cost of the requested visual variation, not a
reason to couple materials to geometry.

Avoid one generic renderer type per possible material/mesh combination.
Keep CPU-side typed wrappers small and convert them to runtime handles at
asset creation. Cache pipelines by shader, vertex layout, color/depth target
formats, and fixed render state. Cache bind-group layouts by shader interface
and material class. Reuse GPU buffers for unchanged geometry; update
parameters/textures without re-uploading vertices.

Dynamic replacement should update one part's handles and bounds. If the
replacement changes the shader interface, validate it when attaching or
uploading, then regenerate only the affected pipeline/material resources.

## Compile-time versus runtime validation

**Good compile-time candidates**

- Required declarations exist on a shader/material type (`@hasDecl`).
- Known required vertex locations are present in a compile-time vertex layout.
- Attribute formats match, locations are unique, and declared offsets fit the
  stride.
- A typed uniform value has the expected Zig type and layout declaration.
- A named static composition supplies all required slots.

**Runtime checks**

- Buffer allocation, GPU validation, and device feature support.
- Geometry loaded from files or assembled from runtime customization.
- Texture dimensions/formats and resource-handle validity.
- Unsupported wireframe/pipeline features.
- Bind-group contents and resource lifetime.
- Whether a dynamically loaded geometry satisfies a material's interface.

Compile-time metadata should be explicit. A shader generator may emit
`ShaderInterface.vertex_attributes` and binding descriptions, but the current
anygpu JSON lacks vertex locations. Until that is available, declare those
requirements in Zig or add a WGSL reflection stage; do not infer them from
struct field names or byte offsets.

## Trade-offs

| Choice | Benefit | Cost |
|---|---|---|
| Generic typed parts during authoring | Inferred material/geometry types and early interface errors | More compile-time work and monomorphization at call sites |
| Runtime handles in renderer/assets | Heterogeneous materials, dynamic replacement, compact iteration | Runtime lookup and validation; less nominal type information |
| Explicit attribute metadata | Correct distinction between shader locations and buffer offsets | Small amount of declaration/generated metadata |
| Named fixed slots | Readable weapon/character APIs and simple replacement | Awkward for arbitrary mod-defined slots |
| Runtime part arrays | Data-driven assets and flexible counts | Slot names need an identifier/map and validation |
| Pipeline variants for render state | Matches WebGPU's pipeline model and enables cache keys | More pipeline variants and cache entries |
| One part per independently rendered section | Different shader/material/state per section | More draw calls unless compatible parts are batched |

The recommended combination is typed authoring plus runtime handles, with
named structs for game-defined slots and arrays/maps for extensible content.

## Phased prototype roadmap

1. **Physical vertex layout and upload.** Define `VertexAttribute`,
   `VertexLayout`, and a small geometry upload path to `zgpu` buffers. Add a
   triangle example that describes both locations and binds its vertex buffer.
   Keep the shader requirements explicit in Zig because current JSON omits
   locations.
2. **Shader interface/material contract.** Define a material namespace with
   explicit vertex requirements and binding metadata. Add compile-time
   validation for static geometry and runtime validation for loaded assets.
   Make generated pipeline helpers accept the vertex layouts they currently
   omit.
3. **Typed part and runtime conversion.** Implement `MeshPart.attach` with
   inferred types, then upload it into `RuntimePart` handles. Specify ownership
   and replacement/release behavior before introducing asset caching.
4. **Composition/customization.** Add named weapon/character structs over
   runtime part handles, optional slots, and replacement of one part without
   rebuilding others.
5. **Queues and optimization.** Add opaque/transparent queues, pipeline
   variant keys, stable sorting, then batching/instancing where measurements
   justify it. Add backend feature checks for wireframe.

The smallest useful prototype is phases 1 and 2 for the existing triangle:
one explicit vertex layout, one uploaded geometry, a pipeline that declares
that layout, and a render-pass draw. It directly resolves the current missing
vertex-attribute validation while establishing the right boundary between
shader metadata, physical geometry, and `zgpu`.
