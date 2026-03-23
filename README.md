# marimo.nvim

> This is pre-alpha. Expect breaking changes

Neovim support for working with marimo notebooks.

## Install

With `lazy.nvim`:

```lua
{
  "hermabr/marimo.nvim",
}
```

For local development:

```sh
MARIMO_NVIM_DEV_PATH=~/dev/marimo.nvim nvim
```

For an isolated Neovim instance that ignores `~/.config/nvim` and loads only the
local checkout of `marimo.nvim`:

With `lazy.nvim`:

```sh
./dev/minimal-nvim
```

Without `lazy.nvim`:

```sh
sh ./dev/minimal-nvim-nolazy
```

Both launchers set a separate `NVIM_APPNAME`, so they keep their state out of
your normal Neovim config.

## Test

Run:

```sh
nvim -u NONE --headless -l tests/run.lua
```
