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

## Features

- Projects marimo notebooks into `# +` cells for editing.
- Normalizes projected buffers so marker spacing stays stable and consecutive
  empty cells collapse to a single empty cell.
- Adds buffer-local cell navigation for projected marimo buffers:
  ` [m` jumps to the previous cell and `]m` jumps to the next cell.
- Adds a buffer-local disabled toggle for the current cell:
  `<leader>md` toggles `marimo_disabled` on the current projected cell.
- Automatically creates a new trailing `# +` cell when jumping past the last
  cell.

You can also use:

- `:MarimoCellPrev`
- `:MarimoCellNext`
- `:MarimoOutput`
- `:MarimoFormat`

The default keymaps can be changed or disabled in `setup`:

```lua
require("marimo").setup({
  keymaps = {
    prev_cell = "[m",
    next_cell = "]m",
    toggle_disabled = "<leader>md",
    show_output = "<leader>mo",
  },
})
```

`<leader>mo` opens the current cell's output in a larger floating window you can scroll with normal motions. If `snacks.image` is available, image outputs render there too.

## Test

Run:

```sh
nvim -u NONE --headless -l tests/run.lua
```
