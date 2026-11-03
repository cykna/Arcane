const std = @import("std");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;

pub const ShaderStage = enum { vertex, fragment, compute };
pub const BindingKind = enum { buffer, sampler, texture, storage_texture };
pub const BufferResourceType = enum { uniform, storage };
pub const StorageBufferAccess = enum { load, store, load_store, atomic };
pub const SamplerBindingType = enum { filtering, non_filtering, comparison };
pub const TextureSampleType = enum { float, depth, sint, uint };
pub const TextureViewDimension = enum { d1, d2, d2_array, cube, cube_array, d3 };
pub const StorageTextureAccess = enum { write_only, read_only, read_write };
pub const ResourceAddressSpace = enum { uniform, storage, handle };
pub const ResourceAccess = enum { read, write, read_write, atomic, not_applicable };

pub const Binding = struct {
    group: ?u32,
    binding: u32,
    name: []const u8,
    slot_name: []const u8 = "",
    kind: BindingKind,
    address_space: ?ResourceAddressSpace,
    access: ?ResourceAccess,
    visibility: wgpu.ShaderStage,
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
    /// Minimum binding size in bytes reflected by anygpu. For a runtime-sized
    /// array this is the size of one element (the schema's array stride), not
    /// the size of the whole buffer. `null` means the whole binding.
    min_binding_size: ?u64,
    array_stride: ?u32 = null,
    array_length: ?u32 = null,
    runtime_sized_array: bool = false,
    ty: ?type = null,
};

pub fn toBindGroupLayoutEntry(
    binding: Binding,
    visibility_override: ?wgpu.ShaderStage,
) wgpu.BindGroupLayoutEntry {
    if (binding.count != null) {
        @panic("anygpu binding arrays are not supported by this wgpu API");
    }
    var entry = wgpu.BindGroupLayoutEntry{
        .binding = binding.binding,
        .visibility = visibility_override orelse binding.visibility,
    };
    switch (binding.kind) {
        .buffer => {
            const resource_type = binding.resource_type orelse
                @panic("anygpu buffer binding is missing its resource type");
            entry.buffer = .{
                .binding_type = switch (resource_type) {
                    .uniform => .uniform,
                    .storage => switch (binding.read_only orelse .load_store) {
                        .load => .read_only_storage,
                        .store, .load_store, .atomic => .storage,
                    },
                },
                .has_dynamic_offset = if (binding.has_dynamic_offset) .true else .false,
                .min_binding_size = binding.min_binding_size orelse 0,
            };
        },
        .sampler => {
            const sampler_type = binding.sampler_type orelse
                @panic("anygpu sampler binding is missing its sampler type");
            entry.sampler = .{ .binding_type = switch (sampler_type) {
                .filtering => .filtering,
                .non_filtering => .non_filtering,
                .comparison => .comparison,
            } };
        },
        .texture => {
            const sample_type = binding.sample_type orelse
                @panic("anygpu texture binding is missing its sample type");
            entry.texture = .{
                .sample_type = switch (sample_type) {
                    .float => if (binding.filterable orelse true) .float else .unfilterable_float,
                    .depth => .depth,
                    .sint => .sint,
                    .uint => .uint,
                },
                .view_dimension = wgpuTextureViewDimension(binding.view_dimension orelse
                    @panic("anygpu texture binding is missing its view dimension")),
                .multisampled = binding.multisampled orelse false,
            };
        },
        .storage_texture => {
            entry.storage_texture = .{
                .access = wgpuStorageTextureAccess(binding.storage_access orelse
                    @panic("anygpu storage texture binding is missing its access mode")),
                .format = textureFormat(binding.format orelse
                    @panic("anygpu storage texture binding is missing its format")),
                .view_dimension = wgpuTextureViewDimension(binding.view_dimension orelse
                    @panic("anygpu storage texture binding is missing its view dimension")),
            };
        },
    }
    return entry;
}

pub const bindGroupLayoutEntry = toBindGroupLayoutEntry;

pub fn stageMask(stages: []const ShaderStage) wgpu.ShaderStage {
    var mask = wgpu.ShaderStage{};
    for (stages) |stage| switch (stage) {
        .vertex => mask.vertex = true,
        .fragment => mask.fragment = true,
        .compute => mask.compute = true,
    };
    return mask;
}

fn shaderStageMask(stages: []const ShaderStage) wgpu.ShaderStage {
    var mask = wgpu.ShaderStage{};
    for (stages) |stage| switch (stage) {
        .vertex => mask.vertex = true,
        .fragment => mask.fragment = true,
        .compute => mask.compute = true,
    };
    return mask;
}

fn wgpuTextureViewDimension(dimension: TextureViewDimension) wgpu.TextureViewDimension {
    return switch (dimension) {
        .d1 => .tvdim_1d,
        .d2 => .tvdim_2d,
        .d2_array => .tvdim_2d_array,
        .cube => .tvdim_cube,
        .cube_array => .tvdim_cube_array,
        .d3 => .tvdim_3d,
    };
}

fn wgpuStorageTextureAccess(access: StorageTextureAccess) wgpu.StorageTextureAccess {
    return switch (access) {
        .write_only => .write_only,
        .read_only, .read_write => @panic("this wgpu build only supports write-only storage textures"),
    };
}

const TextureFormatAlias = struct {
    name: []const u8,
    format: wgpu.TextureFormat,
};

const texture_format_aliases = [_]TextureFormatAlias{
    .{ .name = "r8unorm", .format = .r8_unorm },
    .{ .name = "r8snorm", .format = .r8_snorm },
    .{ .name = "r8uint", .format = .r8_uint },
    .{ .name = "r8sint", .format = .r8_sint },
    .{ .name = "r16uint", .format = .r16_uint },
    .{ .name = "r16sint", .format = .r16_sint },
    .{ .name = "r16float", .format = .r16_float },
    .{ .name = "rg8unorm", .format = .rg8_unorm },
    .{ .name = "rg8snorm", .format = .rg8_snorm },
    .{ .name = "rg8uint", .format = .rg8_uint },
    .{ .name = "rg8sint", .format = .rg8_sint },
    .{ .name = "r32float", .format = .r32_float },
    .{ .name = "r32uint", .format = .r32_uint },
    .{ .name = "r32sint", .format = .r32_sint },
    .{ .name = "rg16uint", .format = .rg16_uint },
    .{ .name = "rg16sint", .format = .rg16_sint },
    .{ .name = "rg16float", .format = .rg16_float },
    .{ .name = "rgba8unorm", .format = .rgba8_unorm },
    .{ .name = "rgba8snorm", .format = .rgba8_snorm },
    .{ .name = "rgba8uint", .format = .rgba8_uint },
    .{ .name = "rgba8sint", .format = .rgba8_sint },
    .{ .name = "bgra8unorm", .format = .bgra8_unorm },
    .{ .name = "rgb10a2unorm", .format = .rgb10_a2_unorm },
    .{ .name = "rg11b10ufloat", .format = .rg11_b10_ufloat },
    .{ .name = "rg32float", .format = .rg32_float },
    .{ .name = "rg32uint", .format = .rg32_uint },
    .{ .name = "rg32sint", .format = .rg32_sint },
    .{ .name = "rgba16uint", .format = .rgba16_uint },
    .{ .name = "rgba16sint", .format = .rgba16_sint },
    .{ .name = "rgba16float", .format = .rgba16_float },
    .{ .name = "rgba32float", .format = .rgba32_float },
    .{ .name = "rgba32uint", .format = .rgba32_uint },
    .{ .name = "rgba32sint", .format = .rgba32_sint },
};

pub fn textureFormat(format: []const u8) wgpu.TextureFormat {
    var normalized: [64]u8 = undefined;
    if (format.len > normalized.len) @panic("texture format name is too long");
    var length: usize = 0;
    for (format) |byte| {
        if (byte == '_') continue;
        normalized[length] = std.ascii.toLower(byte);
        length += 1;
    }
    for (texture_format_aliases) |alias| {
        if (std.mem.eql(u8, normalized[0..length], alias.name)) return alias.format;
    }
    @panic("texture format is not supported by this wgpu build");
}

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
