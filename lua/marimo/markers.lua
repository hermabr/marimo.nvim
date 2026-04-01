local M = {}

local next_cell_nonce = 0

local function new_cell_id()
	next_cell_nonce = next_cell_nonce + 1
	return string.format("cell-%x-%x", vim.uv.hrtime(), next_cell_nonce)
end

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

local function similarity_score(left, right)
	local prefix_len = 0
	local limit = math.min(#left, #right)
	while prefix_len < limit and left:sub(prefix_len + 1, prefix_len + 1) == right:sub(prefix_len + 1, prefix_len + 1) do
		prefix_len = prefix_len + 1
	end
	local suffix_len = 0
	if prefix_len < limit then
		while suffix_len < (limit - prefix_len)
			and left:sub(#left - suffix_len, #left - suffix_len) == right:sub(#right - suffix_len, #right - suffix_len)
		do
			suffix_len = suffix_len + 1
		end
	end
	return #left + #right - 2 * (prefix_len + suffix_len)
end

local function match_previous_cell(previous, current, used)
	local exact = nil
	for index, cell in ipairs(previous or {}) do
		if not used[index]
			and cell.code == current.code
			and cell.name == current.name
			and vim.deep_equal(cell.options or {}, current.options or {})
		then
			exact = index
			break
		end
	end
	if exact ~= nil then
		return exact
	end

	local best_index = nil
	local best_score = nil
	for index, cell in ipairs(previous or {}) do
		if not used[index] and cell.name == current.name and vim.deep_equal(cell.options or {}, current.options or {}) then
			local score = similarity_score(cell.code or "", current.code or "")
			if best_score == nil or score < best_score then
				best_score = score
				best_index = index
			end
		end
	end
	return best_index
end

function M.parse_options_text(text)
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

function M.render_options(opts)
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
			local opts = M.parse_options_text(marker)
			opts.marimo = true
			promoted[idx] = "# +" .. M.render_options(opts)
			return promoted, true
		end
	end
	return promoted, false
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
			local options = M.parse_options_text(marker)
			local setup = options.setup == true
			options.setup = nil
			current = {
				options = options,
				setup = setup,
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

function M.normalize_projected_buffer_lines(lines)
	local cells = parse_projected_buffer_cells(lines)
	local normalized = {}
	for idx, cell in ipairs(cells) do
		local keep_empty = idx == 1
		if #cell.body > 0 or keep_empty then
			local opts = vim.deepcopy(cell.options)
			if cell.setup then
				opts.setup = true
			end
			table.insert(normalized, "# +" .. M.render_options(opts))
			table.insert(normalized, "")
			for _, body_line in ipairs(cell.body) do
				table.insert(normalized, body_line)
			end
			table.insert(normalized, "")
		end
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
		table.insert(ranges, vim.deepcopy(cell.range))
	end
	return ranges
end

function M.parse_projected_snapshot(lines, previous_cells)
	local parsed = parse_projected_buffer_cells(lines)
	local previous = previous_cells or {}
	local used = {}
	local cells = {}
	for index, cell in ipairs(parsed) do
		local code = table.concat(cell.body, "\n")
		local current = {
			name = cell.setup and "setup" or "_",
			code = code,
			options = vim.deepcopy(cell.options),
			index = index - 1,
			projection_range = vim.deepcopy(cell.range),
		}
		current.options.marimo = nil
		local previous_index = match_previous_cell(previous, current, used)
		if previous_index ~= nil then
			used[previous_index] = true
			local previous_cell = previous[previous_index]
			current.id = previous_cell.id
			current.editor_status = (previous_cell.code == current.code and vim.deep_equal(previous_cell.options or {}, current.options or {}) and previous_cell.name == current.name)
					and "clean"
				or "edited"
		else
			current.id = new_cell_id()
			current.editor_status = previous_cells and "edited" or "clean"
		end
		table.insert(cells, current)
	end
	return cells
end

function M.wrap_manual_python(lines)
	local body = trim_blank_lines(lines)
	return {
		{
			id = new_cell_id(),
			name = "_",
			code = table.concat(body, "\n"),
			options = {},
			index = 0,
			editor_status = "clean",
			projection_range = {
				start_line = 1,
				start_col = 1,
				end_line = math.max(#body + 2, 1),
				end_col = 1,
			},
		},
	}
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
		table.insert(projected, "# +" .. M.render_options(opts))
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

function M.build_projection_map(cells, canonical_ranges)
	local items = {}
	for index, cell in ipairs(cells or {}) do
		table.insert(items, {
			id = cell.id,
			name = cell.name,
			projection_range = vim.deepcopy(cell.projection_range),
			canonical_range = vim.deepcopy(canonical_ranges[index] or {}),
		})
	end
	return { cells = items }
end

function M.compute_changed_and_deleted(previous_cells, current_cells)
	local previous_by_id = {}
	local current_ids = {}
	local changed_ids = {}
	local delete_ids = {}
	for _, cell in ipairs(previous_cells or {}) do
		previous_by_id[cell.id] = cell
	end
	for _, cell in ipairs(current_cells or {}) do
		current_ids[cell.id] = true
		local previous = previous_by_id[cell.id]
		if previous == nil
			or previous.code ~= cell.code
			or previous.name ~= cell.name
			or vim.deep_equal(previous.options or {}, cell.options or {}) == false
		then
			table.insert(changed_ids, cell.id)
		end
	end
	for _, cell in ipairs(previous_cells or {}) do
		if not current_ids[cell.id] then
			table.insert(delete_ids, cell.id)
		end
	end
	return changed_ids, delete_ids
end

return M
