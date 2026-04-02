local M = {}

function M.set_session(bufnr, payload)
	local runtime_cells = vim.b[bufnr].marimo_runtime_cells or {}
	vim.b[bufnr].marimo_projected = true
	vim.b[bufnr].marimo_session_id = payload.session_id
	vim.b[bufnr].marimo_project_root = payload.project_root
	vim.b[bufnr].marimo_runtime_kind = payload.runtime_kind
	vim.b[bufnr].marimo_launch_cwd = payload.launch_cwd
	vim.b[bufnr].marimo_header = payload.header
	vim.b[bufnr].marimo_app_options = payload.app_options or vim.empty_dict()
	vim.b[bufnr].marimo_cells = payload.cells or {}
	vim.b[bufnr].marimo_runtime_enabled = payload.runtime_enabled == true
	vim.b[bufnr].marimo_runtime_cells = runtime_cells
	vim.b[bufnr].marimo_projection_map = payload.projection_map or {}
	vim.b[bufnr].marimo_canonical_source = payload.canonical_source or ""
	vim.b[bufnr].marimo_last_saved_source_hash = payload.last_saved_source_hash
end

function M.clear_session(bufnr)
	vim.b[bufnr].marimo_projected = false
	vim.b[bufnr].marimo_session_id = nil
	vim.b[bufnr].marimo_project_root = nil
	vim.b[bufnr].marimo_runtime_kind = nil
	vim.b[bufnr].marimo_launch_cwd = nil
	vim.b[bufnr].marimo_header = nil
	vim.b[bufnr].marimo_app_options = nil
	vim.b[bufnr].marimo_cells = nil
	vim.b[bufnr].marimo_runtime_cells = nil
	vim.b[bufnr].marimo_runtime_enabled = nil
	vim.b[bufnr].marimo_projection_map = nil
	vim.b[bufnr].marimo_canonical_source = nil
	vim.b[bufnr].marimo_last_saved_source_hash = nil
end

return M
