# neoclipboard

Hackable clipboard manager

## Goals

- Build easily extentdable and hackable clipboard manager
- Learn [Zig](https://ziglang.org)
- Do not overthink things, just make things work

## Features

- [ ] SQLite storage
- [ ] Clipboard transforms via [Lua](https://www.lua.org)
- [ ] Clipboard workflows. Example paste login and password
- [ ] CLI/TUI native. Usable with [neovim](https://neovim.io), [tmux](https://github.com/tmux/tmux) and [fzf](https://junegunn.github.io/fzf/)
- [ ] Application groups
- [ ] Native UX. Follow [ghostty](https://ghostty.org) example
- [ ] Secure storage
- [ ] Client/server architecture to allow usage over ssh

## Future

- Clipboard as service

## Running project

Zig version `0.15.1`

```console
$ zig build run
```
Or

```console
$ zig build
$ ./zig-out/bin/nclip
```
