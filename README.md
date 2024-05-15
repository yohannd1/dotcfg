# dotcfg

A small configuration daemon for use with my
[dotfiles](https://github.com/YohananDiamond/dotfiles)

## build & requirements

- libc (POSIX-compatible, with unix domain sockets)
- zig 0.12.0

To build:

```bash
zig build
```

## usage

A proper help is on the way. Just a moment.

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

## to do

* [ ] Write a help file
* [ ] Reorganize the file (the code is spaghetti rn)
