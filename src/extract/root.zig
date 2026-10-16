//! zigmem extraction (phase 2): conversation turn → candidate memories. Module root for `zig build test-extract`.
pub const allow = @import("allow.zig");
pub const llm = @import("llm.zig");
pub const parse = @import("parse.zig");
pub const prompts = @import("prompts.zig");
pub const chunk = @import("chunk.zig");
pub const people = @import("people.zig");
pub const sink = @import("sink.zig");
pub const pipeline = @import("pipeline.zig");
pub const store_sink = @import("store_sink.zig");
pub const review = @import("review.zig");

test {
    _ = allow;
    _ = llm;
    _ = parse;
    _ = prompts;
    _ = chunk;
    _ = people;
    _ = sink;
    _ = pipeline;
    _ = store_sink;
    _ = review;
    _ = @import("pipeline_test.zig");
}
