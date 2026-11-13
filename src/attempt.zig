const std = @import("std");

/// An Action has one Attempt. The Store issues it this ordinal; 0 means the
/// Action is unattempted.
pub const action_attempt_ordinal: u64 = 1;

pub const ActionAttemptBinding = struct {
    turn_id: u64,
    parent_operation_id: u64,
    action_id: u64,
};

pub const ActionDispatchPermit = DispatchPermitOf(ActionAttemptBinding);

pub const AttemptBinding = struct {
    turn_id: u64,
    operation_id: u64,
    attempt_ordinal: u64,
};

pub const DispatchPermit = DispatchPermitOf(AttemptBinding);

/// A one-shot permit: `consume` yields `binding` once, then refuses.
fn DispatchPermitOf(comptime Binding: type) type {
    return struct {
        binding: Binding,
        available: bool = true,

        pub fn consume(self: *@This()) error{DispatchPermitConsumed}!Binding {
            if (!self.available) return error.DispatchPermitConsumed;
            self.available = false;
            return self.binding;
        }
    };
}
