const std = @import("std");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

const main = @import("main.zig");
const c = main.c;
const Self = @This();
const Literal = @TypeOf(.literal);
const misc = @import("misc.zig");
const die = misc.die;
const log = std.log.scoped(.daemon);

pub const HashMap = std.HashMap([]u8, []u8, struct {
    pub fn hash(_: @This(), s: []u8) u64 {
        return std.hash_map.hashString(s);
    }

    pub fn eql(_: @This(), a: []u8, b: []u8) bool {
        return std.hash_map.eqlString(a, b);
    }
}, std.hash_map.default_max_load_percentage);

allocator: Allocator,
socket: std.posix.socket_t,
current_client: ?std.net.Stream,
map: HashMap,

pub fn init(socket_path: []const u8, allocator: Allocator) !Self {
    const cwd = std.fs.cwd();
    cwd.deleteFile(socket_path) catch |err| switch (err) {
        error.FileNotFound => {}, // no problem if the socket didn't exist previously
        else => {
            log.err("failed to delete old socket: {}", .{err});
            return err;
        },
    };

    const socket = std.posix.socket(c.AF_UNIX, c.SOCK_STREAM, 0) catch |err| {
        log.err("failed to create socket: {}", .{err});
        return err;
    };
    errdefer _ = std.posix.close(socket);

    var addr = try std.net.Address.initUnix(socket_path);
    std.posix.bind(socket, &addr.any, addr.getOsSockLen()) catch |err| {
        log.err("failed to bind: {}", .{err});
        return err;
    };
    log.debug("socket succesfully bound", .{});

    std.posix.listen(socket, misc.max_connections) catch |err| {
        log.err("failed to begin listening: {}", .{err});
        return err;
    };
    log.debug("listening...", .{});

    return Self{
        .allocator = allocator,
        .socket = socket,
        .current_client = null,
        .map = HashMap.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    // deinit the connection
    _ = std.posix.close(self.socket); // FIXME: what does this return, again?

    // deinit the map
    var it = self.map.iterator();
    while (it.next()) |e| {
        self.allocator.free(e.key_ptr.*);
        self.allocator.free(e.value_ptr.*);
    }
    self.map.deinit();

    self.* = undefined;
}

/// Runs the main loop. Returns the exit code for the daemon process.
pub fn mainLoop(self: *Self) u8 {
    main_loop: while (true) {
        // TODO: 1s timeout (not too much of an issue since... why the hell would I DoS my own machine?)
        // I think reading an env var like DOTCFG_TIMEOUT would be convenient.

        const conn = blk: {
            const fd = std.posix.accept(self.socket, null, null, c.SOCK_CLOEXEC) catch |err| {
                log.err("could not accept: {}", .{err});
                continue :main_loop;
            };
            break :blk std.net.Stream{ .handle = fd };
        };
        defer {
            log.debug("closing connection with conn #{}", .{conn});
            conn.close();
        }
        log.debug("accepted #{}", .{conn.handle});
        self.current_client = conn;

        var line = std.ArrayList(u8).init(self.allocator);
        defer line.deinit();
        const r = conn.reader();
        get_line: while (true) {
            r.readUntilDelimiterArrayList(&line, '\n', misc.usize_max) catch |err| switch (err) {
                error.OutOfMemory => die("OOM", .{}),
                else => {
                    log.err("failed to read: {}", .{err});
                    conn.writeAll("err:read-error\n") catch {};
                    return 1;
                },
            };

            log.debug("got line: {s}", .{line.items});

            if (std.mem.eql(u8, line.items, "end"))
                break :get_line;

            self.processLine(line.items);
        }

        log.debug("done", .{});
    }

    return 0;
}

pub fn write(self: Self, data: []const u8) void {
    const current_client = self.current_client orelse {
        log.err("failed to write: no current client\n", .{});
        return;
    };

    _ = std.posix.write(current_client.handle, data) catch |err| {
        log.err("failed to write: {}\n", .{err});
    };
}

pub fn setOption(self: *Self, key: []const u8, value: []const u8) Allocator.Error!void {
    const k2 = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(k2);

    const v2 = try self.allocator.dupe(u8, value);
    errdefer self.allocator.free(v2);

    try self.map.put(k2, v2);
}

/// Process a line and reply accordingly to the connection.
pub fn processLine(self: *Self, line: []const u8) void {
    var it = std.mem.split(u8, line, ":");

    const command = it.next() orelse {
        self.write("err:missing-command\n");
        return;
    };

    if (eql(u8, command, "get")) {
        const key = it.rest();

        const key_mut = constToMut(u8, key);
        if (self.map.get(key_mut)) |v| {
            self.write("ok:");
            self.write(v);
            self.write("\n");
        } else {
            self.write("err:unknown-key\n");
        }
    } else if (eql(u8, command, "set")) {
        const key = it.next() orelse {
            self.write("err:missing-key\n");
            return;
        };
        const value = it.rest();

        self.setOption(key, value) catch {
            self.write("OOM\n");
            die("OOM", .{});
        };
        self.write("ok\n");
    } else {
        self.write("err:unknown-command\n");
    }
}

fn constToMut(comptime T: type, slice: []const T) []T {
    // FIXME: not a good idea, I think... :(
    const arr: [*]T = @ptrFromInt(@intFromPtr(slice.ptr));
    return arr[0..slice.len];
}

// pub fn stupidWrite(f: std.fs.File, data: []const u8, comptime scope: @TypeOf(.literal)) void {
//     _ = f.write(data) catch |err| {
//         std.log.defaultLog(.err, scope, "failed to write: {}\n", .{err});
//     };
// }

// pub fn daemonProcessLine(line: []const u8, conn: std.fs.File, map: *DaemonHashMap, allocator: Allocator) void {
//     var it = std.mem.split(u8, line, ":");

//     const command = it.next() orelse {
//         stupidWrite(conn, "err:missing-command\n", .daemonProcessLine);
//         return;
//     };

//     if (eql(u8, command, "get")) {
//         // log.debug(.daemonProcessLine, "got GET", .{});
//         const key = it.rest();
//         const key_mut = constToMut(u8, key);
//         if (map.get(key_mut)) |v| {
//             stupidWrite(conn, "ok:", .daemonProcessLine);
//             stupidWrite(conn, v, .daemonProcessLine);
//             stupidWrite(conn, "\n", .daemonProcessLine);
//         } else {
//             stupidWrite(conn, "err:unknown-key\n", .daemonProcessLine);
//         }
//     } else if (eql(u8, command, "set")) {
//         // log.debug(.daemonProcessLine, "got SET", .{});

//         const key = it.next() orelse {
//             stupidWrite(conn, "err:missing-key\n", .daemonProcessLine);
//             return;
//         };
//         const value = it.rest();

//         daemonSetValue(map, key, value) catch {
//             stupidWrite(conn, "OOM\n", .daemonProcessLine);
//             die("OOM", .{});
//         };
//         stupidWrite(conn, "ok\n", .daemonProcessLine);
//     };
//     } else {
//         stupidWrite(conn, "err:unknown-command\n", .daemonProcessLine);
//     }
// }
