local M = {}
local rich_output = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/rich_output.lua")

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
	if encoded_data == nil then
		return nil
	end
	local payload = tostring(encoded_data):gsub("%s+", "")
	if payload == "" then
		return nil
	end
	mimetype = tostring(mimetype or "")
	local decode_ok = true
	local decoded
	if vim.base64 and type(vim.base64.decode) == "function" then
		decode_ok, decoded = pcall(vim.base64.decode, payload)
		if not decode_ok then
			decoded = nil
		end
	else
		local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
		local clean = payload:gsub("[^" .. alphabet .. "=]", "")
		local bit_pattern = clean:gsub(".", function(char)
			if char == "=" then
				return ""
			end
			local index = alphabet:find(char, 1, true)
			if not index then
				return ""
			end
			local value = index - 1
			local bits = {}
			for bit = 6, 1, -1 do
				bits[#bits + 1] = value % 2 ^ bit - value % 2 ^ (bit - 1) > 0 and "1" or "0"
			end
			return table.concat(bits)
		end)
		local bytes = {}
		for index = 1, #bit_pattern - 7, 8 do
			local chunk = bit_pattern:sub(index, index + 7)
			local value = 0
			for bit = 1, 8 do
				if chunk:sub(bit, bit) == "1" then
					value = value + 2 ^ (8 - bit)
				end
			end
			bytes[#bytes + 1] = string.char(value)
		end
		decoded = table.concat(bytes)
	end
	if not decode_ok or type(decoded) ~= "string" or decoded == "" then
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
	local decoded_bundle = rich_output.decode_stringified_bundle(data)
	if decoded_bundle then
		local src = extract_bundle_image(decoded_bundle)
		if src then
			return src
		end
	end
	if mimetype == "application/json" then
		local decoded = data
		if type(data) == "string" then
			decoded = rich_output.decode_json_value(data)
		end
		local bundle = rich_output.find_first_bundle(decoded)
		if bundle then
			local src = extract_bundle_image(bundle)
			if src then
				return src
			end
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
			local decoded_bundle = rich_output.decode_stringified_bundle(entry.data)
			if decoded_bundle then
				local src = extract_bundle_image(decoded_bundle)
				if src then
					return src
				end
			end
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
	-- Force a follow-up refresh after buffer/extmark updates land so newly
	-- placed inline images become visible reliably across terminals.
	local function refresh_placement()
		pcall(function()
			if placement and type(placement.update) == "function" then
				placement:update()
			end
			if placement and type(placement.show) == "function" then
				placement:show()
			end
		end)
		pcall(vim.cmd, "redraw")
	end
	vim.schedule(refresh_placement)
	vim.defer_fn(refresh_placement, 20)
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
