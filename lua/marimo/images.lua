local M = {}

local IMAGE_CACHE_DIR = vim.fn.stdpath("cache") .. "/marimo.nvim/images"

local function as_string(value)
	if type(value) == "string" then
		return value
	end
	return nil
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

function M.image_source_from_value(mimetype, data)
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
	for key, _ in pairs(decoded) do
		if type(key) == "string" and (key == "text/plain" or key == "text/html" or key:match("^image/")) then
			return decoded
		end
	end
	return nil
end

local function extract_bundle_image(data)
	if type(data) ~= "table" then
		return nil
	end
	for bundle_type, bundle_data in pairs(data) do
		if type(bundle_type) == "string" and bundle_type:match("^image/") then
			local src = M.image_source_from_value(bundle_type, bundle_data)
			if src then
				return src
			end
		end
	end
	local html = as_string(data["text/html"])
	if html then
		local src = extract_html_image_src(html)
		if src then
			return M.image_source_from_value(nil, src) or src
		end
	end
	return nil
end

function M.extract_output_image(output)
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
		return M.image_source_from_value(mimetype, data)
	end
	if mimetype == "text/html" or mimetype == "text/markdown" then
		local src = extract_html_image_src(data)
		if src then
			return M.image_source_from_value(nil, src) or src
		end
	end
	if mimetype == "application/vnd.marimo+mimebundle" and type(data) == "table" then
		return extract_bundle_image(data)
	end
	return nil
end

function M.extract_console_image(console)
	for _, entry in ipairs(console or {}) do
		local channel = as_string(entry.channel) or "stdout"
		local mimetype = as_string(entry.mimetype) or "text/plain"
		if channel == "media" then
			local src = M.image_source_from_value(mimetype, entry.data)
			if src then
				return src
			end
		end
	end
	return nil
end

function M.supports_images()
	return get_snacks_image() ~= nil
end

function M.place_image(bufnr, line, src, opts)
	local snacks_image = get_snacks_image()
	if not snacks_image or type(src) ~= "string" or src == "" then
		return nil
	end
	local placement_opts = vim.tbl_extend("force", {
		inline = true,
		pos = { line, 0 },
		max_width = 80,
		max_height = 24,
		auto_resize = true,
	}, opts or {})
	local ok, placement = pcall(snacks_image.placement.new, bufnr, src, placement_opts)
	if not ok or placement == nil then
		return nil
	end
	return placement
end

function M.close_placements(entry)
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
	entry.placements = {}
end

return M
