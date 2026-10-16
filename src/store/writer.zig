//! The one writer thread: owns the write connection, drains a bounded queue, group-commits each batch in one
//! transaction (one savepoint per op, so a failing op rolls back alone). Callers block until their op is
//! committed to the WAL. Promise (synchronous=NORMAL): an acked op survives a process crash (kill -9); a power loss may drop
//! the last commits, never corrupts. Not fsync-per-commit: FULL measured 229-248/s vs the 2K/s bar (receipts/fixbatch).
const std = @import("std");
const root = @import("store.zig");
const Store = root.Store;
const Io = std.Io;

pub const Op = struct {
    run: *const fn (op: *Op, st: *Store) anyerror!void,
    err: ?anyerror = null,
    done: Io.Event = .unset,
};

pub const capacity = 1024;
pub const batch_max = 256;

pub const Writer = struct {
    st: *Store,
    io: Io,
    mu: Io.Mutex = .init,
    not_empty: Io.Condition = .init,
    not_full: Io.Condition = .init,
    q: [capacity]*Op = undefined,
    head: usize = 0,
    len: usize = 0,
    stopping: bool = false,
    thread: ?std.Thread = null,
    commits: u64 = 0,

    pub fn init(st: *Store) Writer {
        return .{ .st = st, .io = st.io };
    }

    pub fn start(self: *Writer) !void {
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    /// Drain what is queued, then join the thread.
    pub fn stop(self: *Writer) void {
        self.mu.lockUncancelable(self.io);
        self.stopping = true;
        self.not_empty.signal(self.io);
        self.mu.unlock(self.io);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    /// Queue `op` (blocks while the queue is full) and wait until its batch committed or failed.
    pub fn submit(self: *Writer, op: *Op) !void {
        self.mu.lockUncancelable(self.io);
        while (self.len == capacity and !self.stopping) self.not_full.waitUncancelable(self.io, &self.mu);
        if (self.stopping) {
            self.mu.unlock(self.io);
            return error.WriterStopped;
        }
        self.q[(self.head + self.len) % capacity] = op;
        self.len += 1;
        self.not_empty.signal(self.io);
        self.mu.unlock(self.io);
        op.done.waitUncancelable(self.io);
        if (op.err) |e| return e;
    }

    /// Run `func(store, args...)` on the writer thread; returns its result once committed.
    pub fn call(self: *Writer, comptime func: anytype, args: anytype) anyerror!root.ReturnPayload(func) {
        const Box = struct {
            op: Op,
            args: @TypeOf(args),
            out: root.ReturnPayload(func) = undefined,
            fn run(op: *Op, st: *Store) anyerror!void {
                const b: *@This() = @fieldParentPtr("op", op);
                b.out = try @call(.auto, func, .{st} ++ b.args);
            }
        };
        var box: Box = .{ .op = .{ .run = Box.run }, .args = args };
        try self.submit(&box.op);
        return box.out;
    }

    fn loop(self: *Writer) void {
        var batch: [batch_max]*Op = undefined;
        while (true) {
            self.mu.lockUncancelable(self.io);
            while (self.len == 0 and !self.stopping) self.not_empty.waitUncancelable(self.io, &self.mu);
            if (self.len == 0) {
                self.mu.unlock(self.io);
                return;
            }
            const n = @min(self.len, batch_max);
            for (0..n) |i| batch[i] = self.q[(self.head + i) % capacity];
            self.head = (self.head + n) % capacity;
            self.len -= n;
            self.not_full.broadcast(self.io);
            self.mu.unlock(self.io);
            self.commitBatch(batch[0..n]);
            for (batch[0..n]) |op| op.done.set(self.io);
        }
    }

    fn commitBatch(self: *Writer, ops: []*Op) void {
        const db = self.st.db;
        db.exec("BEGIN IMMEDIATE") catch |e| {
            for (ops) |op| op.err = e;
            return;
        };
        for (ops) |op| {
            db.exec("SAVEPOINT op") catch |e| {
                op.err = e;
                continue;
            };
            op.run(op, self.st) catch |e| {
                op.err = e;
                db.exec("ROLLBACK TO op") catch {};
            };
            db.exec("RELEASE op") catch {};
        }
        db.exec("COMMIT") catch |e| {
            db.exec("ROLLBACK") catch {};
            for (ops) |op| op.err = op.err orelse e;
            return;
        };
        self.commits += 1;
    }
};
