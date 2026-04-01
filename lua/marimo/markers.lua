local source = debug.getinfo(1, "S").source:sub(2)
local M = {}

local function normalize_scalar(value)
	local trimmed = vim.trim(value)
	if trimmed == "True" or trimmed == "true" then
		return true
	end
	if trimmed == "False" or trimmed == "false" then
		return false
	end
	if trimmed == "None" or trimmed == "null" then
		return nil
	end
	if (#trimmed >= 2 and trimmed:sub(1, 1) == "'" and trimmed:sub(-1) == "'")
		or (#trimmed >= 2 and trimmed:sub(1, 1) == '"' and trimmed:sub(-1) == '"')
	then
		return trimmed:sub(2, -2)
	end

	local number = tonumber(trimmed)
	if number ~= nil then
		return number
	end
	return trimmed
end

local function split_csv_like(text)
	local parts = {}
	local current = {}
	local quote = nil
	local prev = ""

	for idx = 1, #text do
		local char = text:sub(idx, idx)
		if quote ~= nil then
			table.insert(current, char)
			if char == quote and prev ~= "\\" then
				quote = nil
			end
		elseif char == "'" or char == '"' then
			quote = char
			table.insert(current, char)
		elseif char == "," then
			table.insert(parts, table.concat(current))
			current = {}
		else
			table.insert(current, char)
		end
		prev = char
	end

	if #current > 0 then
		table.insert(parts, table.concat(current))
	end

	return parts
end

local function parse_options_text(text)
	if not text then
		return {}
	end

	local inner = vim.trim(text)
	if inner:sub(1, 1) == "{" and inner:sub(-1) == "}" then
		inner = inner:sub(2, -2)
	end
	if vim.trim(inner) == "" then
		return {}
	end

	local opts = {}
	for _, chunk in ipairs(split_csv_like(inner)) do
		local item = vim.trim(chunk)
		if item ~= "" then
			if item == "marimo" then
				opts.marimo = true
			elseif item == "marimo_disabled" then
				opts.disabled = true
			else
				local eq = item:find("=", 1, true)
				if not eq then
					error("invalid option: " .. item)
				end
				local key = vim.trim(item:sub(1, eq - 1))
				if key == "" then
					error("invalid option: " .. item)
				end
				opts[key] = normalize_scalar(item:sub(eq + 1))
			end
		end
	end
	return opts
end

local function render_scalar(value)
	if value == nil then
		return "None"
	end
	if type(value) == "boolean" then
		return value and "True" or "False"
	end
	if type(value) == "number" then
		return tostring(value)
	end
	return vim.json.encode(tostring(value))
end

local function render_options(opts)
	local keys = vim.tbl_keys(opts)
	table.sort(keys)

	local parts = {}
	if opts.marimo then
		table.insert(parts, "marimo")
	end
	if opts.disabled then
		table.insert(parts, "marimo_disabled")
	end
	for _, key in ipairs(keys) do
		if key ~= "marimo" and key ~= "disabled" then
			table.insert(parts, string.format("%s=%s", key, render_scalar(opts[key])))
		end
	end

	if #parts == 0 then
		return ""
	end

	return " {" .. table.concat(parts, ",") .. "}"
end

local function trim_blank_lines(lines)
	local start_idx = 1
	local end_idx = #lines

	while start_idx <= end_idx and not lines[start_idx]:match("%S") do
		start_idx = start_idx + 1
	end
	while end_idx >= start_idx and not lines[end_idx]:match("%S") do
		end_idx = end_idx - 1
	end

	local trimmed = {}
	for idx = start_idx, end_idx do
		table.insert(trimmed, lines[idx])
	end
	return trimmed
end

local function parse_projected_buffer_cells(lines)
	local cells = {}
	local current = nil

	local function flush(end_line)
		if not current then
			return
		end

		current.body = trim_blank_lines(current.body)
		current.range = {
			start_line = current.start_line,
			start_col = 1,
			end_line = math.max(end_line, current.start_line),
			end_col = 1,
		}
		table.insert(cells, current)
		current = nil
	end

	for line_number, line in ipairs(lines) do
		local is_marker, marker = M.parse_marker_line(line)
		if is_marker then
			flush(line_number - 1)
			current = {
				options = parse_options_text(marker),
				body = {},
				start_line = line_number,
			}
		elseif current then
			table.insert(current.body, line)
		end
	end
	flush(#lines)

	if #cells == 0 then
		error("projected marimo buffer has no `# +` cells")
	end
	if cells[1].options.marimo ~= true then
		error("first cell must be marked with `{marimo}`")
	end

	return cells
end

function M.parse_marker_line(line)
	if line == "# +" then
		return true, nil
	end

	local stripped = vim.trim(line)
	if stripped:sub(1, 3) ~= "# +" then
		return false, nil
	end

	local opts = vim.trim(stripped:sub(4))
	if opts:match("^%b{}$") then
		return true, opts
	end
	return false, nil
end

function M.looks_like_marimo(lines)
	local has_import = false
	local has_app = false
	for _, line in ipairs(lines) do
		if line:match("^%s*import%s+marimo%s*$")
			or line:match("^%s*import%s+marimo%s+as%s+[%w_]+%s*$")
			or line:match("^%s*import%s+marimo%s*,")
		then
			has_import = true
		end
		if line:match("^%s*app%s*=%s*[%w_%.]+%.App%(") then
			has_app = true
		end
	end
	return has_import and has_app
end

function M.looks_like_projected(lines)
	local first = lines[1] or ""
	local ok, marker = M.parse_marker_line(first)
	return ok and marker ~= nil and marker:match("marimo") ~= nil
end

function M.has_any_projected_markers(lines)
	for _, line in ipairs(lines) do
		if M.parse_marker_line(line) then
			return true
		end
	end
	return false
end

function M.promote_first_marker_to_marimo(lines)
	local promoted = vim.deepcopy(lines)
	local first_marker_idx = nil
	for idx, line in ipairs(promoted) do
		if M.parse_marker_line(line) then
			first_marker_idx = idx
			break
		end
	end

	if first_marker_idx == nil then
		return promoted, false
	end

	if first_marker_idx > 1 then
		table.insert(promoted, 1, "")
		table.insert(promoted, 1, "# + {marimo}")
		return promoted, true
	end

	for idx, line in ipairs(promoted) do
		local ok, marker = M.parse_marker_line(line)
		if ok then
			local opts = parse_options_text(marker)
			opts.marimo = true
			promoted[idx] = "# +" .. render_options(opts)
			return promoted, true
		end
	end

	return promoted, false
end

function M.normalize_projected_buffer_lines(lines)
	local cells = parse_projected_buffer_cells(lines)
	local normalized_cells = {}
	for idx, cell in ipairs(cells) do
		local is_empty = #cell.body == 0
		local keep_empty = idx == 1 and cell.options.marimo == true
		if not is_empty or keep_empty then
			table.insert(normalized_cells, cell)
		end
	end

	local normalized = {}
	for _, cell in ipairs(normalized_cells) do
		table.insert(normalized, "# +" .. render_options(cell.options))
		table.insert(normalized, "")
		for _, body_line in ipairs(cell.body) do
			table.insert(normalized, body_line)
		end
		table.insert(normalized, "")
	end

	while #normalized > 0 and normalized[#normalized] == "" do
		table.remove(normalized)
	end

	return normalized
end

function M.projected_cell_ranges(lines)
	local cells = parse_projected_buffer_cells(lines)
	local ranges = {}
	for _, cell in ipairs(cells) do
		if #cell.body > 0 then
			table.insert(ranges, vim.deepcopy(cell.range))
		end
	end
	if #ranges == 0 then
		table.insert(ranges, vim.deepcopy(cells[1].range))
	end
	return ranges
end

function M.parse_projected_cells(lines)
	local parsed = parse_projected_buffer_cells(lines)
	local cells = {}
	for idx, cell in ipairs(parsed) do
		local options = vim.deepcopy(cell.options or {})
		local is_setup = options.setup == true
		options.setup = nil
		if idx == 1 then
			options.marimo = nil
		end
		table.insert(cells, {
			name = is_setup and "setup" or "_",
			options = options,
			code = table.concat(cell.body or {}, "\n"),
			projection_range = vim.deepcopy(cell.range),
		})
	end
	for idx, cell in ipairs(cells) do
		if cell.name == "setup" and idx ~= 1 then
			error("setup cell must be the first cell")
		end
	end
	return cells
end

function M.render_projected_buffer_lines(cells)
	local projected = {}
	for idx, cell in ipairs(cells or {}) do
		local opts = vim.deepcopy(cell.options or {})
		if idx == 1 then
			opts.marimo = true
		end
		if cell.name == "setup" then
			opts.setup = true
		end
		table.insert(projected, "# +" .. render_options(opts))
		table.insert(projected, "")
		local body = {}
		if type(cell.code) == "string" and cell.code ~= "" then
			body = trim_blank_lines(vim.split(cell.code, "\n", { plain = true }))
		end
		for _, line in ipairs(body) do
			table.insert(projected, line)
		end
		table.insert(projected, "")
	end

	while #projected > 0 and projected[#projected] == "" do
		table.remove(projected)
	end

	return projected
end

function M.parse_options_text(text)
	return parse_options_text(text)
end

function M.render_options(opts)
	return render_options(opts)
end

return M
