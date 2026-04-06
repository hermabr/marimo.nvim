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

local function normalize_bufnr(bufnr)
	if bufnr == nil or bufnr == 0 then
		return vim.api.nvim_get_current_buf()
	end
	return bufnr
end

local function state_for(bufnr)
	bufnr = normalize_bufnr(bufnr)
	runtime_state[bufnr] = runtime_state[bufnr] or {
		timer = nil,
		sync_token = 0,
		write_generation = 0,
		write_in_flight = nil,
		pending_write = nil,
		serialize_generation = 0,
		serialize_in_flight = nil,
		pending_serialize = nil,
		runtime_request = nil,
		interrupt_in_flight = nil,
		interrupt_token = 0,
		pending_sync = nil,
		pending_run = nil,
		stale_followup_token = 0,
		runtime_snapshot_dirty = false,
		runtime_snapshot_delete_ids = {},
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

local function cancel_active_runtime_request(bufnr)
	local entry = state_for(bufnr)
	local active = entry.runtime_request
	if not active then
		return nil
	end
	entry.runtime_request = nil
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	if filepath ~= "" then
		worker.finish_request(filepath, active.request_id)
	end
	return active
end

local function runtime_started(bufnr)
	if vim.b[bufnr].marimo_runtime_enabled == true then
		return true
	end
	if next(vim.b[bufnr].marimo_runtime_cells or {}) ~= nil then
		return true
	end
	local entry = state_for(bufnr)
	return entry.runtime_request ~= nil or entry.pending_sync ~= nil or entry.pending_run ~= nil
end

local function launch_cwd_for_buffer(bufnr)
	local launch_cwd = vim.b[bufnr].marimo_launch_cwd
	if type(launch_cwd) == "string" and launch_cwd ~= "" then
		return launch_cwd
	end
	return vim.fn.getcwd()
end

local function runtime_snapshot_dirty(bufnr)
	return state_for(bufnr).runtime_snapshot_dirty == true
end

local function clear_runtime_snapshot_dirty(bufnr)
	local entry = state_for(bufnr)
	entry.runtime_snapshot_dirty = false
	entry.runtime_snapshot_delete_ids = {}
end

local function mark_runtime_snapshot_dirty(bufnr, snapshot, deleted_ids)
	local entry = state_for(bufnr)
	entry.runtime_snapshot_dirty = true
	local current_lookup = {}
	for _, cell in ipairs((snapshot or {}).cells or {}) do
		current_lookup[cell.id] = true
	end
	local merged_delete_ids = {}
	local seen = {}
	local function append(ids)
		for _, cell_id in ipairs(ids or {}) do
			if not current_lookup[cell_id] and not seen[cell_id] then
				seen[cell_id] = true
				table.insert(merged_delete_ids, cell_id)
			end
		end
	end
	append(entry.runtime_snapshot_delete_ids)
	append(deleted_ids)
	entry.runtime_snapshot_delete_ids = merged_delete_ids
end

local function delete_ids_for_runtime_sync(bufnr, snapshot, deleted_ids)
	local entry = state_for(bufnr)
	local current_lookup = {}
	for _, cell in ipairs((snapshot or {}).cells or {}) do
		current_lookup[cell.id] = true
	end
	local merged_delete_ids = {}
	local seen = {}
	local function append(ids)
		for _, cell_id in ipairs(ids or {}) do
			if not current_lookup[cell_id] and not seen[cell_id] then
				seen[cell_id] = true
				table.insert(merged_delete_ids, cell_id)
			end
		end
	end
	append(entry.runtime_snapshot_delete_ids)
	append(deleted_ids)
	return merged_delete_ids
end

local function runtime_metadata(bufnr)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local project_root = vim.b[bufnr].marimo_project_root
	local runtime_kind = vim.b[bufnr].marimo_runtime_kind
	local launch_cwd = launch_cwd_for_buffer(bufnr)
	if project_root and runtime_kind then
		return project_root, runtime_kind, launch_cwd
	end
	local resolved_project_root, resolved_runtime_kind = worker.resolve_runtime(filepath)
	return resolved_project_root, resolved_runtime_kind, launch_cwd
end

local function refresh_cells(bufnr, opts)
	local runtime_cells = vim.b[bufnr].marimo_runtime_cells or {}
	local current_cells = vim.b[bufnr].marimo_cells or {}
	vim.b[bufnr].marimo_cells = runtime.attach_runtime(current_cells, runtime_cells)
	render.render(bufnr, vim.b[bufnr].marimo_cells, opts)
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
	if opts.skip_refresh ~= true then
		refresh_cells(bufnr, opts.render_opts)
	end
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

local function preserve_canonical_ranges(snapshot, previous_cells, changed_ids)
	local changed_lookup = {}
	for _, cell_id in ipairs(changed_ids or {}) do
		changed_lookup[cell_id] = true
	end
	local previous_by_id = {}
	for _, cell in ipairs(previous_cells or {}) do
		previous_by_id[cell.id] = vim.deepcopy(cell.canonical_range)
	end
	for _, cell in ipairs(snapshot.cells or {}) do
		if not changed_lookup[cell.id] then
			cell.canonical_range = vim.deepcopy(previous_by_id[cell.id])
		end
	end
end

local function start_snapshot_serialization(bufnr, request)
	local entry = state_for(bufnr)
	entry.serialize_in_flight = request.generation
	serialize_notebook_async(request.filepath, "serialize_notebook", {
		snapshot = request.snapshot,
	}, function(payload, err)
		local current = runtime_state[bufnr]
		if not current then
			return
		end
		if current.serialize_in_flight == request.generation then
			current.serialize_in_flight = nil
		end
		if current.pending_serialize then
			local next_request = current.pending_serialize
			current.pending_serialize = nil
			start_snapshot_serialization(bufnr, next_request)
		end
		if err then
			util.notify("failed to serialize marimo notebook: " .. err, vim.log.levels.ERROR)
			return
		end
		if not vim.api.nvim_buf_is_valid(bufnr) or current.serialize_generation ~= request.generation then
			return
		end
		snapshot_state.attach_canonical_ranges(request.snapshot, payload.canonical_ranges or {})
		apply_snapshot(bufnr, request.snapshot, payload.canonical_source, vim.bo[bufnr].modified, {
			update_buffer_lines = false,
			projected_lines = request.projected_lines,
			last_saved_source_hash = vim.b[bufnr].marimo_last_saved_source_hash,
			skip_refresh = true,
		})
	end)
end

local function queue_snapshot_serialization(bufnr, snapshot, projected_lines)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local entry = state_for(bufnr)
	entry.serialize_generation = entry.serialize_generation + 1
	local request = {
		generation = entry.serialize_generation,
		filepath = filepath,
		snapshot = vim.deepcopy(snapshot),
		projected_lines = vim.deepcopy(projected_lines),
	}
	if entry.serialize_in_flight then
		entry.pending_serialize = request
		return
	end
	start_snapshot_serialization(bufnr, request)
end

local function sync_local_snapshot_async(bufnr, snapshot, projected_lines, keep_modified, opts)
	opts = opts or {}
	snapshot_state.attach_projected_ranges(snapshot, projected_lines)
	preserve_canonical_ranges(snapshot, opts.previous_cells, opts.changed_ids)
	local render_opts = nil
	local changed_ids = opts.changed_ids or {}
	local deleted_ids = opts.deleted_ids or {}
	if opts.update_buffer_lines ~= true and (#changed_ids > 0 or #deleted_ids > 0) then
		render_opts = {
			changed_ids = vim.deepcopy(changed_ids),
			deleted_ids = vim.deepcopy(deleted_ids),
		}
	end
	apply_snapshot(bufnr, snapshot, vim.b[bufnr].marimo_canonical_source or "", keep_modified, {
		update_buffer_lines = opts.update_buffer_lines,
		projected_lines = projected_lines,
		last_saved_source_hash = vim.b[bufnr].marimo_last_saved_source_hash,
		render_opts = render_opts,
		skip_refresh = opts.update_buffer_lines ~= true and render_opts == nil,
	})
	queue_snapshot_serialization(bufnr, snapshot, projected_lines)
	return snapshot
end

local function current_snapshot_from_buffer(bufnr)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local project_root, runtime_kind, launch_cwd = runtime_metadata(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local ok, snapshot, projected_lines = pcall(snapshot_state.snapshot_from_projected_lines, {
		session_id = vim.b[bufnr].marimo_session_id or filepath,
		path = filepath,
		project_root = project_root,
		runtime_kind = runtime_kind,
		launch_cwd = launch_cwd,
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

local function mark_cells_pending(bufnr, cell_ids)
	local runtime_cells = vim.b[bufnr].marimo_runtime_cells or {}
	for _, cell_id in ipairs(cell_ids or {}) do
		local next_runtime = vim.deepcopy(runtime_cells[cell_id] or {})
		next_runtime.status = next_runtime.status == "running" and "running" or "queued"
		next_runtime.stale_inputs = false
		next_runtime.output = nil
		next_runtime.console = {}
		runtime_cells[cell_id] = next_runtime
	end
	vim.b[bufnr].marimo_runtime_cells = runtime_cells
	refresh_cells(bufnr, {
		changed_ids = cell_ids,
	})
end

local function mark_cells_locally_queued(bufnr, cell_ids)
	local runtime_cells = vim.b[bufnr].marimo_runtime_cells or {}
	local changed_ids = {}
	for _, cell_id in ipairs(cell_ids or {}) do
		local next_runtime = vim.deepcopy(runtime_cells[cell_id] or {})
		local updated = false
		if next_runtime.status ~= "running" and next_runtime.status ~= "queued" then
			next_runtime.status = "queued"
			updated = true
		end
		if next_runtime.stale_inputs == true then
			next_runtime.stale_inputs = false
			updated = true
		end
		if updated then
			runtime_cells[cell_id] = next_runtime
			table.insert(changed_ids, cell_id)
		end
	end
	if #changed_ids == 0 then
		return
	end
	vim.b[bufnr].marimo_runtime_cells = runtime_cells
	refresh_cells(bufnr, {
		changed_ids = changed_ids,
	})
end

local function runnable_untouched_cell_ids(snapshot, active_ids)
	local active_lookup = {}
	for _, cell_id in ipairs(active_ids or {}) do
		active_lookup[cell_id] = true
	end
	local stale_ids = {}
	for _, cell in ipairs(snapshot.cells or {}) do
		if not active_lookup[cell.id] and not (cell.options or {}).disabled then
			table.insert(stale_ids, cell.id)
		end
	end
	return stale_ids
end

local function mark_cells_stale(bufnr, cell_ids)
	local runtime_cells = vim.b[bufnr].marimo_runtime_cells or {}
	local changed_ids = {}
	for _, cell_id in ipairs(cell_ids or {}) do
		local previous = runtime_cells[cell_id] or {}
		local next_runtime = vim.deepcopy(previous)
		local updated = false
		if next_runtime.status ~= nil then
			next_runtime.status = nil
			updated = true
		end
		if next_runtime.stale_inputs ~= true then
			next_runtime.stale_inputs = true
			updated = true
		end
		if next_runtime.output ~= nil then
			next_runtime.output = nil
			updated = true
		end
		if next_runtime.console == nil or #next_runtime.console > 0 then
			next_runtime.console = {}
			updated = true
		end
		if next_runtime.last_execution_time_ms ~= nil then
			next_runtime.last_execution_time_ms = nil
			updated = true
		end
		if next_runtime._running_timestamp ~= nil then
			next_runtime._running_timestamp = nil
			updated = true
		end
		if next_runtime._running_started_at_ns ~= nil then
			next_runtime._running_started_at_ns = nil
			updated = true
		end
		if updated then
			runtime_cells[cell_id] = next_runtime
			table.insert(changed_ids, cell_id)
		end
	end
	if #changed_ids == 0 then
		return
	end
	vim.b[bufnr].marimo_runtime_cells = runtime_cells
	refresh_cells(bufnr, {
		changed_ids = changed_ids,
	})
end

local function mark_fresh_partial_run_cells_stale(bufnr, snapshot, cell_ids)
	if runtime_started(bufnr) then
		return
	end
	mark_cells_stale(bufnr, runnable_untouched_cell_ids(snapshot, cell_ids))
end

local function clear_running_runtime_state(bufnr)
	local runtime_cells, changed, changed_ids = runtime.apply_operation(vim.b[bufnr].marimo_runtime_cells or {}, {
		op = "interrupted",
	})
	if not changed then
		return
	end
	vim.b[bufnr].marimo_runtime_cells = runtime_cells
	refresh_cells(bufnr, {
		changed_ids = changed_ids,
	})
end

local function clear_runtime_outputs(bufnr)
	vim.b[bufnr].marimo_runtime_cells = {}
	vim.b[bufnr].marimo_runtime_enabled = false
	refresh_cells(bufnr)
end

local function runtime_has_pending_work(bufnr)
	for _, cell_runtime in pairs(vim.b[bufnr].marimo_runtime_cells or {}) do
		if cell_runtime.status == "queued" or cell_runtime.status == "running" then
			return true
		end
	end
	return false
end

local finish_runtime_request

local function settle_completed_runtime_request(bufnr)
	local entry = runtime_state[bufnr]
	if not entry or not entry.runtime_request then
		return false
	end
	local active = entry.runtime_request
	if not active.saw_operation or runtime_has_pending_work(bufnr) then
		return false
	end
	finish_runtime_request(bufnr, active.request_id)
	return true
end

local flush_runtime_queue
local queue_runtime_run
local codes_for_cell_ids

finish_runtime_request = function(bufnr, request_id)
	local entry = runtime_state[bufnr]
	if not entry then
		return
	end
	local active = entry.runtime_request
	if not active or active.request_id ~= request_id then
		return
	end
	entry.runtime_request = nil
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	if filepath ~= "" then
		worker.finish_request(filepath, request_id)
	end
	flush_runtime_queue(bufnr)
end

local function handle_runtime_event(bufnr, request_id, event)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	if type(event) ~= "table" or event.event ~= "operation" then
		return
	end
	vim.b[bufnr].marimo_runtime_enabled = true
	local active = state_for(bufnr).runtime_request
	if request_id and (not active or active.request_id ~= request_id) then
		return
	end
	local runtime_cells, changed, changed_ids = runtime.apply_operation(vim.b[bufnr].marimo_runtime_cells or {}, event.operation)
	if changed then
		vim.b[bufnr].marimo_runtime_cells = runtime_cells
		refresh_cells(bufnr, {
			changed_ids = changed_ids,
		})
	end
	if not active or not active.awaits_events then
		return
	end
	active.saw_operation = true
	if active.kind == "sync"
		and active.followup_snapshot
		and type(event.operation) == "table"
		and event.operation.op == "cell-op"
		and event.operation.stale_inputs == true
		and event.operation.cell_id
	then
		for _, cell in ipairs(active.followup_snapshot.cells or {}) do
			if cell.id == event.operation.cell_id and not (cell.options or {}).disabled then
				queue_runtime_run(
					bufnr,
					active.followup_snapshot,
					{ cell.id },
					codes_for_cell_ids(active.followup_snapshot, { cell.id })
				)
				break
			end
		end
	end
	local op = type(event.operation) == "table" and event.operation.op or nil
	if runtime_has_pending_work(bufnr) then
		return
	end
	if op == "completed-run" or op == "interrupted" then
		vim.defer_fn(function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end
			local current = state_for(bufnr).runtime_request
			if current and current.request_id == request_id and not runtime_has_pending_work(bufnr) then
				finish_runtime_request(bufnr, request_id)
			end
		end, 300)
	end
end

local function submit_runtime_request(bufnr, request)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local entry = state_for(bufnr)
	if request.pending_cell_ids and #request.pending_cell_ids > 0 then
		mark_cells_pending(bufnr, request.pending_cell_ids)
	end
	local request_id
	request_id = worker.request_async(filepath, request.method, request.params, function(payload, err)
		local active = state_for(bufnr).runtime_request
		if err then
			if active and active.request_id == request_id then
				entry.runtime_request = nil
			end
			worker.finish_request(filepath, request_id)
			util.notify(request.error_prefix .. err, vim.log.levels.ERROR)
			flush_runtime_queue(bufnr)
			return
		end
		if not vim.api.nvim_buf_is_valid(bufnr) then
			worker.finish_request(filepath, request_id)
			return
		end
		if payload and payload.session_id then
			vim.b[bufnr].marimo_runtime_enabled = true
			if request.params and request.params.snapshot then
				clear_runtime_snapshot_dirty(bufnr)
			end
		end
		if not request.awaits_events then
			finish_runtime_request(bufnr, request_id)
		end
	end, function(event)
		handle_runtime_event(bufnr, request_id, event)
	end)
	entry.runtime_request = {
		request_id = request_id,
		kind = request.kind,
		awaits_events = request.awaits_events,
		saw_operation = false,
		followup_snapshot = request.followup_snapshot,
	}
end

flush_runtime_queue = function(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local entry = state_for(bufnr)
	if entry.runtime_request ~= nil then
		if settle_completed_runtime_request(bufnr) then
		end
		return
	end
	if entry.interrupt_in_flight ~= nil then
		return
	end
	local next_request = entry.pending_sync
	if next_request then
		entry.pending_sync = nil
		submit_runtime_request(bufnr, next_request)
		return
	end
	next_request = entry.pending_run
	if next_request then
		entry.pending_run = nil
		submit_runtime_request(bufnr, next_request)
	end
end

local function send_interrupt_request(bufnr, cancelled_request_id)
	local entry = state_for(bufnr)
	entry.interrupt_token = entry.interrupt_token + 1
	local interrupt_token = entry.interrupt_token
	entry.interrupt_in_flight = interrupt_token
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local interrupt_request_id
	interrupt_request_id = worker.request_async(filepath, "interrupt", {
		session_id = vim.b[bufnr].marimo_session_id,
		cancel_request_id = cancelled_request_id,
	}, function(payload, request_err)
		local current = runtime_state[bufnr]
		local is_active = current and current.interrupt_in_flight == interrupt_token
		if is_active then
			current.interrupt_in_flight = nil
		end
		worker.finish_request(filepath, interrupt_request_id)
		if not is_active then
			return
		end
		if request_err then
			util.notify(request_err, vim.log.levels.ERROR)
			if vim.api.nvim_buf_is_valid(bufnr) then
				flush_runtime_queue(bufnr)
			end
			return
		end
		if payload and payload.session_id and vim.api.nvim_buf_is_valid(bufnr) then
			vim.b[bufnr].marimo_runtime_enabled = true
		end
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.defer_fn(function()
				if runtime_state[bufnr] == current and vim.api.nvim_buf_is_valid(bufnr) then
					flush_runtime_queue(bufnr)
				end
			end, 150)
		end
	end)
end

local function prepare_runtime_invalidation(bufnr)
	settle_completed_runtime_request(bufnr)
	local entry = state_for(bufnr)
	local should_interrupt = entry.runtime_request ~= nil
	entry.pending_sync = nil
	entry.pending_run = nil
	entry.stale_followup_token = entry.stale_followup_token + 1
	return should_interrupt
end

local function interrupt_active_runtime_for_invalidation(bufnr)
	local interrupted_request = cancel_active_runtime_request(bufnr)
	if not interrupted_request then
		return
	end
	clear_running_runtime_state(bufnr)
	send_interrupt_request(bufnr, interrupted_request.request_id)
end

local function queue_runtime_sync(bufnr, snapshot, run_ids, delete_ids)
	local entry = state_for(bufnr)
	if #run_ids > 0 then
		mark_fresh_partial_run_cells_stale(bufnr, snapshot, run_ids)
	end
	entry.pending_sync = {
		kind = "sync",
		method = "sync_notebook",
		params = {
			snapshot = vim.deepcopy(snapshot),
			run_ids = vim.deepcopy(run_ids),
			delete_ids = vim.deepcopy(delete_ids),
		},
			awaits_events = #run_ids > 0,
			pending_cell_ids = vim.deepcopy(run_ids),
			followup_snapshot = #run_ids > 0 and vim.deepcopy(snapshot) or nil,
			error_prefix = "failed to sync marimo runtime: ",
		}
	flush_runtime_queue(bufnr)
end

queue_runtime_run = function(bufnr, snapshot, cell_ids, codes)
	settle_completed_runtime_request(bufnr)
	local entry = state_for(bufnr)
	mark_fresh_partial_run_cells_stale(bufnr, snapshot, cell_ids)
	if entry.pending_run and entry.pending_run.params and entry.pending_run.params.cell_ids then
		local merged_ids = vim.deepcopy(entry.pending_run.params.cell_ids)
		local seen = {}
		for _, existing_id in ipairs(merged_ids) do
			seen[existing_id] = true
		end
		for _, cell_id in ipairs(cell_ids or {}) do
			if not seen[cell_id] then
				table.insert(merged_ids, cell_id)
				seen[cell_id] = true
			end
		end
		cell_ids = merged_ids
		codes = codes_for_cell_ids(snapshot, cell_ids)
	end
	entry.pending_run = {
		kind = "run",
		method = "run_cells",
		params = {
			session_id = vim.b[bufnr].marimo_session_id,
			snapshot = vim.deepcopy(snapshot),
			cell_ids = vim.deepcopy(cell_ids),
			codes = vim.deepcopy(codes),
		},
		awaits_events = #cell_ids > 0,
		pending_cell_ids = vim.deepcopy(cell_ids),
		error_prefix = "failed to run marimo cells: ",
	}
	if entry.runtime_request ~= nil or entry.pending_sync ~= nil or entry.interrupt_in_flight ~= nil then
		mark_cells_locally_queued(bufnr, cell_ids)
	end
	flush_runtime_queue(bufnr)
end

local function sync_context_from_buffer(bufnr, opts)
	opts = opts or {}
	local previous_cells = vim.deepcopy(vim.b[bufnr].marimo_cells or {})
	local keep_modified = vim.bo[bufnr].modified
	local snapshot, projected_lines, snapshot_err = current_snapshot_from_buffer(bufnr)
	if snapshot_err then
		return nil, nil, nil, nil, nil, nil, snapshot_err
	end
	local raw_changed_ids, deleted_ids = snapshot_state.compute_changes(previous_cells, snapshot.cells)
	local synced_snapshot = sync_local_snapshot_async(bufnr, snapshot, projected_lines, keep_modified, {
		update_buffer_lines = opts.update_buffer_lines,
		previous_cells = previous_cells,
		changed_ids = raw_changed_ids,
		deleted_ids = deleted_ids,
	})
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local runtime_changed_ids = vim.deepcopy(raw_changed_ids)
	local dependent_ids = {}
	local deleted_dependent_ids = {}
	if #raw_changed_ids > 0 then
		local resolved, dependent_err = worker.request(filepath, "resolve_runtime_updates", {
			snapshot = vim.deepcopy(synced_snapshot),
			previous_cells = vim.deepcopy(previous_cells),
			cell_ids = vim.deepcopy(raw_changed_ids),
		})
		if not dependent_err and resolved then
			if vim.islist(resolved.changed_ids) then
				runtime_changed_ids = resolved.changed_ids
			end
			if vim.islist(resolved.dependent_ids) then
				dependent_ids = resolved.dependent_ids
			end
		end
	end
	if #deleted_ids > 0 then
		local resolved, dependent_err = worker.request(filepath, "resolve_changed_dependents", {
			snapshot = {
				session_id = synced_snapshot.session_id,
				path = synced_snapshot.path,
				project_root = synced_snapshot.project_root,
				runtime_kind = synced_snapshot.runtime_kind,
				header = synced_snapshot.header,
				app_options = vim.deepcopy(synced_snapshot.app_options or {}),
				cells = vim.deepcopy(previous_cells),
			},
			cell_ids = vim.deepcopy(deleted_ids),
		})
		if not dependent_err and resolved and vim.islist(resolved.cell_ids) then
			local current_by_id = {}
			for _, cell in ipairs(synced_snapshot.cells or {}) do
				current_by_id[cell.id] = cell
			end
			for _, cell_id in ipairs(resolved.cell_ids) do
				local cell = current_by_id[cell_id]
				if cell and not (cell.options or {}).disabled then
					table.insert(deleted_dependent_ids, cell_id)
				end
			end
		end
	end
	return synced_snapshot, raw_changed_ids, deleted_ids, runtime_changed_ids, dependent_ids, deleted_dependent_ids, nil
end

codes_for_cell_ids = function(snapshot, cell_ids)
	local codes_by_id = {}
	for _, cell in ipairs(snapshot.cells or {}) do
		codes_by_id[cell.id] = cell.code
	end
	local codes = {}
	for _, cell_id in ipairs(cell_ids or {}) do
		table.insert(codes, codes_by_id[cell_id] or "")
	end
	return codes
end

local function autorun_ids_for_changes(snapshot, changed_ids)
	local changed_lookup = {}
	for _, cell_id in ipairs(changed_ids or {}) do
		changed_lookup[cell_id] = true
	end
	local run_ids = {}
	for _, cell in ipairs(snapshot.cells or {}) do
		if changed_lookup[cell.id] and not (cell.options or {}).disabled then
			table.insert(run_ids, cell.id)
		end
	end
	return run_ids
end

local function merged_snapshot_cell_ids(snapshot, ...)
	local wanted = {}
	for idx = 1, select("#", ...) do
		for _, cell_id in ipairs(select(idx, ...) or {}) do
			wanted[cell_id] = true
		end
	end
	local merged = {}
	for _, cell in ipairs((snapshot or {}).cells or {}) do
		if wanted[cell.id] then
			table.insert(merged, cell.id)
		end
	end
	return merged
end

local function schedule_stale_followup(bufnr, snapshot)
	local entry = state_for(bufnr)
	entry.stale_followup_token = entry.stale_followup_token + 1
	local followup_token = entry.stale_followup_token
	local followup_snapshot = vim.deepcopy(snapshot)
	local function attempt(remaining)
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		local current = state_for(bufnr)
		if current.stale_followup_token ~= followup_token then
			return
		end
		local stale_ids = {}
		local runtime_cells = vim.b[bufnr].marimo_runtime_cells or {}
		for _, cell in ipairs(followup_snapshot.cells or {}) do
			local cell_runtime = runtime_cells[cell.id]
			if cell_runtime and cell_runtime.stale_inputs == true and not (cell.options or {}).disabled then
				table.insert(stale_ids, cell.id)
			end
		end
		if #stale_ids > 0 then
			queue_runtime_run(bufnr, followup_snapshot, stale_ids, codes_for_cell_ids(followup_snapshot, stale_ids))
			return
		end
		if remaining > 1 then
			vim.defer_fn(function()
				attempt(remaining - 1)
			end, 200)
		end
	end
	attempt(25)
end

local function queue_invalidating_runtime_sync(bufnr, snapshot, run_ids, delete_ids, opts)
	opts = opts or {}
	local should_interrupt = false
	if opts.preempt_active then
		should_interrupt = prepare_runtime_invalidation(bufnr)
	end
	queue_runtime_sync(bufnr, snapshot, run_ids, delete_ids)
	if should_interrupt then
		interrupt_active_runtime_for_invalidation(bufnr)
	end
	if opts.schedule_stale_followup then
		schedule_stale_followup(bufnr, snapshot)
	end
end

local function clear_pending_runtime_request(bufnr)
	local entry = runtime_state[bufnr]
	if not entry or not entry.runtime_request then
		return
	end
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	if filepath ~= "" then
		worker.finish_request(filepath, entry.runtime_request.request_id)
	end
	entry.runtime_request = nil
	entry.pending_sync = nil
	entry.pending_run = nil
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
			skip_refresh = true,
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
	bufnr = normalize_bufnr(bufnr)
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
	clear_pending_runtime_request(bufnr)
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
		launch_cwd = launch_cwd_for_buffer(bufnr),
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
	bufnr = normalize_bufnr(bufnr)
	if not state.is_enabled(bufnr) then
		return false
	end
	if vim.b[bufnr].marimo_projected then
		util.notify("already projected: " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:."))
		return false
	end
	if not is_file_buffer(bufnr) then
		util.notify("current buffer is not a file buffer", vim.log.levels.WARN)
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not markers.looks_like_marimo(lines) then
		util.notify("no marimo notebook detected in " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:."), vim.log.levels.WARN)
		return false
	end
	return open_raw_notebook(bufnr, opts)
end

function M.write_buffer(bufnr)
	bufnr = normalize_bufnr(bufnr)
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
	bufnr = normalize_bufnr(bufnr)
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	local synced_snapshot, changed_ids, deleted_ids, runtime_changed_ids, dependent_ids, deleted_dependent_ids, err = sync_context_from_buffer(bufnr, {
		update_buffer_lines = false,
	})
	if err then
		util.notify("failed to sync marimo notebook: " .. err, vim.log.levels.ERROR)
		return
	end
	local runtime_delete_ids = delete_ids_for_runtime_sync(bufnr, synced_snapshot, deleted_ids)
	if opts.respect_lazy_execution ~= false and state.is_lazy_execution(bufnr) and not opts.start_runtime then
		if runtime_started(bufnr) and (#runtime_changed_ids > 0 or #runtime_delete_ids > 0) then
			mark_runtime_snapshot_dirty(bufnr, synced_snapshot, runtime_delete_ids)
			local should_interrupt = prepare_runtime_invalidation(bufnr)
			if should_interrupt then
				interrupt_active_runtime_for_invalidation(bufnr)
			end
		end
		local stale_ids = merged_snapshot_cell_ids(
			synced_snapshot,
			runtime_changed_ids,
			dependent_ids,
			deleted_dependent_ids
		)
		if #stale_ids > 0 then
			mark_cells_stale(bufnr, stale_ids)
		end
		return synced_snapshot, changed_ids, deleted_ids
	end
	local should_autorun = opts.autorun ~= false
	local run_ids = should_autorun and autorun_ids_for_changes(synced_snapshot, runtime_changed_ids) or {}
	if ((runtime_started(bufnr) or opts.start_runtime) and (#runtime_changed_ids > 0 or #runtime_delete_ids > 0 or opts.start_runtime)) then
		queue_invalidating_runtime_sync(bufnr, synced_snapshot, run_ids, runtime_delete_ids, {
			preempt_active = runtime_started(bufnr) and (#runtime_changed_ids > 0 or #runtime_delete_ids > 0 or runtime_snapshot_dirty(bufnr)),
			schedule_stale_followup = runtime_started(bufnr) and (#runtime_changed_ids > 0 or #runtime_delete_ids > 0),
		})
		if #dependent_ids > 0 then
			queue_runtime_run(bufnr, synced_snapshot, dependent_ids, codes_for_cell_ids(synced_snapshot, dependent_ids))
		end
	elseif #run_ids > 0 then
		queue_runtime_run(bufnr, synced_snapshot, run_ids, codes_for_cell_ids(synced_snapshot, run_ids))
	end
	return synced_snapshot, changed_ids, deleted_ids
end

function M.format_buffer(bufnr)
	bufnr = normalize_bufnr(bufnr)
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
	local synced_snapshot, _, deleted_ids, _, _, _, err = sync_context_from_buffer(bufnr, {
		update_buffer_lines = true,
	})
	if err then
		util.notify("failed to format marimo notebook: " .. err, vim.log.levels.ERROR)
		return false, err
	end
	if runtime_started(bufnr) then
		queue_runtime_sync(bufnr, synced_snapshot, {}, delete_ids_for_runtime_sync(bufnr, synced_snapshot, deleted_ids))
	end
	return true
end

function M.schedule_sync(bufnr, opts)
	opts = opts or {}
	bufnr = normalize_bufnr(bufnr)
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	stop_autorun_timer(bufnr)
	local entry = state_for(bufnr)
	entry.sync_token = entry.sync_token + 1
	local sync_token = entry.sync_token
	local delay = opts.immediate and 0 or 300
	local timer = vim.uv.new_timer()
	entry.timer = timer
	timer:start(delay, 0, function()
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end
			if state_for(bufnr).sync_token ~= sync_token then
				return
			end
			M.sync_buffer(bufnr)
		end)
	end)
end

function M.run_all_cells(bufnr)
	bufnr = normalize_bufnr(bufnr)
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	stop_autorun_timer(bufnr)
	local synced_snapshot, changed_ids, deleted_ids, runtime_changed_ids, _, _, err = sync_context_from_buffer(bufnr, {
		update_buffer_lines = false,
	})
	if err then
		util.notify("failed to sync marimo notebook: " .. err, vim.log.levels.ERROR)
		return
	end
	local cell_ids = {}
	for _, cell in ipairs(synced_snapshot.cells or {}) do
		table.insert(cell_ids, cell.id)
	end
	local runtime_delete_ids = delete_ids_for_runtime_sync(bufnr, synced_snapshot, deleted_ids)
	queue_invalidating_runtime_sync(bufnr, synced_snapshot, cell_ids, runtime_delete_ids, {
		preempt_active = runtime_started(bufnr) and (#runtime_changed_ids > 0 or #runtime_delete_ids > 0 or runtime_snapshot_dirty(bufnr)),
		schedule_stale_followup = runtime_started(bufnr) and (#runtime_changed_ids > 0 or #runtime_delete_ids > 0),
	})
end

function M.run_current_cell(bufnr)
	bufnr = normalize_bufnr(bufnr)
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	stop_autorun_timer(bufnr)
	local synced_snapshot, changed_ids, deleted_ids, runtime_changed_ids, _, _, err = sync_context_from_buffer(bufnr, {
		update_buffer_lines = false,
	})
	if err then
		util.notify("failed to sync marimo notebook: " .. err, vim.log.levels.ERROR)
		return
	end
	local cell = navigation.find_current_cell(bufnr)
	if not cell then
		util.notify("no current marimo cell", vim.log.levels.WARN)
		return
	end
	local runtime_delete_ids = delete_ids_for_runtime_sync(bufnr, synced_snapshot, deleted_ids)
	if runtime_started(bufnr) and (#runtime_changed_ids > 0 or #runtime_delete_ids > 0 or runtime_snapshot_dirty(bufnr)) then
		queue_invalidating_runtime_sync(bufnr, synced_snapshot, {}, runtime_delete_ids, {
			preempt_active = true,
		})
	end
	queue_runtime_run(bufnr, synced_snapshot, { cell.id }, { cell.code })
end

function M.interrupt(bufnr)
	bufnr = normalize_bufnr(bufnr)
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	local entry = state_for(bufnr)
	local interrupted_request = entry.runtime_request
	if not runtime_started(bufnr)
		and interrupted_request == nil
		and entry.pending_sync == nil
		and entry.pending_run == nil
		and not runtime_has_pending_work(bufnr)
	then
		return
	end
	entry.pending_sync = nil
	entry.pending_run = nil
	entry.stale_followup_token = entry.stale_followup_token + 1
	interrupted_request = cancel_active_runtime_request(bufnr)
	clear_running_runtime_state(bufnr)
	send_interrupt_request(bufnr, interrupted_request and interrupted_request.request_id or nil)
end

function M.restart(bufnr)
	bufnr = normalize_bufnr(bufnr)
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	stop_autorun_timer(bufnr)
	local synced_snapshot, _, _, _, _, _, err = sync_context_from_buffer(bufnr, {
		update_buffer_lines = false,
	})
	if err then
		util.notify("failed to restart marimo kernel: " .. err, vim.log.levels.ERROR)
		return
	end
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local session_id = vim.b[bufnr].marimo_session_id
	local entry = state_for(bufnr)
	entry.pending_sync = nil
	entry.pending_run = nil
	entry.stale_followup_token = entry.stale_followup_token + 1
	entry.interrupt_token = entry.interrupt_token + 1
	entry.interrupt_in_flight = nil
	cancel_active_runtime_request(bufnr)
	clear_runtime_outputs(bufnr)
	close_session_async(filepath, session_id, function(_, close_err)
		if close_err then
			util.notify("failed to restart marimo kernel: " .. close_err, vim.log.levels.ERROR)
			return
		end
		if not vim.api.nvim_buf_is_valid(bufnr)
			or not vim.b[bufnr].marimo_projected
			or vim.b[bufnr].marimo_session_id ~= session_id
		then
			return
		end
		worker.request_async(filepath, "ensure_session", {
			snapshot = synced_snapshot,
		}, function(payload, restart_err)
			if restart_err then
				util.notify("failed to restart marimo kernel: " .. restart_err, vim.log.levels.ERROR)
				return
			end
			if not vim.api.nvim_buf_is_valid(bufnr)
				or not vim.b[bufnr].marimo_projected
				or vim.b[bufnr].marimo_session_id ~= session_id
			then
				return
			end
			if payload and payload.session_id then
				vim.b[bufnr].marimo_runtime_enabled = true
				util.notify("marimo kernel restarted")
			end
		end)
	end)
end

function M.confirm_restart(bufnr)
	bufnr = normalize_bufnr(bufnr)
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return false
	end
	local choice = vim.fn.confirm("Restart marimo kernel? [Y/n]", "&Yes\n&No", 1)
	if choice ~= 1 then
		return false
	end
	M.restart(bufnr)
	return true
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
	bufnr = normalize_bufnr(bufnr)
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
	M.sync_buffer(bufnr, { autorun = false, start_runtime = true, respect_lazy_execution = false })
end

function M.open_current_output(bufnr)
	bufnr = normalize_bufnr(bufnr)
	return output_window.open_current(bufnr)
end

function M.activate(bufnr, opts)
	opts = opts or {}
	bufnr = normalize_bufnr(bufnr)
	if not state.is_enabled(bufnr) then
		util.notify("marimo mode is disabled for this buffer", vim.log.levels.WARN)
		return false
	end
	if not is_file_buffer(bufnr) then
		util.notify("current buffer is not a file buffer", vim.log.levels.WARN)
		return false
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local project_root, runtime_kind, launch_cwd = runtime_metadata(bufnr)
	if markers.looks_like_marimo(lines) then
		return M.project_buffer(bufnr, opts)
	end
	if markers.looks_like_projected(lines) then
		local ok, snapshot, projected_lines = pcall(snapshot_state.snapshot_from_projected_lines, {
			session_id = filepath,
			path = filepath,
			project_root = project_root,
			runtime_kind = runtime_kind,
			launch_cwd = launch_cwd,
			header = nil,
			app_options = vim.empty_dict(),
			previous_cells = nil,
			lines = lines,
		})
		if not ok then
			util.notify(snapshot, vim.log.levels.WARN)
			return false
		end
		return open_local_snapshot(bufnr, snapshot, projected_lines, vim.tbl_extend("force", opts, {
			update_buffer_lines = false,
		}))
	end
	if markers.has_any_projected_markers(lines) then
		if opts.manual then
			local promoted, changed = markers.promote_first_marker_to_marimo(lines)
			if not changed then
				util.notify("buffer is neither a real marimo notebook nor a projected `# +` notebook", vim.log.levels.WARN)
				return false
			end
			local ok, snapshot, projected_lines = pcall(snapshot_state.snapshot_from_projected_lines, {
				session_id = filepath,
				path = filepath,
				project_root = project_root,
				runtime_kind = runtime_kind,
				launch_cwd = launch_cwd,
				header = nil,
				app_options = vim.empty_dict(),
				previous_cells = nil,
				lines = promoted,
			})
			if not ok then
				util.notify(snapshot, vim.log.levels.WARN)
				return false
			end
			return open_local_snapshot(bufnr, snapshot, projected_lines, vim.tbl_extend("force", opts, {
				update_buffer_lines = true,
			}))
		end
		return false
	end
	if opts.manual then
		local ok, snapshot, projected_lines = pcall(snapshot_state.snapshot_from_manual_python, {
			session_id = filepath,
			path = filepath,
			project_root = project_root,
			runtime_kind = runtime_kind,
			launch_cwd = launch_cwd,
			previous_cells = nil,
			lines = lines,
		})
		if not ok then
			util.notify(snapshot, vim.log.levels.WARN)
			return false
		end
		return open_local_snapshot(bufnr, snapshot, projected_lines, vim.tbl_extend("force", opts, {
			update_buffer_lines = true,
		}))
	end
	util.notify("buffer is neither a real marimo notebook nor a projected `# +` notebook", vim.log.levels.WARN)
	return false
end

function M.reconcile_buffer(bufnr, opts)
	opts = opts or {}
	bufnr = normalize_bufnr(bufnr)
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
	local bufnr = normalize_bufnr(opts.bufnr)
	local previous_mode = vim.b[bufnr].marimo_mode
	vim.b[bufnr].marimo_mode = enabled
	if enabled then
		local ok = M.activate(bufnr, opts)
		if not ok then
			vim.b[bufnr].marimo_mode = previous_mode
			return false
		end
		return true
	end
	if vim.b[bufnr].marimo_projected then
		local ok, err = M.reload_raw_buffer(bufnr)
		if not ok then
			vim.b[bufnr].marimo_mode = previous_mode
			return ok, err
		end
		M.cleanup_buffer(bufnr)
		return true
	end
	return true
end

function M.cleanup_buffer(bufnr)
	bufnr = normalize_bufnr(bufnr)
	local session_id = vim.b[bufnr].marimo_session_id
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	stop_autorun_timer(bufnr)
	clear_pending_runtime_request(bufnr)
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

function M.refresh(bufnr)
	bufnr = normalize_bufnr(bufnr)
	refresh_cells(bufnr)
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
