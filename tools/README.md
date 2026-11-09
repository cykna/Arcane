# anygpu JSON to Zig

`anygpu_ziggen/anygpu_ziggen.zig` is the entry point for the Zig generator.
Its implementation is split into focused modules under `tools/anygpu_ziggen/`.
It reads the JSON schema emitted by `anygpu` and writes Zig source ahead of
compilation. It targets Zig 0.17.0 and only depends on the standard library.

```sh
zig run tools/anygpu_ziggen/anygpu_ziggen.zig -- path/to/shader.json
zig run tools/anygpu_ziggen/anygpu_ziggen.zig -- path/to/json-directory -o path/to/zig-directory
zig test tools/anygpu_ziggen/generate.zig
zig build anygpu-ziggen -- path/to/shader.json -o path/to/shader.zig
```

A single input defaults to the same path with a `.zig` extension. Directory
mode processes direct-child `.json` files in place, or into the directory
provided with `-o`. Both modes write the static `shared.zig` module beside the
generated shader files; each shader imports it for common binding metadata,
pipeline declarations, and WGSL vector types. Consumers should keep that file
alongside the generated shader modules. `zig build test` also runs the
generator's focused tests.

Linked modules also expose `Source`, an `@embedFile` of the module's compiled
WGSL file (for example, `triangle.Source`). Generated render pipelines expose
`Pipeline.create(gctx, wgsl_source)`, which creates a
`zgpu.RenderPipelineHandle` using the WGSL entry points, the swapchain format,
and an explicit pipeline layout derived from the module's anygpu bind-group
metadata. Pass the module's `Source` as the sentinel-terminated WGSL string.
`Pipeline.createWithOptions` allows overriding the color target format and
primitive state; a caller-provided `layout` is used when present. Bind the
returned handle inside a render pass with `try Pipeline.bind(gctx, pass,
handle)`, then issue the draw call; release it with `Pipeline.destroy(gctx,
handle)`. `Pipeline.createPipelineLayout(gctx)` creates the explicit
bind-group layouts and pipeline layout from the same metadata. Bind-group
resource creation remains the caller's responsibility.
Generated buffer struct fields use explicit offsets,
padding, and WGSL member alignment, and include compile-time size/alignment
checks where Zig can represent both exactly. Vectors are component structs;
matrix columns and padded array elements use explicit stride wrappers.
`type_layouts` preserves the schema's WGSL size, alignment, array stride, and
array length, including alignment metadata that cannot be represented on a
standalone Zig vector type.

The generator emits the binding and pipeline-layout metadata present in the
schema and does not infer missing relationships. Opaque handles and
runtime-sized arrays are not exposed as fabricated host-side values;
runtime-array tails remain zero-length typed fields with the schema's fixed
struct prefix and stride. WGSL `bool` is represented as `u32` in memory, not
Zig's one-byte `bool`.
