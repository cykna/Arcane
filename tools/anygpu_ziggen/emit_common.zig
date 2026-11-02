const std = @import("std");
const schema = @import("schema.zig");
const Value = schema.Value;
const Writer = @import("std").Io.Writer;
const field = schema.field;
const string = schema.string;

pub fn writeZigString(w: *Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |byte| {
        switch (byte) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11...12, 14...31, 127 => try w.print("\\x{x:0>2}", .{byte}),
            else => try w.writeByte(byte),
        }
    }
    try w.writeByte('"');
}

pub fn writeOptionalString(w: *Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try writeZigString(w, text);
    } else {
        try w.writeAll("null");
    }
}

pub fn writeOptionalU32(w: *Writer, value: ?u32) !void {
    if (value) |number_value| {
        try w.print("{d}", .{number_value});
    } else {
        try w.writeAll("null");
    }
}

pub fn writeStageList(w: *Writer, value: *const Value) !void {
    if (value.* != .array) return error.InvalidSchema;
    try w.writeAll("&.{");
    for (value.array.items, 0..) |*stage, index| {
        if (index != 0) try w.writeAll(", ");
        try w.writeByte('.');
        const name = try string(stage);
        if (std.mem.eql(u8, name, "Vertex")) {
            try w.writeAll("vertex");
        } else if (std.mem.eql(u8, name, "Fragment")) {
            try w.writeAll("fragment");
        } else if (std.mem.eql(u8, name, "Compute")) {
            try w.writeAll("compute");
        } else {
            return error.UnsupportedStage;
        }
    }
    try w.writeByte('}');
}

pub fn writeStageMask(w: *Writer, value: *const Value) !void {
    if (value.* != .array) return error.InvalidSchema;
    var flags = [_]bool{ false, false, false };
    for (value.array.items) |*stage| {
        const name = try string(stage);
        if (std.mem.eql(u8, name, "Vertex")) {
            flags[0] = true;
        } else if (std.mem.eql(u8, name, "Fragment")) {
            flags[1] = true;
        } else if (std.mem.eql(u8, name, "Compute")) {
            flags[2] = true;
        } else {
            return error.UnsupportedStage;
        }
    }
    try w.writeAll(".{ .vertex = ");
    try w.print("{s}", .{if (flags[0]) "true" else "false"});
    try w.writeAll(", .fragment = ");
    try w.print("{s}", .{if (flags[1]) "true" else "false"});
    try w.writeAll(", .compute = ");
    try w.print("{s}", .{if (flags[2]) "true" else "false"});
    try w.writeByte('}');
}

pub fn writeSnakeEnum(w: *Writer, text: []const u8) !void {
    for (text, 0..) |byte, index| {
        if (std.ascii.isUpper(byte) and index != 0) try w.writeByte('_');
        try w.writeByte(std.ascii.toLower(byte));
    }
}

pub fn writeOptionalEnum(w: *Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try w.writeByte('.');
        try writeSnakeEnum(w, text);
    } else {
        try w.writeAll("null");
    }
}
