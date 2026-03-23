local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local util = dofile(dir .. "/util.lua")

local M = {}

function M.is_enabled(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if vim.b[bufnr].marimo_mode ~= nil then
		return vim.b[bufnr].marimo_mode ~= false
	end
	return vim.g.marimo_mode ~= false
end

function M.clear_projected_state(bufnr)
	vim.b[bufnr].marimo_projected = false
	vim.b[bufnr].marimo_header = nil
	vim.b[bufnr].marimo_app_options = nil
end

function M.mark_projected(bufnr, ensure_write_autocmd)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	vim.b[bufnr].marimo_projected = true
	vim.b[bufnr].marimo_header = vim.b[bufnr].marimo_header or nil
	vim.b[bufnr].marimo_app_options = util.as_json_object(vim.b[bufnr].marimo_app_options or {})
	ensure_write_autocmd(bufnr)
end

return M
