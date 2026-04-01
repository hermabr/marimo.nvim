local M = {}
_G.__marimo_runtime_cells_by_bufnr = _G.__marimo_runtime_cells_by_bufnr or {}
local runtime_cells_by_bufnr = _G.__marimo_runtime_cells_by_bufnr

function M.set_session(bufnr, payload)
	vim.b[bufnr].marimo_projected = true
	vim.b[bufnr].marimo_session_id = payload.session_id
	vim.b[bufnr].marimo_project_root = payload.project_root
	vim.b[bufnr].marimo_runtime_kind = payload.runtime_kind
	vim.b[bufnr].marimo_header = payload.header
	vim.b[bufnr].marimo_app_options = payload.app_options or vim.empty_dict()
	vim.b[bufnr].marimo_cells = payload.cells or {}
	vim.b[bufnr].marimo_runtime_enabled = true
	runtime_cells_by_bufnr[bufnr] = {}
	vim.b[bufnr].marimo_projection_map = payload.projection_map or {}
	vim.b[bufnr].marimo_canonical_source = payload.canonical_source or ""
	vim.b[bufnr].marimo_last_saved_source_hash = payload.last_saved_source_hash
end

function M.set_runtime_cells(bufnr, runtime_cells)
	runtime_cells_by_bufnr[bufnr] = runtime_cells or {}
end

function M.get_runtime_cells(bufnr)
	return runtime_cells_by_bufnr[bufnr] or {}
end

function M.clear_session(bufnr)
	vim.b[bufnr].marimo_projected = false
	vim.b[bufnr].marimo_session_id = nil
	vim.b[bufnr].marimo_project_root = nil
	vim.b[bufnr].marimo_runtime_kind = nil
	vim.b[bufnr].marimo_header = nil
	vim.b[bufnr].marimo_app_options = nil
	vim.b[bufnr].marimo_cells = nil
	runtime_cells_by_bufnr[bufnr] = nil
	vim.b[bufnr].marimo_runtime_enabled = nil
	vim.b[bufnr].marimo_projection_map = nil
	vim.b[bufnr].marimo_canonical_source = nil
	vim.b[bufnr].marimo_last_saved_source_hash = nil
end

return M
