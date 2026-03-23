local source = debug.getinfo(1, "S").source:sub(2)
local M = {}

local workers = {}
local next_request_id = 0

local function find_project_root(path)
	local absolute = vim.fn.fnamemodify(path, ":p")
	local dirpath = vim.fn.fnamemodify(absolute, ":h")
	local previous = nil
	while dirpath ~= previous and dirpath ~= "" do
		if vim.uv.fs_stat(dirpath .. "/uv.lock") then
			return dirpath
		end
		if vim.uv.fs_stat(dirpath .. "/pyproject.toml") then
			return dirpath
		end
		previous = dirpath
		dirpath = vim.fn.fnamemodify(dirpath, ":h")
	end
	return vim.fn.fnamemodify(absolute, ":h")
end

local function worker_script_path()
	local root = vim.fn.fnamemodify(source, ":p:h:h:h")
	return root
end

local function launch_spec(project_root)
	local script_root = worker_script_path()
	local specs = {
		{ runtime_kind = "uv_project", cmd = { "uv", "run", "--project", project_root, "--directory", script_root, "python", "-m", "marimo_nvim_py" } },
		{ runtime_kind = "uv_with_marimo", cmd = { "uv", "run", "--with", "marimo", "--directory", script_root, "python", "-m", "marimo_nvim_py" } },
		{ runtime_kind = "python", cmd = { "python3", "-m", "marimo_nvim_py" } },
	}
	return specs
end

local function ensure_worker(project_root)
	local existing = workers[project_root]
	if existing and existing.job_id and vim.fn.jobwait({ existing.job_id }, 0)[1] == -1 then
		return existing
	end

	local specs = launch_spec(project_root)
	local last_error = nil

	for _, spec in ipairs(specs) do
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
				if not data then
					return
				end
				for _, chunk in ipairs(data) do
					if chunk ~= "" then
						worker.stdout_buffer = worker.stdout_buffer .. chunk .. "\n"
					end
				end
				while true do
					local newline = worker.stdout_buffer:find("\n", 1, true)
					if not newline then
						break
					end
					local line = worker.stdout_buffer:sub(1, newline - 1)
					worker.stdout_buffer = worker.stdout_buffer:sub(newline + 1)
					if line ~= "" then
						local ok, decoded = pcall(vim.json.decode, line)
						if ok and decoded and decoded.id ~= nil then
							local pending = worker.pending[decoded.id]
							if pending then
								pending.response = decoded
							end
						end
					end
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
	end

	error(last_error or "failed to start marimo worker")
end

function M.resolve_runtime(path)
	local project_root = find_project_root(path)
	local worker = ensure_worker(project_root)
	return project_root, worker.runtime_kind
end

function M.request(path, method, params)
	local project_root = find_project_root(path)
	local worker = ensure_worker(project_root)
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
