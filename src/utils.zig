const std = @import("std");

pub fn usizeCmp(a: usize, b: usize) std.math.Order {
    return std.math.order(a, b);
}
