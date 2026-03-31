local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local util = dofile(dir .. "/util.lua")
local markers = dofile(dir .. "/markers.lua")
local state = dofile(dir .. "/state.lua")
local worker = dofile(dir .. "/worker.lua")
local session = dofile(dir .. "/session.lua")
local render = dofile(dir .. "/render.lua")
local output_window = dofile(dir .. "/output_window.lua")
local lsp_bridge = dofile(dir .. "/lsp_bridge.lua")
local navigation = dofile(dir .. "/navigation.lua")

local M = {}
local runtime_state = {}
local write_projection_async = worker.request_isolated_async
local close_session_async = function(filepath, session_id, callback)
	worker.request_async(filepath, "close_session", {
		session_id = session_id,
	}, callback or function() end)
end

local function state_for(bufnr)
	runtime_state[bufnr] = runtime_state[bufnr] or {
		timer = nil,
		request_id = 0,
		write_generation = 0,
		write_in_flight = nil,
		pending_write = nil,
	}
	return runtime_state[bufnr]
end

local function is_file_buffer(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	return name ~= "" and vim.bo[bufnr].buftype == ""
end

local function with_internal_buffer_update(bufnr, fn)
	vim.b[bufnr].marimo_internal_update = true
	local ok, result = pcall(fn)
	vim.b[bufnr].marimo_internal_update = false
	if not ok then
		error(result)
	end
	return result
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
	output_window.refresh(bufnr)
	util.request_redraw()
end

local function apply_current_projection_ranges(payload, lines)
	local ok, ranges_or_err = pcall(markers.projected_cell_ranges, lines)
	if not ok then
		return payload, ranges_or_err
	end
	local ranges = ranges_or_err
	for idx, cell in ipairs(payload.cells or {}) do
		cell.projection_range = ranges[idx] or cell.projection_range
	end
	for idx, cell in ipairs((payload.projection_map or {}).cells or {}) do
		cell.projection_range = ranges[idx] or cell.projection_range
	end
	return payload
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
	output_window.refresh(bufnr)
	util.request_redraw()
end

local function mark_cells_pending(bufnr, cell_ids)
	local current = vim.b[bufnr].marimo_runtime_cells or {}
	local updates = {}
	for _, cell_id in ipairs(cell_ids or {}) do
		local runtime = vim.deepcopy(current[cell_id] or {})
		runtime.status = runtime.status == "running" and "running" or "queued"
		runtime.stale_inputs = false
		runtime.output = runtime.output or nil
		runtime.console = runtime.console or {}
		updates[cell_id] = runtime
	end
	merge_runtime_cells(bufnr, updates)
end

local function update_cell_marker(bufnr, cell, mutate)
	local range = cell.projection_range or {}
	local marker_row = math.max((range.start_line or 1) - 1, 0)
	local marker_line = vim.api.nvim_buf_get_lines(bufnr, marker_row, marker_row + 1, false)[1]
	if not marker_line then
		return false, "no current marimo cell"
	end

	local ok, marker = markers.parse_marker_line(marker_line)
	if not ok then
		return false, "current cell marker is invalid"
	end

	local opts = markers.parse_options_text(marker)
	mutate(opts)
	local updated = "# +" .. markers.render_options(opts)
	if updated == marker_line then
		return true
	end

	with_internal_buffer_update(bufnr, function()
		vim.api.nvim_buf_set_lines(bufnr, marker_row, marker_row + 1, false, { updated })
	end)
	vim.bo[bufnr].modified = true
	return true
end


local function apply_projection_payload(bufnr, payload, keep_modified, opts)
	opts = opts or {}
	local update_buffer_lines = opts.update_buffer_lines ~= false
	local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local final_lines = current
	if update_buffer_lines and vim.deep_equal(current, payload.projected_lines or {}) == false then
		final_lines = payload.projected_lines or {}
		with_internal_buffer_update(bufnr, function()
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, final_lines)
		end)
	elseif update_buffer_lines then
		final_lines = payload.projected_lines or current
	end
	payload = apply_current_projection_ranges(payload, final_lines)
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
	apply_projection_payload(bufnr, payload, keep_modified, { update_buffer_lines = false })
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
	if type(event) ~= "table" then
		return
	end
	if event.event == "runtime_update" then
		local payload = event.payload or {}
		merge_runtime_cells(bufnr, payload.runtime_cells or {})
		return
	end
	if event.event == "session_update" then
		local payload = event.payload or {}
		apply_projection_payload(bufnr, payload, true, { update_buffer_lines = false })
	end
end

local function finish_projected_write(bufnr, request, payload, err)
	local entry = runtime_state[bufnr]
	if not entry then
		return
	end
	if entry.write_in_flight == request.generation then
		entry.write_in_flight = nil
	end
	if entry.pending_write then
		local next_request = entry.pending_write
		entry.pending_write = nil
		entry.write_in_flight = next_request.generation
		write_projection_async(next_request.filepath, "write_projection", next_request.params, function(next_payload, next_err)
			finish_projected_write(bufnr, next_request, next_payload, next_err)
		end)
	end
	if err then
		util.notify("failed to write marimo notebook: " .. err, vim.log.levels.ERROR)
		return
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	if entry.pending_write then
		return
	end
	vim.b[bufnr].marimo_canonical_source = payload.canonical_source or vim.b[bufnr].marimo_canonical_source
	vim.b[bufnr].marimo_last_saved_source_hash = payload.last_saved_source_hash
	lsp_bridge.sync_mirror(bufnr, vim.b[bufnr].marimo_canonical_source)
	if vim.api.nvim_buf_get_changedtick(bufnr) == request.changedtick then
		vim.bo[bufnr].modified = false
	end
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
	util.show_write_message(bufnr)
end

local function enqueue_projected_write(bufnr, filepath, lines)
	local entry = state_for(bufnr)
	entry.write_generation = entry.write_generation + 1
	local request = {
		generation = entry.write_generation,
		filepath = filepath,
		changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
		params = {
			path = filepath,
			content = util.join_lines(lines),
			header = vim.b[bufnr].marimo_header,
			app_options = vim.b[bufnr].marimo_app_options or vim.empty_dict(),
		},
	}
	if entry.write_in_flight then
		entry.pending_write = request
		return
	end
	entry.write_in_flight = request.generation
	write_projection_async(filepath, "write_projection", request.params, function(payload, err)
		finish_projected_write(bufnr, request, payload, err)
	end)
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
	output_window.close(bufnr)
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
	apply_projection_payload(bufnr, payload, keep_modified, {
		update_buffer_lines = input_kind ~= "projected",
	})
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
	if vim.api.nvim_buf_get_changedtick(bufnr) ~= changedtick then
		changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
	end
	enqueue_projected_write(bufnr, filepath, lines)
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
	apply_projection_payload(bufnr, payload, keep_modified, { update_buffer_lines = false })
end

function M.format_buffer(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not markers.has_any_projected_markers(lines) then
		return false, "current buffer is not a projected marimo buffer"
	end
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		local ok, normalized_or_err = pcall(markers.normalize_projected_buffer_lines, lines)
		if not ok then
			return false, normalized_or_err
		end
		if vim.deep_equal(lines, normalized_or_err) then
			return true
		end
		with_internal_buffer_update(bufnr, function()
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, normalized_or_err)
		end)
		vim.bo[bufnr].modified = true
		return true
	end
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local payload, err = worker.request(filepath, "sync_projection", {
		session_id = vim.b[bufnr].marimo_session_id,
		content = util.join_lines(lines),
	})
	if err then
		util.notify("failed to format marimo projection: " .. err, vim.log.levels.ERROR)
		return false, err
	end
	local changed = vim.deep_equal(lines, payload.projected_lines or {}) == false
	apply_projection_payload(bufnr, payload, vim.bo[bufnr].modified or changed, {
		update_buffer_lines = true,
	})
	return true
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

function M.toggle_current_cell_disabled(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end

	local cell = navigation.find_current_cell(bufnr)
	if not cell then
		util.notify("no current marimo cell", vim.log.levels.WARN)
		return
	end

	local ok, err = update_cell_marker(bufnr, cell, function(opts)
		opts.disabled = not (opts.disabled == true)
	end)
	if not ok then
		util.notify(err, vim.log.levels.WARN)
		return
	end

	M.sync_buffer(bufnr, { autorun = false })
end

function M.open_current_output(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	return output_window.open_current(bufnr)
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

function M.reconcile_buffer(bufnr, opts)
	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not state.is_enabled(bufnr) or not is_file_buffer(bufnr) then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if vim.b[bufnr].marimo_projected then
		if markers.looks_like_projected(lines) then
			if opts.ensure_projected_buffer_setup then
				opts.ensure_projected_buffer_setup(bufnr)
			end
			render.render(bufnr, vim.b[bufnr].marimo_cells or {})
			return
		end
		if markers.looks_like_marimo(lines) then
			local cells = vim.b[bufnr].marimo_cells or {}
			if vim.b[bufnr].marimo_session_id and #cells > 0 then
				local projected_lines = markers.render_projected_buffer_lines(cells)
				with_internal_buffer_update(bufnr, function()
					vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, projected_lines)
				end)
				if opts.ensure_projected_buffer_setup then
					opts.ensure_projected_buffer_setup(bufnr)
				end
				render.render(bufnr, cells)
				return
			end
			open_with_worker(bufnr, "raw_marimo", opts)
		end
		return
	end

	if markers.looks_like_marimo(lines) then
		M.project_buffer(bufnr, opts)
	end
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
		local ok, err = M.reload_raw_buffer(bufnr)
		if not ok then
			return ok, err
		end
		M.cleanup_buffer(bufnr)
		return true
	end

	return true
end

function M.cleanup_buffer(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local session_id = vim.b[bufnr].marimo_session_id
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	stop_autorun_timer(bufnr)
	runtime_state[bufnr] = nil
	if session_id and filepath ~= "" then
		close_session_async(filepath, session_id)
	end
	output_window.close(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		render.clear(bufnr)
		session.clear_session(bufnr)
	end
end

M._private = {
	set_write_projection_async = function(fn)
		write_projection_async = fn or worker.request_isolated_async
	end,
	set_close_session_async = function(fn)
		close_session_async = fn
			or function(filepath, session_id, callback)
				worker.request_async(filepath, "close_session", {
					session_id = session_id,
				}, callback or function() end)
			end
	end,
}

return M
