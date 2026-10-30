const std = @import("std");

/// Compile-time adapter used to verify that each generated container has append.
fn requireMethod(
    comptime C: type,
    comptime name: []const u8,
    comptime param_count: usize, // contando o self
) void {
    if (!@hasDecl(C, name))
        @compileError(@typeName(C) ++ " doesn't have '" ++ name ++ "'");

    const info = @typeInfo(@TypeOf(@field(C, name)));
    if (info != .@"fn")
        @compileError(@typeName(C) ++ "." ++ name ++ " is not a function ");
    if (info.@"fn".param_types.len != param_count)
        @compileError(std.fmt.comptimePrint("{}.{} expected to have {d} arguments, instead its got {}", .{ @typeName(C), name, param_count, info.@"fn".param_types.len }));
}

/// Creates a struct containing one container for each compile-time type.
///
/// `types` is expected to be a tuple of types, and `container` maps each type to
/// its corresponding storage type. `push(T, value)` selects the matching
/// container at comptime; it does not perform runtime type erasure or lookup.
/// Each resulting container is expected to provide `append`. The current
/// signature check counts three declared parameters (including `self`), while
/// `push` calls `append(data)`; reconcile those shapes before using a custom
/// container, since the helper is not yet a general-purpose adapter.
pub fn HeterogeneousContainer(comptime types: anytype, comptime container: anytype) type {
    const field_names, const field_types, const field_attrs = comptime blk: {
        const info = if (@typeInfo(types) == .@"struct") @typeInfo(types).@"struct" else @compileError("Expected the type of a heterogeneous container to be a struct or a tuple");
        const len = info.field_types.len;

        const names = if (!info.is_tuple)
            info.field_names
        else names: {
            var names: [len][]const u8 = undefined;
            for (types, 0..) |_, i| {
                names[i] = std.fmt.comptimePrint("storage_{d}", .{i});
            }
            break :names names;
        };

        const field_types = tys: {
            var result: [len]type = undefined;

            for (info.field_types, 0..) |T, i| {
                const C = container(T);
                result[i] = C;
                requireMethod(C, "append", 3);
            }

            break :tys result;
        };
        const field_attrs: [len]std.lang.Type.Struct.FieldAttributes = @splat(.{});
        break :blk .{ names, field_types, field_attrs };
    };

    const Storage = @Struct(
        .auto,
        null,
        field_names,
        &field_types,
        &field_attrs,
    );
    return struct {
        const Self = @This();
        storage: Storage,

        /// Initializes all generated storage fields with their zero values.
        pub fn init() Self {
            return Self{ .storage = {} };
        }

        /// Appends `data` to the storage associated with compile-time type `T`.
        ///
        /// A type not present in the original `types` tuple is a compile error.
        pub fn push(self: *Self, comptime T: type, data: T) void {
            inline for (types, 0..) |u, i| {
                if (u == T) {
                    @field(self.storage, std.fmt.comptimePrint("storage_{d}", .{i})).append(data);
                    return;
                }
            }
            const type_names = comptime blk: {
                var result: []const u8 = "";

                for (types, 0..) |t, i| {
                    result = result ++
                        (if (i == 0) "" else ", ") ++
                        @typeName(t);
                }

                break :blk result;
            };

            @compileError(std.fmt.comptimePrint("Type '{}' is not supported on heterogeneous container that only supports {}", .{ @typeName(T), type_names }));
        }
    };
}
