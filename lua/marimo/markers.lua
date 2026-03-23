local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local util = dofile(dir .. "/util.lua")

local M = {}

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
	local marker = first:match("^# %+%s*(%b{})%s*$")
	return marker ~= nil and marker:match("^%{.*marimo.*%}$") ~= nil
end

function M.has_any_projected_markers(lines)
	for _, line in ipairs(lines) do
		if line:match("^# %+$") or line:match("^# %+%s*%b{}%s*$") then
			return true
		end
	end
	return false
end

function M.parse_marker_line(line)
	if line:match("^# %+$") then
		return true, nil
	end

	local opts = line:match("^# %+%s*(%b{})%s*$")
	if opts then
		return true, opts
	end

	return false, nil
end

local function parse_scalar(value)
	local trimmed = vim.trim(value)
	if trimmed == "True" or trimmed == "true" then
		return true
	end
	if trimmed == "False" or trimmed == "false" then
		return false
	end
	if trimmed == "None" or trimmed == "null" then
		return vim.NIL
	end
	local quoted = trimmed:match("^'(.*)'$") or trimmed:match('^"(.*)"$')
	if quoted ~= nil then
		return quoted
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

	for i = 1, #text do
		local ch = text:sub(i, i)
		if quote then
			table.insert(current, ch)
			if ch == quote and text:sub(i - 1, i - 1) ~= "\\" then
				quote = nil
			end
		elseif ch == "'" or ch == '"' then
			quote = ch
			table.insert(current, ch)
		elseif ch == "," then
			table.insert(parts, table.concat(current))
			current = {}
		else
			table.insert(current, ch)
		end
	end

	if #current > 0 then
		table.insert(parts, table.concat(current))
	end

	return parts
end

function M.parse_options_text(text)
	if not text or text == "" then
		return {}
	end

	local opts = {}
	local inner = vim.trim(text)
	if inner:sub(1, 1) == "{" and inner:sub(-1) == "}" then
		inner = inner:sub(2, -2)
	end

	if vim.trim(inner) == "" then
		return opts
	end

	for _, chunk in ipairs(split_csv_like(inner)) do
		local item = vim.trim(chunk)
		if item ~= "" then
			if item == "marimo" then
				opts.marimo = true
			else
				local key, value = item:match("^([%a_][%w_]*)%s*=%s*(.-)%s*$")
				if not key then
					error("invalid option: " .. item)
				end
				opts[key] = parse_scalar(value)
			end
		end
	end

	return opts
end

local function render_scalar(value)
	if value == nil or value == vim.NIL then
		return "None"
	end
	if type(value) == "boolean" then
		return value and "True" or "False"
	end
	if type(value) == "number" then
		return tostring(value)
	end
	return string.format("%q", tostring(value))
end

function M.render_options(opts)
	if not opts or vim.tbl_isempty(opts) then
		return ""
	end

	local keys = vim.tbl_keys(opts)
	table.sort(keys)
	local parts = {}
	if opts.marimo then
		table.insert(parts, "marimo")
	end
	for _, key in ipairs(keys) do
		if key ~= "marimo" then
			table.insert(parts, string.format("%s=%s", key, render_scalar(opts[key])))
		end
	end
	return " {" .. table.concat(parts, ",") .. "}"
end

function M.parse_projected_cells(lines)
	local cells = {}
	local current = nil

	local function flush()
		if not current then
			return
		end
		local body = vim.deepcopy(current.body)
		while #body > 0 and body[1]:match("^%s*$") do
			table.remove(body, 1)
		end
		while #body > 0 and body[#body]:match("^%s*$") do
			table.remove(body)
		end
		table.insert(cells, {
			name = current.setup and "setup" or "_",
			options = util.as_json_object(current.options),
			code = util.join_lines(body),
		})
		current = nil
	end

	for _, line in ipairs(lines) do
		local is_marker, marker = M.parse_marker_line(line)
		if is_marker then
			flush()
			local ok, opts = pcall(M.parse_options_text, marker)
			if not ok then
				error(opts)
			end
			local setup = opts.setup == true
			opts.setup = nil
			current = { options = opts, setup = setup, body = {} }
		elseif current then
			table.insert(current.body, line)
		end
	end

	flush()

	if #cells == 0 then
		error("projected marimo buffer has no `# +` cells")
	end

	for idx, cell in ipairs(cells) do
		if cell.name == "setup" and idx ~= 1 then
			error("setup cell must be the first cell")
		end
	end

	if cells[1].options.marimo ~= true then
		error("first cell must be marked with `{marimo}`")
	end

	cells[1].options.marimo = nil
	cells[1].options = util.as_json_object(cells[1].options)

	return cells
end

function M.dedupe_empty_cells(cells)
	local deduped = {}
	local previous_empty = false

	for _, cell in ipairs(cells) do
		local is_empty = cell.code == ""
		if not (is_empty and previous_empty) then
			table.insert(deduped, cell)
		end
		previous_empty = is_empty
	end

	return deduped
end

function M.render_projected_lines(parsed)
	local lines = {}
	for idx, cell in ipairs(parsed.cells) do
		local opts = vim.deepcopy(cell.options or {})
		if idx == 1 then
			opts.marimo = true
		end
		if cell.name == "setup" then
			opts.setup = true
		end
		table.insert(lines, "# +" .. M.render_options(opts))
		table.insert(lines, "")

		if cell.code ~= "" then
			local code_lines = util.split_lines(cell.code)
			while #code_lines > 0 and code_lines[1]:match("^%s*$") do
				table.remove(code_lines, 1)
			end
			while #code_lines > 0 and code_lines[#code_lines]:match("^%s*$") do
				table.remove(code_lines)
			end
			vim.list_extend(lines, code_lines)
		end

		table.insert(lines, "")
		if idx < #parsed.cells then
			table.insert(lines, "# __marimo_cell_break__")
		end
	end

	local normalized = {}
	for _, line in ipairs(lines) do
		if line == "# __marimo_cell_break__" then
			if #normalized > 0 and normalized[#normalized] ~= "" then
				table.insert(normalized, "")
			end
		else
			table.insert(normalized, line)
		end
	end

	for i = #normalized, 1, -1 do
		if normalized[i] == "# __marimo_cell_break__" then
			table.remove(normalized, i)
		end
	end
	while #normalized > 0 and normalized[#normalized] == "" do
		table.remove(normalized)
	end
	return normalized
end

function M.normalize_projected_buffer_lines(lines)
	local cells = M.dedupe_empty_cells(M.parse_projected_cells(lines))
	return M.render_projected_lines({ cells = cells })
end

function M.promote_first_marker_to_marimo(lines)
	local promoted = vim.deepcopy(lines)
	local first_marker_idx = nil
	for idx, line in ipairs(promoted) do
		if line:match("^# %+$") or line:match("^# %+%s*%b{}%s*$") then
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
		if line:match("^# %+$") then
			promoted[idx] = "# + {marimo}"
			return promoted, true
		end

		local marker = line:match("^# %+%s*(%b{})%s*$")
		if marker then
			local ok, opts = pcall(M.parse_options_text, marker)
			if not ok then
				error(opts)
			end
			opts.marimo = true
			promoted[idx] = "# +" .. M.render_options(opts)
			return promoted, true
		end
	end

	return promoted, false
end

return M
