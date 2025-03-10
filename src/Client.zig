const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.client);

const c = @import("root.zig").c;
const Self = @This();

const misc = @import("misc.zig");
const die = misc.die;

allocator: Allocator,
conn: std.net.Stream,

pub fn init(socket_path: []const u8, allocator: Allocator) Self {
    const addr = std.net.Address.initUnix(socket_path) catch |err| {
        die("failed to bind: {}", .{err});
    };

    const s_fd = std.posix.socket(c.AF_UNIX, c.SOCK_STREAM, 0) catch |err| {
        die("failed to create socket: {}", .{err});
    };
    errdefer _ = std.posix.close(s_fd);

    log.debug("server socket opened (fd: {})", .{s_fd});

    std.posix.connect(s_fd, @ptrCast(&addr), addr.getOsSockLen()) catch |err| {
        die("failed to connect: {}", .{err});
    };

    log.debug("succesfully connected", .{});

    return .{
        .allocator = allocator,
        .conn = std.net.Stream{ .handle = s_fd },
    };
}

pub fn deinit(self: *Self) void {
    self.conn.close();
    self.* = undefined;
}

/// The returned memory should be freed
pub fn sendAndReceive(self: *const Self, msg: []const u8) ?[]u8 {
    _ = blk: {
        const f = self.conn;
        _ = f.writeAll(msg) catch |err| break :blk err;
        if (msg.len > 0 and msg[msg.len - 1] != '\n')
            _ = f.writeAll("\n") catch |err| break :blk err;
        _ = f.writeAll("end\n") catch |err| break :blk err;
    } catch |err| {
        log.err("failed to write: {}", .{err});
    };

    log.debug("sent message; reading", .{});

    const mem = self.conn.reader().readAllAlloc(self.allocator, misc.usize_max) catch |err| {
        log.err("failed to read: {}", .{err});
        return null;
    };

    log.debug("read response", .{});

    return mem;
}

pub fn sendReceiveAndParse(self: *const Self, msg: []const u8) u8 {
    const response = self.sendAndReceive(msg) orelse return 1;
    defer self.allocator.free(response);

    const stdout = std.io.getStdOut();

    var full_success = true;
    var it = std.mem.splitSequence(u8, response, "\n");
    while (it.next()) |line| {
        const ok_prefix = "ok:";
        if (std.mem.startsWith(u8, line, ok_prefix)) {
            _ = stdout.write(line[ok_prefix.len..]) catch return 1;
            _ = stdout.write("\n") catch return 1;
        } else if (std.mem.startsWith(u8, line, "ok")) {
            // for set messages
            _ = stdout.write("ok\n") catch return 1;
        } else if (std.mem.startsWith(u8, line, "err:")) {
            _ = stdout.write(line) catch return 1;
            _ = stdout.write("\n") catch return 1;
            full_success = false;
        } else if (std.mem.trim(u8, line, " \n\r\t").len == 0) {
            // skip
        } else {
            log.err("unknown response: {s}\n", .{line});
            return 1;
        }
    }

    return if (full_success) 0 else 1;
}
