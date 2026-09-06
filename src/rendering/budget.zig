const std = @import("std");

pub const hard_max_depth = 128;

/// Work counts control steps, inspected bytes, and output bytes.
/// This budget bounds library work, not arbitrary custom writer callbacks.
pub const Limits = struct {
    max_depth: usize = 64,
    max_work: usize = 1_000_000,
};

pub const Failure = error{
    DepthLimitExceeded,
    WorkLimitExceeded,
    UnsupportedFeature,
    InvalidTemplate,
};

pub const Budget = struct {
    remaining: usize,
    max_depth: usize,
    depth: usize = 0,
    failure: ?Failure = null,

    pub fn init(limits: Limits) Failure!Budget {
        if (limits.max_depth > hard_max_depth) return error.DepthLimitExceeded;
        return .{ .remaining = limits.max_work, .max_depth = limits.max_depth };
    }

    pub fn fail(self: *Budget, reason: Failure) bool {
        if (self.failure == null) self.failure = reason;
        return false;
    }

    pub fn spend(self: *Budget, amount: usize) bool {
        if (self.failure != null) return false;
        if (amount > self.remaining) return self.fail(error.WorkLimitExceeded);
        self.remaining -= amount;
        return true;
    }

    pub fn enter(self: *Budget) bool {
        if (!self.spend(1)) return false;
        if (self.depth >= self.max_depth) return self.fail(error.DepthLimitExceeded);
        self.depth += 1;
        return true;
    }

    pub fn leave(self: *Budget) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
    }
};

pub fn spend(budget: ?*Budget, amount: usize) bool {
    return if (budget) |b| b.spend(amount) else true;
}

/// The adapter has no output buffer and forwards bytes to the caller's writer.
/// The caller retains both writers and the budget through the render call.
pub const Writer = struct {
    interface: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
    destination: *std.Io.Writer,
    budget: *Budget,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Writer = @fieldParentPtr("interface", w);
        std.debug.assert(w.end == 0 and data.len > 0);
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            if (!self.budget.spend(bytes.len)) return error.WriteFailed;
            try self.destination.writeAll(bytes);
            total += bytes.len; // The remaining budget bounds this sum.
        }
        const pattern = data[data.len - 1];
        if (pattern.len == 0) return total;
        for (0..splat) |_| {
            if (!self.budget.spend(pattern.len)) return error.WriteFailed;
            try self.destination.writeAll(pattern);
            total += pattern.len;
        }
        return total;
    }
};
