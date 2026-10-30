const std = @import("std");
const schema = @import("schema.zig");
const generator = @import("generate.zig");
const Value = schema.Value;
const Allocator = std.mem.Allocator;
const generate = generator.generate;
const generateShared = generator.generateShared;

fn replaceExtension(allocator: Allocator, path: []const u8) ![]const u8 {
    const extension = std.fs.path.extension(path);
    const stem = path[0 .. path.len - extension.len];
    return try std.fmt.allocPrint(allocator, "{s}.zig", .{stem});
}

fn readSchema(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
}

fn reportPathError(action: []const u8, path: []const u8, err: anyerror) void {
    std.debug.print("anygpu-ziggen: {s} `{s}`: {s}\n", .{ action, path, @errorName(err) });
}

fn checkShaderOutput(path: []const u8) !void {
    if (std.mem.eql(u8, std.fs.path.basename(path), "shared.zig")) return error.OutputConflictsWithShared;
}

fn generateOne(allocator: Allocator, io: std.Io, input: []const u8, output_path: []const u8) !void {
    try checkShaderOutput(output_path);
    const source = readSchema(allocator, io, input) catch |err| {
        reportPathError("failed to read", input, err);
        return err;
    };
    defer allocator.free(source);
    const parsed = std.json.parseFromSlice(Value, allocator, source, .{}) catch |err| {
        reportPathError("failed to parse JSON", input, err);
        return err;
    };
    defer parsed.deinit();
    const generated = generate(&parsed.value, allocator) catch |err| {
        reportPathError("failed to generate bindings from", input, err);
        return err;
    };
    defer allocator.free(generated);
    const schemas = [_]*const Value{&parsed.value};
    const shared_generated = generateShared(&schemas, allocator) catch |err| {
        reportPathError("failed to generate shared bindings from", input, err);
        return err;
    };
    defer allocator.free(shared_generated);
    if (std.fs.path.dirname(output_path)) |parent| {
        if (parent.len != 0 and !std.mem.eql(u8, parent, ".")) {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }
    }
    const shared_path = try outputPathForShared(allocator, output_path);
    defer allocator.free(shared_path);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = shared_path, .data = shared_generated }) catch |err| {
        reportPathError("failed to write shared bindings", shared_path, err);
        return err;
    };
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = generated }) catch |err| {
        reportPathError("failed to write", output_path, err);
        return err;
    };
}

fn outputPathForShared(allocator: Allocator, output_path: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(output_path) orelse "";
    if (parent.len == 0 or std.mem.eql(u8, parent, ".")) return try allocator.dupe(u8, "shared.zig");
    return try std.fmt.allocPrint(allocator, "{s}{c}shared.zig", .{ parent, std.fs.path.sep });
}

fn openDir(path: []const u8, io: std.Io, iterate: bool) !std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) return std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = iterate });
    return std.Io.Dir.cwd().openDir(io, path, .{ .iterate = iterate });
}

fn lessThanName(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn generateDirectory(allocator: Allocator, io: std.Io, input: []const u8, output_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const work_allocator = arena.allocator();
    try std.Io.Dir.cwd().createDirPath(io, output_path);
    const input_dir = openDir(input, io, true) catch |err| {
        reportPathError("failed to open directory", input, err);
        return err;
    };
    defer input_dir.close(io);
    const output_dir = openDir(output_path, io, false) catch |err| {
        reportPathError("failed to open output directory", output_path, err);
        return err;
    };
    defer output_dir.close(io);
    var count: usize = 0;
    var counter = input_dir.iterate();
    while (try counter.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) count += 1;
    }
    if (count == 0) return error.NoJsonInputs;
    const input_names = try work_allocator.alloc([]const u8, count);
    var name_iterator = input_dir.iterate();
    var name_count: usize = 0;
    while (try name_iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        input_names[name_count] = try work_allocator.dupe(u8, entry.name);
        name_count += 1;
    }
    if (name_count != count) return error.InputDirectoryChanged;
    std.mem.sort([]const u8, input_names, {}, lessThanName);
    const schemas = try work_allocator.alloc(*const Value, count);
    var schema_count: usize = 0;
    for (input_names) |name| {
        const source = input_dir.readFileAlloc(io, name, work_allocator, .unlimited) catch |err| {
            reportPathError("failed to read", name, err);
            return err;
        };
        const parsed = std.json.parseFromSliceLeaky(Value, work_allocator, source, .{}) catch |err| {
            reportPathError("failed to parse JSON", name, err);
            return err;
        };
        const schema_value = try work_allocator.create(Value);
        schema_value.* = parsed;
        schemas[schema_count] = schema_value;
        schema_count += 1;
        const generated = generate(&parsed, allocator) catch |err| {
            reportPathError("failed to generate bindings from", name, err);
            return err;
        };
        defer allocator.free(generated);
        const stem = name[0 .. name.len - ".json".len];
        const destination = try std.fmt.allocPrint(allocator, "{s}.zig", .{stem});
        defer allocator.free(destination);
        try checkShaderOutput(destination);
        output_dir.writeFile(io, .{ .sub_path = destination, .data = generated }) catch |err| {
            reportPathError("failed to write", destination, err);
            return err;
        };
    }
    const shared_generated = generateShared(schemas, allocator) catch |err| {
        reportPathError("failed to generate combined shared bindings", input, err);
        return err;
    };
    defer allocator.free(shared_generated);
    output_dir.writeFile(io, .{ .sub_path = "shared.zig", .data = shared_generated }) catch |err| {
        reportPathError("failed to write shared bindings", output_path, err);
        return err;
    };
}

fn run(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const input = args.next() orelse return error.Usage;
    var output: ?[]const u8 = null;
    while (args.next()) |argument| {
        if (std.mem.eql(u8, argument, "-o") or std.mem.eql(u8, argument, "--output")) {
            if (output != null) return error.Usage;
            output = args.next() orelse return error.Usage;
        } else {
            return error.Usage;
        }
    }
    const stat = std.Io.Dir.cwd().statFile(init.io, input, .{}) catch |err| {
        reportPathError("failed to inspect", input, err);
        return err;
    };
    if (stat.kind == .directory) {
        try generateDirectory(init.gpa, init.io, input, output orelse input);
        return;
    }
    if (stat.kind != .file or !std.mem.endsWith(u8, input, ".json")) return error.ExpectedJsonFile;
    const destination = output orelse try replaceExtension(init.gpa, input);
    try generateOne(init.gpa, init.io, input, destination);
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (err == error.Usage) {
            std.debug.print("Usage: zig run tools/anygpu_ziggen/anygpu_ziggen.zig -- <schema.json|directory> [-o <output.zig|directory>]\n", .{});
        } else {
            std.debug.print("anygpu-ziggen: {s}\n", .{@errorName(err)});
        }
        std.process.exit(1);
    };
}
