const std = @import("std");
const zgpu = @import("zgpu");
const BufferBinding = @import("../core/GpuBuffer.zig").BufferBinding;

pub fn MaterialOptions(comptime T: type) type {
    const maxgroups = g: {
        var out = 0;
        for (T.bindings) |bind| {
            if (bind.group) |g| out = g;
        }
        break :g out + 1;
    };
    var group_count: [maxgroups]u32 = @splat(0);
    for (T.bindings) |bind| {
        if (bind.group) |g| group_count[g] += 1;
    }

    var group_names: [maxgroups][]const u8 = undefined;
    var group_types: [maxgroups]type = undefined;
    var group_attrs: [maxgroups]std.lang.Type.Struct.FieldAttributes = @splat(.{});

    {
        for (group_count, 0..) |count, idx| {
            if (count == 0) continue;
            group_names[idx] = std.fmt.comptimePrint("group{}", .{idx});

            group_types[idx] = group_type: {
                var member_names: [count][]const u8 = undefined;
                var member_types: [count]type = undefined;
                var member_attrs: [count]std.lang.Type.Struct.FieldAttributes = @splat(.{});
                var member_idx = 0;
                for (T.bindings) |bind| {
                    const valid = if (bind.group) |g| g == idx else false;
                    if (valid) {
                        if (bind.ty) |ty| {
                            member_names[member_idx] = bind.name;
                            member_types[member_idx] = BufferBinding(ty);
                            member_idx += 1;
                        } else {
                            @compileError("Not able to generate material because binding doesn't specify the type");
                        }
                    }
                }

                break :group_type @Struct(.auto, null, &member_names, &member_types, &member_attrs);
            };
        }
    }
    return @Struct(.auto, null, &group_names, &group_types, &group_attrs);
}

pub fn Material(comptime T: type) type {
    const Options = MaterialOptions(T);
    return struct {
        binds: Options,

        const Self = @This();
        pub fn bind(self: *const Self, ctx: *zgpu.GraphicsContext, pass: zgpu.wgpu.RenderPassEncoder) !void {
            inline for (@typeInfo(@TypeOf(self.binds)).@"struct".field_names) |group| {
                const group_value = @field(self.binds, group);
                inline for (@typeInfo(@TypeOf(group_value)).@"struct".field_names) |binding_name| {
                    const b = &@field(group_value, binding_name);
                    try b.bind(ctx, pass);
                }
            }
        }
    };
}
