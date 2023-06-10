# dotcfg

A small configuration daemon for use with my
[dotfiles](https://github.com/YohananDiamond/dotfiles)

Dependencies: zig, libc (with unix domain sockets)

I'm too lazy to write a proper help right now so check out `showHelp()`
on the code or run `dotcfg help` on the executable.

Usage examples:

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
