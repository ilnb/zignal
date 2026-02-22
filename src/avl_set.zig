const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

pub fn Set(T: type) type {
    const AVL = struct {
        pub const Node = struct {
            child: [2]?*@This() = .{ null, null },
            parent: ?*@This() = null,
            height: i32 = 1,
            key: T,
        };

        const Self = @This();

        root: ?*Node = null,
        alloc: Allocator,
        count: usize = 0,
        cmp: *const fn (T, T) Order,

        pub fn init(aa: Allocator, cmp: fn (T, T) Order) Self {
            return Self{ .alloc = aa, .cmp = cmp };
        }

        pub fn deinit(self: *Self) void {
            self.free(self.root);
            self.root = null;
        }

        fn free(self: *Self, node: ?*Node) void {
            if (node) |n| {
                for (n.child) |c| self.free(c);
                self.alloc.destroy(n);
                self.count -= 1;
            }
        }

        fn getBalance(node: ?*Node) i32 {
            var balance: i32 = 0;
            if (node) |n| {
                if (n.child[0]) |c| balance += c.height;
                if (n.child[1]) |c| balance -= c.height;
            }
            return balance;
        }

        fn updateHeight(node: *Node) void {
            const lh: i32 = if (node.child[0]) |l| l.height else 0;
            const rh: i32 = if (node.child[1]) |r| r.height else 0;
            node.height = @max(lh, rh) + 1;
        }

        fn leftRotate(x: **Node) void {
            const y: *Node = x.*.child[1].?;
            const t2 = y.child[0];
            y.child[0] = x.*;
            x.*.child[1] = t2;
            y.parent = x.*.parent;
            x.*.parent = y;
            if (t2) |t| t.parent = x.*;
            updateHeight(y);
            updateHeight(x.*);
            x.* = y;
        }

        fn rightRotate(x: **Node) void {
            const y: *Node = x.*.child[0].?;
            const t2 = y.child[1];
            y.child[1] = x.*;
            x.*.child[0] = t2;
            y.parent = x.*.parent;
            x.*.parent = y;
            if (t2) |t| t.parent = x.*;
            updateHeight(y);
            updateHeight(x.*);
            x.* = y;
        }

        pub fn put(self: *Self, key: T) !void {
            if (self.root == null) {
                const new = try self.alloc.create(Node);
                new.* = .{ .key = key };
                self.root = new;
                self.count += 1;
                return;
            }

            var node: *?*Node = &self.root;
            var parent: ?*Node = null;
            var found = false;
            while (true) {
                if (node.* == null) break;

                const order = self.cmp(node.*.?.key, key);
                if (order == .eq) {
                    found = true;
                    break;
                } else {
                    parent = node.*;
                    if (order == .lt) {
                        node = &node.*.?.child[1];
                    } else {
                        node = &node.*.?.child[0];
                    }
                }
            }

            if (found) return;

            const new = try self.alloc.create(Node);
            new.* = .{ .key = key, .parent = parent };
            node.* = new;
            self.count += 1;

            while (parent) |p| {
                updateHeight(p);
                const balance = getBalance(p);

                var pref: **Node = &self.root.?;
                if (p.parent) |gp| {
                    pref = if (gp.child[0] == p) &gp.child[0].? else &gp.child[1].?;
                }
                if (balance > 1) {
                    if (getBalance(p.child[0]) < 0) {
                        leftRotate(&p.child[0].?);
                    }
                    rightRotate(pref);
                } else if (balance < -1) {
                    if (getBalance(p.child[1]) > 0) {
                        rightRotate(&p.child[1].?);
                    }
                    leftRotate(pref);
                }
                parent = p.parent;
            }
        }

        pub fn contains(self: *Self, key: T) ?*Node {
            var node = self.root;
            while (node) |n| {
                const order = self.cmp(n.key, key);
                if (order == .eq) return n;
                if (order == .lt) node = n.child[1];
                if (order == .gt) node = n.child[0];
            }
            return null;
        }

        pub fn minKey(self: *Self) ?T {
            if (self.root == null) return null;
            return minNode(self.root.?).key;
        }

        fn minNode(node: *Node) *Node {
            var n = node;
            while (n.child[0]) |c| n = c;
            return n;
        }

        pub fn maxKey(self: *Self) ?T {
            if (self.root == null) return null;
            return maxNode(self.root.?).key;
        }

        fn maxNode(node: *Node) *Node {
            var n = node;
            while (n.child[1]) |c| n = c;
            return n;
        }

        pub fn remove(self: *Self, key: T) void {
            var curr: *?*Node = &self.root;
            while (curr.*) |n| {
                const order = self.cmp(n.key, key);
                if (order == .lt) {
                    curr = &n.child[1];
                } else if (order == .gt) {
                    curr = &n.child[0];
                } else break;
            }

            var node = curr.* orelse return;
            var child_count: u2 = 0;
            for (node.child) |c| {
                if (c != null) child_count += 1;
            }

            if (child_count == 2) {
                const succ = minNode(node.child[1].?);
                node.key = succ.key;
                node = succ;
            }

            var parent = node.parent;
            const child = node.child[0] orelse node.child[1];
            if (parent) |p| {
                if (p.child[0] == node) {
                    p.child[0] = child;
                } else {
                    p.child[1] = child;
                }
            } else {
                self.root = child;
            }

            if (child) |c| c.parent = parent;

            self.count -= 1;
            self.alloc.destroy(node);

            while (parent) |p| {
                updateHeight(p);
                const balance = getBalance(p);

                var pref: **Node = &self.root.?;
                if (p.parent) |gp| {
                    pref = if (gp.child[0] == p) &gp.child[0].? else &gp.child[1].?;
                }

                if (balance > 1) {
                    if (getBalance(p.child[0]) < 0) {
                        leftRotate(&p.child[0].?);
                    }
                    rightRotate(pref);
                } else if (balance < -1) {
                    if (getBalance(p.child[1]) > 0) {
                        rightRotate(&p.child[1].?);
                    }
                    leftRotate(pref);
                }
                parent = p.parent;
            }
        }

        pub const Iterator = struct {
            curr: ?*Node,

            pub fn next(self: *Iterator) ?*Node {
                const ret = self.curr;
                if (self.curr) |curr| {
                    if (curr.child[1]) |r| {
                        self.curr = minNode(r);
                    } else {
                        var node = curr;
                        while (node.parent) |p| {
                            if (p.child[0] == node) {
                                self.curr = p;
                                return ret;
                            }
                            node = p;
                        }
                        self.curr = null;
                    }
                }
                return ret;
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return Iterator{ .curr = if (self.root) |r| minNode(r) else null };
        }

        pub const ReverseIterator = struct {
            curr: ?*Node,

            pub fn next(self: *ReverseIterator) ?*Node {
                const ret = self.curr;
                if (self.curr) |curr| {
                    if (curr.child[0]) |l| {
                        self.curr = maxNode(l);
                    } else {
                        var node = curr;
                        while (node.parent) |p| {
                            if (p.child[1] == node) {
                                self.curr = p;
                                return ret;
                            }
                            node = p;
                        }
                        self.curr = null;
                    }
                }
                return ret;
            }
        };

        pub fn reverseIterator(self: *Self) ReverseIterator {
            return ReverseIterator{ .curr = if (self.root) |r| maxNode(r) else null };
        }

        pub fn format(
            self: Self,
            wr: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            try printImpl(self.root, wr);
        }

        pub fn print(self: *Self, wr: *std.Io.Writer) !void {
            try printImpl(self.root, wr);
            try wr.writeAll("\n");
        }

        fn printImpl(node: ?*Node, wr: *std.Io.Writer) !void {
            if (node) |n| {
                try printImpl(n.child[0], wr);
                try wr.print("{d} ", .{n.key});
                try printImpl(n.child[1], wr);
            }
        }
    };
    return AVL;
}
