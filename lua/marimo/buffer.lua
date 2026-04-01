local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local util = dofile(dir .. "/util.lua")
local markers = dofile(dir .. "/markers.lua")
local snapshot_state = dofile(dir .. "/snapshot.lua")
local runtime = dofile(dir .. "/runtime.lua")
local state = dofile(dir .. "/state.lua")
local worker = dofile(dir .. "/worker.lua")
local session = dofile(dir .. "/session.lua")
local render = dofile(dir .. "/render.lua")
local output_window = dofile(dir .. "/output_window.lua")
local lsp_bridge = dofile(dir .. "/lsp_bridge.lua")
local navigation = dofile(dir .. "/navigation.lua")

local M = {}

local runtime_state = {}
local serialize_notebook_async = worker.request_isolated_async
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
	if entry.timer then
		entry.timer:stop()
		entry.timer:close()
		entry.timer = nil
	end
end

local function runtime_started(bufnr)
	return vim.b[bufnr].marimo_runtime_enabled == true
end

local function runtime_metadata(bufnr)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local project_root = vim.b[bufnr].marimo_project_root
	local runtime_kind = vim.b[bufnr].marimo_runtime_kind
	if project_root and runtime_kind then
		return project_root, runtime_kind
	end
	return worker.resolve_runtime(filepath)
end

local function refresh_cells(bufnr)
	local runtime_cells = vim.b[bufnr].marimo_runtime_cells or {}
	local current_cells = vim.b[bufnr].marimo_cells or {}
	vim.b[bufnr].marimo_cells = runtime.attach_runtime(current_cells, runtime_cells)
	render.render(bufnr, vim.b[bufnr].marimo_cells)
	output_window.refresh(bufnr)
	util.request_redraw()
end

local function apply_snapshot(bufnr, snapshot, canonical_source, keep_modified, opts)
	opts = opts or {}
	local projected_lines = opts.projected_lines or snapshot_state.projected_lines_for_snapshot(snapshot)
	local update_buffer_lines = opts.update_buffer_lines ~= false
	if update_buffer_lines then
		snapshot_state.attach_projected_ranges(snapshot, projected_lines)
	end
	if update_buffer_lines then
		local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		if not vim.deep_equal(current, projected_lines) then
			with_internal_buffer_update(bufnr, function()
				vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, projected_lines)
			end)
		end
	end

	local runtime_cells = runtime.filter_runtime(vim.b[bufnr].marimo_runtime_cells or {}, snapshot.cells or {})
	local payload = vim.deepcopy(snapshot)
	payload.runtime_enabled = runtime_started(bufnr)
	payload.projection_map = snapshot_state.projection_map(payload)
	payload.canonical_source = canonical_source
	payload.last_saved_source_hash = opts.last_saved_source_hash or vim.b[bufnr].marimo_last_saved_source_hash
	vim.b[bufnr].marimo_runtime_cells = runtime_cells
	payload.cells = runtime.attach_runtime(payload.cells or {}, runtime_cells)
	session.set_session(bufnr, payload)
	lsp_bridge.sync_mirror(bufnr, canonical_source)
	vim.bo[bufnr].modified = keep_modified and true or false
	refresh_cells(bufnr)
end

local function serialize_snapshot(bufnr, snapshot)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local result, err = worker.request(filepath, "serialize_notebook", {
		snapshot = snapshot,
	})
	if err then
		return nil, err
	end
	return result, nil
end

local function sync_local_snapshot(bufnr, snapshot, projected_lines, keep_modified, opts)
	local serialized, err = serialize_snapshot(bufnr, snapshot)
	if err then
		return nil, nil, err
	end
	snapshot_state.attach_canonical_ranges(snapshot, serialized.canonical_ranges or {})
	apply_snapshot(bufnr, snapshot, serialized.canonical_source, keep_modified, {
		update_buffer_lines = opts and opts.update_buffer_lines,
		projected_lines = projected_lines,
	})
	return snapshot, serialized, nil
end

local function current_snapshot_from_buffer(bufnr)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local project_root, runtime_kind = runtime_metadata(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local ok, snapshot, projected_lines = pcall(snapshot_state.snapshot_from_projected_lines, {
		session_id = vim.b[bufnr].marimo_session_id or filepath,
		path = filepath,
		project_root = project_root,
		runtime_kind = runtime_kind,
		header = vim.b[bufnr].marimo_header,
		app_options = vim.b[bufnr].marimo_app_options or {},
		previous_cells = vim.b[bufnr].marimo_cells,
		lines = lines,
	})
	if not ok then
		return nil, nil, snapshot
	end
	return snapshot, projected_lines, nil
end

local function ensure_runtime_session(bufnr, snapshot)
	if runtime_started(bufnr) then
		return true
	end
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local _, err = worker.request(filepath, "ensure_session", {
		snapshot = snapshot,
	})
	if err then
		return false, err
	end
	vim.b[bufnr].marimo_runtime_enabled = true
	return true
end

local function mark_cells_pending(bufnr, cell_ids)
	local runtime_cells = vim.b[bufnr].marimo_runtime_cells or {}
	for _, cell_id in ipairs(cell_ids or {}) do
		local next_runtime = vim.deepcopy(runtime_cells[cell_id] or {})
		next_runtime.status = next_runtime.status == "running" and "running" or "queued"
		next_runtime.stale_inputs = false
		next_runtime.output = next_runtime.output or nil
		next_runtime.console = next_runtime.console or {}
		runtime_cells[cell_id] = next_runtime
	end
	vim.b[bufnr].marimo_runtime_cells = runtime_cells
	refresh_cells(bufnr)
end

local function handle_async_result(bufnr, request_id, payload, err)
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
	if payload and payload.session_id then
		vim.b[bufnr].marimo_runtime_enabled = true
	end
end

local function handle_async_runtime_event(bufnr, request_id, event)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	if request_id and state_for(bufnr).request_id ~= request_id then
		return
	end
	if type(event) ~= "table" or event.event ~= "operation" then
		return
	end
	local runtime_cells, changed = runtime.apply_operation(vim.b[bufnr].marimo_runtime_cells or {}, event.operation)
	if not changed then
		return
	end
	vim.b[bufnr].marimo_runtime_cells = runtime_cells
	refresh_cells(bufnr)
end

local function clear_running_runtime_state(bufnr)
	local runtime_cells, changed = runtime.apply_operation(vim.b[bufnr].marimo_runtime_cells or {}, {
		op = "interrupted",
	})
	if not changed then
		return
	end
	vim.b[bufnr].marimo_runtime_cells = runtime_cells
	refresh_cells(bufnr)
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
		serialize_notebook_async(next_request.filepath, "serialize_notebook", next_request.params, function(next_payload, next_err)
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
	local canonical_source = payload.canonical_source
	vim.fn.writefile(util.split_lines(canonical_source), request.filepath)
	local last_saved_source_hash = vim.fn.sha256(canonical_source)
	if vim.api.nvim_buf_get_changedtick(bufnr) == request.changedtick then
		snapshot_state.attach_canonical_ranges(request.snapshot, payload.canonical_ranges or {})
		apply_snapshot(bufnr, request.snapshot, canonical_source, false, {
			update_buffer_lines = false,
			last_saved_source_hash = last_saved_source_hash,
		})
	else
		vim.b[bufnr].marimo_canonical_source = canonical_source
		vim.b[bufnr].marimo_last_saved_source_hash = last_saved_source_hash
		lsp_bridge.sync_mirror(bufnr, canonical_source)
	end
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
	util.show_write_message(bufnr)
end

local function enqueue_projected_write(bufnr, filepath, snapshot)
	local entry = state_for(bufnr)
	entry.write_generation = entry.write_generation + 1
	local request = {
		generation = entry.write_generation,
		filepath = filepath,
		changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
		snapshot = vim.deepcopy(snapshot),
		params = {
			snapshot = snapshot,
		},
	}
	if entry.write_in_flight then
		entry.pending_write = request
		return
	end
	entry.write_in_flight = request.generation
	serialize_notebook_async(filepath, "serialize_notebook", request.params, function(payload, err)
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

local function open_raw_notebook(bufnr, opts)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local keep_modified = vim.bo[bufnr].modified
	local loaded, err = worker.request(filepath, "load_raw_notebook", {
		path = filepath,
		content = util.join_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)),
	})
	if err then
		util.notify("failed to open marimo notebook: " .. err, vim.log.levels.ERROR)
		return false
	end
	local snapshot, projected_lines = snapshot_state.snapshot_from_loaded_raw(loaded)
	local synced_snapshot, _, sync_err = sync_local_snapshot(bufnr, snapshot, projected_lines, keep_modified, {
		update_buffer_lines = true,
	})
	if sync_err then
		util.notify("failed to open marimo notebook: " .. sync_err, vim.log.levels.ERROR)
		return false
	end
	if opts.ensure_projected_buffer_setup then
		opts.ensure_projected_buffer_setup(bufnr)
	end
	vim.b[bufnr].marimo_cells = synced_snapshot.cells
	return true
end

local function open_local_snapshot(bufnr, snapshot, projected_lines, opts)
	local keep_modified = vim.bo[bufnr].modified
	local synced_snapshot, _, err = sync_local_snapshot(bufnr, snapshot, projected_lines, keep_modified, {
		update_buffer_lines = opts.update_buffer_lines == true,
	})
	if err then
		util.notify("failed to open marimo notebook: " .. err, vim.log.levels.ERROR)
		return false
	end
	if opts.ensure_projected_buffer_setup then
		opts.ensure_projected_buffer_setup(bufnr)
	end
	vim.b[bufnr].marimo_cells = synced_snapshot.cells
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
	open_raw_notebook(bufnr, opts)
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

	local snapshot, _, err = current_snapshot_from_buffer(bufnr)
	if err then
		util.notify(err, vim.log.levels.ERROR)
		return
	end
	enqueue_projected_write(bufnr, filepath, snapshot)
end

function M.sync_buffer(bufnr, opts)
	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	local previous_cells = vim.deepcopy(vim.b[bufnr].marimo_cells or {})
	local keep_modified = vim.bo[bufnr].modified
	local snapshot, projected_lines, snapshot_err = current_snapshot_from_buffer(bufnr)
	if snapshot_err then
		util.notify("failed to sync marimo notebook: " .. snapshot_err, vim.log.levels.ERROR)
		return
	end
	local changed_ids, deleted_ids = snapshot_state.compute_changes(previous_cells, snapshot.cells)
	local synced_snapshot, _, err = sync_local_snapshot(bufnr, snapshot, projected_lines, keep_modified, {
		update_buffer_lines = false,
	})
	if err then
		util.notify("failed to sync marimo notebook: " .. err, vim.log.levels.ERROR)
		return
	end
	local should_autorun = opts.autorun ~= false
	if not runtime_started(bufnr) and not opts.start_runtime and not should_autorun then
		return synced_snapshot, changed_ids, deleted_ids
	end
	if not runtime_started(bufnr) then
		local ok, ensure_err = ensure_runtime_session(bufnr, synced_snapshot)
		if not ok then
			util.notify("failed to start marimo runtime: " .. ensure_err, vim.log.levels.ERROR)
			return
		end
	end
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local run_ids = {}
	if should_autorun then
		for _, cell in ipairs(synced_snapshot.cells) do
			if vim.tbl_contains(changed_ids, cell.id) and not (cell.options or {}).disabled then
				table.insert(run_ids, cell.id)
			end
		end
	end
	local _, runtime_err = worker.request(filepath, "sync_notebook", {
		snapshot = synced_snapshot,
		run_ids = run_ids,
		delete_ids = deleted_ids,
	})
	if runtime_err then
		util.notify("failed to sync marimo runtime: " .. runtime_err, vim.log.levels.ERROR)
		return
	end
	vim.b[bufnr].marimo_runtime_enabled = true
	return synced_snapshot, changed_ids, deleted_ids
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
	local snapshot, projected_lines, snapshot_err = current_snapshot_from_buffer(bufnr)
	if snapshot_err then
		util.notify("failed to format marimo notebook: " .. snapshot_err, vim.log.levels.ERROR)
		return false, snapshot_err
	end
	local previous_cells = vim.deepcopy(vim.b[bufnr].marimo_cells or {})
	local changed_ids, deleted_ids = snapshot_state.compute_changes(previous_cells, snapshot.cells)
	local _, _, err = sync_local_snapshot(bufnr, snapshot, projected_lines, vim.bo[bufnr].modified, {
		update_buffer_lines = true,
	})
	if err then
		util.notify("failed to format marimo notebook: " .. err, vim.log.levels.ERROR)
		return false, err
	end
	if runtime_started(bufnr) then
		local filepath = vim.api.nvim_buf_get_name(bufnr)
		local _, runtime_err = worker.request(filepath, "sync_notebook", {
			snapshot = snapshot,
			run_ids = {},
			delete_ids = deleted_ids,
		})
		if runtime_err then
			util.notify("failed to sync marimo runtime: " .. runtime_err, vim.log.levels.ERROR)
			return false, runtime_err
		end
	end
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
	local request_id = entry.request_id
	local delay = opts.immediate and 0 or 300
	local timer = vim.uv.new_timer()
	entry.timer = timer
	timer:start(delay, 0, function()
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end
			if state_for(bufnr).request_id ~= request_id then
				return
			end
			local previous_cells = vim.deepcopy(vim.b[bufnr].marimo_cells or {})
			local keep_modified = vim.bo[bufnr].modified
			local snapshot, projected_lines, snapshot_err = current_snapshot_from_buffer(bufnr)
			if snapshot_err then
				util.notify("failed to sync marimo notebook: " .. snapshot_err, vim.log.levels.ERROR)
				return
			end
			local changed_ids, deleted_ids = snapshot_state.compute_changes(previous_cells, snapshot.cells)
			local synced_snapshot, _, err = sync_local_snapshot(bufnr, snapshot, projected_lines, keep_modified, {
				update_buffer_lines = false,
			})
			if err then
				util.notify("failed to sync marimo notebook: " .. err, vim.log.levels.ERROR)
				return
			end
			local run_ids = {}
			for _, cell in ipairs(synced_snapshot.cells) do
				if vim.tbl_contains(changed_ids, cell.id) and not (cell.options or {}).disabled then
					table.insert(run_ids, cell.id)
				end
			end
			if #run_ids == 0 and #deleted_ids == 0 and not runtime_started(bufnr) then
				return
			end
			mark_cells_pending(bufnr, run_ids)
			local filepath = vim.api.nvim_buf_get_name(bufnr)
			worker.request_async(filepath, "sync_notebook", {
				snapshot = synced_snapshot,
				run_ids = run_ids,
				delete_ids = deleted_ids,
			}, function(payload, request_err)
				handle_async_result(bufnr, request_id, payload, request_err)
			end, function(event)
				handle_async_runtime_event(bufnr, request_id, event)
			end)
		end)
	end)
end

function M.run_all_cells(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	local synced_snapshot = M.sync_buffer(bufnr, { autorun = false })
	if type(synced_snapshot) ~= "table" then
		synced_snapshot = vim.tbl_deep_extend("force", {}, {
			session_id = vim.b[bufnr].marimo_session_id,
			path = vim.api.nvim_buf_get_name(bufnr),
			project_root = vim.b[bufnr].marimo_project_root,
			runtime_kind = vim.b[bufnr].marimo_runtime_kind,
			header = vim.b[bufnr].marimo_header,
			app_options = vim.b[bufnr].marimo_app_options or {},
			cells = vim.b[bufnr].marimo_cells or {},
		})
	end
	local ok, err = ensure_runtime_session(bufnr, synced_snapshot)
	if not ok then
		util.notify("failed to start marimo runtime: " .. err, vim.log.levels.ERROR)
		return
	end
	stop_autorun_timer(bufnr)
	local entry = state_for(bufnr)
	entry.request_id = entry.request_id + 1
	local request_id = entry.request_id
	local cell_ids = {}
	local codes = {}
	for _, cell in ipairs(vim.b[bufnr].marimo_cells or {}) do
		table.insert(cell_ids, cell.id)
		table.insert(codes, cell.code)
	end
	mark_cells_pending(bufnr, cell_ids)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	worker.request_async(filepath, "run_cells", {
		session_id = vim.b[bufnr].marimo_session_id,
		cell_ids = cell_ids,
		codes = codes,
	}, function(payload, request_err)
		handle_async_result(bufnr, request_id, payload, request_err)
	end, function(event)
		handle_async_runtime_event(bufnr, request_id, event)
	end)
end

function M.run_current_cell(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	local synced_snapshot = M.sync_buffer(bufnr, { autorun = false })
	local cell = navigation.find_current_cell(bufnr)
	if not cell then
		util.notify("no current marimo cell", vim.log.levels.WARN)
		return
	end
	local ok, err = ensure_runtime_session(bufnr, synced_snapshot or {
		session_id = vim.b[bufnr].marimo_session_id,
		path = vim.api.nvim_buf_get_name(bufnr),
		project_root = vim.b[bufnr].marimo_project_root,
		runtime_kind = vim.b[bufnr].marimo_runtime_kind,
		header = vim.b[bufnr].marimo_header,
		app_options = vim.b[bufnr].marimo_app_options or {},
		cells = vim.b[bufnr].marimo_cells or {},
	})
	if not ok then
		util.notify("failed to start marimo runtime: " .. err, vim.log.levels.ERROR)
		return
	end
	stop_autorun_timer(bufnr)
	local entry = state_for(bufnr)
	entry.request_id = entry.request_id + 1
	local request_id = entry.request_id
	mark_cells_pending(bufnr, { cell.id })
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	worker.request_async(filepath, "run_cells", {
		session_id = vim.b[bufnr].marimo_session_id,
		cell_ids = { cell.id },
		codes = { cell.code },
	}, function(payload, request_err)
		handle_async_result(bufnr, request_id, payload, request_err)
	end, function(event)
		handle_async_runtime_event(bufnr, request_id, event)
	end)
end

function M.interrupt(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id or not runtime_started(bufnr) then
		return
	end
	local entry = state_for(bufnr)
	entry.request_id = entry.request_id + 1
	local request_id = entry.request_id
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	worker.request_async(filepath, "interrupt", {
		session_id = vim.b[bufnr].marimo_session_id,
	}, function(payload, request_err)
		if not request_err then
			clear_running_runtime_state(bufnr)
		end
		handle_async_result(bufnr, request_id, payload, request_err)
	end, function(event)
		handle_async_runtime_event(bufnr, request_id, event)
	end)
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
	M.sync_buffer(bufnr, { autorun = false, start_runtime = true })
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
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local project_root, runtime_kind = runtime_metadata(bufnr)
	if markers.looks_like_marimo(lines) then
		M.project_buffer(bufnr, opts)
		return
	end
	if markers.looks_like_projected(lines) then
		local ok, snapshot, projected_lines = pcall(snapshot_state.snapshot_from_projected_lines, {
			session_id = filepath,
			path = filepath,
			project_root = project_root,
			runtime_kind = runtime_kind,
			header = nil,
			app_options = vim.empty_dict(),
			previous_cells = nil,
			lines = lines,
		})
		if not ok then
			util.notify(snapshot, vim.log.levels.WARN)
			return
		end
		open_local_snapshot(bufnr, snapshot, projected_lines, vim.tbl_extend("force", opts, {
			update_buffer_lines = false,
		}))
		return
	end
	if markers.has_any_projected_markers(lines) then
		if opts.manual then
			local promoted, changed = markers.promote_first_marker_to_marimo(lines)
			if not changed then
				util.notify("buffer is neither a real marimo notebook nor a projected `# +` notebook", vim.log.levels.WARN)
				return
			end
			local ok, snapshot, projected_lines = pcall(snapshot_state.snapshot_from_projected_lines, {
				session_id = filepath,
				path = filepath,
				project_root = project_root,
				runtime_kind = runtime_kind,
				header = nil,
				app_options = vim.empty_dict(),
				previous_cells = nil,
				lines = promoted,
			})
			if not ok then
				util.notify(snapshot, vim.log.levels.WARN)
				return
			end
			open_local_snapshot(bufnr, snapshot, projected_lines, vim.tbl_extend("force", opts, {
				update_buffer_lines = true,
			}))
		end
		return
	end
	if opts.manual then
		local ok, snapshot, projected_lines = pcall(snapshot_state.snapshot_from_manual_python, {
			session_id = filepath,
			path = filepath,
			project_root = project_root,
			runtime_kind = runtime_kind,
			previous_cells = nil,
			lines = lines,
		})
		if not ok then
			util.notify(snapshot, vim.log.levels.WARN)
			return
		end
		open_local_snapshot(bufnr, snapshot, projected_lines, vim.tbl_extend("force", opts, {
			update_buffer_lines = true,
		}))
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
			refresh_cells(bufnr)
			return
		end
		if markers.looks_like_marimo(lines) then
			local cells = vim.b[bufnr].marimo_cells or {}
			if #cells > 0 then
				local projected_lines = markers.render_projected_buffer_lines(cells)
				with_internal_buffer_update(bufnr, function()
					vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, projected_lines)
				end)
				if opts.ensure_projected_buffer_setup then
					opts.ensure_projected_buffer_setup(bufnr)
				end
				refresh_cells(bufnr)
				return
			end
			open_raw_notebook(bufnr, opts)
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
	if session_id and filepath ~= "" and runtime_started(bufnr) then
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
		serialize_notebook_async = fn or worker.request_isolated_async
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
