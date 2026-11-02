const std = @import("std");
const schema = @import("schema.zig");
const linked_model = @import("linked_model.zig");
const generator = @import("generate.zig");
const identifiers = @import("identifiers.zig");

const Value = schema.Value;
const Allocator = std.mem.Allocator;

pub const GeneratedFile = struct {
    path: []const u8,
    contents: []const u8,
};

pub fn generate(value: *const Value, allocator: Allocator) ![]GeneratedFile {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const work_allocator = arena.allocator();
    const model = linked_model.build(value, work_allocator) catch |err| {
        std.debug.print("anygpu-ziggen: invalid linked schema: {s}\n", .{@errorName(err)});
        return err;
    };
    const modules_value = try schema.field(value, "modules");
    const modules = modules_value.array.items;
    const files = try work_allocator.alloc(GeneratedFile, modules.len + 2);

    files[0] = .{
        .path = "shared.zig",
        .contents = generator.generateLinkedShared(&model, work_allocator) catch |err| {
            std.debug.print("anygpu-ziggen: failed to generate shared types: {s}\n", .{@errorName(err)});
            return err;
        },
    };
    files[1] = .{
        .path = "types.zig",
        .contents = generator.generateLinkedTypes(&model, work_allocator) catch |err| {
            std.debug.print("anygpu-ziggen: failed to generate canonical types: {s}\n", .{@errorName(err)});
            return err;
        },
    };

    const module_order = try work_allocator.alloc(usize, modules.len);
    for (module_order, 0..) |*entry, index| entry.* = index;
    std.mem.sort(usize, module_order, modules, lessModuleId);
    const used_paths = try work_allocator.alloc([]const u8, modules.len);
    for (module_order, 0..) |module_index, output_index| {
        const module = &modules[module_index];
        const module_id = try schema.string(try schema.field(module, "id"));
        var path = try moduleOutputName(work_allocator, module_id);
        var collision_index: usize = 0;
        while (std.mem.eql(u8, path, "shared.zig") or
            std.mem.eql(u8, path, "types.zig") or
            identifiers.stringExists(used_paths[0..output_index], path))
        {
            path = try std.fmt.allocPrint(
                work_allocator,
                "{s}_module_{d}.zig",
                .{ path[0 .. path.len - ".zig".len], collision_index },
            );
            collision_index += 1;
        }
        used_paths[output_index] = path;
        files[output_index + 2] = .{
            .path = path,
            .contents = generator.generateLinkedModule(module, &model, work_allocator) catch |err| {
                std.debug.print("anygpu-ziggen: failed to generate module `{s}`: {s}\n", .{ module_id, @errorName(err) });
                return err;
            },
        };
    }
    const result = try allocator.alloc(GeneratedFile, files.len);
    for (files, 0..) |file, index| {
        result[index] = .{
            .path = try allocator.dupe(u8, file.path),
            .contents = try allocator.dupe(u8, file.contents),
        };
    }
    return result;
}

fn lessModuleId(context: []const Value, lhs: usize, rhs: usize) bool {
    const left = schema.string(schema.field(&context[lhs], "id") catch unreachable) catch unreachable;
    const right = schema.string(schema.field(&context[rhs], "id") catch unreachable) catch unreachable;
    return std.mem.lessThan(u8, left, right);
}

fn moduleOutputName(allocator: Allocator, module_id: []const u8) ![]const u8 {
    const module_path = if (std.mem.startsWith(u8, module_id, "package::"))
        module_id["package::".len..]
    else
        module_id;
    var output: std.Io.Writer.Allocating = .init(allocator);
    const writer = &output.writer;
    var index: usize = 0;
    while (index < module_path.len) {
        if (index + 1 < module_path.len and module_path[index] == ':' and module_path[index + 1] == ':') {
            try writer.writeAll("__");
            index += 2;
        } else {
            try writer.writeByte(module_path[index]);
            index += 1;
        }
    }
    const raw = try output.toOwnedSlice();
    const safe = try identifiers.zigIdentifier(allocator, raw, 0);
    return try std.fmt.allocPrint(allocator, "{s}.zig", .{safe});
}

test "linked types are emitted once and modules keep their own bindings" {
    const source =
        \\{
        \\  "schema_version":2,
        \\  "types":[
        \\    {"id":"ct0","name":"Inner","identity":{"module_path":"package::globals","name":"Inner"},"descriptor":{"Struct":{"size":4,"alignment":4,"members":[{"name":"value","offset":0,"ty":{"Canonical":"ct2"}}]}}},
        \\    {"id":"ct1","name":"Outer","identity":{"module_path":"package::globals","name":"Outer"},"descriptor":{"Struct":{"size":4,"alignment":4,"members":[{"name":"inner","offset":0,"ty":{"Canonical":"ct0"}}]}}},
        \\    {"id":"ct2","name":"u32","descriptor":{"Scalar":{"scalar":{"name":"uint","width":4}}}},
        \\    {"id":"ct3","name":"Camera","identity":{"module_path":"package::renderer","name":"Camera"},"descriptor":{"Struct":{"size":4,"alignment":4,"members":[{"name":"value","offset":0,"ty":{"Canonical":"ct2"}}]}}},
        \\    {"id":"ct4","name":"Camera","identity":{"module_path":"package::editor","name":"Camera"},"descriptor":{"Struct":{"size":4,"alignment":4,"members":[{"name":"value","offset":0,"ty":{"Canonical":"ct2"}}]}}}
        \\  ],
        \\  "modules":[
        \\    {"id":"package::first","types":[
        \\      {"id":"t0","name":"array<Outer, 2>","descriptor":{"Array":{"base":{"Canonical":"ct1"},"size":2,"stride":4}}}
        \\    ],"local_to_canonical":{},"pipelines":{
        \\      "layout":{"bind_group_layouts":[
        \\        {"group":0,"entries":[{"binding":0,"name":"camera","visibility":["Vertex"],"ty":{"Buffer":{"buffer_type":"Uniform","has_dynamic_offset":false,"min_binding_size":4,"ty":"ct3"}},"address_space":"Uniform","access":"Read","resource_type":{"Canonical":"ct3"},"count":null}]},
        \\        {"group":1,"entries":[{"binding":0,"name":"items","visibility":["Vertex"],"ty":{"Buffer":{"buffer_type":{"Storage":{"read_only":"Load"}},"has_dynamic_offset":false,"min_binding_size":8,"ty":"t0"}},"address_space":"Storage","access":"Read","resource_type":{"Local":{"module_id":"package::first","type_id":"t0"}},"count":null}]}
        \\      ],"push_constant_ranges":[]},"vertex":null,"fragment":null,"compute":null
        \\    },"bindgroups":[]},
        \\    {"id":"package::second","types":[],"local_to_canonical":{},"pipelines":{
        \\      "layout":{"bind_group_layouts":[{"group":0,"entries":[{"binding":0,"name":"camera","visibility":["Fragment"],"ty":{"Buffer":{"buffer_type":"Uniform","has_dynamic_offset":false,"min_binding_size":4,"ty":"ct4"}},"address_space":"Uniform","access":"Read","resource_type":{"Canonical":"ct4"},"count":null}]}],"push_constant_ranges":[]},"vertex":null,"fragment":null,"compute":null
        \\    },"bindgroups":[]}
        \\  ]
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const first = try generate(&parsed.value, std.testing.allocator);
    defer freeFiles(std.testing.allocator, first);
    const second = try generate(&parsed.value, std.testing.allocator);
    defer freeFiles(std.testing.allocator, second);
    try std.testing.expectEqual(first.len, second.len);
    for (first, second) |left, right| {
        try std.testing.expectEqualStrings(left.path, right.path);
        try std.testing.expectEqualStrings(left.contents, right.contents);
    }

    const types_file = findGenerated(first, "types.zig").?;
    try std.testing.expectEqual(@as(usize, 1), occurrences(types_file.contents, "pub const Inner ="));
    try std.testing.expectEqual(@as(usize, 1), occurrences(types_file.contents, "pub const Outer ="));
    try std.testing.expect(std.mem.indexOf(u8, types_file.contents, "package__renderer__Camera") != null);
    try std.testing.expect(std.mem.indexOf(u8, types_file.contents, "package__editor__Camera") != null);

    const first_module = findGenerated(first, "first.zig").?;
    const second_module = findGenerated(first, "second.zig").?;
    try std.testing.expect(std.mem.indexOf(u8, first_module.contents, "const canonical = @import(\"types.zig\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_module.contents, "items: [2]canonical.Outer") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_module.contents, ".group = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_module.contents, ".group = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_module.contents, ".group = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_module.contents, ".group = 1") == null);
    try std.testing.expect(std.mem.indexOf(u8, first_module.contents, "pub const Type_") != null);
}

test "linked schemas reject unsupported versions and broken references" {
    const wrong_version =
        \\{"schema_version":99,"types":[],"modules":[]}
    ;
    const wrong = try std.json.parseFromSlice(Value, std.testing.allocator, wrong_version, .{});
    defer wrong.deinit();
    try std.testing.expectError(error.UnsupportedSchemaVersion, linked_model.build(&wrong.value, std.testing.allocator));

    const broken_reference =
        \\{"schema_version":2,"types":[
        \\{"id":"ct0","name":"Broken","identity":{"module_path":"package::globals","name":"Broken"},
        \\"descriptor":{"Struct":{"size":4,"alignment":4,"members":[{"name":"value","offset":0,"ty":{"Canonical":"missing"}}]}}}
        \\],"modules":[]}
    ;
    const broken = try std.json.parseFromSlice(Value, std.testing.allocator, broken_reference, .{});
    defer broken.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownType, linked_model.build(&broken.value, arena.allocator()));
}

fn findGenerated(files: []const GeneratedFile, path: []const u8) ?GeneratedFile {
    for (files) |file| if (std.mem.eql(u8, file.path, path)) return file;
    return null;
}

fn occurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |found| {
        count += 1;
        offset = found + needle.len;
    }
    return count;
}

fn freeFiles(allocator: Allocator, files: []GeneratedFile) void {
    for (files) |file| {
        allocator.free(file.path);
        allocator.free(file.contents);
    }
    allocator.free(files);
}
