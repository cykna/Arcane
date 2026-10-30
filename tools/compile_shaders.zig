// tools/compile_shaders.zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Aqui você recebe o I/O do ambiente de forma explícita!
    var cwd_dir = std.Io.Dir.cwd();

    // Cria a pasta de saída de forma segura
    cwd_dir.createDirPath(init.io, "shaders/wgsl") catch {};
    try cwd_dir.createDirPath(init.io, "src/shaders/wgsl");

    const wesl_dir_path = "shaders/wesl";
    var dir = try cwd_dir.openDir(init.io, wesl_dir_path, .{ .iterate = true });
    defer dir.close(init.io);

    var iterator = dir.iterate();
    while (try iterator.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".wesl")) continue;

        const name = entry.name[0 .. entry.name.len - ".wesl".len];
        const input_path = try std.fs.path.join(allocator, &.{ "shaders/wesl", entry.name });
        const output_path = try std.fmt.allocPrint(allocator, "shaders/wgsl/{s}.wgsl", .{name});
        const embedded_output_path = try std.fmt.allocPrint(allocator, "src/shaders/wgsl/{s}.wgsl", .{name});

        // run = spawn + lê stdout/stderr + wait
        const result = try std.process.run(allocator, init.io, .{
            .argv = &.{ "wesl", "compile", input_path },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.log.err("wesl falhou em {s}:\n{s}", .{ input_path, result.stderr });
                return error.WeslCompileFailed;
            },
            else => return error.WeslCompileFailed,
        }

        const out_file = try cwd_dir.createFile(init.io, output_path, .{});
        defer out_file.close(init.io);
        try out_file.writePositionalAll(init.io, result.stdout, 0);

        const embedded_out_file = try cwd_dir.createFile(init.io, embedded_output_path, .{});
        defer embedded_out_file.close(init.io);
        try embedded_out_file.writePositionalAll(init.io, result.stdout, 0);

        std.log.info("compiled {s} -> {s}", .{ input_path, output_path });
    }
}
