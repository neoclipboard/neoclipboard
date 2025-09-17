# neoclipboard

Hackable clipboard manager

## Goals

- Build easily extentdable and hackable clipboard manager
- Learn [Zig](https://ziglang.org)
- Do not overthink things, just make things work
- Focus on improving own existing workflows

## Features

- [x] SQLite storage
- [x] [XDG](https://specifications.freedesktop.org/basedir-spec/latest/) support for storing configs
- [x] Clipboard transforms via [Lua](https://www.lua.org)
- [ ] Clipboard workflows. Example paste login and password
- [x] CLI/TUI native. Usable with [neovim](https://neovim.io), [tmux](https://github.com/tmux/tmux) and [fzf](https://junegunn.github.io/fzf/)
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

## TODO

...

## Configure with vim and tmux

Update `init.lua`:

```lua
vim.g.clipboard = {
    name = 'nclip',
    copy = {
        ["*"] = {'nclip', 'copy', '-'},
    },
    paste = {
        ["*"] = {'nclip', 'paste', '-h'},
    },
}
```

Update `tmux.conf`:

```tmux
bind-key -T copy-mode-vi Y send-keys -X copy-pipe "nclip copy -"
bind-key -T copy-mode-vi M-Y send-keys -X copy-pipe-and-cancel "nclip copy -"
bind-key P run-shell "nclip paste -h | tmux load-buffer - && tmux paste-buffer"
bind-key Y run-shell "tmux save-buffer - | nclip copy -"
```

## Usage

```console
nclip copy:
    -: accept stdin
    -t {transform}: transform before copy. {transform} is a function name from your `init.lua`.
    file_name: copy file
nclip paste:
    -o: Output clipboard (bypass storage)
    -h: Output last clipboard from storage
    -t {transform}: transform on paste. {transform} is a function name from your `init.lua`.
nclip list: List clipboards from storage (NUL terminated for fzf usage)
```

List from storage with fzf

```console
$ nclip list | fzf --read0
```

### Lua tranforms

```console
$ mkdir -p ~/.config/nclip/lua/
$ touch ~/.config/nclip/lua/init.lua
echo "
```

Update `~/.config/nclip/lua/init.lua`:

```lua
package.path = package.path .. ";~/.config/nclip/lua/?.lua"

function upper(input)
   return string.upper(input)
end

function trim(input)
   return input:gsub("%s+", "")
end

function trim_upper(input)
   return trim(upper(input))
end
```
