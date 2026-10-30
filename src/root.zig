//! Root module for the Arcane library package.
//!
//! The renderer sample and GPU helpers currently live in their own source
//! modules; this module exposes the small package-level utilities below.
const std = @import("std");
const Io = std.Io;

/// Writes a short hint for running the project tests.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

/// Adds two signed 32-bit integers.
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
