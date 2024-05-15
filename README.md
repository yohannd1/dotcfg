# dotcfg

A small and fast configuration daemon for use with my
[dotfiles](https://github.com/YohananDiamond/dotfiles)

## build & requirements

- libc (POSIX-compatible, with unix domain sockets)
- zig 0.12.0

To build:

```bash
zig build
```

## usage

Usage example:

```bash
dotcfg daemon &
dotcfg send 'set:bemenu.font:Mononoki Normal 15'
dotcfg send 'get:bemenu.font' # Mononoki Normal 15

dotcfg stdin-send <<EOF
set:dummy:aargh
get:dummy
EOF
# will output "aargh"
```

Here is an excerpt from the output of `dotcfg help`:

```
$ dotcfg help
Usage: dotcfg { daemon | send [MESSAGES...] | stdin-send | help }

COMMANDS

  daemon: starts the daemon, taking into account the DOTCFG_SOCKET path.

  send: send one message per argument

  help: show this message

MESSAGES

  When communicating with the daemon, you send messages. They can be:

  set:<KEY>:<VALUE> to set a property
    (note that key CANNOT have any commas, but the value can)

  get:<KEY> to get a property's value
    (key SHOULD not have any commas)

  Upon dealing with these commands, you can receive responses.

  Successful operations internally return "ok:" but that is stripped out for
  convenience.

  The following responses are error responses:

  err:missing-command
  err:missing-key
  err:unknown-command
  err:read-error

  If at least one of the responses is an error, the program exits 1 after
  printing all responses. If an invalid response is detected, the program
  exits 1 immediately.
```

## to do

* [ ] Reorganize the file (the code is spaghetti rn)
