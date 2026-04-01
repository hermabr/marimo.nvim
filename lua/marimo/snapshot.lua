local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local markers = dofile(dir .. "/markers.lua")
local util = dofile(dir .. "/util.lua")

local M = {}

local function copy_cell(cell)
	return {
		id = cell.id,
		name = cell.name,
		code = cell.code,
		options = vim.deepcopy(cell.options or {}),
		editor_status = cell.editor_status,
		projection_range = vim.deepcopy(cell.projection_range),
		canonical_range = vim.deepcopy(cell.canonical_range),
	}
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

local function parse_projected_cells(lines)
	local parsed = {}
	for _, cell in ipairs(markers.parse_projected_cells(lines)) do
		table.insert(parsed, {
			name = cell.name,
			code = cell.code,
			options = vim.deepcopy(cell.options or {}),
			projection_range = vim.deepcopy(cell.projection_range),
		})
	end
	return parsed
end

local function drop_empty_cells(cells)
	local kept = {}
	for _, cell in ipairs(cells) do
		if vim.trim(cell.code or "") ~= "" then
			table.insert(kept, cell)
		end
	end
	if #kept > 0 then
		return kept
	end
	if #cells == 0 then
		return {}
	end
	local first = copy_cell(cells[1])
	first.code = ""
	return { first }
end

local function nearest_index_match(candidates, index)
	local best_idx = 1
	local best_distance = nil
	for idx, candidate in ipairs(candidates) do
		local distance = math.abs((candidate.index or idx) - index)
		if best_distance == nil or distance < best_distance then
			best_distance = distance
			best_idx = idx
		end
	end
	return table.remove(candidates, best_idx)
end

local function similarity_score(previous_code, next_code)
	local prefix = 0
	local max_prefix = math.min(#previous_code, #next_code)
	while prefix < max_prefix and previous_code:sub(prefix + 1, prefix + 1) == next_code:sub(prefix + 1, prefix + 1) do
		prefix = prefix + 1
	end
	local suffix = 0
	if prefix < max_prefix then
		while suffix < (#previous_code - prefix)
			and suffix < (#next_code - prefix)
			and previous_code:sub(#previous_code - suffix, #previous_code - suffix) == next_code:sub(#next_code - suffix, #next_code - suffix)
		do
			suffix = suffix + 1
		end
	end
	return #previous_code + #next_code - 2 * (prefix + suffix)
end

function M.reconcile_cell_ids(previous_cells, next_cells)
	if not previous_cells or #previous_cells == 0 then
		local fresh = {}
		for _, cell in ipairs(next_cells) do
			local next_cell = copy_cell(cell)
			next_cell.id = util.new_local_id()
			next_cell.editor_status = "clean"
			table.insert(fresh, next_cell)
		end
		return fresh
	end

	local available_by_code = {}
	for idx, cell in ipairs(previous_cells) do
		local code = cell.code or ""
		available_by_code[code] = available_by_code[code] or {}
		table.insert(available_by_code[code], { index = idx, cell = cell })
	end

	local reconciled = {}
	local unmatched_indices = {}
	local used_ids = {}
	local remaining_previous = {}
	for idx, previous in ipairs(previous_cells) do
		remaining_previous[idx] = previous
	end

	for idx, cell in ipairs(next_cells) do
		local candidates = available_by_code[cell.code or ""]
		local matched = nil
		local matched_index = nil
		if candidates and #candidates > 0 then
			local candidate = nearest_index_match(candidates, idx)
			matched = candidate.cell
			matched_index = candidate.index
		end
		if matched ~= nil and not used_ids[matched.id] then
			used_ids[matched.id] = true
			if matched_index ~= nil then
				remaining_previous[matched_index] = nil
			end
			local next_cell = copy_cell(cell)
			next_cell.id = matched.id
			if matched.code == cell.code and matched.name == cell.name and vim.deep_equal(matched.options or {}, cell.options or {}) then
				next_cell.editor_status = "clean"
			else
				next_cell.editor_status = "edited"
			end
			table.insert(reconciled, next_cell)
		else
			table.insert(reconciled, copy_cell(cell))
			table.insert(unmatched_indices, idx)
		end
	end

	local unmatched_previous = {}
	for _, cell in pairs(remaining_previous) do
		if cell ~= nil then
			table.insert(unmatched_previous, cell)
		end
	end

	for _, idx in ipairs(unmatched_indices) do
		local cell = reconciled[idx]
		local best_previous = nil
		local best_previous_idx = nil
		local best_score = nil
		for previous_idx, previous in ipairs(unmatched_previous) do
			local score = similarity_score(previous.code or "", cell.code or "")
			if previous.name ~= cell.name then
				score = score + 1000
			end
			if not vim.deep_equal(previous.options or {}, cell.options or {}) then
				score = score + 1000
			end
			if best_score == nil or score < best_score then
				best_score = score
				best_previous_idx = previous_idx
				best_previous = previous
			end
		end
		if best_previous ~= nil and best_previous_idx ~= nil then
			cell.id = best_previous.id
			cell.editor_status = "edited"
			table.remove(unmatched_previous, best_previous_idx)
		else
			cell.id = util.new_local_id()
			cell.editor_status = "edited"
		end
	end

	return reconciled
end

function M.compute_changes(previous_cells, next_cells)
	if not previous_cells then
		local all_ids = {}
		for _, cell in ipairs(next_cells) do
			table.insert(all_ids, cell.id)
		end
		return all_ids, {}
	end
	local previous_by_id = {}
	for _, cell in ipairs(previous_cells) do
		previous_by_id[cell.id] = cell
	end
	local current_ids = {}
	local changed_ids = {}
	for _, cell in ipairs(next_cells) do
		current_ids[cell.id] = true
		local previous = previous_by_id[cell.id]
		if previous == nil
			or previous.code ~= cell.code
			or previous.name ~= cell.name
			or not vim.deep_equal(previous.options or {}, cell.options or {})
		then
			table.insert(changed_ids, cell.id)
		end
	end
	local deleted_ids = {}
	for _, cell in ipairs(previous_cells) do
		if not current_ids[cell.id] then
			table.insert(deleted_ids, cell.id)
		end
	end
	return changed_ids, deleted_ids
end

local function with_ranges(cells, projected_lines)
	local ranges = markers.projected_cell_ranges(projected_lines)
	for idx, cell in ipairs(cells) do
		cell.projection_range = vim.deepcopy(ranges[idx] or cell.projection_range)
	end
	return cells
end

function M.projected_lines_for_snapshot(snapshot)
	return markers.render_projected_buffer_lines(snapshot.cells or {})
end

function M.snapshot_from_projected_lines(opts)
	local lines = opts.lines or {}
	local parsed = parse_projected_cells(lines)
	local cells = drop_empty_cells(parsed)
	cells = M.reconcile_cell_ids(opts.previous_cells, cells)
	local snapshot = {
		session_id = opts.session_id,
		path = opts.path,
		project_root = opts.project_root,
		runtime_kind = opts.runtime_kind,
		header = opts.header,
		app_options = util.as_json_object(opts.app_options or {}),
		cells = cells,
	}
	local projected_lines = M.projected_lines_for_snapshot(snapshot)
	return snapshot, projected_lines
end

function M.snapshot_from_manual_python(opts)
	local code = util.join_lines(trim_blank_lines(opts.lines or {}))
	local cells = M.reconcile_cell_ids(opts.previous_cells, {
		{
			name = "_",
			code = code,
			options = {},
		},
	})
	local snapshot = {
		session_id = opts.session_id,
		path = opts.path,
		project_root = opts.project_root,
		runtime_kind = opts.runtime_kind,
		header = nil,
		app_options = vim.empty_dict(),
		cells = cells,
	}
	local projected_lines = M.projected_lines_for_snapshot(snapshot)
	snapshot.cells = with_ranges(snapshot.cells, projected_lines)
	return snapshot, projected_lines
end

function M.snapshot_from_loaded_raw(loaded)
	local snapshot = vim.deepcopy(loaded)
	local projected_lines = M.projected_lines_for_snapshot(snapshot)
	snapshot.cells = with_ranges(snapshot.cells or {}, projected_lines)
	return snapshot, projected_lines
end

function M.attach_projected_ranges(snapshot, projected_lines)
	snapshot.cells = with_ranges(snapshot.cells or {}, projected_lines)
	return snapshot
end

function M.attach_canonical_ranges(snapshot, canonical_ranges)
	for idx, cell in ipairs(snapshot.cells or {}) do
		cell.canonical_range = vim.deepcopy(canonical_ranges[idx])
	end
	return snapshot
end

function M.projection_map(snapshot)
	local cells = {}
	for _, cell in ipairs(snapshot.cells or {}) do
		table.insert(cells, {
			id = cell.id,
			name = cell.name,
			projection_range = vim.deepcopy(cell.projection_range),
			canonical_range = vim.deepcopy(cell.canonical_range),
		})
	end
	return { cells = cells }
end

return M
