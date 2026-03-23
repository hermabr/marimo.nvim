local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h")

vim.opt.rtp:prepend(root)
dofile(root .. "/tests/marimo_spec.lua")
