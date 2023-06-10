const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h"); // unix domain socket
    @cInclude("unistd.h");
});

const std = @import("std");
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;

const max_connections = 64;
const buf_size = 128;
const usize_max = std.math.maxInt(usize);

pub fn die(comptime str: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print("error: " ++ str ++ "\n", args) catch {};

    std.os.exit(1);
}

pub fn helpAndExit() noreturn {
    const help_text =
        \\Usage: dotcfg { daemon | send [MESSAGES...] | stdin-send | help }
        \\
        \\COMMANDS
        \\
        \\  daemon: starts the daemon, taking into account the DOTCFG_SOCKET path.
        \\
        \\  send: send one message per argument
        \\
        \\  stdin-send: same as send, but instead of one command per argument it is one
        \\  command per line (TODO:implement)
        \\
        \\  help: show this message
        \\
        \\MESSAGES
        \\
        \\  When communicating with the daemon, you send messages. They can be:
        \\
        \\  set:<KEY>:<VALUE> to set a property
        \\    (note that key CANNOT have any commas, but the value can)
        \\
        \\  get:<KEY> to get a property's value
        \\    (key SHOULD not have any commas)
        \\
        \\  Upon dealing with these commands, you can receive responses.
        \\
        \\  Successful operations internally return "ok:" but that is stripped out for
        \\  convenience.
        \\
        \\  The following responses are error responses:
        \\
        \\  err:missing-command
        \\  err:missing-key
        \\  err:unknown-command
        \\  err:read-error
        \\
        \\  If at least one of the responses is an error, the program exits 1 after
        \\  printing all responses. If an invalid response is detected, the program
        \\  exits 1 immediately.
        \\
    ;

    const stderr = std.io.getStdErr().writer();
    _ = stderr.write(help_text) catch std.os.exit(1);
    std.os.exit(0);
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

pub fn stupidWrite(f: std.fs.File, data: []const u8, comptime scope: @TypeOf(.literal)) void {
    _ = f.write(data) catch |err| {
        std.log.defaultLog(.err, scope, "failed to write: {}\n", .{err});
    };
}

const DaemonHashMap = std.HashMap([]u8, []u8, struct {
    pub fn hash(_: @This(), s: []u8) u64 {
        return std.hash_map.hashString(s);
    }

    pub fn eql(_: @This(), a: []u8, b: []u8) bool {
        return std.hash_map.eqlString(a, b);
    }
}, 80);

pub fn daemonProcessLine(line: []const u8, conn: std.fs.File, map: *DaemonHashMap, allocator: Allocator) void {
    var it = std.mem.split(u8, line, ":");

    const command = it.next() orelse {
        stupidWrite(conn, "err:missing-command\n", .daemonProcessLine);
        return;
    };

    if (eql(u8, command, "get")) {
        // log.debug(.daemonProcessLine, "got GET", .{});
        const key = it.rest();
        const key_mut = @intToPtr([*]u8, @ptrToInt(key.ptr))[0..key.len]; // FIXME: try not to spawn a demon
        if (map.get(key_mut)) |v| {
            stupidWrite(conn, "ok:", .daemonProcessLine);
            stupidWrite(conn, v, .daemonProcessLine);
            stupidWrite(conn, "\n", .daemonProcessLine);
        } else {
            stupidWrite(conn, "err:unknown-key\n", .daemonProcessLine);
        }
    } else if (eql(u8, command, "set")) {
        // log.debug(.daemonProcessLine, "got SET", .{});

        const key = it.next() orelse {
            stupidWrite(conn, "err:missing-key\n", .daemonProcessLine);
            return;
        };
        const value = it.rest();

        const k2 = allocator.dupe(u8, key) catch {
            stupidWrite(conn, "OOM\n", .daemonProcessLine);
            die("OOM", .{});
        };
        errdefer allocator.free(k2);

        const v2 = allocator.dupe(u8, value) catch {
            stupidWrite(conn, "OOM\n", .daemonProcessLine);
            die("OOM", .{});
        };
        errdefer allocator.free(v2);

        map.put(k2, v2) catch {
            stupidWrite(conn, "OOM\n", .daemonProcessLine);
            die("OOM", .{});
        };

        stupidWrite(conn, "ok\n", .daemonProcessLine);
    } else {
        stupidWrite(conn, "err:unknown-command\n", .daemonProcessLine);
    }
}

// TODO: turn this into a struct with some methods
pub fn daemonLoop(allocator: Allocator, addr: c.sockaddr_un) u8 {
    const log = std.log.scoped(.server);

    switch (std.c.getErrno(c.unlink(&addr.sun_path))) {
        .SUCCESS, .NOENT => {},
        else => |e| {
            log.err("failed to delete old socket: {?}", .{e});
            return 1;
        },
    }

    const s_fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (s_fd == -1) {
        log.err("failed to create socket: {}", .{std.c.getErrno(-1)});
        return 1;
    }
    log.debug("server socket opened (fd: {})", .{s_fd});
    defer _ = c.close(s_fd);

    if (c.bind(s_fd, @ptrCast(*const c.sockaddr, &addr), @sizeOf(c.sockaddr_un)) == -1) {
        log.err("failed to bind socket: {}", .{std.c.getErrno(-1)});
        return 1;
    }
    log.debug("socket succesfully bound", .{});

    if (c.listen(s_fd, max_connections) == -1) {
        log.err("failed to begin listening", .{});
        return 1;
    }
    log.debug("listening...", .{});

    var map = DaemonHashMap.init(allocator);
    defer {
        var it = map.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        map.deinit();
    }

    connected: while (true) {
        const conn = blk: {
            const fd = c.accept(s_fd, null, null);
            if (fd == -1) {
                log.err("could not accept: {}", .{std.c.getErrno(-1)});
            }

            break :blk std.fs.File{ .handle = fd };
        };
        defer {
            log.debug("closing connection with conn #{}", .{conn.handle});
            conn.close();
        }

        log.debug("accepted (socket = {})", .{conn.handle});

        // TODO: 1s timeout (not too much of an issue since why the hell would I DDOS my own machine, and via itself
        // (it's a local socket))

        var line = std.ArrayList(u8).init(allocator);
        defer line.deinit();
        const r = conn.reader();
        get_line: while (true) {
            r.readUntilDelimiterArrayList(&line, '\n', usize_max) catch |err| switch (err) {
                error.OutOfMemory => die("OOM", .{}),
                else => {
                    log.err("failed to read: {}", .{err});
                    conn.writeAll("err:read-error\n") catch {};
                    break :connected;
                },
            };

            log.debug("got line: {s}", .{line.items});

            if (std.mem.eql(u8, line.items, "end"))
                break :get_line;

            daemonProcessLine(line.items, conn, &map, allocator);
        }

        log.debug("done", .{});

        // read: while (true) {
        //     var buf: [4096]u8 = undefined;

        //     const len = conn.read(&buf) catch |err| {
        //         log.err("failed to read: {}", .{err});
        //         conn.writeAll("READ_ERR\n") catch {}; // if we can, report the error
        //         continue :connected;
        //     };

        //     var i: usize = 0;
        //     while (i < len) : (i += 1) {
        //         if (buf[i] == '\n') {
        //             line.appendSlice(buf[0..i]) catch die("OOM", .{});
        //             line.clearRetainingCapacity(); // keep memory allocated for next line
        //         }
        //     }

        //     if (len < buf.len) {
        //         line.appendSlice(buf[0..i]) catch die("OOM", .{});
        //         if (line.items.len > 0) {
        //             log.debug("got line: {s}", .{line.items});
        //             daemonProcessLine(line.items, conn, &map, allocator);
        //         }

        //         // We finally finished! Stop reading.
        //         break :read;
        //     }
        // }
    }

    return 0;
}

const Client = struct {
    allocator: Allocator,
    socket_fd: std.fs.File,

    const Self = @This();
    const log = std.log.scoped(.client);

    pub fn init(addr: c.sockaddr_un, allocator: Allocator) Self {

        const s_fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (s_fd == -1) {
            die("failed to create socket: {?}", .{std.c.getErrno(-1)});
        }
        errdefer _ = c.close(s_fd);

        log.debug("server socket opened (fd: {})", .{s_fd});

        if (c.connect(s_fd, @ptrCast(*const c.sockaddr, &addr), @sizeOf(c.sockaddr_un)) == -1) {
            die("failed to connect", .{});
        }

        log.debug("succesfully connected", .{});

        return .{
            .allocator = allocator,
            .socket_fd = std.fs.File{ .handle = s_fd },
        };
    }

    pub fn deinit(self: *Self) void {
        self.socket_fd.close();
        self.* = undefined;
    }

    /// The returned memory should be freed
    pub fn sendAndReceive(self: *const Self, msg: []const u8) ?[]u8 {
        _ = blk: {
            const f = self.socket_fd;
            _ = f.writeAll(msg) catch |err| break :blk err;
            if (msg.len > 0 and msg[msg.len - 1] != '\n')
                _ = f.writeAll("\n") catch |err| break :blk err;
            _ = f.writeAll("end\n") catch |err| break :blk err;
        } catch |err| {
            log.err("failed to write: {}", .{err});
        };

        log.debug("sent message; reading", .{});

        const mem = self.socket_fd.reader().readAllAlloc(self.allocator, usize_max) catch |err| {
            log.err("failed to read: {}", .{err});
            return null;
        };

        log.debug("read response", .{});

        return mem;
    }

    pub fn sendReceiveAndParse(self: *const Self, msg: []const u8) u8 {
        var response = self.sendAndReceive(msg) orelse return 1;
        defer self.allocator.free(response);

        const stdout = std.io.getStdOut();

        var full_success = true;
        var it = std.mem.split(u8, response, "\n");
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "ok:")) {
                _ = stdout.write(line[3..]) catch return 1;
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
};

pub fn main() u8 {
    const log = std.log.scoped(.main);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const alloc = gpa.allocator();

    const default_s_path: [:0]const u8 = "/tmp/dotcfg.default.sock";
    const s_path = std.os.getenv("DOTCFG_SOCKET") orelse default_s_path;
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
        return daemonLoop(alloc, addr);
    } else if (eql(u8, action, "send")) {
        var client = Client.init(addr, alloc);
        defer client.deinit();

        var messages = std.ArrayList([]const u8).init(alloc);
        defer messages.deinit();

        while (args.next()) |msg| {
            messages.append(msg) catch die("OOM", .{});
        }

        var msg = std.mem.join(alloc, "\n", messages.items) catch die("OOM", .{});
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

        var input = in.reader().readAllAlloc(alloc, usize_max) catch die("OOM", .{});
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
