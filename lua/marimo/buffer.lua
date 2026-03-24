local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local util = dofile(dir .. "/util.lua")
local markers = dofile(dir .. "/markers.lua")
local state = dofile(dir .. "/state.lua")
local worker = dofile(dir .. "/worker.lua")
local session = dofile(dir .. "/session.lua")
local render = dofile(dir .. "/render.lua")
local lsp_bridge = dofile(dir .. "/lsp_bridge.lua")

local M = {}

local function is_file_buffer(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	return name ~= "" and vim.bo[bufnr].buftype == ""
end

function M.reload_raw_buffer(bufnr)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	if filepath == "" then
		return false, "current buffer has no file path"
	end
	if vim.bo[bufnr].modified then
		return false, "buffer has unsaved changes"
	end

	local raw_lines = vim.fn.readfile(filepath)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, raw_lines)
	render.clear(bufnr)
	state.clear_projected_state(bufnr)
	vim.bo[bufnr].modified = false
	return true
end

local function set_projected_buffer(bufnr, payload, keep_modified)
	local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if vim.deep_equal(current, payload.projected_lines or {}) == false then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, payload.projected_lines or {})
	end
	session.set_session(bufnr, payload)
	render.render(bufnr, payload.cells)
	lsp_bridge.sync_mirror(bufnr, payload.canonical_source)
	if not keep_modified then
		vim.bo[bufnr].modified = false
	end
end

local function open_with_worker(bufnr, input_kind, opts)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local payload, err = worker.request(filepath, "open_session", {
		path = filepath,
		content = util.join_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)),
		input_kind = input_kind,
	})
	if err then
		util.notify("failed to open marimo session: " .. err, vim.log.levels.ERROR)
		return false
	end
	set_projected_buffer(bufnr, payload, false)
	opts.ensure_write_autocmd(bufnr)
	if opts.ensure_sync_autocmd then
		opts.ensure_sync_autocmd(bufnr)
	end
	return true
end

function M.project_buffer(bufnr, opts)
	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not state.is_enabled(bufnr) then
		return
	end
	if vim.b[bufnr].marimo_projected then
		util.notify("already projected: " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:."))
		return
	end
	if not is_file_buffer(bufnr) then
		util.notify("current buffer is not a file buffer", vim.log.levels.WARN)
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not markers.looks_like_marimo(lines) then
		util.notify("no marimo notebook detected in " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:."), vim.log.levels.WARN)
		return
	end

	open_with_worker(bufnr, "raw_marimo", opts)
end

function M.write_buffer(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected then
		vim.cmd("write")
		return
	end

	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if markers.looks_like_marimo(lines) and not markers.looks_like_projected(lines) then
		vim.fn.writefile(lines, filepath)
		vim.bo[bufnr].modified = false
		vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
		util.show_write_message(bufnr)
		return
	end

	local payload, err = worker.request(filepath, "write_session", {
		session_id = vim.b[bufnr].marimo_session_id,
		content = util.join_lines(lines),
	})
	if err then
		util.notify("failed to write marimo notebook: " .. err, vim.log.levels.ERROR)
		return
	end

	set_projected_buffer(bufnr, payload, false)
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
	util.show_write_message(bufnr)
end

function M.sync_buffer(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local payload, err = worker.request(filepath, "sync_projection", {
		session_id = vim.b[bufnr].marimo_session_id,
		content = util.join_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)),
	})
	if err then
		util.notify("failed to sync marimo projection: " .. err, vim.log.levels.ERROR)
		return
	end
	set_projected_buffer(bufnr, payload, true)
end

function M.activate(bufnr, opts)
	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not state.is_enabled(bufnr) then
		util.notify("marimo mode is disabled for this buffer", vim.log.levels.WARN)
		return
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	if markers.looks_like_marimo(lines) then
		M.project_buffer(bufnr, opts)
		return
	end

	if markers.looks_like_projected(lines) then
		open_with_worker(bufnr, "projected", opts)
		return
	end

	if markers.has_any_projected_markers(lines) then
		if opts.manual then
			open_with_worker(bufnr, "generic_projected_promotable", opts)
		end
		return
	end

	if opts.manual then
		open_with_worker(bufnr, "manual_python", opts)
		return
	end

	util.notify("buffer is neither a real marimo notebook nor a projected `# +` notebook", vim.log.levels.WARN)
end

function M.set_mode(enabled, opts)
	opts = opts or {}
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	vim.b[bufnr].marimo_mode = enabled

	if enabled then
		M.activate(bufnr, opts)
		return true
	end

	if vim.b[bufnr].marimo_projected then
		local session_id = vim.b[bufnr].marimo_session_id
		local filepath = vim.api.nvim_buf_get_name(bufnr)
		if session_id and filepath ~= "" then
			worker.request(filepath, "close_session", {
				session_id = session_id,
			})
		end
		return M.reload_raw_buffer(bufnr)
	end

	return true
end

return M
