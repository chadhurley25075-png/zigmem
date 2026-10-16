//! zigmem hub (phase 4, integrated): HTTP API + MCP over the phase-1 store, phase-2 extraction worker, phase-3
//! retrieval + privacy gates and phase-5 household identity/scopes (access.zig, retrieval.zig).
//! Module root for the main binary (`zigmem serve|token|people`) and `zig build test-api`.
pub const json = @import("json.zig");
pub const screen = @import("screen.zig");
pub const auth = @import("auth.zig");
pub const http = @import("http.zig");
pub const retriever = @import("retriever.zig");
pub const block = @import("block.zig");
pub const worker = @import("worker.zig");
pub const fold = @import("fold.zig");
pub const hub = @import("hub.zig");
pub const render = @import("render.zig");
pub const rest = @import("rest.zig");
pub const cli = @import("cli.zig");
pub const access = @import("access.zig");
pub const retrieval = @import("retrieval.zig");
pub const household = @import("household");

test {
    _ = json;
    _ = screen;
    _ = auth;
    _ = http;
    _ = retriever;
    _ = block;
    _ = worker;
    _ = fold;
    _ = hub;
    _ = render;
    _ = rest;
    _ = cli;
    _ = access;
    _ = retrieval;
}
