local M = {}
local rich_output = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/rich_output.lua")
local INTERNAL_ROW_ID_COLUMN = "_marimo_row_id"

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

local function decode_html_entities(text)
	if type(text) ~= "string" or text == "" then
		return ""
	end
	local decoded = text
	decoded = decoded:gsub("&#x([%da-fA-F]+);", function(hex)
		local codepoint = tonumber(hex, 16)
		return codepoint and vim.fn.nr2char(codepoint) or ""
	end)
	decoded = decoded:gsub("&#(%d+);", function(decimal)
		local codepoint = tonumber(decimal, 10)
		return codepoint and vim.fn.nr2char(codepoint) or ""
	end)
	decoded = decoded:gsub("&nbsp;", " ")
	decoded = decoded:gsub("&lt;", "<")
	decoded = decoded:gsub("&gt;", ">")
	decoded = decoded:gsub("&amp;", "&")
	decoded = decoded:gsub("&#x27;", "'")
	decoded = decoded:gsub("&quot;", '"')
	return decoded
end

local function strip_non_content_blocks(text)
	if type(text) ~= "string" or text == "" then
		return ""
	end
	local normalized = text
	normalized = normalized:gsub("<!%-%-.-%-%->", "")
	normalized = normalized:gsub("<[Ss][Tt][Yy][Ll][Ee][^>]*>.-</[Ss][Tt][Yy][Ll][Ee]>", "")
	normalized = normalized:gsub("<[Ss][Cc][Rr][Ii][Pp][Tt][^>]*>.-</[Ss][Cc][Rr][Ii][Pp][Tt]>", "")
	return normalized
end

local function normalize_text_line(text)
	if type(text) ~= "string" then
		return ""
	end
	return vim.trim(text:gsub("%s+", " "))
end

local function fragment_to_lines(fragment)
	if type(fragment) ~= "string" or fragment == "" then
		return {}
	end
	local normalized = strip_non_content_blocks(fragment)
	normalized = normalized:gsub("<[Bb][Rr]%s*/?>", "\n")
	normalized = normalized:gsub("</[Pp]>", "\n")
	normalized = normalized:gsub("</[Dd][Ii][Vv]>", "\n")
	normalized = normalized:gsub("</[Ll][Ii]>", "\n")
	normalized = normalized:gsub("</[Tt][Rr]>", "\n")
	normalized = normalized:gsub("</[Tt][Hh][Ee][Aa][Dd]>", "\n")
	normalized = normalized:gsub("</[Tt][Bb][Oo][Dd][Yy]>", "\n")
	normalized = normalized:gsub("</[Tt][Aa][Bb][Ll][Ee]>", "\n")
	normalized = normalized:gsub("</[Hh][1-6]>", "\n")
	normalized = normalized:gsub("<[^>]+>", "")
	normalized = decode_html_entities(normalized)
	local lines = {}
	for _, line in ipairs(vim.split(normalized, "\n", { plain = true })) do
		line = normalize_text_line(line)
		if line ~= "" then
			table.insert(lines, line)
		end
	end
	return lines
end

local function table_to_lines(table_html)
	if type(table_html) ~= "string" or table_html == "" then
		return {}
	end
	local rows = {}
	for row_html in table_html:gmatch("<[Tt][Rr][^>]*>(.-)</[Tt][Rr]>") do
		local row = {}
		for cell_html in row_html:gmatch("<[Tt][DdHh][^>]*>(.-)</[Tt][DdHh]>") do
			local cell_lines = fragment_to_lines(cell_html)
			local cell_text = normalize_text_line(table.concat(cell_lines, " "))
			table.insert(row, cell_text)
		end
		if #row > 0 then
			table.insert(rows, row)
		end
	end
	if #rows == 0 then
		return {}
	end
	local widths = {}
	for _, row in ipairs(rows) do
		for idx, cell in ipairs(row) do
			widths[idx] = math.max(widths[idx] or 0, vim.fn.strdisplaywidth(cell))
		end
	end
	local lines = {}
	for _, row in ipairs(rows) do
		local padded = {}
		for idx, width in ipairs(widths) do
			local cell = row[idx] or ""
			local padding = math.max(width - vim.fn.strdisplaywidth(cell), 0)
			table.insert(padded, cell .. string.rep(" ", padding))
		end
		table.insert(lines, (table.concat(padded, " | "):gsub("%s+$", "")))
	end
	return lines
end

local function extract_tag_attribute(tag_html, attribute)
	if type(tag_html) ~= "string" or tag_html == "" or type(attribute) ~= "string" or attribute == "" then
		return nil
	end
	local single_quoted = tag_html:match(attribute .. "='([^']*)'")
	if single_quoted ~= nil then
		return single_quoted
	end
	local double_quoted = tag_html:match(attribute .. '="([^"]*)"')
	if double_quoted ~= nil then
		return double_quoted
	end
	return nil
end

local function decode_json_attribute(value)
	if type(value) ~= "string" or value == "" or vim.json == nil then
		return nil
	end
	local decoded = decode_html_entities(value)
	local ok, parsed = pcall(vim.json.decode, decoded)
	if not ok then
		return nil
	end
	if type(parsed) == "string" then
		local trimmed = vim.trim(parsed)
		if trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "[" then
			local nested_ok, nested = pcall(vim.json.decode, trimmed)
			if nested_ok then
				return nested
			end
		end
	end
	return parsed
end

local function normalize_rows_data(value)
	if type(value) == "table" then
		return value
	end
	if type(value) ~= "string" or value == "" or vim.json == nil then
		return nil
	end
	local ok, parsed = pcall(vim.json.decode, value)
	if not ok or type(parsed) ~= "table" then
		return nil
	end
	return parsed
end

local function decode_total_rows_value(value, fallback)
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" then
		local decoded = decode_json_attribute(value)
		if type(decoded) == "number" then
			return decoded
		end
		if decoded == "too_many" then
			return decoded
		end
		local numeric = tonumber(decode_html_entities(value))
		if numeric ~= nil then
			return numeric
		end
	end
	return fallback
end

local function decode_total_columns_value(value, fallback)
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" then
		local decoded = decode_json_attribute(value)
		if type(decoded) == "number" then
			return decoded
		end
		local numeric = tonumber(decode_html_entities(value))
		if numeric ~= nil then
			return numeric
		end
	end
	return fallback
end

local function decode_page_size_value(value, fallback)
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" then
		local decoded = decode_json_attribute(value)
		if type(decoded) == "number" then
			return decoded
		end
		local numeric = tonumber(decode_html_entities(value))
		if numeric ~= nil then
			return numeric
		end
	end
	return fallback
end

local function column_names_and_types(field_types, rows_data)
	local column_names = {}
	local type_names = {}
	if type(field_types) == "table" then
		for _, entry in ipairs(field_types) do
			if type(entry) == "table" then
				local column_name = entry[1]
				if type(column_name) == "string" and column_name ~= "" and column_name ~= INTERNAL_ROW_ID_COLUMN then
					table.insert(column_names, column_name)
					local field_type = entry[2]
					if type(field_type) == "table" then
						table.insert(type_names, tostring(field_type[2] or field_type[1] or ""))
					else
						table.insert(type_names, tostring(field_type or ""))
					end
				end
			end
		end
	end
	if #column_names == 0 then
		local first_row = rows_data[1]
		if type(first_row) == "table" then
			for key, _ in pairs(first_row) do
				if key ~= INTERNAL_ROW_ID_COLUMN then
					table.insert(column_names, tostring(key))
				end
			end
			table.sort(column_names)
		end
	end
	return column_names, type_names
end

local function render_table_rows(lines, rows, opts)
	if #rows == 0 then
		return lines
	end
	local widths = {}
	for _, row in ipairs(rows) do
		for idx, cell in ipairs(row) do
			widths[idx] = math.max(widths[idx] or 0, vim.fn.strdisplaywidth(cell))
		end
	end
	for _, row in ipairs(rows) do
		local padded = {}
		for idx, width in ipairs(widths) do
			local cell = row[idx] or ""
			local padding = math.max(width - vim.fn.strdisplaywidth(cell), 0)
			table.insert(padded, cell .. string.rep(" ", padding))
		end
		table.insert(lines, (table.concat(padded, " | "):gsub("%s+$", "")))
	end
	if opts and opts.show_empty_hint and #rows <= 1 then
		table.insert(lines, "[empty table]")
	end
	return lines
end

local function marimo_table_shape_line(total_rows, total_columns)
	if type(total_columns) ~= "number" or total_columns <= 0 then
		return nil
	end
	local rows_label = type(total_rows) == "number" and tostring(total_rows) or "?"
	return string.format("shape: (%s, %d)", rows_label, total_columns)
end

local function marimo_table_view_from_html(text)
	if type(text) ~= "string" or text == "" then
		return nil
	end
	local wrapper_html = text:match("<[Mm][Aa][Rr][Ii][Mm][Oo]%-[Uu][Ii]%-[Ee][Ll][Ee][Mm][Ee][Nn][Tt][^>]*>")
	local tag_html = text:match("<[Mm][Aa][Rr][Ii][Mm][Oo]%-[Tt][Aa][Bb][Ll][Ee][^>]*>")
	if tag_html == nil then
		return nil
	end
	local rows_data = normalize_rows_data(decode_json_attribute(extract_tag_attribute(tag_html, "data%-data")))
	if type(rows_data) ~= "table" then
		return nil
	end
	local field_types = decode_json_attribute(extract_tag_attribute(tag_html, "data%-field%-types"))
	local column_names, type_names = column_names_and_types(field_types, rows_data)
	local total_rows = decode_total_rows_value(extract_tag_attribute(tag_html, "data%-total%-rows"), #rows_data)
	local total_columns = decode_total_columns_value(extract_tag_attribute(tag_html, "data%-total%-columns"), #column_names)
	local page_size = decode_page_size_value(extract_tag_attribute(tag_html, "data%-page%-size"), #rows_data)
	local pagination = decode_json_attribute(extract_tag_attribute(tag_html, "data%-pagination")) == true
	local namespace = wrapper_html and extract_tag_attribute(wrapper_html, "object%-id") or nil
	return {
		namespace = namespace,
		pagination = pagination,
		page_index = 0,
		page_size = page_size,
		total_rows = total_rows,
		total_columns = total_columns,
		column_names = column_names,
		type_names = type_names,
		rows_data = rows_data,
	}
end

local function marimo_table_view_to_lines(table_view)
	if type(table_view) ~= "table" then
		return {}
	end
	local lines = {}
	local shape_line = marimo_table_shape_line(table_view.total_rows, table_view.total_columns)
	if shape_line then
		table.insert(lines, shape_line)
	end
	local table_rows = {}
	local column_names = table_view.column_names or {}
	local type_names = table_view.type_names or {}
	local rows_data = table_view.rows_data or {}
	if #column_names > 0 then
		table.insert(table_rows, column_names)
		local has_type_name = false
		for _, type_name in ipairs(type_names) do
			if type_name ~= "" then
				has_type_name = true
				break
			end
		end
		if has_type_name then
			local type_row = {}
			for idx = 1, #column_names do
				table.insert(type_row, tostring(type_names[idx] or ""))
			end
			table.insert(table_rows, type_row)
		end
		for _, row_data in ipairs(rows_data) do
			if type(row_data) == "table" then
				local row = {}
				for _, column_name in ipairs(column_names) do
					local value = row_data[column_name]
					if value == nil then
						table.insert(row, "")
					else
						table.insert(row, normalize_text_line(tostring(value)))
					end
				end
				table.insert(table_rows, row)
			end
		end
	end
	return render_table_rows(lines, table_rows)
end

local function marimo_table_to_lines(text)
	local table_view = marimo_table_view_from_html(text)
	if type(table_view) ~= "table" then
		return {}
	end
	return marimo_table_view_to_lines(table_view)
end

local function append_lines(target, lines)
	for _, line in ipairs(lines or {}) do
		if type(line) == "string" and line ~= "" then
			table.insert(target, line)
		end
	end
end

local function html_to_lines(text)
	if type(text) ~= "string" or text == "" then
		return {}
	end
	local marimo_table_lines = marimo_table_to_lines(text)
	if #marimo_table_lines > 0 then
		return marimo_table_lines
	end
	local lines = {}
	local normalized = strip_non_content_blocks(text)
	local start_idx = 1
	while true do
		local table_start, table_end, table_html = normalized:find("(<[Tt][Aa][Bb][Ll][Ee][^>]*>.-</[Tt][Aa][Bb][Ll][Ee]>)", start_idx)
		if not table_start then
			break
		end
		append_lines(lines, fragment_to_lines(normalized:sub(start_idx, table_start - 1)))
		local table_lines = table_to_lines(table_html)
		if #table_lines == 0 then
			table_lines = fragment_to_lines(table_html)
		end
		append_lines(lines, table_lines)
		start_idx = table_end + 1
	end
	append_lines(lines, fragment_to_lines(normalized:sub(start_idx)))
	return lines
end

local function html_to_text(text, opts)
	return limit_lines(html_to_lines(text), opts or {})
end

local function looks_like_html(text)
	if type(text) ~= "string" or text == "" then
		return false
	end
	return text:find("<[%a!/][^>]*>") ~= nil
end

local function traceback_to_lines(text)
	if type(text) ~= "string" or text == "" then
		return {}
	end
	if looks_like_html(text) then
		local lines = html_to_lines(text)
		if #lines > 0 then
			return lines
		end
	end
	return vim.split(text, "\n", { plain = true })
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
			if err.type == "multiple-defs" then
				local name = as_string(err.name)
				if name and name ~= "" then
					message = string.format("%s defined by another cell", name)
				else
					message = "defined by another cell"
				end
			end
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
	local ok, encoded = pcall(rich_output.stringify_marshaled_value, sanitized)
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
	if mimetype == "text/plain" or mimetype == "text/latex" then
		return split_lines(data, opts), "String"
	end
	if mimetype == "text/markdown" then
		if looks_like_html(data) then
			local lines = html_to_text(data, opts)
			if #lines > 0 then
				return lines, "String"
			end
		end
		return split_lines(data, opts), "String"
	end
	if mimetype == "application/vnd.marimo+traceback" then
		return limit_lines(traceback_to_lines(data), opts), "ErrorMsg"
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
			local chunks
			if mimetype == "text/html" then
				chunks = html_to_lines(data)
			elseif mimetype == "application/vnd.marimo+traceback" then
				chunks = traceback_to_lines(data)
			else
				chunks = vim.split(data, "\n", { plain = true })
			end
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
	if runtime.status == "disabled-transitively" then
		return "WarningMsg"
	end
	if runtime.stale_inputs then
		return "Comment"
	end
	return "Comment"
end

local function status_label(runtime)
	if runtime.stale_inputs then
		return "marimo stale"
	end
	if runtime.status == "disabled-transitively" then
		return "marimo disabled (ancestor)"
	end
	return "marimo " .. (as_string(runtime.status) or "idle")
end

local function show_status_line(runtime, output_lines, console_lines)
	local has_visible_output = #(output_lines or {}) > 0 or #(console_lines or {}) > 0
	if runtime.stale_inputs then
		if has_visible_output and runtime.status ~= "running" and runtime.status ~= "queued" then
			return false
		end
		return true
	end
	return runtime.status == "running" or runtime.status == "queued" or runtime.status == "disabled-transitively"
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

	if show_status_line(runtime, output_lines, console_lines) then
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

function M.extract_table_view(output)
	if type(output) ~= "table" then
		return nil
	end
	local mimetype = as_string(output.mimetype) or ""
	local data = output.data
	if mimetype == "text/html" and type(data) == "string" then
		return marimo_table_view_from_html(data)
	end
	if mimetype == "application/vnd.marimo+mimebundle" and type(data) == "table" and type(data["text/html"]) == "string" then
		return marimo_table_view_from_html(data["text/html"])
	end
	local decoded_bundle = rich_output.decode_stringified_bundle(data)
	if type(decoded_bundle) == "table" and type(decoded_bundle["text/html"]) == "string" then
		return marimo_table_view_from_html(decoded_bundle["text/html"])
	end
	return nil
end

function M.apply_table_search_result(table_view, result, page_index, page_size)
	if type(table_view) ~= "table" or type(result) ~= "table" then
		return nil
	end
	local rows_data = normalize_rows_data(result.data)
	if type(rows_data) ~= "table" then
		return nil
	end
	local next_view = vim.deepcopy(table_view)
	next_view.rows_data = rows_data
	next_view.page_index = page_index or next_view.page_index or 0
	next_view.page_size = page_size or next_view.page_size or #rows_data
	next_view.total_rows = decode_total_rows_value(result.total_rows, next_view.total_rows)
	if type(next_view.total_columns) ~= "number" then
		next_view.total_columns = #next_view.column_names
	end
	return next_view
end

function M.table_view_lines(table_view)
	return marimo_table_view_to_lines(table_view)
end

return M
