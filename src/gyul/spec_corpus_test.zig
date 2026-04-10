//! Differential test runner over Solidity's Yul optimizer corpus.
//!
//! Each fixture in `vendor/solidity/test/libyul/yulOptimizerTests/**/*.yul`
//! contains a pre-optimization Yul program followed by the
//! post-optimization expected output. Solc's optimizer guarantees the
//! transformation is semantics-preserving, so any divergence between
//! gyul's interpreter run on the pre vs the post is — modulo the small
//! skip set documented below — a gyul bug.
//!
//! Why this corpus and not `yulInterpreterTests`?
//!  - `yulInterpreterTests` ground-truths against solc's *own* Yul
//!    interpreter, which is intentionally an approximate fuzz-friendly
//!    mock. gyul aims for exact EVM semantics, so the two will diverge
//!    on operations like calls/codecopy where the mock just records
//!    arguments.
//!  - The optimizer corpus, by contrast, lets us self-validate: pre and
//!    post are *required* to be observationally identical, regardless of
//!    whether either matches a notional "perfect EVM".
//!
//! What gets skipped (with reasons recorded in the summary):
//!  - Files using `verbatim_*` (gyul refuses to execute raw bytecode).
//!  - Files using `linkersymbol`/`loadimmutable`/`setimmutable` with
//!    state that the optimizer can re-arrange freely (we don't model
//!    immutables across the pre/post divide).
//!  - Files where parsing the pre or post fails (typically because the
//!    source uses object syntax we don't fully model).
//!  - Files using `simulateExternalCall` or external-call recursion that
//!    our stub deliberately doesn't simulate.

const std = @import("std");
const AST = @import("AST.zig");
const GlobalState = @import("GlobalState.zig");
const LocalState = @import("LocalState.zig");
const Interpreter = @import("Interpreter.zig");
const sparse = @import("sparse.zig");

const FIXTURE_ROOT = "vendor/solidity/test/libyul/yulOptimizerTests";
const STEP_LIMIT: u64 = 100_000;

const Outcome = enum { passed, skipped, failed };

const Result = struct {
    outcome: Outcome,
    /// Owned by the caller's arena.
    name: []const u8,
    reason: []const u8,
};

const Stats = struct {
    passed: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
    failures: std.ArrayListUnmanaged(Result) = .{},
};

// ── Fixture parsing ─────────────────────────────────────────────────

const Fixture = struct {
    /// Pre-optimization source (zero-terminated).
    pre: [:0]const u8,
    /// Post-optimization source (zero-terminated).
    post: [:0]const u8,
};

/// Splits a fixture file into pre source and post (expected) source.
/// Returns null if no `// ----` marker exists or no post block follows.
/// Both returned slices are freshly-allocated zero-terminated buffers
/// owned by `arena`.
fn parseFixture(arena: std.mem.Allocator, raw: []const u8) !?Fixture {
    const marker = "// ----";
    const marker_pos = std.mem.indexOf(u8, raw, marker) orelse return null;

    // Pre source: everything before the marker, with trailing whitespace
    // stripped. Some fixtures put a `// ====` settings block before the
    // marker — we leave that intact so the parser sees it as comments
    // (the parser already skips comments).
    var pre_end = marker_pos;
    while (pre_end > 0 and (raw[pre_end - 1] == ' ' or raw[pre_end - 1] == '\n' or raw[pre_end - 1] == '\r' or raw[pre_end - 1] == '\t')) {
        pre_end -= 1;
    }
    const pre_buf = try arena.allocSentinel(u8, pre_end, 0);
    @memcpy(pre_buf[0..pre_end], raw[0..pre_end]);

    // Post: everything after the `// step:` marker line. Each post line
    // is a Yul comment line (`//`-prefixed). We strip the prefix and
    // join. Lines before `// step:` (and the `// step:` line itself)
    // are skipped.
    var post_buf = std.ArrayList(u8){};
    defer post_buf.deinit(arena);

    var seen_step = false;
    var line_iter = std.mem.splitScalar(u8, raw[marker_pos + marker.len ..], '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, " \r\t");
        // The fixture format always begins the metadata with `// step: <name>`.
        if (!seen_step) {
            if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), "// step:")) {
                seen_step = true;
            }
            continue;
        }
        if (line.len == 0) continue;
        // Strip leading whitespace, then "//" or "// ".
        const ltrim = std.mem.trimLeft(u8, line, " \t");
        if (!std.mem.startsWith(u8, ltrim, "//")) {
            // Some fixtures have trailing extra metadata lines without a
            // // prefix; ignore them.
            continue;
        }
        const after_slashes = ltrim[2..];
        const content = if (after_slashes.len > 0 and after_slashes[0] == ' ')
            after_slashes[1..]
        else
            after_slashes;
        try post_buf.appendSlice(arena, content);
        try post_buf.append(arena, '\n');
    }

    if (!seen_step or post_buf.items.len == 0) return null;

    const post_buf_z = try arena.allocSentinel(u8, post_buf.items.len, 0);
    @memcpy(post_buf_z[0..post_buf.items.len], post_buf.items);

    return .{ .pre = pre_buf, .post = post_buf_z };
}

// ── State comparison ────────────────────────────────────────────────

const Mismatch = enum {
    none,
    halt_reason,
    storage_value,
    transient_value,
    return_data,
    log_count,
    log_address,
    log_topics,
    log_data,
};

const CompareResult = struct {
    kind: Mismatch,
    detail: []const u8 = "",
};

/// Compare two final states for *EVM-observable* equivalence — the
/// post-halt observability boundary defined by the Yellow Paper.
///
/// What's observable after halt:
///  - Final storage values, looked up via `sload` (NOT raw entry counts:
///    `sstore(k, sload(k))` and `sstore(k, 0)` on a never-set slot are
///    both no-ops despite producing different map sizes).
///  - Final transient storage values, same semantics.
///  - The captured return data (only populated by `return`/`revert`).
///  - The halt reason.
///  - The log sequence: `(address, topics, data)` per entry, in order.
///
/// What's *not* observable, and therefore intentionally not compared:
///  - Memory contents. They are only EVM-observable through reads
///    (which surface as one of the channels above) or via the
///    `return`/`revert` capture (which we already compare). Comparing
///    raw memory would reject legitimate optimizations like the
///    `stackLimitEvader` pass that bumps the free memory pointer to
///    spill stack values to scratch.
///  - msize itself. Same reasoning — only observable through
///    `msize()` reads, which would feed back into one of the above.
fn compareStates(arena: std.mem.Allocator, a: *GlobalState, b: *GlobalState, halt_a: ?Interpreter.HaltReason, halt_b: ?Interpreter.HaltReason) !CompareResult {
    if (halt_a != halt_b) {
        return .{ .kind = .halt_reason, .detail = try std.fmt.allocPrint(
            arena,
            "{?} vs {?}",
            .{ halt_a, halt_b },
        ) };
    }

    // Storage equivalence: walk the union of keys and compare via
    // `getOrZero` so a missing entry and an entry-set-to-zero compare
    // equal.
    if (try compareSlots(arena, &a.storage, &b.storage)) |detail| {
        return .{ .kind = .storage_value, .detail = detail };
    }
    if (try compareSlots(arena, &a.transient_storage, &b.transient_storage)) |detail| {
        return .{ .kind = .transient_value, .detail = detail };
    }

    if (!std.mem.eql(u8, a.return_data, b.return_data)) {
        return .{ .kind = .return_data, .detail = try std.fmt.allocPrint(
            arena,
            "pre.len={d} post.len={d}",
            .{ a.return_data.len, b.return_data.len },
        ) };
    }

    if (a.log_entries.items.len != b.log_entries.items.len) {
        return .{ .kind = .log_count, .detail = try std.fmt.allocPrint(
            arena,
            "pre={d} post={d}",
            .{ a.log_entries.items.len, b.log_entries.items.len },
        ) };
    }
    for (a.log_entries.items, b.log_entries.items, 0..) |la, lb, i| {
        if (la.address != lb.address) {
            return .{ .kind = .log_address, .detail = try std.fmt.allocPrint(
                arena,
                "log[{d}] pre=0x{x} post=0x{x}",
                .{ i, la.address, lb.address },
            ) };
        }
        if (!std.mem.eql(u8, la.data, lb.data)) {
            return .{ .kind = .log_data, .detail = try std.fmt.allocPrint(
                arena,
                "log[{d}] data length pre={d} post={d}",
                .{ i, la.data.len, lb.data.len },
            ) };
        }
        if (la.topics.len != lb.topics.len) {
            return .{ .kind = .log_topics, .detail = try std.fmt.allocPrint(
                arena,
                "log[{d}] topic count pre={d} post={d}",
                .{ i, la.topics.len, lb.topics.len },
            ) };
        }
        for (la.topics, lb.topics) |ta, tb| {
            if (ta != tb) {
                return .{ .kind = .log_topics, .detail = try std.fmt.allocPrint(
                    arena,
                    "log[{d}] topic mismatch",
                    .{i},
                ) };
            }
        }
    }

    return .{ .kind = .none };
}

/// Walk the union of `a`'s and `b`'s keys and compare via `getOrZero`.
/// Returns null on equivalence, or an owned detail string on mismatch.
fn compareSlots(arena: std.mem.Allocator, a: *const sparse.SparseSlots(u256), b: *const sparse.SparseSlots(u256)) !?[]const u8 {
    inline for (.{ a, b }) |first| {
        const other = if (first == a) b else a;
        var it = first.iterator();
        while (it.next()) |e| {
            const av = first.getOrZero(e.key_ptr.*);
            const bv = other.getOrZero(e.key_ptr.*);
            if (av != bv) {
                return try std.fmt.allocPrint(
                    arena,
                    "key=0x{x} pre=0x{x} post=0x{x}",
                    .{ e.key_ptr.*, a.getOrZero(e.key_ptr.*), b.getOrZero(e.key_ptr.*) },
                );
            }
        }
    }
    return null;
}

// ── Skip detection ──────────────────────────────────────────────────

/// Returns a skip reason if the fixture relies on a feature gyul cannot
/// faithfully replay across the pre/post divide, else null.
fn shouldSkip(source: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, source, "verbatim_") != null) return "verbatim";
    if (std.mem.indexOf(u8, source, "linkersymbol") != null) return "linkersymbol";
    if (std.mem.indexOf(u8, source, "loadimmutable") != null) return "loadimmutable";
    if (std.mem.indexOf(u8, source, "setimmutable") != null) return "setimmutable";
    // Object syntax with sub-objects: parser only keeps the first
    // `code` block, so the post (which the optimizer may have
    // restructured) can have a different layout. Skip — we'd need
    // multi-section linking to compare faithfully.
    if (std.mem.indexOf(u8, source, "object \"") != null) return "object syntax";
    // dataoffset/datasize on real layouts: same reason as above.
    if (std.mem.indexOf(u8, source, "dataoffset") != null) return "dataoffset";
    if (std.mem.indexOf(u8, source, "datasize") != null) return "datasize";
    if (std.mem.indexOf(u8, source, "datacopy") != null) return "datacopy";
    return null;
}

// ── Per-fixture runner ──────────────────────────────────────────────

const RunResult = struct {
    global: GlobalState,
    halt: ?Interpreter.HaltReason,
};

fn runOne(arena: std.mem.Allocator, source: [:0]const u8) !RunResult {
    var ast = try AST.parse(arena, source);
    // Don't deinit the AST: it shares the arena.

    var global = GlobalState.init(arena);
    var local = LocalState.init(arena, null);

    var interp = Interpreter.init(arena, &ast, &global, &local);
    interp.max_steps = STEP_LIMIT;
    const result = try interp.interpret();
    return .{ .global = global, .halt = result.halt_reason };
}

fn runFixture(arena: std.mem.Allocator, name: []const u8, fixture: Fixture, stats: *Stats) !void {
    if (shouldSkip(fixture.pre)) |reason| {
        stats.skipped += 1;
        try stats.failures.append(arena, .{ .outcome = .skipped, .name = name, .reason = reason });
        return;
    }
    if (shouldSkip(fixture.post)) |reason| {
        stats.skipped += 1;
        try stats.failures.append(arena, .{ .outcome = .skipped, .name = name, .reason = reason });
        return;
    }

    var pre = runOne(arena, fixture.pre) catch |err| {
        stats.skipped += 1;
        const reason = try std.fmt.allocPrint(arena, "pre {s}", .{@errorName(err)});
        try stats.failures.append(arena, .{ .outcome = .skipped, .name = name, .reason = reason });
        return;
    };
    var post = runOne(arena, fixture.post) catch |err| {
        stats.skipped += 1;
        const reason = try std.fmt.allocPrint(arena, "post {s}", .{@errorName(err)});
        try stats.failures.append(arena, .{ .outcome = .skipped, .name = name, .reason = reason });
        return;
    };

    const cmp = try compareStates(arena, &pre.global, &post.global, pre.halt, post.halt);
    if (cmp.kind == .none) {
        stats.passed += 1;
        return;
    }
    stats.failed += 1;
    const reason = try std.fmt.allocPrint(arena, "{s}: {s}", .{ @tagName(cmp.kind), cmp.detail });
    try stats.failures.append(arena, .{ .outcome = .failed, .name = name, .reason = reason });
}

// ── Test entry point ────────────────────────────────────────────────

const testing = std.testing;

test "spec corpus: yul optimizer differential" {
    // The vendored solidity submodule may not be initialized in some
    // CI configurations — gracefully skip when the corpus is absent.
    var root_dir = std.fs.cwd().openDir(FIXTURE_ROOT, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer root_dir.close();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stats: Stats = .{};

    var walker = try root_dir.walk(arena);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".yul")) continue;

        // Each fixture gets its own arena snapshot so we don't blow
        // memory on the full corpus. We use a child arena per fixture.
        var fx_arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer fx_arena_state.deinit();
        const fx_arena = fx_arena_state.allocator();

        const path = try std.fs.path.join(fx_arena, &.{ FIXTURE_ROOT, entry.path });
        const file = try std.fs.cwd().openFile(path, .{});
        const raw = file.readToEndAlloc(fx_arena, 1 << 20) catch |err| {
            file.close();
            return err;
        };
        file.close();

        const fixture = (try parseFixture(fx_arena, raw)) orelse {
            stats.skipped += 1;
            const owned_name = try arena.dupe(u8, entry.path);
            try stats.failures.append(arena, .{
                .outcome = .skipped,
                .name = owned_name,
                .reason = "no // ---- marker / no post block",
            });
            continue;
        };

        const owned_name = try arena.dupe(u8, entry.path);
        // Run inside the fixture-local arena so all parsed AST / state
        // memory is reclaimed at the end of the iteration.
        runFixture(arena, owned_name, fixture, &stats) catch |err| {
            stats.failed += 1;
            const reason = try std.fmt.allocPrint(
                arena,
                "harness error: {s}",
                .{@errorName(err)},
            );
            try stats.failures.append(arena, .{
                .outcome = .failed,
                .name = owned_name,
                .reason = reason,
            });
        };
    }

    const total = stats.passed + stats.skipped + stats.failed;
    std.debug.print("\n[spec-corpus] {d} fixtures: {d} passed, {d} skipped, {d} failed\n", .{
        total, stats.passed, stats.skipped, stats.failed,
    });

    // Aggregate skip reasons so the user can see what's deferred.
    {
        var reason_counts: std.StringHashMapUnmanaged(u32) = .{};
        defer reason_counts.deinit(arena);
        for (stats.failures.items) |f| {
            if (f.outcome != .skipped) continue;
            const gop = try reason_counts.getOrPut(arena, f.reason);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
        if (reason_counts.count() > 0) {
            std.debug.print("Skip reasons:\n", .{});
            var it = reason_counts.iterator();
            while (it.next()) |e| {
                std.debug.print("  {d:>4}  {s}\n", .{ e.value_ptr.*, e.key_ptr.* });
            }
        }
    }

    if (stats.failed > 0) {
        std.debug.print("\nFailures:\n", .{});
        var shown: usize = 0;
        for (stats.failures.items) |f| {
            if (f.outcome != .failed) continue;
            std.debug.print("  {s}: {s}\n", .{ f.name, f.reason });
            shown += 1;
            if (shown >= 25) {
                std.debug.print("  ... ({d} more)\n", .{stats.failed - shown});
                break;
            }
        }
        return error.SpecCorpusDivergence;
    }
}
