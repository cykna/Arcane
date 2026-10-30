const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const TypeInfo = @import("schema.zig").TypeInfo;

pub fn zigIdentifier(allocator: Allocator, raw: []const u8, suffix: usize) ![]const u8 {
    var output: Writer.Allocating = .init(allocator);
    const w = &output.writer;
    if (raw.len == 0 or !std.ascii.isAlphabetic(raw[0]) and raw[0] != '_') try w.writeByte('_');
    for (raw) |byte| {
        try w.writeByte(if (std.ascii.isAlphanumeric(byte) or byte == '_') byte else '_');
    }
    const name = try output.toOwnedSlice();
    if (isKeyword(name) or isGeneratedName(name)) {
        return try std.fmt.allocPrint(allocator, "{s}_type_{d}", .{ name, suffix });
    }
    return name;
}

fn isKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "align",          "allowzero",    "and",         "anyframe", "anytype",   "asm",         "async",       "await",
        "break",          "callconv",     "catch",       "comptime", "const",     "continue",    "defer",       "else",
        "enum",           "errdefer",     "error",       "export",   "extern",    "false",       "fn",          "for",
        "if",             "inline",       "noalias",     "noinline", "nosuspend", "null",        "opaque",      "or",
        "orelse",         "packed",       "pub",         "resume",   "return",    "linksection", "struct",      "suspend",
        "switch",         "test",         "threadlocal", "true",     "try",       "union",       "unreachable", "usingnamespace",
        "var",            "volatile",     "while",       "type",     "bool",      "void",        "noreturn",    "anyopaque",
        "comptime_float", "comptime_int", "f16",         "f32",      "f64",       "i8",          "i16",         "i32",
        "i64",            "i128",         "isize",       "u8",       "u16",       "u32",         "u64",         "u128",
        "usize",
    };
    for (keywords) |keyword| if (std.mem.eql(u8, name, keyword)) return true;
    return false;
}

fn isGeneratedName(name: []const u8) bool {
    const reserved = [_][]const u8{
        "Binding",           "BindingKind",          "BufferResourceType",   "StorageBufferAccess", "SamplerBindingType",
        "TextureSampleType", "TextureViewDimension", "StorageTextureAccess", "ShaderStage",         "WgslTypeLayout",
        "PushConstantRange", "Pipeline",             "bindings",             "bindgroups",          "type_layouts",
        "pipeline",          "shared",
    };
    for (reserved) |entry| if (std.mem.eql(u8, name, entry)) return true;
    return std.mem.startsWith(u8, name, "Type_");
}

pub fn nameExists(types: []const TypeInfo, until: usize, candidate: []const u8) bool {
    for (types[0..until]) |ty| if (std.mem.eql(u8, ty.alias, candidate)) return true;
    return false;
}

pub fn stringExists(names: []const []const u8, candidate: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}
