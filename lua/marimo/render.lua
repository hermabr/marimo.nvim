local M = {}

local namespace = vim.api.nvim_create_namespace("marimo.nvim.cells")

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

local function status_label(runtime)
	if runtime.output_kind == "error" then
		return "marimo error"
	end
	if runtime.stale_inputs then
		return "marimo stale"
	end
	return "marimo " .. (runtime.status or "idle")
end

local function virtual_lines(cell)
	local runtime = cell.runtime or {}
	local lines = {
		{
			{ " " .. status_label(runtime), status_highlight(runtime) },
		},
	}

	for _, line in ipairs(runtime.output_lines or {}) do
		table.insert(lines, {
			{ " " .. line, output_highlight(runtime) },
		})
	end

	if type(runtime.output_summary) == "string" and runtime.output_summary ~= "" and #(runtime.output_lines or {}) == 0 then
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
	for _, cell in ipairs(cells or {}) do
		local range = cell.projection_range or {}
		local line = math.max((range.end_line or range.start_line or 1) - 1, 0)
		vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
			virt_lines = virtual_lines(cell),
			virt_lines_above = false,
		})
	end
end

return M
