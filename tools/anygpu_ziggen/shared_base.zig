pub const ShaderStage = enum { vertex, fragment, compute };
pub const BindingKind = enum { buffer, sampler, texture, storage_texture };
pub const BufferResourceType = enum { uniform, storage };
pub const StorageBufferAccess = enum { load, store, load_store, atomic };
pub const SamplerBindingType = enum { filtering, non_filtering, comparison };
pub const TextureSampleType = enum { float, depth, sint, uint };
pub const TextureViewDimension = enum { d1, d2, d2_array, cube, cube_array, d3 };
pub const StorageTextureAccess = enum { write_only, read_only, read_write };

pub const Binding = struct {
    group: ?u32,
    binding: u32,
    name: []const u8,
    kind: BindingKind,
    visibility: []const ShaderStage,
    count: ?u32,
    resource_type: ?BufferResourceType,
    read_only: ?StorageBufferAccess,
    sampler_type: ?SamplerBindingType,
    sample_type: ?TextureSampleType,
    filterable: ?bool,
    view_dimension: ?TextureViewDimension,
    multisampled: ?bool,
    storage_access: ?StorageTextureAccess,
    format: ?[]const u8,
    has_dynamic_offset: bool,
    min_binding_size: ?u64,
};

pub const WgslTypeLayout = struct {
    id: []const u8,
    name: []const u8,
    size: ?u32,
    alignment: ?u32,
    array_stride: ?u32,
    array_length: ?u32,
};

pub const PushConstantRange = struct {
    stages: []const ShaderStage,
    start: u32,
    end: u32,
};

pub const PipelineConstant = struct {
    name: []const u8,
    value: f64,
};

pub fn Vec2(comptime T: type) type {
    return extern struct { x: T, y: T };
}

pub fn Vec3(comptime T: type) type {
    return extern struct { x: T, y: T, z: T };
}

pub fn Vec4(comptime T: type) type {
    return extern struct { x: T, y: T, z: T, w: T };
}

pub const Vec2i8 = Vec2(i8);
pub const Vec3i8 = Vec3(i8);
pub const Vec4i8 = Vec4(i8);
pub const Vec2i16 = Vec2(i16);
pub const Vec3i16 = Vec3(i16);
pub const Vec4i16 = Vec4(i16);
pub const Vec2i32 = Vec2(i32);
pub const Vec3i32 = Vec3(i32);
pub const Vec4i32 = Vec4(i32);
pub const Vec2i64 = Vec2(i64);
pub const Vec3i64 = Vec3(i64);
pub const Vec4i64 = Vec4(i64);

pub const Vec2u8 = Vec2(u8);
pub const Vec3u8 = Vec3(u8);
pub const Vec4u8 = Vec4(u8);
pub const Vec2u16 = Vec2(u16);
pub const Vec3u16 = Vec3(u16);
pub const Vec4u16 = Vec4(u16);
pub const Vec2u32 = Vec2(u32);
pub const Vec3u32 = Vec3(u32);
pub const Vec4u32 = Vec4(u32);
pub const Vec2u64 = Vec2(u64);
pub const Vec3u64 = Vec3(u64);
pub const Vec4u64 = Vec4(u64);

pub const Vec2f16 = Vec2(f16);
pub const Vec3f16 = Vec3(f16);
pub const Vec4f16 = Vec4(f16);
pub const Vec2f32 = Vec2(f32);
pub const Vec3f32 = Vec3(f32);
pub const Vec4f32 = Vec4(f32);
pub const Vec2f64 = Vec2(f64);
pub const Vec3f64 = Vec3(f64);
pub const Vec4f64 = Vec4(f64);
