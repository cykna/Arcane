const std = @import("std");
const schema = @import("schema.zig");
const identifiers = @import("identifiers.zig");

const Value = schema.Value;
const Allocator = std.mem.Allocator;
const Model = schema.Model;
const TypeInfo = schema.TypeInfo;
const field = schema.field;
const object = schema.object;
const string = schema.string;
const tagged = schema.tagged;
const zigIdentifier = identifiers.zigIdentifier;

pub const linked_schema_version = 2;

pub fn build(value: *const Value, allocator: Allocator) !Model {
    const version = try schema.number(try field(value, "schema_version"));
    if (version != linked_schema_version) return error.UnsupportedSchemaVersion;
    const canonical_value = try field(value, "types");
    const modules_value = try field(value, "modules");
    if (canonical_value.* != .array or modules_value.* != .array) return error.InvalidLinkedSchema;

    const modules = modules_value.array.items;
    for (modules, 0..) |*module, index| {
        const id = try string(try field(module, "id"));
        if (id.len == 0) return error.InvalidModuleId;
        for (modules[0..index]) |*previous| {
            if (std.mem.eql(u8, id, try string(try field(previous, "id")))) {
                std.debug.print("anygpu-ziggen: duplicate linked module id `{s}`\n", .{id});
                return error.DuplicateModuleId;
            }
        }
    }

    var canonical_count: usize = canonical_value.array.items.len;
    var local_count: usize = 0;
    for (canonical_value.array.items, 0..) |*type_info, type_index| {
        const id = try string(try field(type_info, "id"));
        for (canonical_value.array.items[0..type_index]) |*previous| {
            if (std.mem.eql(u8, id, try string(try field(previous, "id")))) {
                std.debug.print("anygpu-ziggen: duplicate canonical type id `{s}`\n", .{id});
                return error.DuplicateCanonicalTypeId;
            }
        }
    }
    for (modules) |*module| {
        _ = try field(module, "local_to_canonical");
        _ = try field(module, "pipelines");
        const bindgroups = try field(module, "bindgroups");
        if (bindgroups.* != .array) return error.InvalidLinkedSchema;
        const types_value = try field(module, "types");
        if (types_value.* != .array) return error.InvalidLinkedSchema;
        local_count = try std.math.add(usize, local_count, types_value.array.items.len);
    }
    const infos = try allocator.alloc(TypeInfo, canonical_count + local_count);
    var model = Model{
        .allocator = allocator,
        .types = infos,
        .shared_count = 0,
        .emit_mode = .linked_canonical,
    };

    var index: usize = 0;
    for (canonical_value.array.items) |*type_value| {
        const id = try string(try field(type_value, "id"));
        const name = try string(try field(type_value, "name"));
        const descriptor = try field(type_value, "descriptor");
        const type_kind = try tagged(descriptor);
        const is_shared = isIntrinsic(type_kind.name);
        const identity = (try object(type_value)).getPtr("identity");
        if (std.mem.eql(u8, type_kind.name, "Struct") and identity == null) {
            return error.CanonicalStructMissingIdentity;
        }
        const alias = if (identity) |identity_value|
            try canonicalAlias(allocator, identity_value, id, canonical_value)
        else
            try zigIdentifier(allocator, name, index);
        model.types[index] = .{
            .id = try std.fmt.allocPrint(allocator, "canonical:{s}", .{id}),
            .source_id = id,
            .name = name,
            .descriptor = descriptor,
            .alias = alias,
            .is_shared = is_shared,
            .is_canonical = true,
            .identity_module_path = if (identity) |value_identity|
                try string(try field(value_identity, "module_path"))
            else
                null,
            .identity_name = if (identity) |value_identity|
                try string(try field(value_identity, "name"))
            else
                null,
        };
        index += 1;
    }
    canonical_count = index;
    for (modules) |*module| {
        const module_id = try string(try field(module, "id"));
        const type_values = try field(module, "types");
        for (type_values.array.items, 0..) |*type_value, local_index| {
            const id = try string(try field(type_value, "id"));
            const name = try string(try field(type_value, "name"));
            const descriptor = try field(type_value, "descriptor");
            if ((try object(type_value)).get("identity") != null) {
                std.debug.print("anygpu-ziggen: module `{s}` type `{s}` unexpectedly has a shared identity\n", .{ module_id, id });
                return error.LocalTypeHasIdentity;
            }
            for (model.types[canonical_count..index]) |previous| {
                if (std.mem.eql(u8, previous.source_id, id) and
                    std.mem.eql(u8, previous.owner_module orelse "", module_id))
                {
                    std.debug.print("anygpu-ziggen: duplicate local type id `{s}` in module `{s}`\n", .{ id, module_id });
                    return error.DuplicateTypeId;
                }
            }
            const alias = try zigIdentifier(allocator, name, local_index);
            model.types[index] = .{
                .id = try std.fmt.allocPrint(allocator, "local:{s}:{s}", .{ module_id, id }),
                .source_id = id,
                .name = name,
                .descriptor = descriptor,
                .alias = alias,
                .is_shared = false,
                .owner_module = module_id,
            };
            index += 1;
        }
    }
    try validateCanonicalIdentities(value);

    for (model.types, 0..) |type_info, type_index| {
        const module_id = type_info.owner_module;
        validateDescriptorReferences(&model, type_index, module_id) catch |err| {
            std.debug.print("anygpu-ziggen: unresolved reference in type `{s}` (id `{s}`, module `{s}`): {s}\n", .{
                type_info.name,
                type_info.source_id,
                module_id orelse type_info.identity_module_path orelse "<canonical>",
                @errorName(err),
            });
            return err;
        };
    }
    for (modules) |*module| {
        validateModuleReferences(&model, module) catch |err| {
            std.debug.print("anygpu-ziggen: invalid references in module `{s}`: {s}\n", .{
                try string(try field(module, "id")),
                @errorName(err),
            });
            return err;
        };
    }
    for (model.types, 0..) |type_info, type_index| {
        if (type_info.is_canonical and type_info.is_shared) model.shared_count += 1 else break;
        _ = type_index;
    }
    return model;
}

fn isIntrinsic(name: []const u8) bool {
    return std.mem.eql(u8, name, "Scalar") or
        std.mem.eql(u8, name, "Vector") or
        std.mem.eql(u8, name, "Matrix") or
        std.mem.eql(u8, name, "Atomic");
}

fn canonicalAlias(
    allocator: Allocator,
    identity: *const Value,
    id: []const u8,
    all_types: *const Value,
) ![]const u8 {
    const identity_name = try string(try field(identity, "name"));
    const module_path = try string(try field(identity, "module_path"));
    var same_name = false;
    for (all_types.array.items) |*other| {
        const other_identity = (try object(other)).getPtr("identity") orelse continue;
        if (other_identity == identity) continue;
        if (std.mem.eql(u8, identity_name, try string(try field(other_identity, "name")))) {
            same_name = true;
            break;
        }
    }
    const raw = if (same_name) try qualifiedPath(allocator, module_path) else identity_name;
    const qualified = if (same_name)
        try std.fmt.allocPrint(allocator, "{s}__{s}", .{ raw, identity_name })
    else
        raw;
    const base = try zigIdentifier(allocator, qualified, 0);
    var collisions: usize = 0;
    for (all_types.array.items) |*other| {
        const other_identity = (try object(other)).getPtr("identity") orelse continue;
        if (other_identity == identity) continue;
        const other_name = try string(try field(other_identity, "name"));
        const other_path = try string(try field(other_identity, "module_path"));
        const other_raw = if (same_name) try qualifiedPath(allocator, other_path) else other_name;
        const other_qualified = if (same_name)
            try std.fmt.allocPrint(allocator, "{s}__{s}", .{ other_raw, other_name })
        else
            other_raw;
        const other_alias = try zigIdentifier(allocator, other_qualified, 0);
        if (std.mem.eql(u8, base, other_alias)) collisions += 1;
    }
    if (collisions == 0) return base;
    return try std.fmt.allocPrint(allocator, "{s}__{s}", .{ base, id });
}

fn qualifiedPath(allocator: Allocator, path: []const u8) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    const writer = &output.writer;
    var index: usize = 0;
    while (index < path.len) {
        if (index + 1 < path.len and path[index] == ':' and path[index + 1] == ':') {
            try writer.writeAll("__");
            index += 2;
        } else {
            try writer.writeByte(path[index]);
            index += 1;
        }
    }
    return try output.toOwnedSlice();
}

fn validateCanonicalIdentities(value: *const Value) !void {
    const types = try field(value, "types");
    for (types.array.items, 0..) |*type_info, index| {
        const identity = (try object(type_info)).getPtr("identity") orelse continue;
        const module_path = try string(try field(identity, "module_path"));
        const name = try string(try field(identity, "name"));
        for (types.array.items[0..index]) |*previous| {
            const previous_identity = (try object(previous)).getPtr("identity") orelse continue;
            if (std.mem.eql(u8, module_path, try string(try field(previous_identity, "module_path"))) and
                std.mem.eql(u8, name, try string(try field(previous_identity, "name"))))
            {
                std.debug.print("anygpu-ziggen: duplicate canonical type identity `{s}::{s}`\n", .{ module_path, name });
                return error.DuplicateTypeIdentity;
            }
        }
    }
}

pub fn findReference(model: *const Model, value: *const Value, current_module: ?[]const u8) !usize {
    if (value.* == .string) return findId(model, value.string, current_module);
    const reference = try tagged(value);
    if (std.mem.eql(u8, reference.name, "Canonical")) {
        return findCanonical(model, try string(reference.payload));
    }
    if (std.mem.eql(u8, reference.name, "Local")) {
        const module_id = try string(try field(reference.payload, "module_id"));
        const type_id = try string(try field(reference.payload, "type_id"));
        if (current_module) |expected_module|
            if (!std.mem.eql(u8, module_id, expected_module)) return error.CrossModuleLocalReference;
        return findLocal(model, module_id, type_id);
    }
    return error.InvalidTypeReference;
}

pub fn findId(model: *const Model, id: []const u8, current_module: ?[]const u8) !usize {
    var found: ?usize = null;
    for (model.types, 0..) |type_info, index| {
        const matches = if (type_info.is_canonical)
            std.mem.eql(u8, type_info.source_id, id)
        else
            current_module != null and
                std.mem.eql(u8, type_info.owner_module orelse "", current_module.?) and
                std.mem.eql(u8, type_info.source_id, id);
        if (!matches) continue;
        if (found != null) return error.AmbiguousTypeReference;
        found = index;
    }
    return found orelse error.UnknownType;
}

fn findCanonical(model: *const Model, id: []const u8) !usize {
    for (model.types, 0..) |type_info, index| {
        if (type_info.is_canonical and std.mem.eql(u8, type_info.source_id, id)) return index;
    }
    return error.UnknownType;
}

fn findLocal(model: *const Model, module_id: []const u8, id: []const u8) !usize {
    for (model.types, 0..) |type_info, index| {
        if (!type_info.is_canonical and
            std.mem.eql(u8, type_info.owner_module orelse "", module_id) and
            std.mem.eql(u8, type_info.source_id, id))
        {
            return index;
        }
    }
    return error.UnknownType;
}

fn validateDescriptorReferences(model: *const Model, index: usize, module_id: ?[]const u8) !void {
    const descriptor = try tagged(model.types[index].descriptor);
    if (std.mem.eql(u8, descriptor.name, "Array") or
        std.mem.eql(u8, descriptor.name, "BindingArray") or
        std.mem.eql(u8, descriptor.name, "Pointer"))
    {
        _ = try findReference(model, try field(descriptor.payload, "base"), module_id);
    } else if (std.mem.eql(u8, descriptor.name, "Struct")) {
        const members = try field(descriptor.payload, "members");
        if (members.* != .array) return error.InvalidLinkedSchema;
        for (members.array.items) |*member| {
            _ = try findReference(model, try field(member, "ty"), module_id);
        }
    }
}

fn validateModuleReferences(model: *const Model, module: *const Value) !void {
    const module_id = try string(try field(module, "id"));
    if ((try object(module)).getPtr("local_to_canonical")) |mapping| {
        const entries = try object(mapping);
        var iterator = entries.iterator();
        while (iterator.next()) |entry| {
            _ = try findCanonical(model, try string(entry.value_ptr));
        }
    }
    if ((try object(module)).getPtr("pipelines")) |pipelines| {
        if (pipelines.* != .null) try validatePipelineReferences(model, pipelines, module_id);
    }
    if ((try object(module)).getPtr("bindgroups")) |bindgroups| {
        if (bindgroups.* != .array) return error.InvalidLinkedSchema;
        for (bindgroups.array.items) |*entry| {
            _ = try findReference(model, try field(entry, "resource_type"), module_id);
        }
    }
}

fn validatePipelineReferences(model: *const Model, pipelines: *const Value, module_id: []const u8) !void {
    const layout_value = try field(pipelines, "layout");
    const groups = try field(layout_value, "bind_group_layouts");
    if (groups.* != .array) return error.InvalidLinkedSchema;
    for (groups.array.items) |*group| {
        const entries = try field(group, "entries");
        if (entries.* != .array) return error.InvalidLinkedSchema;
        for (entries.array.items) |*entry| {
            _ = findReference(model, try field(entry, "resource_type"), module_id) catch |err| {
                std.debug.print("anygpu-ziggen: unresolved resource type in module `{s}` binding `{s}`: {s}\n", .{
                    module_id,
                    try string(try field(entry, "name")),
                    @errorName(err),
                });
                return err;
            };
            const binding_type = try tagged(try field(entry, "ty"));
            if (std.mem.eql(u8, binding_type.name, "Buffer")) {
                _ = findId(model, try string(try field(binding_type.payload, "ty")), module_id) catch |err| {
                    std.debug.print("anygpu-ziggen: unresolved buffer type in module `{s}` binding `{s}`: {s}\n", .{
                        module_id,
                        try string(try field(entry, "name")),
                        @errorName(err),
                    });
                    return err;
                };
            }
        }
    }
    if ((try object(pipelines)).getPtr("vertex")) |stage| {
        if (stage.* != .null) {
            try validateTypeList(model, try field(stage, "inputs"), module_id);
            try validateTypeList(model, try field(stage, "outputs"), module_id);
            const buffers = try field(stage, "buffers");
            if (buffers.* != .array) return error.InvalidLinkedSchema;
            for (buffers.array.items) |*buffer| {
                const attributes = try field(buffer, "attributes");
                if (attributes.* != .array) return error.InvalidLinkedSchema;
                try validateTypeList(model, attributes, module_id);
            }
        }
    }
    inline for (.{ "fragment", "compute" }) |stage_name| {
        if ((try object(pipelines)).getPtr(stage_name)) |stage| {
            if (stage.* != .null and std.mem.eql(u8, stage_name, "fragment")) {
                try validateTypeList(model, try field(stage, "inputs"), module_id);
                try validateTypeList(model, try field(stage, "outputs"), module_id);
            }
        }
    }
}

fn validateTypeList(model: *const Model, values: *const Value, module_id: []const u8) !void {
    if (values.* != .array) return error.InvalidLinkedSchema;
    for (values.array.items) |*entry| {
        _ = try findId(model, try string(try field(entry, "ty")), module_id);
    }
}
