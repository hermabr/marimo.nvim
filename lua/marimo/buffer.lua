local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local util = dofile(dir .. "/util.lua")
local markers = dofile(dir .. "/markers.lua")
local notebook = dofile(dir .. "/notebook.lua")
local runtime_reducer = dofile(dir .. "/runtime_state.lua")
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

local function sync_cells_with_runtime(bufnr)
	local runtime_cells = vim.b[bufnr].marimo_runtime_cells or {}
	local cells = {}
	for _, cell in ipairs(vim.b[bufnr].marimo_cells or {}) do
		local next_cell = vim.deepcopy(cell)
		next_cell.runtime = runtime_cells[next_cell.id] or runtime_reducer.empty_runtime()
		table.insert(cells, next_cell)
	end
	vim.b[bufnr].marimo_cells = cells
end

local function apply_session_payload(bufnr, payload, keep_modified, opts)
	opts = opts or {}
	local update_buffer_lines = opts.update_buffer_lines ~= false
	local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local final_lines = current_lines
	if update_buffer_lines and vim.deep_equal(current_lines, payload.projected_lines or {}) == false then
		final_lines = payload.projected_lines or {}
		with_internal_buffer_update(bufnr, function()
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, final_lines)
		end)
	elseif update_buffer_lines then
		final_lines = payload.projected_lines or current_lines
	end
	payload.cells = notebook.apply_projection_ranges(payload.cells or {}, final_lines)
	payload.projection_map = notebook.build_projection_map(payload.cells or {})
	local runtime_cells = vim.deepcopy(vim.b[bufnr].marimo_runtime_cells or {})
	session.set_session(bufnr, payload)
	vim.b[bufnr].marimo_runtime_cells = runtime_cells
	sync_cells_with_runtime(bufnr)
	render.render(bufnr, vim.b[bufnr].marimo_cells or {})
	output_window.refresh(bufnr)
	lsp_bridge.sync_mirror(bufnr, payload.canonical_source)
	vim.bo[bufnr].modified = keep_modified and true or false
	util.request_redraw()
end

local function current_snapshot(bufnr)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local cells = notebook.parse_projected_lines(lines, vim.b[bufnr].marimo_cells)
	return notebook.build_snapshot(
		filepath,
		vim.b[bufnr].marimo_project_root,
		vim.b[bufnr].marimo_header,
		vim.b[bufnr].marimo_app_options or vim.empty_dict(),
		cells
	)
end

local function build_session_payload(snapshot, runtime_kind, codec_payload)
	return notebook.build_session_payload(snapshot, runtime_kind, codec_payload)
end

local function serialize_snapshot(filepath, snapshot)
	return worker.request(filepath, "serialize_notebook", {
		path = filepath,
		snapshot = snapshot,
	})
end

local function apply_codec_snapshot(bufnr, snapshot, runtime_kind, codec_payload, keep_modified, opts)
	local payload = build_session_payload(snapshot, runtime_kind, codec_payload)
	apply_session_payload(bufnr, payload, keep_modified, opts)
end

local function merge_runtime_cells(bufnr, runtime_cells)
	local cells = vim.b[bufnr].marimo_cells or {}
	local by_id = vim.b[bufnr].marimo_runtime_cells or {}
	for cell_id, runtime in pairs(runtime_cells or {}) do
		by_id[cell_id] = runtime
	end
	vim.b[bufnr].marimo_runtime_cells = by_id
	sync_cells_with_runtime(bufnr)
	render.render(bufnr, vim.b[bufnr].marimo_cells or {})
	output_window.refresh(bufnr)
	util.request_redraw()
end

local function mark_cells_pending(bufnr, cell_ids)
	local current = vim.b[bufnr].marimo_runtime_cells or {}
	local updates = {}
	for _, cell_id in ipairs(cell_ids or {}) do
		local runtime = vim.deepcopy(current[cell_id] or runtime_reducer.empty_runtime())
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
	if payload and payload.started then
		vim.b[bufnr].marimo_runtime_started = true
	end
	if payload and payload.runtime_cells then
		merge_runtime_cells(bufnr, payload.runtime_cells)
	end
	if keep_modified ~= nil then
		vim.bo[bufnr].modified = keep_modified and true or false
	end
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
	if payload and payload.session_id then
		vim.b[bufnr].marimo_runtime_started = true
	end
	if payload and payload.runtime_cells then
		merge_runtime_cells(bufnr, payload.runtime_cells)
	end
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
	if event.event == "operation" and type(event.operation) == "table" then
		local runtime_cells, changed = runtime_reducer.apply_operation(vim.b[bufnr].marimo_runtime_cells or {}, event.operation)
		if changed then
			merge_runtime_cells(bufnr, runtime_cells)
		end
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
		write_projection_async(next_request.filepath, "serialize_notebook", next_request.params, function(next_payload, next_err)
			finish_projected_write(bufnr, next_request, next_payload, next_err)
		end)
	end
	if err then
		util.notify("failed to write marimo notebook: " .. err, vim.log.levels.ERROR)
		return
	end
	vim.fn.writefile(util.split_lines(payload.canonical_source or ""), request.filepath)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	if entry.pending_write then
		return
	end
	if request.codec_cells then
		local cells = notebook.apply_codec_cells(vim.b[bufnr].marimo_cells or {}, request.codec_cells)
		cells = notebook.apply_projection_ranges(cells, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		vim.b[bufnr].marimo_cells = cells
		vim.b[bufnr].marimo_projection_map = notebook.build_projection_map(cells)
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
	local ok, snapshot_or_err = pcall(current_snapshot, bufnr)
	if not ok then
		util.notify("failed to write marimo notebook: " .. snapshot_or_err, vim.log.levels.ERROR)
		return
	end
	local snapshot = snapshot_or_err
	entry.write_generation = entry.write_generation + 1
	local request = {
		generation = entry.write_generation,
		filepath = filepath,
		changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
		codec_cells = vim.deepcopy(snapshot.cells or {}),
		params = {
			path = filepath,
			snapshot = snapshot,
		},
	}
	if entry.write_in_flight then
		entry.pending_write = request
		return
	end
	entry.write_in_flight = request.generation
	write_projection_async(filepath, "serialize_notebook", request.params, function(payload, err)
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

local function open_with_snapshot(bufnr, snapshot, runtime_kind, codec_payload, opts)
	apply_codec_snapshot(bufnr, snapshot, runtime_kind, codec_payload, vim.bo[bufnr].modified, {
		update_buffer_lines = opts.update_buffer_lines,
	})
	if opts.ensure_projected_buffer_setup then
		opts.ensure_projected_buffer_setup(bufnr)
	end
	return true
end

local function open_raw_notebook(bufnr, opts)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local payload, err = worker.request(filepath, "load_raw_notebook", {
		path = filepath,
		content = util.join_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)),
	})
	if err then
		util.notify("failed to open marimo notebook: " .. err, vim.log.levels.ERROR)
		return false
	end
	local project_root, runtime_kind = worker.resolve_runtime(filepath)
	local snapshot = notebook.build_snapshot(filepath, project_root, payload.header, payload.app_options, payload.cells)
	return open_with_snapshot(bufnr, snapshot, runtime_kind, payload, vim.tbl_extend("force", opts or {}, {
		update_buffer_lines = true,
	}))
end

local function open_projected_notebook(bufnr, opts)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local project_root, runtime_kind = worker.resolve_runtime(filepath)
	local ok, cells_or_err = pcall(notebook.parse_projected_lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), nil)
	if not ok then
		util.notify("failed to open projected notebook: " .. cells_or_err, vim.log.levels.ERROR)
		return false
	end
	local snapshot = notebook.build_snapshot(filepath, project_root, nil, vim.empty_dict(), cells_or_err)
	local codec_payload, err = serialize_snapshot(filepath, snapshot)
	if err then
		util.notify("failed to serialize notebook: " .. err, vim.log.levels.ERROR)
		return false
	end
	return open_with_snapshot(bufnr, snapshot, runtime_kind, codec_payload, vim.tbl_extend("force", opts or {}, {
		update_buffer_lines = false,
	}))
end

local function open_manual_python(bufnr, opts)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local project_root, runtime_kind = worker.resolve_runtime(filepath)
	local ok, cells_or_err = pcall(notebook.from_manual_python, util.join_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)))
	if not ok then
		util.notify("failed to open marimo buffer: " .. cells_or_err, vim.log.levels.ERROR)
		return false
	end
	local snapshot = notebook.build_snapshot(filepath, project_root, nil, vim.empty_dict(), cells_or_err)
	local codec_payload, err = serialize_snapshot(filepath, snapshot)
	if err then
		util.notify("failed to serialize notebook: " .. err, vim.log.levels.ERROR)
		return false
	end
	return open_with_snapshot(bufnr, snapshot, runtime_kind, codec_payload, vim.tbl_extend("force", opts or {}, {
		update_buffer_lines = true,
	}))
end

local function prepare_snapshot_sync(bufnr)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local previous_cells = vim.deepcopy(vim.b[bufnr].marimo_cells or {})
	local snapshot = current_snapshot(bufnr)
	local changed_ids, delete_ids = notebook.compute_changed_ids(previous_cells, snapshot.cells)
	local codec_payload, err = serialize_snapshot(filepath, snapshot)
	if err then
		return nil, nil, nil, nil, err
	end
	local payload = build_session_payload(snapshot, vim.b[bufnr].marimo_runtime_kind, codec_payload)
	return snapshot, payload, changed_ids, delete_ids, nil
end

local function runnable_changed_ids(cells, changed_ids)
	local changed = {}
	for _, cell_id in ipairs(changed_ids or {}) do
		changed[cell_id] = true
	end
	local run_ids = {}
	for _, cell in ipairs(cells or {}) do
		if changed[cell.id] and not (cell.options or {}).disabled and cell.disabled_transitively ~= true then
			table.insert(run_ids, cell.id)
		end
	end
	return run_ids
end

local function codes_for_cell_ids(cells, cell_ids)
	local wanted = {}
	for _, cell_id in ipairs(cell_ids or {}) do
		wanted[cell_id] = true
	end
	local codes = {}
	for _, cell in ipairs(cells or {}) do
		if wanted[cell.id] then
			table.insert(codes, cell.code)
		end
	end
	return codes
end

local function ensure_runtime_session(bufnr, snapshot)
	local filepath = snapshot.path
	local result, err = worker.request(filepath, "ensure_session", {
		session_id = snapshot.session_id,
		path = snapshot.path,
		project_root = snapshot.project_root,
		runtime_kind = vim.b[bufnr].marimo_runtime_kind,
		snapshot = snapshot,
	})
	if err then
		return nil, err
	end
	return result
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

	enqueue_projected_write(bufnr, filepath, lines)
end

function M.sync_buffer(bufnr, opts)
	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	local snapshot, payload, changed_ids, delete_ids, err = prepare_snapshot_sync(bufnr)
	if err then
		util.notify("failed to sync marimo projection: " .. err, vim.log.levels.ERROR)
		return
	end
	apply_session_payload(bufnr, payload, vim.bo[bufnr].modified, { update_buffer_lines = false })
	if opts.generation and state_for(bufnr).request_id ~= opts.generation then
		return
	end
	if opts.autorun == false then
		return
	end
	local run_ids = runnable_changed_ids(payload.cells, changed_ids)
	if #run_ids == 0 and #delete_ids == 0 then
		return
	end
	if not vim.b[bufnr].marimo_runtime_started and #run_ids > 0 then
		local _, ensure_err = ensure_runtime_session(bufnr, snapshot)
		if ensure_err then
			util.notify("failed to start marimo runtime: " .. ensure_err, vim.log.levels.ERROR)
			return
		end
		vim.b[bufnr].marimo_runtime_started = true
	end
	if #delete_ids > 0 then
		local result, sync_err = worker.request(snapshot.path, "sync_notebook", {
			session_id = snapshot.session_id,
			path = snapshot.path,
			project_root = snapshot.project_root,
			runtime_kind = vim.b[bufnr].marimo_runtime_kind,
			snapshot = snapshot,
			run_ids = {},
			delete_ids = delete_ids,
		})
		if sync_err then
			util.notify("failed to sync marimo runtime: " .. sync_err, vim.log.levels.ERROR)
			return
		end
		if result and result.runtime_cells then
			merge_runtime_cells(bufnr, result.runtime_cells)
		end
	end
	if #run_ids > 0 then
		local result, run_err = worker.request(snapshot.path, "run_cells", {
			session_id = snapshot.session_id,
			cell_ids = run_ids,
			codes = codes_for_cell_ids(payload.cells, run_ids),
		})
		if run_err then
			util.notify("failed to run marimo cells: " .. run_err, vim.log.levels.ERROR)
			return
		end
		if result and result.runtime_cells then
			merge_runtime_cells(bufnr, result.runtime_cells)
		end
	end
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
	local project_root = vim.b[bufnr].marimo_project_root
	local cells = notebook.parse_projected_lines(lines, vim.b[bufnr].marimo_cells)
	local snapshot = notebook.build_snapshot(filepath, project_root, vim.b[bufnr].marimo_header, vim.b[bufnr].marimo_app_options or vim.empty_dict(), cells)
	local payload, err = serialize_snapshot(filepath, snapshot)
	if err then
		util.notify("failed to format marimo projection: " .. err, vim.log.levels.ERROR)
		return false, err
	end
	local session_payload = build_session_payload(snapshot, vim.b[bufnr].marimo_runtime_kind, payload)
	local changed = vim.deep_equal(lines, session_payload.projected_lines or {}) == false
	apply_session_payload(bufnr, session_payload, vim.bo[bufnr].modified or changed, {
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
			M.sync_buffer(bufnr, { generation = generation })
		end)
	end)
end

function M.run_all_cells(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	local snapshot, payload, changed_ids, delete_ids, err = prepare_snapshot_sync(bufnr)
	if err then
		util.notify("failed to sync marimo projection: " .. err, vim.log.levels.ERROR)
		return
	end
	apply_session_payload(bufnr, payload, vim.bo[bufnr].modified, { update_buffer_lines = false })
	stop_autorun_timer(bufnr)
	local entry = state_for(bufnr)
	entry.request_id = entry.request_id + 1
	local request_id = entry.request_id
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local cell_ids = {}
	local codes = {}
	for _, cell in ipairs(vim.b[bufnr].marimo_cells or {}) do
		table.insert(cell_ids, cell.id)
		table.insert(codes, cell.code)
	end
	if not vim.b[bufnr].marimo_runtime_started then
		local _, ensure_err = ensure_runtime_session(bufnr, snapshot)
		if ensure_err then
			util.notify("failed to start marimo runtime: " .. ensure_err, vim.log.levels.ERROR)
			return
		end
		vim.b[bufnr].marimo_runtime_started = true
	end
	local run_ids = runnable_changed_ids(payload.cells, changed_ids)
	if #run_ids > 0 or #delete_ids > 0 then
		local sync_result, sync_err = worker.request(filepath, "sync_notebook", {
			session_id = snapshot.session_id,
			path = snapshot.path,
			project_root = snapshot.project_root,
			runtime_kind = vim.b[bufnr].marimo_runtime_kind,
			snapshot = snapshot,
			run_ids = run_ids,
			delete_ids = delete_ids,
		})
		if sync_err then
			util.notify("failed to sync marimo runtime: " .. sync_err, vim.log.levels.ERROR)
			return
		end
		if sync_result and sync_result.runtime_cells then
			merge_runtime_cells(bufnr, sync_result.runtime_cells)
		end
	end
	mark_cells_pending(bufnr, cell_ids)
	worker.request_async(filepath, "run_cells", {
		session_id = vim.b[bufnr].marimo_session_id,
		cell_ids = cell_ids,
		codes = codes,
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
	local snapshot, payload, changed_ids, delete_ids, err = prepare_snapshot_sync(bufnr)
	if err then
		util.notify("failed to sync marimo projection: " .. err, vim.log.levels.ERROR)
		return
	end
	apply_session_payload(bufnr, payload, vim.bo[bufnr].modified, { update_buffer_lines = false })
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
	if not vim.b[bufnr].marimo_runtime_started then
		local _, ensure_err = ensure_runtime_session(bufnr, snapshot)
		if ensure_err then
			util.notify("failed to start marimo runtime: " .. ensure_err, vim.log.levels.ERROR)
			return
		end
		vim.b[bufnr].marimo_runtime_started = true
	end
	local run_ids = runnable_changed_ids(payload.cells, changed_ids)
	if #run_ids > 0 or #delete_ids > 0 then
		local sync_result, sync_err = worker.request(filepath, "sync_notebook", {
			session_id = snapshot.session_id,
			path = snapshot.path,
			project_root = snapshot.project_root,
			runtime_kind = vim.b[bufnr].marimo_runtime_kind,
			snapshot = snapshot,
			run_ids = run_ids,
			delete_ids = delete_ids,
		})
		if sync_err then
			util.notify("failed to sync marimo runtime: " .. sync_err, vim.log.levels.ERROR)
			return
		end
		if sync_result and sync_result.runtime_cells then
			merge_runtime_cells(bufnr, sync_result.runtime_cells)
		end
	end
	mark_cells_pending(bufnr, { cell.id })
	worker.request_async(filepath, "run_cells", {
		session_id = vim.b[bufnr].marimo_session_id,
		cell_ids = { cell.id },
		codes = { cell.code },
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
		open_projected_notebook(bufnr, opts)
		return
	end

	if markers.has_any_projected_markers(lines) then
		if opts.manual then
			open_manual_python(bufnr, opts)
		end
		return
	end

	if opts.manual then
		open_manual_python(bufnr, opts)
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
