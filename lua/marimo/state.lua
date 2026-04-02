local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local util = dofile(dir .. "/util.lua")

local M = {}
local execution_modes = {
	eager = true,
	lazy = true,
}

function M.is_enabled(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if vim.b[bufnr].marimo_mode ~= nil then
		return vim.b[bufnr].marimo_mode ~= false
	end
	return vim.g.marimo_mode ~= false
end

function M.execution_mode(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local buffer_mode = vim.b[bufnr].marimo_execution_mode
	if type(buffer_mode) == "string" and execution_modes[buffer_mode] then
		return buffer_mode
	end
	local global_mode = vim.g.marimo_execution_mode
	if type(global_mode) == "string" and execution_modes[global_mode] then
		return global_mode
	end
	return "eager"
end

function M.is_lazy_execution(bufnr)
	return M.execution_mode(bufnr) == "lazy"
end

function M.set_execution_mode(mode, bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if type(mode) ~= "string" or not execution_modes[mode] then
		return false, "execution mode must be 'eager' or 'lazy'"
	end
	vim.b[bufnr].marimo_execution_mode = mode
	return true, mode
end

function M.toggle_execution_mode(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local next_mode = M.is_lazy_execution(bufnr) and "eager" or "lazy"
	return M.set_execution_mode(next_mode, bufnr)
end

function M.clear_projected_state(bufnr)
	vim.b[bufnr].marimo_projected = false
	vim.b[bufnr].marimo_session_id = nil
	vim.b[bufnr].marimo_project_root = nil
	vim.b[bufnr].marimo_runtime_kind = nil
	vim.b[bufnr].marimo_header = nil
	vim.b[bufnr].marimo_app_options = nil
	vim.b[bufnr].marimo_cells = nil
	vim.b[bufnr].marimo_runtime_cells = nil
	vim.b[bufnr].marimo_runtime_enabled = nil
	vim.b[bufnr].marimo_projection_map = nil
	vim.b[bufnr].marimo_canonical_source = nil
	vim.b[bufnr].marimo_last_saved_source_hash = nil
end

function M.mark_projected(bufnr, ensure_projected_buffer_setup)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	vim.b[bufnr].marimo_projected = true
	vim.b[bufnr].marimo_header = vim.b[bufnr].marimo_header or nil
	vim.b[bufnr].marimo_app_options = util.as_json_object(vim.b[bufnr].marimo_app_options or {})
	ensure_projected_buffer_setup(bufnr)
end

return M
