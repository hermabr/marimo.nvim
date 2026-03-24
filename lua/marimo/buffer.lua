local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local util = dofile(dir .. "/util.lua")
local markers = dofile(dir .. "/markers.lua")
local state = dofile(dir .. "/state.lua")
local worker = dofile(dir .. "/worker.lua")
local session = dofile(dir .. "/session.lua")
local render = dofile(dir .. "/render.lua")
local lsp_bridge = dofile(dir .. "/lsp_bridge.lua")
local navigation = dofile(dir .. "/navigation.lua")

local M = {}

local function is_file_buffer(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	return name ~= "" and vim.bo[bufnr].buftype == ""
end

local function stop_autorun_timer(bufnr)
	local timer = vim.b[bufnr].marimo_autorun_timer
	if timer then
		timer:stop()
		timer:close()
		vim.b[bufnr].marimo_autorun_timer = nil
	end
end

local function apply_runtime_payload(bufnr, payload)
	session.set_session(bufnr, payload)
	vim.b[bufnr].marimo_runtime_cells = {}
	for _, cell in ipairs(payload.cells or {}) do
		vim.b[bufnr].marimo_runtime_cells[cell.id] = cell.runtime or {}
	end
	render.render(bufnr, payload.cells)
end

local function apply_projection_payload(bufnr, payload, keep_modified)
	local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if vim.deep_equal(current, payload.projected_lines or {}) == false then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, payload.projected_lines or {})
	end
	apply_runtime_payload(bufnr, payload)
	lsp_bridge.sync_mirror(bufnr, payload.canonical_source)
	vim.bo[bufnr].modified = keep_modified and true or false
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
	stop_autorun_timer(bufnr)
	render.clear(bufnr)
	state.clear_projected_state(bufnr)
	vim.bo[bufnr].modified = false
	return true
end

local function open_with_worker(bufnr, input_kind, opts)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local keep_modified = vim.bo[bufnr].modified
	local payload, err = worker.request(filepath, "open_session", {
		path = filepath,
		content = util.join_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)),
		input_kind = input_kind,
	})
	if err then
		util.notify("failed to open marimo session: " .. err, vim.log.levels.ERROR)
		return false
	end
	apply_projection_payload(bufnr, payload, keep_modified)
	if opts.ensure_projected_buffer_setup then
		opts.ensure_projected_buffer_setup(bufnr)
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

	apply_projection_payload(bufnr, payload, false)
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
	util.show_write_message(bufnr)
end

function M.sync_buffer(bufnr, opts)
	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local method = opts.autorun == false and "sync_projection" or "sync_and_run"
	local payload, err = worker.request(filepath, method, {
		session_id = vim.b[bufnr].marimo_session_id,
		content = util.join_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)),
	})
	if err then
		util.notify("failed to sync marimo projection: " .. err, vim.log.levels.ERROR)
		return
	end
	if opts.generation and vim.b[bufnr].marimo_last_runtime_request_id ~= opts.generation then
		return
	end
	apply_projection_payload(bufnr, payload, true)
end

function M.schedule_sync(bufnr, opts)
	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	stop_autorun_timer(bufnr)
	vim.b[bufnr].marimo_last_runtime_request_id = (vim.b[bufnr].marimo_last_runtime_request_id or 0) + 1
	local generation = vim.b[bufnr].marimo_last_runtime_request_id
	local delay = opts.immediate and 0 or 300
	local timer = vim.uv.new_timer()
	vim.b[bufnr].marimo_autorun_timer = timer
	timer:start(delay, 0, function()
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end
			if vim.b[bufnr].marimo_last_runtime_request_id ~= generation then
				return
			end
			M.sync_buffer(bufnr, { generation = generation })
		end)
	end)
end

function M.run_all_cells(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	M.sync_buffer(bufnr, { autorun = false })
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local cell_ids = {}
	for _, cell in ipairs(vim.b[bufnr].marimo_cells or {}) do
		table.insert(cell_ids, cell.id)
	end
	local payload, err = worker.request(filepath, "run_cells", {
		session_id = vim.b[bufnr].marimo_session_id,
		cell_ids = cell_ids,
	})
	if err then
		util.notify("failed to run marimo cells: " .. err, vim.log.levels.ERROR)
		return
	end
	apply_runtime_payload(bufnr, payload)
end

function M.run_current_cell(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	M.sync_buffer(bufnr, { autorun = false })
	local cell = navigation.find_current_cell(bufnr)
	if not cell then
		util.notify("no current marimo cell", vim.log.levels.WARN)
		return
	end
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local payload, err = worker.request(filepath, "run_cells", {
		session_id = vim.b[bufnr].marimo_session_id,
		cell_ids = { cell.id },
	})
	if err then
		util.notify("failed to run marimo cell: " .. err, vim.log.levels.ERROR)
		return
	end
	apply_runtime_payload(bufnr, payload)
end

function M.interrupt(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local payload, err = worker.request(filepath, "interrupt", {
		session_id = vim.b[bufnr].marimo_session_id,
	})
	if err then
		util.notify("failed to interrupt marimo runtime: " .. err, vim.log.levels.ERROR)
		return
	end
	apply_runtime_payload(bufnr, payload)
end

function M.activate(bufnr, opts)
	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not state.is_enabled(bufnr) then
		util.notify("marimo mode is disabled for this buffer", vim.log.levels.WARN)
		return
	end
	if not is_file_buffer(bufnr) then
		util.notify("current buffer is not a file buffer", vim.log.levels.WARN)
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
		local ok, err = M.reload_raw_buffer(bufnr)
		if not ok then
			return ok, err
		end
		if session_id and filepath ~= "" then
			worker.request(filepath, "close_session", {
				session_id = session_id,
			})
		end
		return true
	end

	return true
end

return M
