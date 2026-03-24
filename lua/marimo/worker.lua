local source = debug.getinfo(1, "S").source:sub(2)
local M = {}

local workers = {}
local next_request_id = 0

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
		runtime_kind = spec.runtime_kind,
	}

	worker.job_id = vim.fn.jobstart(spec.cmd, {
		stdout_buffered = false,
		stderr_buffered = true,
		on_stdout = function(_, data)
			if not data or #data == 0 then
				return
			end
			worker.stdout_buffer = worker.stdout_buffer .. (data[1] or "")
			if #data == 1 then
				return
			end

			local ok, decoded = pcall(vim.json.decode, worker.stdout_buffer)
			if ok and decoded and decoded.id ~= nil then
				local pending = worker.pending[decoded.id]
				if pending then
					pending.response = decoded
				end
			elseif worker.stdout_buffer ~= "" then
				last_error = "failed to decode marimo worker response: " .. worker.stdout_buffer
			end

			for idx = 2, #data - 1 do
				local line = data[idx]
				if line ~= "" then
					local line_ok, line_decoded = pcall(vim.json.decode, line)
					if line_ok and line_decoded and line_decoded.id ~= nil then
						local pending = worker.pending[line_decoded.id]
						if pending then
							pending.response = line_decoded
						end
					else
						last_error = "failed to decode marimo worker response: " .. line
					end
				end
			end

			worker.stdout_buffer = data[#data] or ""
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

function M.request(path, method, params)
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
