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
local runtime_state = {}

local function state_for(bufnr)
	runtime_state[bufnr] = runtime_state[bufnr] or {
		timer = nil,
		request_id = 0,
	}
	return runtime_state[bufnr]
end

local function is_file_buffer(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	return name ~= "" and vim.bo[bufnr].buftype == ""
end

local function stop_autorun_timer(bufnr)
	local entry = state_for(bufnr)
	local timer = entry.timer
	if timer then
		timer:stop()
		timer:close()
		entry.timer = nil
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

local function merge_runtime_cells(bufnr, runtime_cells)
	local cells = vim.b[bufnr].marimo_cells or {}
	local by_id = vim.b[bufnr].marimo_runtime_cells or {}
	for cell_id, runtime in pairs(runtime_cells or {}) do
		by_id[cell_id] = runtime
	end
	vim.b[bufnr].marimo_runtime_cells = by_id
	for _, cell in ipairs(cells) do
		if by_id[cell.id] ~= nil then
			cell.runtime = by_id[cell.id]
		end
	end
	render.render(bufnr, cells)
end

local function mark_cells_pending(bufnr, cell_ids)
	local current = vim.b[bufnr].marimo_runtime_cells or {}
	local updates = {}
	for _, cell_id in ipairs(cell_ids or {}) do
		local runtime = vim.deepcopy(current[cell_id] or {})
		runtime.status = runtime.status == "running" and "running" or "queued"
		runtime.stale_inputs = false
		runtime.output_kind = runtime.output_kind or "empty"
		runtime.output_lines = runtime.output_lines or {}
		runtime.console_lines = runtime.console_lines or {}
		updates[cell_id] = runtime
	end
	merge_runtime_cells(bufnr, updates)
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

local function handle_async_payload(bufnr, generation, keep_modified, payload, err)
	if err then
		util.notify(err, vim.log.levels.ERROR)
		return
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	if generation and state_for(bufnr).request_id ~= generation then
		return
	end
	apply_projection_payload(bufnr, payload, keep_modified)
end

local function handle_async_runtime_payload(bufnr, request_id, payload, err)
	if err then
		util.notify(err, vim.log.levels.ERROR)
		return
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	if request_id and state_for(bufnr).request_id ~= request_id then
		return
	end
	apply_runtime_payload(bufnr, payload)
end

local function handle_async_runtime_event(bufnr, request_id, event)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	if request_id and state_for(bufnr).request_id ~= request_id then
		return
	end
	if type(event) ~= "table" or event.event ~= "runtime_update" then
		return
	end
	local payload = event.payload or {}
	merge_runtime_cells(bufnr, payload.runtime_cells or {})
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
	runtime_state[bufnr] = nil
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

	local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
	worker.request_isolated_async(filepath, "write_projection", {
		path = filepath,
		content = util.join_lines(lines),
		header = vim.b[bufnr].marimo_header,
		app_options = vim.b[bufnr].marimo_app_options or vim.empty_dict(),
	}, function(payload, err)
		if err then
			util.notify("failed to write marimo notebook: " .. err, vim.log.levels.ERROR)
			return
		end
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		vim.b[bufnr].marimo_canonical_source = payload.canonical_source or vim.b[bufnr].marimo_canonical_source
		vim.b[bufnr].marimo_last_saved_source_hash = payload.last_saved_source_hash
		lsp_bridge.sync_mirror(bufnr, vim.b[bufnr].marimo_canonical_source)
		if vim.api.nvim_buf_get_changedtick(bufnr) == changedtick then
			vim.bo[bufnr].modified = false
		end
		vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
		util.show_write_message(bufnr)
	end)
end

function M.sync_buffer(bufnr, opts)
	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	local keep_modified = vim.bo[bufnr].modified
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
	if opts.generation and state_for(bufnr).request_id ~= opts.generation then
		return
	end
	apply_projection_payload(bufnr, payload, keep_modified)
end

function M.schedule_sync(bufnr, opts)
	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	stop_autorun_timer(bufnr)
	local entry = state_for(bufnr)
	entry.request_id = entry.request_id + 1
	local generation = entry.request_id
	local delay = opts.immediate and 0 or 300
	local timer = vim.uv.new_timer()
	entry.timer = timer
	timer:start(delay, 0, function()
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end
			if state_for(bufnr).request_id ~= generation then
				return
			end
			local keep_modified = vim.bo[bufnr].modified
			local filepath = vim.api.nvim_buf_get_name(bufnr)
			worker.request_async(filepath, "sync_and_run", {
				session_id = vim.b[bufnr].marimo_session_id,
				content = util.join_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)),
			}, function(payload, err)
				handle_async_payload(bufnr, generation, keep_modified, payload, err)
			end, function(event)
				handle_async_runtime_event(bufnr, generation, event)
			end)
		end)
	end)
end

function M.run_all_cells(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	M.sync_buffer(bufnr, { autorun = false })
	stop_autorun_timer(bufnr)
	local entry = state_for(bufnr)
	entry.request_id = entry.request_id + 1
	local request_id = entry.request_id
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local cell_ids = {}
	for _, cell in ipairs(vim.b[bufnr].marimo_cells or {}) do
		table.insert(cell_ids, cell.id)
	end
	mark_cells_pending(bufnr, cell_ids)
	worker.request_async(filepath, "run_cells", {
		session_id = vim.b[bufnr].marimo_session_id,
		cell_ids = cell_ids,
	}, function(payload, err)
		handle_async_runtime_payload(bufnr, request_id, payload, err)
	end, function(event)
		handle_async_runtime_event(bufnr, request_id, event)
	end)
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
	stop_autorun_timer(bufnr)
	local entry = state_for(bufnr)
	entry.request_id = entry.request_id + 1
	local request_id = entry.request_id
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	mark_cells_pending(bufnr, { cell.id })
	worker.request_async(filepath, "run_cells", {
		session_id = vim.b[bufnr].marimo_session_id,
		cell_ids = { cell.id },
	}, function(payload, err)
		handle_async_runtime_payload(bufnr, request_id, payload, err)
	end, function(event)
		handle_async_runtime_event(bufnr, request_id, event)
	end)
end

function M.interrupt(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	local entry = state_for(bufnr)
	entry.request_id = entry.request_id + 1
	local request_id = entry.request_id
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	worker.request_async(filepath, "interrupt", {
		session_id = vim.b[bufnr].marimo_session_id,
	}, function(payload, err)
		handle_async_runtime_payload(bufnr, request_id, payload, err)
	end)
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
		runtime_state[bufnr] = nil
		return true
	end

	return true
end

return M
