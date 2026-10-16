//! zigmem build: one exe (`zig build`), unit tests (`zig build test`). Later modules (core, store, extract, hub) join src/.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{ .name = "zigmem", .root_module = root });
    b.installArtifact(exe);
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = root }));
    b.step("test", "Unit tests").dependOn(&tests.step);

    // ---- phase 1: the store (vendored SQLite 3.54.0 amalgamation + translate-c). `zig build test-store`, `zig build storebench`.
    const sqlite_c = b.addTranslateC(.{ .root_source_file = b.path("vendor/sqlite/sqlite3.h"), .target = target, .optimize = optimize });
    // WAL_SYNCHRONOUS=1 (NORMAL): acked writes survive a process crash; power loss may drop the last commits, never
    // corrupts. Keep in step with the pragma in src/store/schema.zig.
    const sqlite_flags = &[_][]const u8{ "-DSQLITE_ENABLE_FTS5", "-DSQLITE_DQS=0", "-DSQLITE_THREADSAFE=1", "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DEFAULT_FOREIGN_KEYS=1" };
    const store_test_mod = b.createModule(.{ .root_source_file = b.path("src/store_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const bench_mod = b.createModule(.{ .root_source_file = b.path("src/store/bench.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_]*std.Build.Module{ store_test_mod, bench_mod }) |m| {
        m.addImport("c", sqlite_c.createModule());
        m.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = sqlite_flags });
    }
    const store_tests = b.addRunArtifact(b.addTest(.{ .root_module = store_test_mod }));
    b.step("test-store", "Phase-1 store tests").dependOn(&store_tests.step);
    const bench = b.addExecutable(.{ .name = "zigmem-storebench", .root_module = bench_mod });
    b.step("storebench", "Build the phase-1 store gate tool").dependOn(&b.addInstallArtifact(bench, .{}).step);

    // ---- phase 2: extraction (src/extract; store via its own module). `zig build test-extract`, `zig build extractgate`.
    const store_mod = b.createModule(.{ .root_source_file = b.path("src/store/store.zig"), .target = target, .optimize = optimize, .link_libc = true });
    store_mod.addImport("c", sqlite_c.createModule());
    store_mod.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = sqlite_flags });
    const ex_test_mod = b.createModule(.{ .root_source_file = b.path("src/extract/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const ex_gate_mod = b.createModule(.{ .root_source_file = b.path("src/extract/gate.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_]*std.Build.Module{ ex_test_mod, ex_gate_mod }) |m| m.addImport("store", store_mod);
    const ex_tests = b.addRunArtifact(b.addTest(.{ .root_module = ex_test_mod }));
    b.step("test-extract", "Phase-2 extraction tests (offline)").dependOn(&ex_tests.step);
    const ex_gate = b.addExecutable(.{ .name = "zigmem-extractgate", .root_module = ex_gate_mod });
    b.step("extractgate", "Build the phase-2 extraction gate tool").dependOn(&b.addInstallArtifact(ex_gate, .{}).step);

    // ---- phase 3: retrieval + privacy gates. `zig build test-phase3`, `zig build phase3` (zigmem-gate, zigmem-recall).
    const p3_store = b.createModule(.{ .root_source_file = b.path("src/store/store.zig"), .target = target, .optimize = optimize, .link_libc = true });
    p3_store.addImport("c", sqlite_c.createModule());
    p3_store.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = sqlite_flags });
    const p3_privacy = b.createModule(.{ .root_source_file = b.path("src/privacy/gates.zig"), .target = target, .optimize = optimize, .link_libc = true });
    p3_privacy.addImport("store", p3_store); // for store.private (one module may own a file)
    const p3_retrieve = b.createModule(.{ .root_source_file = b.path("src/retrieve/retrieve.zig"), .target = target, .optimize = optimize, .link_libc = true });
    p3_retrieve.addImport("store", p3_store);
    p3_retrieve.addImport("privacy", p3_privacy);
    const p3_step = b.step("phase3", "Build the phase-3 tools (zigmem-gate, zigmem-recall)");
    const p3_tests = b.step("test-phase3", "Phase-3 retrieval + gate tests (offline)");
    for ([_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "zigmem-gate", .root = "src/privacy/cli.zig" },
        .{ .name = "zigmem-recall", .root = "src/retrieve/cli.zig" },
    }) |e| {
        const m = b.createModule(.{ .root_source_file = b.path(e.root), .target = target, .optimize = optimize, .link_libc = true });
        m.addImport("privacy", p3_privacy);
        m.addImport("store", p3_store);
        m.addImport("retrieve", p3_retrieve);
        p3_step.dependOn(&b.addInstallArtifact(b.addExecutable(.{ .name = e.name, .root_module = m }), .{}).step);
    }
    p3_tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = p3_privacy })).step);
    p3_tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = p3_retrieve })).step);

    // ---- phase 4: hub API + MCP (src/api, src/mcp) inside the main `zigmem` binary (`zigmem serve|token|people`).
    // `zig build test-api`. Its own store/extract module instances (one per compilation, shared by api + extract).
    const p4_store = b.createModule(.{ .root_source_file = b.path("src/store/store.zig"), .target = target, .optimize = optimize, .link_libc = true });
    p4_store.addImport("c", sqlite_c.createModule());
    p4_store.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = sqlite_flags });
    const p4_extract = b.createModule(.{ .root_source_file = b.path("src/extract/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    p4_extract.addImport("store", p4_store);
    const p4_mcp = b.createModule(.{ .root_source_file = b.path("src/mcp/mcp.zig"), .target = target, .optimize = optimize });
    const p4_api = b.createModule(.{ .root_source_file = b.path("src/api/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    p4_api.addImport("store", p4_store);
    p4_api.addImport("extract", p4_extract);
    p4_api.addImport("mcp", p4_mcp);
    // integration: phase-3 retrieval + privacy gates and phase-5 household, all on the SAME p4_store instance
    const p4_privacy = b.createModule(.{ .root_source_file = b.path("src/privacy/gates.zig"), .target = target, .optimize = optimize, .link_libc = true });
    p4_privacy.addImport("store", p4_store);
    const p4_retrieve = b.createModule(.{ .root_source_file = b.path("src/retrieve/retrieve.zig"), .target = target, .optimize = optimize, .link_libc = true });
    p4_retrieve.addImport("store", p4_store);
    p4_retrieve.addImport("privacy", p4_privacy);
    const p4_hh = b.createModule(.{ .root_source_file = b.path("src/household/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    p4_hh.addImport("store", p4_store);
    p4_api.addImport("privacy", p4_privacy);
    p4_api.addImport("retrieve", p4_retrieve);
    p4_api.addImport("household", p4_hh);
    root.addImport("api", p4_api);
    const p4_tests = b.step("test-api", "Phase-4 hub API + MCP tests (offline)");
    p4_tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = p4_api })).step);
    p4_tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = p4_mcp })).step);

    // ---- phase 6: minimal web panel (src/panel, assets embedded) served by `zigmem serve` under /panel. `zig build test-panel`.
    const p6_panel = b.createModule(.{ .root_source_file = b.path("src/panel/panel.zig"), .target = target, .optimize = optimize, .link_libc = true });
    p6_panel.addImport("api", p4_api);
    p6_panel.addImport("store", p4_store);
    root.addImport("panel", p6_panel);
    b.step("test-panel", "Phase-6 panel tests (offline)").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = p6_panel })).step);

    // ---- phase 5: household memory (src/household). `zig build test-household`, `zig build household-gate`.
    const p5_store = b.createModule(.{ .root_source_file = b.path("src/store/store.zig"), .target = target, .optimize = optimize, .link_libc = true });
    p5_store.addImport("c", sqlite_c.createModule());
    p5_store.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = sqlite_flags });
    const p5_hh = b.createModule(.{ .root_source_file = b.path("src/household/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    p5_hh.addImport("store", p5_store);
    b.step("test-household", "Phase-5 household tests (offline, synthetic)").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = p5_hh })).step);
    const p5_gate = b.createModule(.{ .root_source_file = b.path("src/household/gate.zig"), .target = target, .optimize = optimize, .link_libc = true });
    p5_gate.addImport("store", p5_store);
    b.step("household-gate", "Build the phase-5 gate tool").dependOn(&b.addInstallArtifact(b.addExecutable(.{ .name = "zigmem-household-gate", .root_module = p5_gate }), .{}).step);

    // ---- integration: the synthetic household fixture exporter for the API-level phase-5 gate (test tool only,
    // never part of `zigmem`). `zig build hh-fixture` → zigmem-hh-fixture --db NEW_FILE.
    const hx = b.createModule(.{ .root_source_file = b.path("src/household/export.zig"), .target = target, .optimize = optimize, .link_libc = true });
    hx.addImport("store", p5_store);
    b.step("hh-fixture", "Build the integration fixture exporter").dependOn(&b.addInstallArtifact(b.addExecutable(.{ .name = "zigmem-hh-fixture", .root_module = hx }), .{}).step);
}
