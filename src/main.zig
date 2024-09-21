pub const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h"); // unix domain socket
    @cInclude("unistd.h");
});

const std = @import("std");
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;

const Client = @import("Client.zig");
const Daemon = @import("Daemon.zig");
const helpAndExit = @import("help.zig").helpAndExit;
const misc = @import("misc.zig");
const die = misc.die;

pub fn main() u8 {
    const log = std.log.scoped(.main);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const alloc = gpa.allocator();

    const default_s_path: [:0]const u8 = "/tmp/dotcfg.default.sock";
    const s_path = std.posix.getenv("DOTCFG_SOCKET") orelse default_s_path;
    log.debug("got socket path: {s}", .{s_path});

    const addr = getAddr(s_path) orelse return 1;

    var args = std.process.args();
    defer args.deinit();

    _ = args.next(); // skip program name

    const action = args.next() orelse {
        log.err("missing action argument", .{});
        helpAndExit();
    };

    if (eql(u8, action, "daemon")) {
        if (args.next()) |a| {
            log.err("trailing argument: {s}", .{a});
            helpAndExit();
        }

        var daemon = Daemon.init(s_path, alloc) catch return 1;
        defer daemon.deinit();

        return daemon.mainLoop();
    } else if (eql(u8, action, "send")) {
        var client = Client.init(addr, alloc);
        defer client.deinit();

        var messages = std.ArrayList([]const u8).init(alloc);
        defer messages.deinit();

        while (args.next()) |msg| {
            messages.append(msg) catch die("OOM", .{});
        }

        const msg = std.mem.join(alloc, "\n", messages.items) catch die("OOM", .{});
        defer alloc.free(msg);

        return client.sendReceiveAndParse(msg);
    } else if (eql(u8, action, "stdin-send")) {
        if (args.next()) |a| {
            log.err("trailing argument: {s}", .{a});
            helpAndExit();
        }

        var client = Client.init(addr, alloc);
        defer client.deinit();

        const in = std.io.getStdIn();

        const input = in.reader().readAllAlloc(alloc, misc.usize_max) catch die("OOM", .{});
        defer alloc.free(input);

        return client.sendReceiveAndParse(input);
    } else if (eql(u8, action, "help")) {
        if (args.next()) |a| {
            log.err("trailing argument: {s}", .{a});
        }

        helpAndExit();
    } else {
        log.err("unknown action: {s}", .{action});
        helpAndExit();
    }
}

pub fn getAddr(path: []const u8) ?c.sockaddr_un {
    const log = std.log.scoped(.getAddr);

    const max_size = @sizeOf(std.meta.fieldInfo(c.sockaddr_un, .sun_path).type);
    if (path.len + 1 > max_size) {
        log.err("server socket path too long", .{});
        return null;
    }

    var addr = std.mem.zeroes(c.sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    std.mem.copyForwards(u8, &addr.sun_path, path);
    addr.sun_path[path.len] = 0;

    return addr;
}
