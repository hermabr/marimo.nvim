local M = {}

local REMOVE = {}

local function decode_json_value(data)
	if type(data) ~= "string" or data == "" or vim.json == nil then
		return nil
	end
	local trimmed = vim.trim(data)
	local first = trimmed:sub(1, 1)
	if first ~= "{" and first ~= "[" then
		return nil
	end
	local ok, decoded = pcall(vim.json.decode, trimmed)
	if not ok then
		return nil
	end
	return decoded
end

local function is_bundle(value)
	if type(value) ~= "table" then
		return false
	end
	for key, _ in pairs(value) do
		if type(key) == "string" and (key == "text/plain" or key == "text/html" or key:match("^image/") or key:match("^video/")) then
			return true
		end
	end
	return false
end

local function decode_stringified_bundle(data)
	local decoded = decode_json_value(data)
	if is_bundle(decoded) then
		return decoded
	end
	return nil
end

local function decode_marshaled_bundle(value)
	if type(value) ~= "string" then
		return nil
	end
	local prefix = "application/vnd.marimo+mimebundle:"
	if value:sub(1, #prefix) ~= prefix then
		return nil
	end
	return decode_stringified_bundle(value:sub(#prefix + 1))
end

local function parse_marshaled_leaf(value)
	if type(value) ~= "string" then
		return nil, nil
	end
	local separator = value:find(":", 1, true)
	if separator == nil then
		return nil, nil
	end
	return value:sub(1, separator - 1), value:sub(separator + 1)
end

local function is_array(value)
	if type(value) ~= "table" then
		return false
	end
	local max_index = 0
	for key, _ in pairs(value) do
		if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then
			return false
		end
		if key > max_index then
			max_index = key
		end
	end
	for index = 1, max_index do
		if value[index] == nil then
			return false
		end
	end
	return true
end

local function sanitize_marshaled_value(value)
	local marshaled_bundle = decode_marshaled_bundle(value)
	if marshaled_bundle then
		return REMOVE
	end
	if type(value) ~= "table" then
		return value
	end
	if is_bundle(value) then
		return REMOVE
	end
	if is_array(value) then
		local items = {}
		for _, item in ipairs(value) do
			local sanitized = sanitize_marshaled_value(item)
			if sanitized ~= REMOVE then
				table.insert(items, sanitized)
			end
		end
		if #items == 0 then
			return REMOVE
		end
		return items
	end
	local object = {}
	for key, item in pairs(value) do
		local sanitized = sanitize_marshaled_value(item)
		if sanitized ~= REMOVE then
			object[key] = sanitized
		end
	end
	if next(object) == nil then
		return REMOVE
	end
	return object
end

local stringify_marshaled_value

local function stringify_marshaled_leaf(value)
	local mimetype, data = parse_marshaled_leaf(value)
	if mimetype == nil then
		return nil
	end
	if mimetype == "text/plain+float" or mimetype == "text/plain+bigint" or mimetype == "text/plain+tuple" then
		return data
	end
	if mimetype == "text/plain+set" then
		local decoded = decode_json_value(data)
		if decoded ~= nil then
			return "set" .. stringify_marshaled_value(decoded)
		end
		return data
	end
	if mimetype == "text/plain" or mimetype == "text/html" or mimetype == "text/markdown" then
		return vim.json.encode(data)
	end
	if mimetype == "application/json" then
		local decoded = decode_json_value(data)
		if decoded ~= nil then
			return stringify_marshaled_value(decoded)
		end
		return vim.json.encode(data)
	end
	return nil
end

function stringify_marshaled_value(value)
	if value == vim.NIL then
		return "null"
	end
	if type(value) == "string" then
		local rendered = stringify_marshaled_leaf(value)
		if rendered ~= nil then
			return rendered
		end
		return vim.json.encode(value)
	end
	if type(value) ~= "table" then
		return vim.json.encode(value)
	end
	if is_array(value) then
		local items = {}
		for _, item in ipairs(value) do
			table.insert(items, stringify_marshaled_value(item))
		end
		return "[" .. table.concat(items, ",") .. "]"
	end
	local keys = {}
	for key, _ in pairs(value) do
		table.insert(keys, key)
	end
	table.sort(keys, function(left, right)
		return tostring(left) < tostring(right)
	end)
	local items = {}
	for _, key in ipairs(keys) do
		table.insert(items, vim.json.encode(key) .. ":" .. stringify_marshaled_value(value[key]))
	end
	return "{" .. table.concat(items, ",") .. "}"
end

local function find_first_bundle(value)
	local marshaled_bundle = decode_marshaled_bundle(value)
	if marshaled_bundle then
		return marshaled_bundle
	end
	if type(value) ~= "table" then
		return nil
	end
	if is_bundle(value) then
		return value
	end
	for _, item in ipairs(value) do
		local bundle = find_first_bundle(item)
		if bundle then
			return bundle
		end
	end
	for key, item in pairs(value) do
		if type(key) ~= "number" then
			local bundle = find_first_bundle(item)
			if bundle then
				return bundle
			end
		end
	end
	return nil
end

M.REMOVE = REMOVE
M.decode_json_value = decode_json_value
M.decode_stringified_bundle = decode_stringified_bundle
M.decode_marshaled_bundle = decode_marshaled_bundle
M.find_first_bundle = find_first_bundle
M.is_bundle = is_bundle
M.sanitize_marshaled_value = sanitize_marshaled_value
M.stringify_marshaled_value = stringify_marshaled_value

return M
