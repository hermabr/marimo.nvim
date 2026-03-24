local source = debug.getinfo(1, "S").source:sub(2)
local M = {}

local workers = {}
local next_request_id = 0

local function extract_internal_error_id(runtime)
	if type(runtime) ~= "table" then
		return nil
	end
	if runtime.output_kind ~= "error" then
		return nil
	end
	for _, line in ipairs(runtime.output_lines or {}) do
		local error_id = tostring(line):match("An internal error occurred:%s*([%w%-]+)")
		if error_id then
			return error_id
		end
	end
	return nil
end

local function append_unique_lines(target, lines)
	local seen = {}
	for _, line in ipairs(target) do
		seen[line] = true
	end
	for _, line in ipairs(lines or {}) do
		if line ~= "" and not seen[line] then
			table.insert(target, line)
			seen[line] = true
		end
	end
	return target
end

local function enrich_runtime_errors(runtime, error_details)
	local error_id = extract_internal_error_id(runtime)
	if not error_id then
		return runtime
	end
	local details = error_details[error_id]
	if type(details) ~= "table" or #details == 0 then
		return runtime
	end
	local enriched = vim.deepcopy(runtime)
	enriched.output_lines = append_unique_lines(vim.deepcopy(enriched.output_lines or {}), details)
	return enriched
end

local function enrich_payload_errors(payload, error_details)
	if type(payload) ~= "table" then
		return payload
	end
	local enriched = vim.deepcopy(payload)
	if type(enriched.cells) == "table" then
		for _, cell in ipairs(enriched.cells) do
			if type(cell) == "table" and type(cell.runtime) == "table" then
				cell.runtime = enrich_runtime_errors(cell.runtime, error_details)
			end
		end
	end
	if type(enriched.runtime_cells) == "table" then
		for cell_id, runtime in pairs(enriched.runtime_cells) do
			enriched.runtime_cells[cell_id] = enrich_runtime_errors(runtime, error_details)
		end
	end
	return enriched
end

local function find_project_root(path)
	local absolute = vim.fn.fnamemodify(path, ":p")
	local dirpath = vim.fn.fnamemodify(absolute, ":h")
	local fallback = dirpath
	local previous = nil
	while dirpath ~= previous and dirpath ~= "" do
		if vim.uv.fs_stat(dirpath .. "/uv.lock") then
			return dirpath, true
		end
		if vim.uv.fs_stat(dirpath .. "/pyproject.toml") then
			return dirpath, true
		end
		previous = dirpath
		dirpath = vim.fn.fnamemodify(dirpath, ":h")
	end
	return fallback, false
end

local function worker_script_path()
	local root = vim.fn.fnamemodify(source, ":p:h:h:h")
	return root
end

local function launch_spec(path)
	local project_root, has_project = find_project_root(path)
	local root = worker_script_path()
	local cmd = { "uv", "run" }
	local runtime_kind = "uv"
	if has_project then
		vim.list_extend(cmd, { "--project", project_root })
		runtime_kind = "uv_project"
	end
	vim.list_extend(cmd, { "--directory", root, "--with", "marimo", "python", "-m", "marimo_nvim_py.worker" })
	return {
		project_root = project_root,
		runtime_kind = runtime_kind,
		cmd = cmd,
	}
end

local function ensure_worker(path)
	local spec = launch_spec(path)
	local project_root = spec.project_root
	local existing = workers[project_root]
	if existing and existing.job_id and vim.fn.jobwait({ existing.job_id }, 0)[1] == -1 then
		return existing
	end

	local last_error = nil
	local worker = {
		project_root = project_root,
		pending = {},
		stdout_buffer = "",
		stderr_buffer = "",
		runtime_kind = spec.runtime_kind,
		error_details = {},
		active_error = nil,
	}

	local function finish_error_block()
		local active = worker.active_error
		if not active then
			return
		end
		if #active.lines > 0 then
			worker.error_details[active.id] = vim.deepcopy(active.lines)
		end
		worker.active_error = nil
	end

	local function capture_stderr_line(line)
		if line == "" then
			finish_error_block()
			return
		end
		local error_id, rest = line:match("error_id=([%w%-]+)%)%s*(.*)$")
		if error_id then
			finish_error_block()
			worker.active_error = { id = error_id, lines = {} }
			if rest and rest ~= "" then
				table.insert(worker.active_error.lines, rest)
			end
			return
		end
		local active = worker.active_error
		if not active then
			return
		end
		if line:match("^%s") then
			table.insert(active.lines, line)
			return
		end
		finish_error_block()
	end

	local function dispatch_response(decoded)
		finish_error_block()
		local pending = worker.pending[decoded.id]
		if not pending then
			return
		end
		if decoded.ok then
			decoded.result = enrich_payload_errors(decoded.result, worker.error_details)
		end
		pending.response = decoded
		if pending.callback then
			worker.pending[decoded.id] = nil
			vim.schedule(function()
				if decoded.ok then
					pending.callback(decoded.result, nil)
				else
					pending.callback(nil, decoded.error and decoded.error.message or "marimo worker error")
				end
			end)
		end
	end

	local function dispatch_event(decoded)
		finish_error_block()
		local pending = worker.pending[decoded.request_id]
		if not pending or not pending.event_callback then
			return
		end
		decoded.payload = enrich_payload_errors(decoded.payload, worker.error_details)
		vim.schedule(function()
			pending.event_callback(decoded)
		end)
	end

	local function handle_stdout_line(line)
		if line == "" then
			return
		end
		local ok, decoded = pcall(vim.json.decode, line)
		if not ok or type(decoded) ~= "table" then
			last_error = "failed to decode marimo worker response: " .. line
			return
		end
		if decoded.event ~= nil then
			dispatch_event(decoded)
			return
		end
		if decoded.id ~= nil then
			dispatch_response(decoded)
			return
		end
		last_error = "failed to decode marimo worker response: " .. line
	end

	worker.job_id = vim.fn.jobstart(spec.cmd, {
		stdout_buffered = false,
		stderr_buffered = false,
		on_stdout = function(_, data)
			if not data or #data == 0 then
				return
			end
			worker.stdout_buffer = worker.stdout_buffer .. table.concat(data, "\n")
			while true do
				local newline = worker.stdout_buffer:find("\n", 1, true)
				if not newline then
					break
				end
				local line = worker.stdout_buffer:sub(1, newline - 1)
				worker.stdout_buffer = worker.stdout_buffer:sub(newline + 1)
				handle_stdout_line(line)
			end
		end,
		on_stderr = function(_, data)
			if not data then
				return
			end
			worker.stderr_buffer = worker.stderr_buffer .. table.concat(data, "\n")
			while true do
				local newline = worker.stderr_buffer:find("\n", 1, true)
				if not newline then
					break
				end
				local line = worker.stderr_buffer:sub(1, newline - 1)
				worker.stderr_buffer = worker.stderr_buffer:sub(newline + 1)
				capture_stderr_line(line)
				if line:gsub("%s+", "") ~= "" then
					last_error = line
				end
			end
		end,
		on_exit = function()
			if worker.stderr_buffer ~= "" then
				capture_stderr_line(worker.stderr_buffer)
				worker.stderr_buffer = ""
			end
			finish_error_block()
			for request_id, pending in pairs(worker.pending) do
				if pending.callback then
					vim.schedule(function()
						pending.callback(nil, last_error or "marimo worker exited")
					end)
				end
				worker.pending[request_id] = nil
			end
			workers[project_root] = nil
		end,
	})

	if worker.job_id > 0 then
		local status = vim.fn.jobwait({ worker.job_id }, 100)[1]
		if status == -1 then
			workers[project_root] = worker
			return worker
		end
		pcall(vim.fn.jobstop, worker.job_id)
		last_error = last_error or ("failed to start worker with " .. table.concat(spec.cmd, " "))
	else
		last_error = last_error or ("failed to start worker with " .. table.concat(spec.cmd, " "))
	end
	error(last_error or "failed to start marimo worker")
end

function M.resolve_runtime(path)
	local project_root = find_project_root(path)
	local worker = ensure_worker(path)
	return project_root, worker.runtime_kind
end

local function send_request(path, method, params)
	local project_root = find_project_root(path)
	local worker = ensure_worker(path)
	next_request_id = next_request_id + 1
	local request_id = next_request_id
	local payload = {
		id = request_id,
		method = method,
		params = vim.tbl_extend("force", params or {}, {
			project_root = project_root,
			runtime_kind = worker.runtime_kind,
		}),
	}
	return worker, request_id, payload
end

function M.request(path, method, params)
	local worker, request_id, payload = send_request(path, method, params)
	worker.pending[request_id] = {}
	vim.fn.chansend(worker.job_id, vim.json.encode(payload) .. "\n")
	local ok = vim.wait(30000, function()
		return worker.pending[request_id] and worker.pending[request_id].response ~= nil
	end, 10)
	local pending = worker.pending[request_id]
	if not ok or not pending or not pending.response then
		worker.pending[request_id] = nil
		return nil, "timed out waiting for marimo worker"
	end
	local response = pending.response
	worker.pending[request_id] = nil
	if not response.ok then
		return nil, response.error and response.error.message or "marimo worker error"
	end
	return response.result, nil
end

function M.request_async(path, method, params, callback, event_callback)
	local worker, request_id, payload = send_request(path, method, params)
	worker.pending[request_id] = {
		callback = callback,
		event_callback = event_callback,
	}
	local ok = vim.fn.chansend(worker.job_id, vim.json.encode(payload) .. "\n")
	if ok == 0 then
		worker.pending[request_id] = nil
		vim.schedule(function()
			callback(nil, "failed to send request to marimo worker")
		end)
	end
	return request_id
end

function M.request_isolated_async(path, method, params, callback)
	local spec = launch_spec(path)
	local stdout_chunks = {}
	local last_error = nil
	local job_id = vim.fn.jobstart(spec.cmd, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if data then
				stdout_chunks = data
			end
		end,
		on_stderr = function(_, data)
			if not data then
				return
			end
			local stderr = table.concat(data, "\n")
			if stderr:gsub("%s+", "") ~= "" then
				last_error = stderr
			end
		end,
		on_exit = function()
			vim.schedule(function()
				local response = nil
				for _, line in ipairs(stdout_chunks) do
					if line ~= "" then
						local ok, decoded = pcall(vim.json.decode, line)
						if ok and type(decoded) == "table" and decoded.id ~= nil then
							response = decoded
							break
						end
					end
				end
				if not response then
					callback(nil, last_error or "failed to start marimo worker")
					return
				end
				if not response.ok then
					callback(nil, response.error and response.error.message or "marimo worker error")
					return
				end
				callback(response.result, nil)
			end)
		end,
	})
	if job_id <= 0 then
		vim.schedule(function()
			callback(nil, "failed to start marimo worker")
		end)
		return
	end
	local payload = {
		id = 1,
		method = method,
		params = vim.tbl_extend("force", params or {}, {
			project_root = find_project_root(path),
			runtime_kind = spec.runtime_kind,
		}),
	}
	local ok = vim.fn.chansend(job_id, vim.json.encode(payload) .. "\n")
	pcall(vim.fn.chanclose, job_id, "stdin")
	if ok == 0 then
		vim.schedule(function()
			callback(nil, "failed to send request to marimo worker")
		end)
	end
end

function M.shutdown_all()
	for project_root, worker in pairs(workers) do
		pcall(vim.fn.chansend, worker.job_id, vim.json.encode({ id = -1, method = "shutdown", params = {} }) .. "\n")
		pcall(vim.fn.jobstop, worker.job_id)
		workers[project_root] = nil
	end
end

M._private = {
	find_project_root = find_project_root,
}

return M
