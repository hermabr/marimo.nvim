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
- Adds buffer-local run keymaps for projected marimo buffers:
  `<leader>mr` runs the current cell, `<leader>mR` runs all cells, and
  `<leader>mi` interrupts the active runtime.
- Adds a buffer-local kernel restart keymap for projected marimo buffers:
  `<leader>mk` restarts the kernel after a confirmation prompt.
- Adds a buffer-local mode toggle for Python files:
  `<leader>mm` toggles marimo mode for the buffer.
- Adds a buffer-local formatting keymap for projected marimo buffers:
  `<leader>mf` formats the projected layout.
- Adds a buffer-local execution toggle:
  `<leader>ml` switches the current buffer between eager and lazy execution.
- Adds a buffer-local disabled toggle for the current cell:
  `<leader>md` toggles `marimo_disabled` on the current projected cell.
- Supports eager and lazy execution modes. Lazy mode keeps runtime execution on
  `:MarimoRunCell` and `:MarimoRunAll`, and marks changed or dependent cells as
  stale when you edit code.
- Automatically creates a new trailing `# +` cell when jumping past the last
  cell.

You can also use:

- `:MarimoCellPrev`
- `:MarimoCellNext`
- `:MarimoRunCell`
- `:MarimoRunAll`
- `:MarimoRestart`
- `:MarimoExecution [eager|lazy]`
- `:MarimoInterrupt`
- `:MarimoOutput`
- `:MarimoFormat`

The default keymaps can be changed or disabled in `setup`:

```lua
require("marimo").setup({
  execution = {
    mode = "eager", -- or "lazy"
  },
  runtime = {
    idle_timeout_ms = 30 * 60 * 1000, -- set to 0 to disable kernel sleep
  },
  keymaps = {
    mode_toggle = "<leader>mm",
    execution_toggle = "<leader>ml",
    prev_cell = "[m",
    next_cell = "]m",
    run_cell = "<leader>mr",
    run_all_cells = "<leader>mR",
    restart = "<leader>mk",
    interrupt = "<leader>mi",
    format = "<leader>mf",
    toggle_disabled = "<leader>md",
    show_output = "<leader>mo",
  },
})
```

`mode_toggle` is installed for Python files so you can promote a plain
`.py` file into a projected marimo buffer. The remaining keymaps are added
when marimo is active for the current buffer.

`execution.mode` sets the default for new buffers. You can switch the current
buffer at runtime with `<leader>ml` or `:MarimoExecution`. With no arguments,
`:MarimoExecution` toggles the current buffer between eager and lazy.

In lazy mode, edit-time sync still updates the projected buffer and stale
markers, but it does not queue runtime execution until you explicitly run a
cell or the whole notebook.

`runtime.idle_timeout_ms` controls how long an idle kernel process is kept
alive after its last command or runtime event. Sleeping keeps the projected
buffer and notebook session state in Neovim; the next runtime action starts a
fresh kernel and stale outputs are marked before new results arrive.

Projected marimo buffers show a small text-only floating indicator in the
top-right corner of the window:

- `marimo` while the current buffer is using its default execution mode
- `marimo (lazy)` if your default is eager and the current buffer has been switched to lazy
- `marimo (eager)` if your default is lazy and the current buffer has been switched back to eager

`<leader>mo` opens the current cell's output in a larger floating window you can scroll with normal motions. The float title shows the live runtime for a running cell, or how long it took after it finishes. If `snacks.image` is available, image outputs render there too.

## Test

Run:

```sh
nvim -u NONE --headless -l tests/run.lua
```
