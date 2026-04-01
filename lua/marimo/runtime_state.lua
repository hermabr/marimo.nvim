local M = {}

local function empty_runtime()
	return {
		status = nil,
		stale_inputs = false,
		output = nil,
		console = {},
		last_run_timestamp = nil,
		last_execution_time_ms = nil,
	}
end

local function is_nullish(value)
	return value == nil or value == vim.NIL
end

local function append_console(current, update)
	if is_nullish(update) then
		return current
	end
	if vim.islist(update) then
		if #update == 0 then
			return {}
		end
		local next_console = vim.deepcopy(current or {})
		for _, item in ipairs(update) do
			table.insert(next_console, vim.deepcopy(item))
		end
		return next_console
	end
	local next_console = vim.deepcopy(current or {})
	table.insert(next_console, vim.deepcopy(update))
	return next_console
end

function M.apply_operation(runtime_by_id, operation)
	if type(operation) ~= "table" then
		return runtime_by_id, false
	end

	local updated = false
	local next_runtime = runtime_by_id or {}
	local name = operation.op or operation.name

	if name == "cell-op" then
		local cell_id = operation.cell_id
		if not cell_id then
			return next_runtime, false
		end
		local runtime = vim.deepcopy(next_runtime[cell_id] or empty_runtime())
		if not is_nullish(operation.status) then
			runtime.status = operation.status
			updated = true
		end
		if not is_nullish(operation.stale_inputs) then
			runtime.stale_inputs = operation.stale_inputs == true
			updated = true
		end
		if not is_nullish(operation.output) then
			runtime.output = vim.deepcopy(operation.output)
			updated = true
		end
		if not is_nullish(operation.console) then
			runtime.console = append_console(runtime.console, operation.console)
			updated = true
		end
		if not is_nullish(operation.timestamp) and operation.status == "idle" then
			runtime.last_run_timestamp = operation.timestamp
		end
		next_runtime[cell_id] = runtime
		return next_runtime, updated
	end

	if name == "interrupted" then
		for cell_id, runtime in pairs(next_runtime) do
			if runtime.status == "running" or runtime.status == "queued" then
				runtime.status = "idle"
				next_runtime[cell_id] = runtime
				updated = true
			end
		end
	end

	return next_runtime, updated
end

function M.empty_runtime()
	return empty_runtime()
end

return M
