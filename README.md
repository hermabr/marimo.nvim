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

## Test

Run:

```sh
nvim -u NONE --headless -l tests/run.lua
```
