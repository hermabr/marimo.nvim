local M = {}

local namespace = vim.api.nvim_create_namespace("marimo.nvim.cells")

local MAX_OUTPUT_LINES = 12
local MAX_OUTPUT_LINE_CHARS = 160

local function as_string(value)
	if type(value) == "string" then
		return value
	end
	return nil
end

local function truncate_lines(lines)
	local trimmed = {}
	local truncated = false
	for _, line in ipairs(lines or {}) do
		local current = tostring(line)
		if #current > MAX_OUTPUT_LINE_CHARS then
			current = current:sub(1, MAX_OUTPUT_LINE_CHARS - 3) .. "..."
			truncated = true
		end
		table.insert(trimmed, current)
	end
	while #trimmed > 0 and trimmed[#trimmed] == "" do
		table.remove(trimmed)
	end
	while #trimmed > MAX_OUTPUT_LINES do
		table.remove(trimmed)
		truncated = true
	end
	if truncated then
		table.insert(trimmed, "[output truncated]")
	end
	return trimmed
end

local function split_lines(text)
	if type(text) ~= "string" or text == "" then
		return {}
	end
	return truncate_lines(vim.split(text, "\n", { plain = true }))
end

local function html_to_text(text)
	if type(text) ~= "string" or text == "" then
		return {}
	end
	local normalized = text
	normalized = normalized:gsub("<br%s*/?>", "\n")
	normalized = normalized:gsub("</[Pp]>", "\n")
	normalized = normalized:gsub("</[Dd][Ii][Vv]>", "\n")
	normalized = normalized:gsub("</[Ll][Ii]>", "\n")
	normalized = normalized:gsub("</[Tt][Rr]>", "\n")
	normalized = normalized:gsub("</[Hh][1-6]>", "\n")
	normalized = normalized:gsub("<[^>]+>", "")
	normalized = normalized:gsub("&lt;", "<")
	normalized = normalized:gsub("&gt;", ">")
	normalized = normalized:gsub("&amp;", "&")
	normalized = normalized:gsub("&#x27;", "'")
	normalized = normalized:gsub("&quot;", '"')
	local lines = {}
	for _, line in ipairs(vim.split(normalized, "\n", { plain = true })) do
		line = vim.trim(line)
		if line ~= "" then
			table.insert(lines, line)
		end
	end
	return truncate_lines(lines)
end

local function placeholder_for_mimetype(mimetype)
	if mimetype == "text/html" then
		return "[html output]"
	end
	if mimetype == "application/vnd.marimo+mimebundle" then
		return "[widget output]"
	end
	if type(mimetype) == "string" and mimetype ~= "" then
		return "[" .. mimetype .. " output]"
	end
	return "[output]"
end

local function render_error_output(data)
	if type(data) ~= "table" then
		return { "[marimo error]" }
	end
	local lines = {}
	for _, err in ipairs(data) do
		local traceback = err.traceback or err.msg
		if type(traceback) == "table" and #traceback > 0 then
			for _, line in ipairs(traceback) do
				table.insert(lines, tostring(line))
			end
		else
			local message = as_string(err.msg) or as_string(err.evalue) or as_string(err.ename) or as_string(err.type) or "[marimo error]"
			table.insert(lines, message)
			if err.type == "multiple-defs" and type(err.cells) == "table" then
				for _, cell_id in ipairs(err.cells) do
					table.insert(lines, tostring(cell_id))
				end
			end
		end
	end
	return truncate_lines(lines)
end

local function render_output(output)
	if type(output) ~= "table" then
		return {}, nil
	end
	local mimetype = as_string(output.mimetype) or ""
	local data = output.data
	if mimetype == "text/plain" or mimetype == "text/markdown" or mimetype == "text/latex" then
		return split_lines(data), "String"
	end
	if mimetype == "application/vnd.marimo+traceback" then
		return split_lines(data), "ErrorMsg"
	end
	if mimetype == "application/vnd.marimo+error" then
		return render_error_output(data), "ErrorMsg"
	end
	if mimetype == "application/vnd.marimo+mimebundle" and type(data) == "table" then
		if type(data["text/plain"]) == "string" then
			return split_lines(data["text/plain"]), "String"
		end
		if type(data["text/html"]) == "string" then
			local lines = html_to_text(data["text/html"])
			if #lines > 0 then
				return lines, "String"
			end
		end
		return { placeholder_for_mimetype(mimetype) }, "Comment"
	end
	if mimetype == "text/html" then
		local lines = html_to_text(data)
		if #lines > 0 then
			return lines, "String"
		end
		return { placeholder_for_mimetype(mimetype) }, "Comment"
	end
	if type(data) == "string" then
		if mimetype:match("^image/") or mimetype:match("^video/") then
			return { placeholder_for_mimetype(mimetype) }, "Comment"
		end
		return split_lines(data), "String"
	end
	return { placeholder_for_mimetype(mimetype) }, "Comment"
end

local function render_console(console)
	local lines = {}
	for _, entry in ipairs(console or {}) do
		local channel = as_string(entry.channel) or "stdout"
		local mimetype = as_string(entry.mimetype) or "text/plain"
		local data = entry.data
		if channel == "media" then
			table.insert(lines, placeholder_for_mimetype(mimetype))
		elseif type(data) == "string" then
			local chunks = mimetype == "text/html" and html_to_text(data) or vim.split(data, "\n", { plain = true })
			for _, line in ipairs(chunks) do
				table.insert(lines, line)
			end
		end
	end
	return truncate_lines(lines)
end

local function status_highlight(runtime, output_highlight)
	if output_highlight == "ErrorMsg" then
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

local function has_visible_runtime(runtime, output_lines, console_lines)
	if #output_lines > 0 then
		return true
	end
	if #console_lines > 0 then
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
	if runtime.stale_inputs then
		return "marimo stale"
	end
	return "marimo " .. (as_string(runtime.status) or "idle")
end

local function show_status_line(runtime)
	if runtime.stale_inputs then
		return true
	end
	return runtime.status == "running" or runtime.status == "queued"
end

local function virtual_lines(cell)
	local runtime = cell.runtime or {}
	local output_lines, output_highlight = render_output(runtime.output)
	local console_lines = render_console(runtime.console)
	if not has_visible_runtime(runtime, output_lines, console_lines) then
		return nil
	end

	local lines = {}
	if show_status_line(runtime) then
		table.insert(lines, {
			{ " " .. status_label(runtime), status_highlight(runtime, output_highlight) },
		})
	end
	for _, line in ipairs(output_lines) do
		table.insert(lines, {
			{ " " .. line, output_highlight or "String" },
		})
	end
	for _, line in ipairs(console_lines) do
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
