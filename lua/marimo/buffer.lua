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

local function default_runtime()
	return {
		status = nil,
		stale_inputs = false,
		output = nil,
		console = {},
		last_run_timestamp = nil,
		last_execution_time_ms = nil,
	}
end

local function project_root(filepath)
	return worker._private.find_project_root(filepath)
end

local function localize_loaded_cells(cells, previous_cells)
	local projected_lines = markers.render_projected_buffer_lines(cells)
	return markers.parse_projected_snapshot(projected_lines, previous_cells)
end

local function snapshot_for(bufnr, cells)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	return {
		session_id = filepath,
		path = filepath,
		project_root = project_root(filepath),
		header = vim.b[bufnr].marimo_header,
		app_options = util.as_json_object(vim.b[bufnr].marimo_app_options or {}),
		cells = vim.deepcopy(cells),
	}
end

local function merged_runtime_cell(current, op)
	local runtime = vim.deepcopy(current or default_runtime())
	local function has_value(value)
		return value ~= nil and value ~= vim.NIL
	end
	if has_value(op.status) then
		runtime.status = op.status
	end
	if has_value(op.stale_inputs) then
		runtime.stale_inputs = op.stale_inputs
	end
	if has_value(op.output) then
		runtime.output = op.output
	end
	if has_value(op.console) then
		if op.status == "running" and runtime.status == "queued" then
			runtime.console = {}
		end
		local items = vim.deepcopy(runtime.console or {})
		if vim.tbl_islist(op.console) then
			if #op.console == 0 then
				items = {}
			else
				vim.list_extend(items, op.console)
			end
		else
			table.insert(items, op.console)
		end
		runtime.console = items
	end
	return runtime
end

local function refresh_render(bufnr)
	local by_id = vim.b[bufnr].marimo_runtime_cells or {}
	for _, cell in ipairs(vim.b[bufnr].marimo_cells or {}) do
		cell.runtime = by_id[cell.id] or default_runtime()
	end
	render.render(bufnr, vim.b[bufnr].marimo_cells or {})
	output_window.refresh(bufnr)
	util.request_redraw()
end

local function set_cells(bufnr, cells, serialized, keep_modified, update_buffer_lines)
	local projected_lines = markers.render_projected_buffer_lines(cells)
	if update_buffer_lines and vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), projected_lines) == false then
		with_internal_buffer_update(bufnr, function()
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, projected_lines)
		end)
	end
	local projection_map = markers.build_projection_map(cells, serialized.canonical_ranges or {})
	session.set_snapshot(bufnr, {
		session_id = vim.api.nvim_buf_get_name(bufnr),
		project_root = project_root(vim.api.nvim_buf_get_name(bufnr)),
		header = vim.b[bufnr].marimo_header,
		app_options = vim.b[bufnr].marimo_app_options or vim.empty_dict(),
		cells = cells,
		projection_map = projection_map,
		canonical_source = serialized.canonical_source,
		last_saved_source_hash = serialized.last_saved_source_hash or vim.b[bufnr].marimo_last_saved_source_hash,
		runtime_enabled = vim.b[bufnr].marimo_runtime_enabled == true,
	})
	lsp_bridge.sync_mirror(bufnr, serialized.canonical_source)
	vim.bo[bufnr].modified = keep_modified and true or false
	refresh_render(bufnr)
end

local function serialize_snapshot(filepath, snapshot)
	return worker.request(filepath, "serialize_notebook", { snapshot = snapshot })
end

local function parse_projected_cells_for_buffer(bufnr, lines, previous_cells)
	local cells = markers.parse_projected_snapshot(lines, previous_cells)
	if #cells == 0 then
		error("projected marimo buffer has no `# +` cells")
	end
	return cells
end

local function parse_open_cells(bufnr, input_kind)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if input_kind == "projected" then
		return parse_projected_cells_for_buffer(bufnr, lines, nil), nil, vim.empty_dict()
	end
	if input_kind == "generic_projected_promotable" then
		local promoted, changed = markers.promote_first_marker_to_marimo(lines)
		if not changed then
			error("buffer is neither a real marimo notebook nor a projected `# +` notebook")
		end
		return parse_projected_cells_for_buffer(bufnr, promoted, nil), nil, vim.empty_dict()
	end
	if input_kind == "manual_python" then
		return markers.wrap_manual_python(lines), nil, vim.empty_dict()
	end
	error("unsupported input kind: " .. tostring(input_kind))
end

local function ensure_runtime_session(bufnr, cells)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local snapshot = snapshot_for(bufnr, cells)
	local result, err = worker.request(filepath, "ensure_session", {
		session_id = filepath,
		path = filepath,
		project_root = snapshot.project_root,
		plugin_root = worker._private.plugin_root(),
		snapshot = snapshot,
	})
	if err then
		return nil, err
	end
	vim.b[bufnr].marimo_runtime_enabled = true
	return result
end

local function sync_runtime(bufnr, cells, run_ids, delete_ids, callback, event_callback)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local snapshot = snapshot_for(bufnr, cells)
	return worker.request_async(filepath, "sync_notebook", {
		session_id = filepath,
		path = filepath,
		project_root = snapshot.project_root,
		plugin_root = worker._private.plugin_root(),
		snapshot = snapshot,
		run_ids = run_ids,
		delete_ids = delete_ids,
	}, callback, event_callback)
end

local function run_runtime_cells(bufnr, cells, cell_ids, callback, event_callback)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local code_by_id = {}
	for _, cell in ipairs(cells) do
		code_by_id[cell.id] = cell.code
	end
	local codes = {}
	for _, cell_id in ipairs(cell_ids) do
		table.insert(codes, code_by_id[cell_id])
	end
	return worker.request_async(filepath, "run_cells", {
		session_id = filepath,
		cell_ids = cell_ids,
		codes = codes,
	}, callback, event_callback)
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

local function apply_operation(bufnr, operation)
	if type(operation) ~= "table" then
		return
	end
	local name = operation.op or operation.name
	if name == "cell-op" then
		local by_id = vim.b[bufnr].marimo_runtime_cells or {}
		local cell_id = operation.cell_id
		by_id[cell_id] = merged_runtime_cell(by_id[cell_id], operation)
		vim.b[bufnr].marimo_runtime_cells = by_id
		refresh_render(bufnr)
		return
	end
	if name == "interrupted" then
		local by_id = vim.b[bufnr].marimo_runtime_cells or {}
		for cell_id, runtime in pairs(by_id) do
			if runtime.status == "running" or runtime.status == "queued" then
				runtime.status = "idle"
				by_id[cell_id] = runtime
			end
		end
		vim.b[bufnr].marimo_runtime_cells = by_id
		refresh_render(bufnr)
	end
end

local function apply_operation_batch(bufnr, payload)
	if type(payload) ~= "table" then
		return
	end
	for _, operation in ipairs(payload.operations or {}) do
		apply_operation(bufnr, operation)
	end
end

local function handle_async_operation(bufnr, request_id, event)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	if request_id and state_for(bufnr).request_id ~= request_id then
		return
	end
	if type(event) ~= "table" or event.event ~= "operation" then
		return
	end
	apply_operation(bufnr, event.operation)
end

local function mark_cells_pending(bufnr, cell_ids)
	local by_id = vim.b[bufnr].marimo_runtime_cells or {}
	for _, cell_id in ipairs(cell_ids or {}) do
		local runtime = vim.deepcopy(by_id[cell_id] or default_runtime())
		runtime.status = runtime.status == "running" and "running" or "queued"
		runtime.stale_inputs = false
		by_id[cell_id] = runtime
	end
	vim.b[bufnr].marimo_runtime_cells = by_id
	refresh_render(bufnr)
end

local function current_cells_from_buffer(bufnr, previous_cells)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	return parse_projected_cells_for_buffer(bufnr, lines, previous_cells)
end

local function build_and_apply_snapshot(bufnr, cells, keep_modified, update_buffer_lines)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local snapshot = snapshot_for(bufnr, cells)
	local serialized, err = serialize_snapshot(filepath, snapshot)
	if err then
		return nil, err
	end
	set_cells(bufnr, cells, serialized, keep_modified, update_buffer_lines)
	return {
		cells = cells,
		snapshot = snapshot,
		serialized = serialized,
	}, nil
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
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	if entry.pending_write then
		return
	end
	vim.fn.writefile(vim.split(payload.canonical_source, "\n", { plain = true }), request.filepath)
	vim.b[bufnr].marimo_canonical_source = payload.canonical_source
	vim.b[bufnr].marimo_last_saved_source_hash = payload.last_saved_source_hash
	lsp_bridge.sync_mirror(bufnr, vim.b[bufnr].marimo_canonical_source)
	if vim.api.nvim_buf_get_changedtick(bufnr) == request.changedtick then
		vim.bo[bufnr].modified = false
	end
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
	util.show_write_message(bufnr)
end

local function enqueue_projected_write(bufnr, filepath, cells)
	local entry = state_for(bufnr)
	entry.write_generation = entry.write_generation + 1
	local request = {
		generation = entry.write_generation,
		filepath = filepath,
		changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
		params = {
			snapshot = snapshot_for(bufnr, cells),
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

local function open_raw_notebook(bufnr, opts)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local keep_modified = vim.bo[bufnr].modified
	local payload, err = worker.request(filepath, "load_raw_notebook", {
		path = filepath,
		content = util.join_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)),
		project_root = project_root(filepath),
	})
	if err then
		util.notify("failed to load marimo notebook: " .. err, vim.log.levels.ERROR)
		return false
	end
	vim.b[bufnr].marimo_header = payload.header
	vim.b[bufnr].marimo_app_options = payload.app_options or vim.empty_dict()
	local cells = localize_loaded_cells(payload.cells or {}, nil)
	local result, serialize_err = build_and_apply_snapshot(bufnr, cells, keep_modified, true)
	if serialize_err then
		util.notify("failed to serialize marimo notebook: " .. serialize_err, vim.log.levels.ERROR)
		return false
	end
	if opts.ensure_projected_buffer_setup then
		opts.ensure_projected_buffer_setup(bufnr)
	end
	return result ~= nil
end

local function open_local_projection(bufnr, input_kind, opts)
	local keep_modified = vim.bo[bufnr].modified
	local cells, header, app_options = parse_open_cells(bufnr, input_kind)
	vim.b[bufnr].marimo_header = header
	vim.b[bufnr].marimo_app_options = app_options
	local result, err = build_and_apply_snapshot(bufnr, cells, keep_modified, input_kind ~= "projected")
	if err then
		util.notify("failed to activate marimo buffer: " .. err, vim.log.levels.ERROR)
		return false
	end
	if opts.ensure_projected_buffer_setup then
		opts.ensure_projected_buffer_setup(bufnr)
	end
	return result ~= nil
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
	local cells = current_cells_from_buffer(bufnr, vim.b[bufnr].marimo_cells or {})
	local result, err = build_and_apply_snapshot(bufnr, cells, true, false)
	if err then
		util.notify("failed to write marimo notebook: " .. err, vim.log.levels.ERROR)
		return
	end
	enqueue_projected_write(bufnr, filepath, result.cells)
end

function M.sync_buffer(bufnr, opts)
	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	local previous_cells = vim.b[bufnr].marimo_cells or {}
	local keep_modified = vim.bo[bufnr].modified
	local cells = current_cells_from_buffer(bufnr, previous_cells)
	local changed_ids, delete_ids = markers.compute_changed_and_deleted(previous_cells, cells)
	local result, err = build_and_apply_snapshot(bufnr, cells, keep_modified, false)
	if err then
		util.notify("failed to sync marimo projection: " .. err, vim.log.levels.ERROR)
		return
	end
	if opts.autorun == false then
		if vim.b[bufnr].marimo_runtime_enabled then
			local _, ensure_err = ensure_runtime_session(bufnr, result.cells)
			if ensure_err then
				util.notify("failed to start marimo runtime: " .. ensure_err, vim.log.levels.ERROR)
				return
			end
			local sync_result, sync_err = worker.request(vim.api.nvim_buf_get_name(bufnr), "sync_notebook", {
				session_id = vim.api.nvim_buf_get_name(bufnr),
				path = vim.api.nvim_buf_get_name(bufnr),
				project_root = project_root(vim.api.nvim_buf_get_name(bufnr)),
				plugin_root = worker._private.plugin_root(),
				snapshot = result.snapshot,
				run_ids = {},
				delete_ids = delete_ids,
			})
			if sync_err then
				util.notify("failed to sync marimo runtime: " .. sync_err, vim.log.levels.ERROR)
				return
			end
			return sync_result
		end
		return result
	end
	local run_ids = {}
	for _, cell in ipairs(result.cells) do
		local disabled = (cell.options or {}).disabled == true
		local changed = false
		for _, changed_id in ipairs(changed_ids) do
			if changed_id == cell.id then
				changed = true
				break
			end
		end
		if changed and not disabled then
			table.insert(run_ids, cell.id)
		end
	end
	if #run_ids == 0 and #delete_ids == 0 then
		return result
	end
	local _, ensure_err = ensure_runtime_session(bufnr, result.cells)
	if ensure_err then
		util.notify("failed to start marimo runtime: " .. ensure_err, vim.log.levels.ERROR)
		return
	end
	mark_cells_pending(bufnr, run_ids)
	local sync_result, sync_err = worker.request(vim.api.nvim_buf_get_name(bufnr), "sync_notebook", {
		session_id = vim.api.nvim_buf_get_name(bufnr),
		path = vim.api.nvim_buf_get_name(bufnr),
		project_root = project_root(vim.api.nvim_buf_get_name(bufnr)),
		plugin_root = worker._private.plugin_root(),
		snapshot = result.snapshot,
		run_ids = run_ids,
		delete_ids = delete_ids,
	})
	if sync_err then
		util.notify("failed to sync marimo runtime: " .. sync_err, vim.log.levels.ERROR)
		return
	end
	return sync_result
end

function M.format_buffer(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not markers.has_any_projected_markers(lines) then
		return false, "current buffer is not a projected marimo buffer"
	end
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
			local previous_cells = vim.b[bufnr].marimo_cells or {}
			local keep_modified = vim.bo[bufnr].modified
			local ok, cells = pcall(current_cells_from_buffer, bufnr, previous_cells)
			if not ok then
				util.notify(cells, vim.log.levels.ERROR)
				return
			end
			local changed_ids, delete_ids = markers.compute_changed_and_deleted(previous_cells, cells)
			local built, err = build_and_apply_snapshot(bufnr, cells, keep_modified, false)
			if err then
				util.notify("failed to sync marimo projection: " .. err, vim.log.levels.ERROR)
				return
			end
			local run_ids = {}
			for _, cell in ipairs(built.cells) do
				for _, changed_id in ipairs(changed_ids) do
					if changed_id == cell.id and not ((cell.options or {}).disabled == true) then
						table.insert(run_ids, cell.id)
					end
				end
			end
			if #run_ids == 0 and #delete_ids == 0 then
				return
			end
			local _, ensure_err = ensure_runtime_session(bufnr, built.cells)
			if ensure_err then
				util.notify("failed to start marimo runtime: " .. ensure_err, vim.log.levels.ERROR)
				return
			end
			mark_cells_pending(bufnr, run_ids)
			sync_runtime(bufnr, built.cells, run_ids, delete_ids, function(payload, async_err)
				if async_err then
					util.notify(async_err, vim.log.levels.ERROR)
				else
					apply_operation_batch(bufnr, payload)
				end
			end, function(event)
				handle_async_operation(bufnr, generation, event)
			end)
		end)
	end)
end

function M.run_all_cells(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	stop_autorun_timer(bufnr)
	local previous_cells = vim.b[bufnr].marimo_cells or {}
	local cells = current_cells_from_buffer(bufnr, previous_cells)
	local _, delete_ids = markers.compute_changed_and_deleted(previous_cells, cells)
	local built, err = build_and_apply_snapshot(bufnr, cells, vim.bo[bufnr].modified, false)
	if err then
		util.notify("failed to prepare marimo runtime: " .. err, vim.log.levels.ERROR)
		return
	end
	local _, ensure_err = ensure_runtime_session(bufnr, built.cells)
	if ensure_err then
		util.notify("failed to start marimo runtime: " .. ensure_err, vim.log.levels.ERROR)
		return
	end
	if #delete_ids > 0 then
		local _, sync_err = worker.request(vim.api.nvim_buf_get_name(bufnr), "sync_notebook", {
			session_id = vim.api.nvim_buf_get_name(bufnr),
			path = vim.api.nvim_buf_get_name(bufnr),
			project_root = project_root(vim.api.nvim_buf_get_name(bufnr)),
			plugin_root = worker._private.plugin_root(),
			snapshot = built.snapshot,
			run_ids = {},
			delete_ids = delete_ids,
		})
		if sync_err then
			util.notify("failed to sync marimo runtime: " .. sync_err, vim.log.levels.ERROR)
			return
		end
	end
	local cell_ids = {}
	for _, cell in ipairs(built.cells) do
		table.insert(cell_ids, cell.id)
	end
	local entry = state_for(bufnr)
	entry.request_id = entry.request_id + 1
	mark_cells_pending(bufnr, cell_ids)
	local codes = {}
	for _, cell in ipairs(built.cells) do
		table.insert(codes, cell.code)
	end
	local payload, run_err = worker.request(vim.api.nvim_buf_get_name(bufnr), "run_cells", {
		session_id = vim.api.nvim_buf_get_name(bufnr),
		cell_ids = cell_ids,
		codes = codes,
	})
	if run_err then
		util.notify(run_err, vim.log.levels.ERROR)
		return
	end
	apply_operation_batch(bufnr, payload)
end

function M.run_current_cell(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_session_id then
		return
	end
	stop_autorun_timer(bufnr)
	local previous_cells = vim.b[bufnr].marimo_cells or {}
	local cells = current_cells_from_buffer(bufnr, previous_cells)
	local _, delete_ids = markers.compute_changed_and_deleted(previous_cells, cells)
	local built, err = build_and_apply_snapshot(bufnr, cells, vim.bo[bufnr].modified, false)
	if err then
		util.notify("failed to prepare marimo runtime: " .. err, vim.log.levels.ERROR)
		return
	end
	local cell = navigation.find_current_cell(bufnr)
	if not cell then
		util.notify("no current marimo cell", vim.log.levels.WARN)
		return
	end
	local _, ensure_err = ensure_runtime_session(bufnr, built.cells)
	if ensure_err then
		util.notify("failed to start marimo runtime: " .. ensure_err, vim.log.levels.ERROR)
		return
	end
	if #delete_ids > 0 then
		local _, sync_err = worker.request(vim.api.nvim_buf_get_name(bufnr), "sync_notebook", {
			session_id = vim.api.nvim_buf_get_name(bufnr),
			path = vim.api.nvim_buf_get_name(bufnr),
			project_root = project_root(vim.api.nvim_buf_get_name(bufnr)),
			plugin_root = worker._private.plugin_root(),
			snapshot = built.snapshot,
			run_ids = {},
			delete_ids = delete_ids,
		})
		if sync_err then
			util.notify("failed to sync marimo runtime: " .. sync_err, vim.log.levels.ERROR)
			return
		end
	end
	local entry = state_for(bufnr)
	entry.request_id = entry.request_id + 1
	mark_cells_pending(bufnr, { cell.id })
	local payload, run_err = worker.request(vim.api.nvim_buf_get_name(bufnr), "run_cells", {
		session_id = vim.api.nvim_buf_get_name(bufnr),
		cell_ids = { cell.id },
		codes = { cell.code },
	})
	if run_err then
		util.notify(run_err, vim.log.levels.ERROR)
		return
	end
	apply_operation_batch(bufnr, payload)
end

function M.interrupt(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected or not vim.b[bufnr].marimo_runtime_enabled then
		return
	end
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	worker.request_async(filepath, "interrupt", {
		session_id = filepath,
	}, function(_, err)
		if err then
			util.notify(err, vim.log.levels.ERROR)
		end
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
		open_local_projection(bufnr, "projected", opts)
		return
	end
	if markers.has_any_projected_markers(lines) then
		if opts.manual then
			open_local_projection(bufnr, "generic_projected_promotable", opts)
		end
		return
	end
	if opts.manual then
		open_local_projection(bufnr, "manual_python", opts)
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
			refresh_render(bufnr)
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
				refresh_render(bufnr)
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
	if session_id and filepath ~= "" and vim.b[bufnr].marimo_runtime_enabled then
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
