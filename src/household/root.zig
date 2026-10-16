//! zigmem household memory (phase 5): members + roles, seat → member binding, scopes (household, person, seat),
//! the medical person-scope rule on a subject column, explicit promotion, audited cross-scope reads.
pub const policy = @import("policy.zig");
pub const resolve = @import("resolve.zig");
pub const medical = @import("medical.zig");
pub const schema = @import("schema.zig");
pub const house = @import("house.zig");
pub const House = house.House;

test {
    _ = @import("tests.zig");
    _ = medical;
}
