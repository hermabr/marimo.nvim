local M = {}
local uv = vim.uv or vim.loop

local function is_nil_like(value)
	return value == nil or value == vim.NIL
end

local function default_runtime()
	return {
		status = nil,
		stale_inputs = false,
		output = nil,
		console = {},
		last_execution_time_ms = nil,
		_running_started_at_ns = nil,
	}
end

local function as_list(value)
	if is_nil_like(value) then
		return {}
	end
	if vim.islist(value) then
		return value
	end
	return { value }
end

local function merge_consecutive_console(console)
	local merged = {}
	for _, entry in ipairs(console or {}) do
		if type(entry) ~= "table" then
			goto continue
		end
		local previous = merged[#merged]
		if previous
			and type(previous) == "table"
			and previous.mimetype == "text/plain"
			and entry.mimetype == "text/plain"
			and previous.channel == entry.channel
			and type(previous.data) == "string"
			and type(entry.data) == "string"
		then
			previous.data = previous.data .. entry.data
		else
			table.insert(merged, vim.deepcopy(entry))
		end
		::continue::
	end
	return merged
end

local function clear_pending_statuses(runtime_by_id)
	local changed_ids = {}
	for cell_id, runtime in pairs(runtime_by_id) do
		if runtime.status == "queued" or runtime.status == "running" then
			runtime.status = "idle"
			runtime._running_timestamp = nil
			runtime._running_started_at_ns = nil
			table.insert(changed_ids, cell_id)
		end
	end
	if #changed_ids == 0 then
		return runtime_by_id, false, nil
	end
	return runtime_by_id, true, changed_ids
end

function M.apply_operation(runtime_by_id, operation)
	if type(operation) ~= "table" then
		return runtime_by_id, false, nil
	end
	local op = operation.op
	if op == "cell-op" then
		local cell_id = operation.cell_id
		if not cell_id then
			return runtime_by_id, false, nil
		end
		local previous = runtime_by_id[cell_id] or default_runtime()
		local next_runtime = vim.deepcopy(previous)
		local next_status = operation.status
		if not is_nil_like(next_status) then
			if next_status == "running" and previous.status == "queued" then
				next_runtime.console = {}
			end
			if previous.status == "running" and next_status ~= "running" then
				if next_status == "idle" then
					local previous_timestamp = previous._running_timestamp or operation.timestamp
					if previous_timestamp and operation.timestamp then
						next_runtime.last_execution_time_ms =
							math.floor(math.max(operation.timestamp - previous_timestamp, 0) * 1000)
					elseif type(previous._running_started_at_ns) == "number" and uv and type(uv.hrtime) == "function" then
						next_runtime.last_execution_time_ms =
							math.floor(math.max((uv.hrtime() - previous._running_started_at_ns) / 1000000, 0))
					end
				end
				next_runtime._running_timestamp = nil
				next_runtime._running_started_at_ns = nil
			elseif next_status == "running" then
				next_runtime._running_timestamp = previous._running_timestamp or operation.timestamp
				if type(previous._running_started_at_ns) == "number" then
					next_runtime._running_started_at_ns = previous._running_started_at_ns
				elseif uv and type(uv.hrtime) == "function" then
					next_runtime._running_started_at_ns = uv.hrtime()
				end
			end
			next_runtime.status = next_status
		end
		if not is_nil_like(operation.stale_inputs) then
			next_runtime.stale_inputs = operation.stale_inputs
		end
		if not is_nil_like(operation.output) then
			next_runtime.output = vim.deepcopy(operation.output)
		end
		local combined_console = as_list(previous.console)
		vim.list_extend(combined_console, as_list(operation.console))
		next_runtime.console = merge_consecutive_console(combined_console)
		runtime_by_id[cell_id] = next_runtime
		return runtime_by_id, true, { cell_id }
	end
	if op == "completed-run" then
		return clear_pending_statuses(runtime_by_id)
	end
	if op == "interrupted" then
		return clear_pending_statuses(runtime_by_id)
	end
	return runtime_by_id, false, nil
end

function M.attach_runtime(cells, runtime_by_id)
	local attached = {}
	for _, cell in ipairs(cells or {}) do
		local next_cell = vim.deepcopy(cell)
		next_cell.runtime = vim.deepcopy(runtime_by_id[next_cell.id] or default_runtime())
		table.insert(attached, next_cell)
	end
	return attached
end

function M.attach_runtime_in_place(cells, runtime_by_id, cell_ids)
	local target_lookup = nil
	if cell_ids ~= nil then
		target_lookup = {}
		for _, cell_id in ipairs(cell_ids) do
			target_lookup[cell_id] = true
		end
	end

	for _, cell in ipairs(cells or {}) do
		if target_lookup == nil or target_lookup[cell.id] or cell.runtime == nil then
			cell.runtime = vim.deepcopy(runtime_by_id[cell.id] or default_runtime())
		end
	end
	return cells
end

function M.filter_runtime(runtime_by_id, cells)
	local keep = {}
	for _, cell in ipairs(cells or {}) do
		if runtime_by_id[cell.id] ~= nil then
			keep[cell.id] = runtime_by_id[cell.id]
		end
	end
	return keep
end

return M
