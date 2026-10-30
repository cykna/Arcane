// Generated from anygpu JSON. Do not edit by hand.
const shared = @import("shared.zig");


pub const type_layouts = [_]shared.WgslTypeLayout{
};

pub const bindings = [_]shared.Binding{
};

const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
pub const Pipeline = struct {
    pub const present = true;
    pub const bind_group_count = 0;
    pub const bind_group_indices = [_]u32{};
    pub const vertex_entry_point: ?[]const u8 = null;
    pub const vertex_constants = [_]shared.PipelineConstant{
    };
    pub const vertex_zero_initialize_workgroup_memory = false;
    pub const fragment_entry_point: ?[]const u8 = null;
    pub const fragment_constants = [_]shared.PipelineConstant{
    };
    pub const fragment_zero_initialize_workgroup_memory = false;
    pub const compute_entry_point: ?[]const u8 = null;
    pub const compute_constants = [_]shared.PipelineConstant{
    };
    pub const compute_zero_initialize_workgroup_memory = false;
    pub const push_constant_ranges = [_]shared.PushConstantRange{
    };
};

comptime {
    _ = bindings;
    _ = Pipeline;
}
