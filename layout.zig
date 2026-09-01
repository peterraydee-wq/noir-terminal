//! noirterm/layout.zig
//!
//! A tmux/zellij-style binary split tree: each leaf holds a pane index,
//! each internal node splits its rect between two children either
//! side-by-side (horizontal) or stacked (vertical). Deliberately kept
//! free of any window/pty/rendering dependency — panes are referred to
//! by plain `usize` index, owned elsewhere (window.zig) — so this file
//! is pure, OS-independent logic.
//!
//! This is the one piece of the multiplexer phase that's actually
//! unit-tested rather than just "compiles, cross-compiles, hope for the
//! best" like the rest of the Windows-only code in this project — there's
//! no OS dependency here to make testing impossible.

const std = @import("std");

pub const Direction = enum { horizontal, vertical };

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Node = union(enum) {
    leaf: usize,
    split: struct {
        direction: Direction,
        ratio: f32 = 0.5,
        first: *Node,
        second: *Node,
    },
};

pub const Layout = struct {
    root: *Node,
    focused: usize,

    pub fn initSingle(allocator: std.mem.Allocator, pane_index: usize) !Layout {
        const root = try allocator.create(Node);
        root.* = .{ .leaf = pane_index };
        return Layout{ .root = root, .focused = pane_index };
    }

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        destroyNode(self.root, allocator);
    }

    fn destroyNode(node: *Node, allocator: std.mem.Allocator) void {
        switch (node.*) {
            .leaf => {},
            .split => |s| {
                destroyNode(s.first, allocator);
                destroyNode(s.second, allocator);
            },
        }
        allocator.destroy(node);
    }

    /// Splits the currently-focused leaf in two, giving the new pane
    /// (`new_pane_index`) the second half. The new pane becomes focused.
    pub fn splitFocused(self: *Layout, allocator: std.mem.Allocator, direction: Direction, new_pane_index: usize) !void {
        _ = try findAndSplit(self.root, self.focused, direction, allocator, new_pane_index);
        self.focused = new_pane_index;
    }

    fn findAndSplit(node: *Node, target: usize, direction: Direction, allocator: std.mem.Allocator, new_index: usize) !bool {
        switch (node.*) {
            .leaf => |idx| {
                if (idx != target) return false;
                const first = try allocator.create(Node);
                first.* = .{ .leaf = idx };
                const second = try allocator.create(Node);
                second.* = .{ .leaf = new_index };
                node.* = .{ .split = .{ .direction = direction, .first = first, .second = second } };
                return true;
            },
            .split => |s| {
                if (try findAndSplit(s.first, target, direction, allocator, new_index)) return true;
                return findAndSplit(s.second, target, direction, allocator, new_index);
            },
        }
    }

    /// Removes the leaf holding `pane_index`, collapsing its parent split
    /// so the sibling takes over the freed space. Returns `true` if the
    /// whole layout is now empty (it was a single leaf and that leaf was
    /// closed) — the caller should close the containing tab in that case,
    /// since a Layout can't represent "zero panes" any other way.
    pub fn closePane(self: *Layout, allocator: std.mem.Allocator, pane_index: usize) !bool {
        if (self.root.* == .leaf) {
            std.debug.assert(self.root.leaf == pane_index);
            return true; // caller closes the tab; nothing left to collapse
        }
        _ = try findAndClose(self.root, pane_index, allocator);
        if (self.focused == pane_index) {
            var list: std.ArrayList(usize) = .empty;
            defer list.deinit(allocator);
            try collectLeaves(self.root, &list, allocator);
            if (list.items.len > 0) self.focused = list.items[0];
        }
        return false;
    }

    fn findAndClose(node: *Node, target: usize, allocator: std.mem.Allocator) !bool {
        switch (node.*) {
            .leaf => return false,
            .split => |s| {
                if (s.first.* == .leaf and s.first.leaf == target) {
                    const sibling = s.second;
                    const removed = s.first;
                    node.* = sibling.*;
                    allocator.destroy(removed);
                    allocator.destroy(sibling);
                    return true;
                }
                if (s.second.* == .leaf and s.second.leaf == target) {
                    const sibling = s.first;
                    const removed = s.second;
                    node.* = sibling.*;
                    allocator.destroy(removed);
                    allocator.destroy(sibling);
                    return true;
                }
                if (try findAndClose(s.first, target, allocator)) return true;
                return findAndClose(s.second, target, allocator);
            },
        }
    }

    fn collectLeaves(node: *Node, list: *std.ArrayList(usize), allocator: std.mem.Allocator) !void {
        switch (node.*) {
            .leaf => |idx| try list.append(allocator, idx),
            .split => |s| {
                try collectLeaves(s.first, list, allocator);
                try collectLeaves(s.second, list, allocator);
            },
        }
    }

    /// Moves focus to the next pane in a stable depth-first order,
    /// wrapping around.
    pub fn cycleFocus(self: *Layout, allocator: std.mem.Allocator) !void {
        var list: std.ArrayList(usize) = .empty;
        defer list.deinit(allocator);
        try collectLeaves(self.root, &list, allocator);
        if (list.items.len == 0) return;
        const cur_pos = std.mem.indexOfScalar(usize, list.items, self.focused) orelse 0;
        self.focused = list.items[(cur_pos + 1) % list.items.len];
    }

    /// Computes each leaf's rect within `total` and calls
    /// `ctx.visit(pane_index, rect)` for each. `ctx` is `anytype` (not a
    /// plain function pointer) so callers can close over whatever state
    /// they need — window.zig's renderer, for instance.
    pub fn walk(self: *Layout, total: Rect, ctx: anytype) void {
        walkNode(self.root, total, ctx);
    }

    fn walkNode(node: *Node, rect: Rect, ctx: anytype) void {
        switch (node.*) {
            .leaf => |idx| ctx.visit(idx, rect),
            .split => |s| switch (s.direction) {
                .vertical => {
                    const h1 = rect.h * s.ratio;
                    walkNode(s.first, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = h1 }, ctx);
                    walkNode(s.second, .{ .x = rect.x, .y = rect.y + h1, .w = rect.w, .h = rect.h - h1 }, ctx);
                },
                .horizontal => {
                    const w1 = rect.w * s.ratio;
                    walkNode(s.first, .{ .x = rect.x, .y = rect.y, .w = w1, .h = rect.h }, ctx);
                    walkNode(s.second, .{ .x = rect.x + w1, .y = rect.y, .w = rect.w - w1, .h = rect.h }, ctx);
                },
            },
        }
    }

    /// Like `walk`, but visits split boundaries instead of leaves —
    /// `ctx.visitSplit(direction, rect)` once per split, where `rect` is
    /// a zero-thickness line along the boundary (zero height for a
    /// vertical/stacked split's horizontal divider, zero width for a
    /// horizontal/side-by-side split's vertical divider). Used to draw
    /// the ASCII borders between panes.
    pub fn walkSplits(self: *Layout, total: Rect, ctx: anytype) void {
        walkSplitsNode(self.root, total, ctx);
    }

    fn walkSplitsNode(node: *Node, rect: Rect, ctx: anytype) void {
        switch (node.*) {
            .leaf => {},
            .split => |s| switch (s.direction) {
                .vertical => {
                    const h1 = rect.h * s.ratio;
                    ctx.visitSplit(Direction.vertical, Rect{ .x = rect.x, .y = rect.y + h1, .w = rect.w, .h = 0 });
                    walkSplitsNode(s.first, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = h1 }, ctx);
                    walkSplitsNode(s.second, .{ .x = rect.x, .y = rect.y + h1, .w = rect.w, .h = rect.h - h1 }, ctx);
                },
                .horizontal => {
                    const w1 = rect.w * s.ratio;
                    ctx.visitSplit(Direction.horizontal, Rect{ .x = rect.x + w1, .y = rect.y, .w = 0, .h = rect.h });
                    walkSplitsNode(s.first, .{ .x = rect.x, .y = rect.y, .w = w1, .h = rect.h }, ctx);
                    walkSplitsNode(s.second, .{ .x = rect.x + w1, .y = rect.y, .w = rect.w - w1, .h = rect.h }, ctx);
                },
            },
        }
    }
};

const testing = std.testing;

test "single pane covers the whole rect" {
    var layout = try Layout.initSingle(testing.allocator, 0);
    defer layout.deinit(testing.allocator);

    const Collector = struct {
        seen: ?struct { idx: usize, rect: Rect } = null,
        fn visit(self: *@This(), idx: usize, rect: Rect) void {
            self.seen = .{ .idx = idx, .rect = rect };
        }
    };
    var c = Collector{};
    layout.walk(.{ .x = 0, .y = 0, .w = 100, .h = 50 }, &c);
    try testing.expectEqual(@as(usize, 0), c.seen.?.idx);
    try testing.expectEqual(@as(f32, 100), c.seen.?.rect.w);
}

test "splitFocused divides the rect and focuses the new pane" {
    var layout = try Layout.initSingle(testing.allocator, 0);
    defer layout.deinit(testing.allocator);

    try layout.splitFocused(testing.allocator, .horizontal, 1);
    try testing.expectEqual(@as(usize, 1), layout.focused);

    const Collector = struct {
        rects: [2]?Rect = .{ null, null },
        fn visit(self: *@This(), idx: usize, rect: Rect) void {
            self.rects[idx] = rect;
        }
    };
    var c = Collector{};
    layout.walk(.{ .x = 0, .y = 0, .w = 100, .h = 40 }, &c);
    // horizontal split = side by side: widths split, full height each
    try testing.expectEqual(@as(f32, 50), c.rects[0].?.w);
    try testing.expectEqual(@as(f32, 50), c.rects[1].?.w);
    try testing.expectEqual(@as(f32, 40), c.rects[0].?.h);
    try testing.expectEqual(@as(f32, 50), c.rects[1].?.x);
}

test "closePane collapses the split back to a single leaf" {
    var layout = try Layout.initSingle(testing.allocator, 0);
    defer layout.deinit(testing.allocator);
    try layout.splitFocused(testing.allocator, .vertical, 1);

    const emptied = try layout.closePane(testing.allocator, 1);
    try testing.expect(!emptied);
    try testing.expect(layout.root.* == .leaf);
    try testing.expectEqual(@as(usize, 0), layout.root.leaf);
    try testing.expectEqual(@as(usize, 0), layout.focused);
}

test "closePane on the last leaf reports the layout is empty" {
    var layout = try Layout.initSingle(testing.allocator, 0);
    defer layout.deinit(testing.allocator);
    const emptied = try layout.closePane(testing.allocator, 0);
    try testing.expect(emptied);
}

test "cycleFocus wraps around across multiple splits" {
    var layout = try Layout.initSingle(testing.allocator, 0);
    defer layout.deinit(testing.allocator);
    try layout.splitFocused(testing.allocator, .horizontal, 1);
    try layout.splitFocused(testing.allocator, .vertical, 2);
    // depth-first leaf order is 0, 1, 2 given how splits nest here
    try testing.expectEqual(@as(usize, 2), layout.focused);
    try layout.cycleFocus(testing.allocator);
    try testing.expectEqual(@as(usize, 0), layout.focused);
    try layout.cycleFocus(testing.allocator);
    try testing.expectEqual(@as(usize, 1), layout.focused);
    try layout.cycleFocus(testing.allocator);
    try testing.expectEqual(@as(usize, 2), layout.focused);
}

test "closePane deep in the tree preserves the rest of the layout" {
    var layout = try Layout.initSingle(testing.allocator, 0);
    defer layout.deinit(testing.allocator);
    try layout.splitFocused(testing.allocator, .horizontal, 1); // 0 | 1
    layout.focused = 1;
    try layout.splitFocused(testing.allocator, .vertical, 2); // 0 | (1 / 2)

    const emptied = try layout.closePane(testing.allocator, 2);
    try testing.expect(!emptied);

    var list: std.ArrayList(usize) = .empty;
    defer list.deinit(testing.allocator);
    try Layout.collectLeaves(layout.root, &list, testing.allocator);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, list.items);
}

test "walkSplits visits one boundary per split, at the right position" {
    var layout = try Layout.initSingle(testing.allocator, 0);
    defer layout.deinit(testing.allocator);
    try layout.splitFocused(testing.allocator, .horizontal, 1); // side by side

    const Collector = struct {
        count: usize = 0,
        last_dir: ?Direction = null,
        last_x: f32 = 0,
        fn visitSplit(self: *@This(), dir: Direction, rect: Rect) void {
            self.count += 1;
            self.last_dir = dir;
            self.last_x = rect.x;
        }
    };
    var c = Collector{};
    layout.walkSplits(.{ .x = 0, .y = 0, .w = 100, .h = 40 }, &c);
    try testing.expectEqual(@as(usize, 1), c.count);
    try testing.expectEqual(Direction.horizontal, c.last_dir.?);
    try testing.expectEqual(@as(f32, 50), c.last_x); // boundary at the 50/50 split point
}
