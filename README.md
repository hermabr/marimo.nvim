# marimo.nvim

Neovim support for working with marimo notebooks as projected `# +` buffers.

## Install

With `lazy.nvim`:

```lua
{
  "hermabr/marimo.nvim",
  config = function()
    require("hermabr.marimo_nvim").setup()
  end,
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
