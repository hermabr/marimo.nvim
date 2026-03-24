local M = {}

local namespace = vim.api.nvim_create_namespace("marimo.nvim.cells")

local function as_string(value)
	if type(value) == "string" then
		return value
	end
	return nil
end

local function status_highlight(runtime)
	if runtime.output_kind == "error" then
		return "ErrorMsg"
	end
	if runtime.status == "running" or runtime.status == "queued" then
		return "Identifier"
	end
	if runtime.stale_inputs then
		return "WarningMsg"
	end
	return "Comment"
end

local function output_highlight(runtime)
	if runtime.output_kind == "error" then
		return "ErrorMsg"
	end
	if runtime.output_kind == "html" or runtime.output_kind == "media" or runtime.output_kind == "widget" then
		return "Comment"
	end
	return "String"
end

local function has_visible_runtime(runtime)
	if #(runtime.output_lines or {}) > 0 then
		return true
	end
	if #(runtime.console_lines or {}) > 0 then
		return true
	end
	if as_string(runtime.output_summary) and runtime.output_summary ~= "" then
		return true
	end
	if runtime.output_kind == "error" then
		return true
	end
	if runtime.stale_inputs then
		return true
	end
	if as_string(runtime.status) and runtime.status ~= "idle" then
		return true
	end
	return false
end

local function status_label(runtime)
	if runtime.output_kind == "error" then
		return "marimo error"
	end
	if runtime.stale_inputs then
		return "marimo stale"
	end
	return "marimo " .. (as_string(runtime.status) or "idle")
end

local function show_status_line(runtime)
	if runtime.output_kind == "error" then
		return true
	end
	if runtime.stale_inputs then
		return true
	end
	return runtime.status == "running" or runtime.status == "queued"
end

local function virtual_lines(cell)
	local runtime = cell.runtime or {}
	if not has_visible_runtime(runtime) then
		return nil
	end
	local lines = {}

	if show_status_line(runtime) then
		table.insert(lines, {
			{ " " .. status_label(runtime), status_highlight(runtime) },
		})
	end

	for _, line in ipairs(runtime.output_lines or {}) do
		table.insert(lines, {
			{ " " .. line, output_highlight(runtime) },
		})
	end

	if as_string(runtime.output_summary) and runtime.output_summary ~= "" and #(runtime.output_lines or {}) == 0 then
		table.insert(lines, {
			{ " " .. runtime.output_summary, output_highlight(runtime) },
		})
	end

	for _, line in ipairs(runtime.console_lines or {}) do
		table.insert(lines, {
			{ " " .. line, "Comment" },
		})
	end

	return lines
end

function M.clear(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

function M.render(bufnr, cells)
	M.clear(bufnr)
	local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
	for _, cell in ipairs(cells or {}) do
		local range = cell.projection_range or {}
		local line = math.max((range.end_line or range.start_line or 1) - 1, 0)
		line = math.min(line, line_count - 1)
		local lines = virtual_lines(cell)
		if lines == nil then
			goto continue
		end
		vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
			virt_lines = lines,
			virt_lines_above = false,
		})
		::continue::
	end
end

return M
