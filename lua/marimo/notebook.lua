local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local markers = dofile(dir .. "/markers.lua")
local util = dofile(dir .. "/util.lua")

local M = {}

local id_counter = 0

local function trim_blank_lines(lines)
	local trimmed = vim.deepcopy(lines)
	while #trimmed > 0 and not trimmed[1]:match("%S") do
		table.remove(trimmed, 1)
	end
	while #trimmed > 0 and not trimmed[#trimmed]:match("%S") do
		table.remove(trimmed, #trimmed)
	end
	return trimmed
end

local function next_cell_id()
	id_counter = id_counter + 1
	return vim.fn.sha256(table.concat({ tostring(vim.uv.hrtime()), tostring(id_counter), tostring(math.random()) }, ":"))
end

local function parse_projected_cells(lines)
	local cells = {}
	local current = nil

	local function flush()
		if not current then
			return
		end
		local options = vim.deepcopy(current.options)
		local setup = options.setup == true
		options.setup = nil
		table.insert(cells, {
			name = setup and "setup" or "_",
			options = options,
			code = util.join_lines(trim_blank_lines(current.body)),
		})
		current = nil
	end

	for _, line in ipairs(lines) do
		local is_marker, marker = markers.parse_marker_line(line)
		if is_marker or line == "# +" then
			flush()
			current = {
				options = markers.parse_options_text(marker),
				body = {},
			}
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
	return cells
end

local function dedupe_empty_cells(cells)
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

local function drop_empty_cells(cells)
	local kept = {}
	for _, cell in ipairs(cells) do
		if vim.trim(cell.code) ~= "" then
			table.insert(kept, cell)
		end
	end
	if #kept > 0 then
		return kept
	end
	if #cells == 0 then
		return {}
	end
	local first = vim.deepcopy(cells[1])
	first.code = ""
	return { first }
end

local function reconcile_ids(previous, parsed_cells)
	if not previous or #previous == 0 then
		local initialized = {}
		for _, cell in ipairs(parsed_cells) do
			table.insert(initialized, vim.tbl_extend("force", cell, {
				id = next_cell_id(),
				editor_status = "clean",
			}))
		end
		return initialized
	end

	local previous_by_key = {}
	for _, old in ipairs(previous) do
		local key = table.concat({
			old.name,
			vim.json.encode(old.options or {}),
			old.code,
		}, "\0")
		previous_by_key[key] = previous_by_key[key] or {}
		table.insert(previous_by_key[key], old)
	end

	local matched_previous_ids = {}
	local provisional = {}
	local unmatched_new_indices = {}

	for idx, cell in ipairs(parsed_cells) do
		local key = table.concat({
			cell.name,
			vim.json.encode(cell.options or {}),
			cell.code,
		}, "\0")
		local queue = previous_by_key[key] or {}
		local matched = nil
		while #queue > 0 do
			local candidate = table.remove(queue, 1)
			if not matched_previous_ids[candidate.id] then
				matched = candidate
				break
			end
		end
		if matched == nil then
			provisional[idx] = vim.deepcopy(cell)
			table.insert(unmatched_new_indices, idx)
		else
			matched_previous_ids[matched.id] = true
			provisional[idx] = vim.tbl_extend("force", cell, {
				id = matched.id,
				editor_status = (matched.code == cell.code and vim.deep_equal(matched.options or {}, cell.options or {}) and matched.name == cell.name)
						and "clean"
					or "edited",
			})
		end
	end

	local remaining_previous = {}
	for _, cell in ipairs(previous) do
		if not matched_previous_ids[cell.id] then
			table.insert(remaining_previous, cell)
		end
	end

	local prev_pos = 1
	for _, idx in ipairs(unmatched_new_indices) do
		local cell = provisional[idx]
		local matched = nil
		for search_idx = prev_pos, #remaining_previous do
			local candidate = remaining_previous[search_idx]
			if candidate.name == cell.name and vim.deep_equal(candidate.options or {}, cell.options or {}) then
				matched = candidate
				prev_pos = search_idx + 1
				break
			end
		end
		provisional[idx] = vim.tbl_extend("force", cell, {
			id = matched and matched.id or next_cell_id(),
			editor_status = "edited",
		})
	end

	return provisional
end

local function enrich_cells(cells, projected_lines, canonical_ranges, disabled_transitively)
	local projection_ranges = markers.projected_cell_ranges(projected_lines)
	local enriched = {}
	for idx, cell in ipairs(cells) do
		local projection_range = projection_ranges[idx] or { start_line = 1, start_col = 1, end_line = 1, end_col = 1 }
		local canonical_range = canonical_ranges[idx] or { start_line = 1, start_col = 1, end_line = 1, end_col = 1 }
		table.insert(enriched, vim.tbl_extend("force", cell, {
			index = idx - 1,
			projection_range = projection_range,
			canonical_range = canonical_range,
			disabled_transitively = (disabled_transitively or {})[cell.id] == true,
		}))
	end
	return enriched
end

function M.parse_projected_snapshot(lines, previous)
	local parsed = parse_projected_cells(lines)
	return drop_empty_cells(dedupe_empty_cells(reconcile_ids(previous, parsed)))
end

function M.manual_snapshot(content)
	local lines = util.split_lines(content)
	if markers.has_any_projected_markers(lines) then
		local promoted, changed = markers.promote_first_marker_to_marimo(lines)
		if not changed then
			error("failed to promote projected markers to marimo cells")
		end
		return M.parse_projected_snapshot(promoted, nil)
	end
	return {
		{
			id = next_cell_id(),
			name = "_",
			code = content,
			options = {},
			editor_status = "clean",
		},
	}
end

function M.build_payload(opts)
	local projected_lines = vim.deepcopy(opts.projected_lines or markers.render_projected_buffer_lines(opts.cells or {}))
	local enriched_cells = enrich_cells(
		opts.cells or {},
		projected_lines,
		opts.canonical_ranges or {},
		opts.disabled_transitively or {}
	)
	return {
		session_id = opts.session_id or opts.path,
		path = opts.path,
		project_root = opts.project_root,
		runtime_kind = opts.runtime_kind,
		header = opts.header,
		app_options = util.as_json_object(opts.app_options or {}),
		projected_lines = projected_lines,
		canonical_source = opts.canonical_source or "",
		cells = enriched_cells,
		projection_map = {
			cells = vim.tbl_map(function(cell)
				return {
					id = cell.id,
					name = cell.name,
					projection_range = cell.projection_range,
					canonical_range = cell.canonical_range,
				}
			end, enriched_cells),
		},
		last_saved_source_hash = opts.last_saved_source_hash,
		last_projection_hash = vim.fn.sha256(util.join_lines(projected_lines)),
	}
end

return M
