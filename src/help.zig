const std = @import("std");

pub fn helpAndExit() noreturn {
    const stderr = std.io.getStdErr().writer();
    _ = stderr.write(help_text) catch std.posix.exit(1);
    std.posix.exit(0);
}

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
    \\  command per line
    \\
    \\  help: show this message
    \\
    \\MESSAGES
    \\
    \\  To communicate with the daemon, the client uses messages, which are one-line strings with commands. They can
    \\  be of the following types:
    \\
    \\    set:<KEY>:<VALUE> to set a property
    \\    get:<KEY> to get a property's value
    \\
    \\    Characters not allowed for the key: ':', '\n'
    \\    Characters not allowed for the value: '\n'
    \\
    \\  Upon dealing with these commands, you can receive responses. The response for successful operations is
    \\  simply a line containing the option's value.
    \\
    \\  The following responses are error responses:
    \\
    \\    err:missing-command
    \\    err:missing-key
    \\    err:unknown-command
    \\    err:read-error
    \\
    \\  After outputting all responses, if at least one of them is an error, the program returns 1. If an invalid
    \\  response is detected, though, the program exits 1 immediately.
    \\
;
