const std = @import("std");

pub fn die(comptime str: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print("error: " ++ str ++ "\n", args) catch {};

    std.posix.exit(1);
}

pub const usize_max = std.math.maxInt(usize);
pub const max_connections = 64;
pub const buf_size = 128;
