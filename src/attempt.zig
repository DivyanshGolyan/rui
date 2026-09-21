const std = @import("std");

pub const ActionAttemptBinding = struct {
    turn_id: u64,
    parent_operation_id: u64,
    action_id: u64,
    attempt_ordinal: u64,
};

pub const ActionDispatchPermit = struct {
    binding: ActionAttemptBinding,
    available: bool = true,

    pub fn consume(self: *ActionDispatchPermit) !ActionAttemptBinding {
        if (!self.available) return error.DispatchPermitConsumed;
        self.available = false;
        return self.binding;
    }
};

pub const AttemptBinding = struct {
    turn_id: u64,
    operation_id: u64,
    attempt_ordinal: u64,
};

pub const DispatchPermit = struct {
    binding: AttemptBinding,
    available: bool = true,

    pub fn consume(self: *DispatchPermit) !AttemptBinding {
        if (!self.available) return error.DispatchPermitConsumed;
        self.available = false;
        return self.binding;
    }
};
