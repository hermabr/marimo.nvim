local M = {}

local namespace = vim.api.nvim_create_namespace("marimo.nvim.cells")
local IMAGE_CACHE_DIR = vim.fn.stdpath("cache") .. "/marimo.nvim/images"

local MAX_OUTPUT_LINES = 12
local MAX_OUTPUT_LINE_CHARS = 160
local image_state = {}

local function as_string(value)
	if type(value) == "string" then
		return value
	end
	return nil
end

local function close_image_placements(bufnr)
	local entry = image_state[bufnr]
	if not entry then
		return
	end
	for _, placement in ipairs(entry.placements or {}) do
		pcall(function()
			if placement and type(placement.close) == "function" then
				placement:close()
			end
		end)
	end
	image_state[bufnr] = nil
end

local function get_snacks_image()
	local ok, snacks_image = pcall(require, "snacks.image")
	if not ok or type(snacks_image) ~= "table" then
		return nil
	end
	if type(snacks_image.supports_terminal) == "function" and not snacks_image.supports_terminal() then
		return nil
	end
	if type(snacks_image.placement) ~= "table" or type(snacks_image.placement.new) ~= "function" then
		return nil
	end
	return snacks_image
end

local function image_extension(mimetype)
	if type(mimetype) ~= "string" then
		return "png"
	end
	local ext = mimetype:match("^image/([%w%+%-%.]+)$")
	if not ext or ext == "" then
		return "png"
	end
	ext = ext:gsub("^x%-", "")
	ext = ext:gsub("%+xml$", "")
	if ext == "jpeg" then
		return "jpg"
	end
	return ext
end

local function write_cached_image_file(mimetype, encoded_data)
	if encoded_data == nil or vim.base64 == nil then
		return nil
	end
	local payload = tostring(encoded_data):gsub("%s+", "")
	if payload == "" then
		return nil
	end
	mimetype = tostring(mimetype or "")
	local ok, decoded = pcall(vim.base64.decode, payload)
	if not ok or type(decoded) ~= "string" or decoded == "" then
		return nil
	end
	vim.fn.mkdir(IMAGE_CACHE_DIR, "p")
	local ext = image_extension(mimetype)
	local digest = string.format("%d-%s", #payload, payload:sub(1, 16):gsub("[^%w]", ""))
	local path = string.format("%s/%s.%s", IMAGE_CACHE_DIR, digest:sub(1, 24), ext)
	if vim.fn.filereadable(path) == 0 then
		local fd = io.open(path, "wb")
		if not fd then
			return nil
		end
		fd:write(decoded)
		fd:close()
	end
	return path
end

local function extract_html_image_src(text)
	if type(text) ~= "string" or text == "" then
		return nil
	end
	return text:match('<img[^>]-src="([^"]+)"') or text:match("<img[^>]-src='([^']+)'")
end

local function image_source_from_value(mimetype, data)
	if type(data) ~= "string" or data == "" then
		return nil
	end
	local uri_mimetype, payload = data:match("^data:([^;,]+);base64,(.+)$")
	if uri_mimetype and payload then
		return write_cached_image_file(uri_mimetype, payload)
	end
	if data:match("^https?://") or data:match("^file://") then
		return data
	end
	if mimetype and mimetype:match("^image/") then
		return write_cached_image_file(mimetype, data)
	end
	return nil
end

local function decode_stringified_bundle(data)
	if type(data) ~= "string" or data == "" or vim.json == nil then
		return nil
	end
	local trimmed = vim.trim(data)
	if trimmed:sub(1, 1) ~= "{" then
		return nil
	end
	local ok, decoded = pcall(vim.json.decode, trimmed)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	return decoded
end

local function extract_bundle_image(data)
	if type(data) ~= "table" then
		return nil
	end
	for bundle_type, bundle_data in pairs(data) do
		if type(bundle_type) == "string" and bundle_type:match("^image/") then
			local src = image_source_from_value(bundle_type, bundle_data)
			if src then
				return src
			end
		end
	end
	local html = as_string(data["text/html"])
	if html then
		local src = extract_html_image_src(html)
		if src then
			return image_source_from_value(nil, src) or src
		end
	end
	return nil
end

local function extract_output_image(output)
	if type(output) ~= "table" then
		return nil
	end
	local mimetype = as_string(output.mimetype) or ""
	local data = output.data
	local decoded_bundle = decode_stringified_bundle(data)
	if decoded_bundle then
		local src = extract_bundle_image(decoded_bundle)
		if src then
			return src
		end
	end
	if mimetype:match("^image/") then
		return image_source_from_value(mimetype, data)
	end
	if mimetype == "text/html" or mimetype == "text/markdown" then
		local src = extract_html_image_src(data)
		if src then
			return image_source_from_value(nil, src) or src
		end
	end
	if mimetype == "application/vnd.marimo+mimebundle" and type(data) == "table" then
		return extract_bundle_image(data)
	end
	return nil
end

local function place_output_image(bufnr, line, src)
	local snacks_image = get_snacks_image()
	if not snacks_image or type(src) ~= "string" or src == "" then
		return false
	end
	local ok, placement = pcall(snacks_image.placement.new, bufnr, src, {
		inline = true,
		pos = { line, 0 },
		max_width = 80,
		max_height = 24,
		auto_resize = true,
	})
	if not ok or placement == nil then
		return false
	end
	image_state[bufnr] = image_state[bufnr] or { placements = {} }
	table.insert(image_state[bufnr].placements, placement)
	return true
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
		return {}, nil, nil
	end
	local mimetype = as_string(output.mimetype) or ""
	local data = output.data
	local image_src = extract_output_image(output)
	if image_src then
		return {}, nil, image_src
	end
	if mimetype == "text/plain" or mimetype == "text/markdown" or mimetype == "text/latex" then
		return split_lines(data), "String", nil
	end
	if mimetype == "application/vnd.marimo+traceback" then
		return split_lines(data), "ErrorMsg", nil
	end
	if mimetype == "application/vnd.marimo+error" then
		return render_error_output(data), "ErrorMsg", nil
	end
	if mimetype == "application/vnd.marimo+mimebundle" and type(data) == "table" then
		if type(data["text/plain"]) == "string" then
			return split_lines(data["text/plain"]), "String", nil
		end
		if type(data["text/html"]) == "string" then
			local lines = html_to_text(data["text/html"])
			if #lines > 0 then
				return lines, "String", nil
			end
		end
		return { placeholder_for_mimetype(mimetype) }, "Comment", nil
	end
	if mimetype == "text/html" then
		local lines = html_to_text(data)
		if #lines > 0 then
			return lines, "String", nil
		end
		return { placeholder_for_mimetype(mimetype) }, "Comment", nil
	end
	if type(data) == "string" then
		if mimetype:match("^image/") or mimetype:match("^video/") then
			return { placeholder_for_mimetype(mimetype) }, "Comment", nil
		end
		return split_lines(data), "String", nil
	end
	return { placeholder_for_mimetype(mimetype) }, "Comment", nil
end

local function render_console(console)
	local lines = {}
	local image_src = nil
	for _, entry in ipairs(console or {}) do
		local channel = as_string(entry.channel) or "stdout"
		local mimetype = as_string(entry.mimetype) or "text/plain"
		local data = entry.data
		if channel == "media" then
			image_src = image_src or image_source_from_value(mimetype, data)
			if image_src == nil then
				table.insert(lines, placeholder_for_mimetype(mimetype))
			end
		elseif type(data) == "string" then
			local chunks = mimetype == "text/html" and html_to_text(data) or vim.split(data, "\n", { plain = true })
			for _, line in ipairs(chunks) do
				table.insert(lines, line)
			end
		end
	end
	return truncate_lines(lines), image_src
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

local function has_visible_runtime(runtime, output_lines, console_lines, output_image, console_image)
	if #output_lines > 0 then
		return true
	end
	if #console_lines > 0 then
		return true
	end
	if output_image or console_image then
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
	local output_lines, output_highlight, output_image = render_output(runtime.output)
	local console_lines, console_image = render_console(runtime.console)
	if not has_visible_runtime(runtime, output_lines, console_lines, output_image, console_image) then
		return nil, nil
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
	return lines, output_image or console_image
end

function M.clear(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
	close_image_placements(bufnr)
end

function M.render(bufnr, cells)
	M.clear(bufnr)
	local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
	for _, cell in ipairs(cells or {}) do
		local range = cell.projection_range or {}
		local line = math.max((range.end_line or range.start_line or 1) - 1, 0)
		line = math.min(line, line_count - 1)
		local lines, image_src = virtual_lines(cell)
		if lines == nil and image_src == nil then
			goto continue
		end
		if lines and #lines > 0 then
			vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
				virt_lines = lines,
				virt_lines_above = false,
			})
		end
		if image_src then
			local image_line = math.min(line + 1, line_count)
			if not place_output_image(bufnr, image_line, image_src) then
				vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
					virt_lines = {
						{ { " " .. placeholder_for_mimetype("image/png"), "Comment" } },
					},
					virt_lines_above = false,
				})
			end
		end
		::continue::
	end
end

return M
