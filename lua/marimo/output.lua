local M = {}
local rich_output = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/rich_output.lua")

local function as_string(value)
	if type(value) == "string" then
		return value
	end
	return nil
end

local function limit_lines(lines, opts)
	local max_lines = opts.max_lines
	local max_line_chars = opts.max_line_chars
	local truncated = false
	local limited = {}

	for _, line in ipairs(lines or {}) do
		local current = tostring(line)
		if type(max_line_chars) == "number" and max_line_chars > 3 and #current > max_line_chars then
			current = current:sub(1, max_line_chars - 3) .. "..."
			truncated = true
		end
		table.insert(limited, current)
	end

	while #limited > 0 and limited[#limited] == "" do
		table.remove(limited)
	end

	if type(max_lines) == "number" and max_lines > 0 then
		while #limited > max_lines do
			table.remove(limited)
			truncated = true
		end
	end

	if truncated then
		table.insert(limited, "[output truncated]")
	end

	return limited
end

local function split_lines(text, opts)
	if type(text) ~= "string" or text == "" then
		return {}
	end
	return limit_lines(vim.split(text, "\n", { plain = true }), opts or {})
end

local function html_to_text(text, opts)
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
	return limit_lines(lines, opts or {})
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

local function render_error_output(data, opts)
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
	return limit_lines(lines, opts or {})
end

local function first_bundle_media_mimetype(data)
	if type(data) ~= "table" then
		return nil
	end
	for bundle_type, _ in pairs(data) do
		if type(bundle_type) == "string" and (bundle_type:match("^image/") or bundle_type:match("^video/")) then
			return bundle_type
		end
	end
	return nil
end

local function render_bundle_output(data, opts)
	if type(data["text/plain"]) == "string" then
		return split_lines(data["text/plain"], opts), "String"
	end
	if type(data["text/html"]) == "string" then
		local lines = html_to_text(data["text/html"], opts)
		if #lines > 0 then
			return lines, "String"
		end
	end
	local media_mimetype = first_bundle_media_mimetype(data)
	if media_mimetype and opts.output_image_resolved then
		return {}, nil
	end
	return { placeholder_for_mimetype(media_mimetype or "application/vnd.marimo+mimebundle") }, "Comment"
end

local function render_marshaled_json_output(data, opts)
	local decoded = data
	if type(data) == "string" then
		decoded = rich_output.decode_json_value(data)
	end
	if decoded == nil then
		return nil
	end
	local sanitized = rich_output.sanitize_marshaled_value(decoded)
	if sanitized == rich_output.REMOVE then
		return {}, nil
	end
	local ok, encoded = pcall(vim.json.encode, sanitized)
	if not ok or type(encoded) ~= "string" then
		return nil
	end
	return split_lines(encoded, opts), "String"
end

local function render_output(output, opts)
	opts = opts or {}
	if type(output) ~= "table" then
		return {}, nil
	end
	local mimetype = as_string(output.mimetype) or ""
	local data = output.data
	local decoded_bundle = rich_output.decode_stringified_bundle(data)
	if decoded_bundle then
		return render_bundle_output(decoded_bundle, opts)
	end
	if mimetype == "application/json" then
		local lines, highlight = render_marshaled_json_output(data, opts)
		if lines ~= nil then
			return lines, highlight
		end
	end
	if mimetype == "text/plain" or mimetype == "text/markdown" or mimetype == "text/latex" then
		return split_lines(data, opts), "String"
	end
	if mimetype == "application/vnd.marimo+traceback" then
		return split_lines(data, opts), "ErrorMsg"
	end
	if mimetype == "application/vnd.marimo+error" then
		return render_error_output(data, opts), "ErrorMsg"
	end
	if mimetype == "application/vnd.marimo+mimebundle" and type(data) == "table" then
		return render_bundle_output(data, opts)
	end
	if mimetype == "text/html" then
		local lines = html_to_text(data, opts)
		if #lines > 0 then
			return lines, "String"
		end
		return { placeholder_for_mimetype(mimetype) }, "Comment"
	end
	if type(data) == "string" then
		if mimetype:match("^image/") or mimetype:match("^video/") then
			if opts.output_image_resolved then
				return {}, nil
			end
			return { placeholder_for_mimetype(mimetype) }, "Comment"
		end
		return split_lines(data, opts), "String"
	end
	return { placeholder_for_mimetype(mimetype) }, "Comment"
end

local function render_console(console, opts)
	opts = opts or {}
	local lines = {}
	for _, entry in ipairs(console or {}) do
		local channel = as_string(entry.channel) or "stdout"
		local mimetype = as_string(entry.mimetype) or "text/plain"
		local data = entry.data
		if channel == "media" then
			if not opts.console_image_resolved then
				local decoded_bundle = rich_output.decode_stringified_bundle(data)
				if decoded_bundle then
					local media_mimetype = first_bundle_media_mimetype(decoded_bundle)
					table.insert(lines, placeholder_for_mimetype(media_mimetype or mimetype))
				else
					table.insert(lines, placeholder_for_mimetype(mimetype))
				end
			end
		elseif type(data) == "string" then
			local chunks = mimetype == "text/html" and html_to_text(data, opts) or vim.split(data, "\n", { plain = true })
			for _, line in ipairs(chunks) do
				table.insert(lines, line)
			end
		end
	end
	return limit_lines(lines, opts)
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

function M.runtime_sections(runtime, opts)
	runtime = runtime or {}
	opts = opts or {}
	local output_lines, output_highlight = render_output(runtime.output, opts)
	local console_lines = render_console(runtime.console, opts)
	local sections = {
		status = nil,
		output = {},
		console = {},
	}

	if show_status_line(runtime) then
		sections.status = {
			text = status_label(runtime),
			highlight = status_highlight(runtime, output_highlight),
		}
	end

	for _, line in ipairs(output_lines) do
		table.insert(sections.output, {
			text = line,
			highlight = output_highlight or "String",
		})
	end

	for _, line in ipairs(console_lines) do
		table.insert(sections.console, {
			text = line,
			highlight = "Comment",
		})
	end

	return sections
end

function M.runtime_lines(runtime, opts)
	local sections = M.runtime_sections(runtime, opts)
	local lines = {}
	if sections.status then
		table.insert(lines, sections.status)
	end
	for _, line in ipairs(sections.output) do
		table.insert(lines, line)
	end
	for _, line in ipairs(sections.console) do
		table.insert(lines, line)
	end

	return lines
end

return M
