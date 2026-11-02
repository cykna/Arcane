const zmath = @import("zmath");
const std = @import("std");
pub const Transform = struct {
    rotation: zmath.Quat,
    scale: zmath.Vec,
    position: zmath.Vec,

    const Self = @This();

    pub fn identity() Self {
        return Self{
            .rotation = zmath.qidentity(),
            .scale = zmath.f32x4s(1.0),
            .position = zmath.f32x4s(0.0),
        };
    }

    /// Estilo FPS: yaw em torno do Y do mundo, pitch no X local. Sem roll.
    /// Limite o pitch (por exemplo ±89°) no código que chama.
    pub fn setYawPitch(self: *Self, yaw: f32, pitch: f32) void {
        const qy = zmath.quatFromAxisAngle(zmath.f32x4(0, 1, 0, 0), yaw);
        const qp = zmath.quatFromAxisAngle(zmath.f32x4(1, 0, 0, 0), pitch);
        self.transform.rotation = zmath.qmul(qp, qy);
    }

    /// Câmera livre: aplica uma rotação incremental e renormaliza.
    pub fn rotateBy(self: *Self, delta: [4]f32) !void {
        const q = zmath.qmul(zmath.loadArr4(delta), zmath.loadArr4(self.rotation));
        var out: [4]f32 = undefined;
        zmath.storeArr4(&out, q);
        self.rotation = try self.camera.normalized(out);
    }

    pub fn toMat4x4(self: *const Self) zmath.Mat {
        const s = zmath.scalingV(self.scale);
        const r = zmath.matFromQuat(self.rotation);
        const t = zmath.translationV(self.position);

        return zmath.mul(zmath.mul(s, r), t);
    }
    const WgslTypes = @import("../../shaders/shared.zig");
    pub fn toWGslMat4x4(self: *const Transform) WgslTypes.WgslMat4x4f32 {
        const col = self.toMat4x4();
        var mat: WgslTypes.WgslMat4x4f32 = undefined;
        inline for (0..4) |column| {
            const rows: [4]std.meta.FieldEnum(WgslTypes.WgslVec4f32) = .{ .x, .y, .z, .w };
            inline for (0..4) |row| {
                @field(mat.columns[column].value, @tagName(rows[row])) = col[column][row];
            }
        }
        return mat;
    }
};
pub fn normalizedRotation(quat: zmath.Quat) ![4]f32 {
    const q = zmath.vecToArr4(quat);
    for (q) |component| {
        if (!std.math.isFinite(component)) return error.NonFiniteCameraVector;
    }
    const length_squared = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
    if (length_squared <= 1.0e-12) return error.InvalidCameraRotation;
    const inverse_length = 1.0 / @sqrt(length_squared);
    return .{ q[0] * inverse_length, q[1] * inverse_length, q[2] * inverse_length, q[3] * inverse_length };
}
