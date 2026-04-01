local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local markers = dofile(dir .. "/markers.lua")

local M = {}
local next_generated_id = 0

local function as_json_object(tbl)
	if tbl == nil or vim.tbl_isempty(tbl) then
		return vim.empty_dict()
	end
	return tbl
end

local function new_cell_id(seed)
	next_generated_id = next_generated_id + 1
	return vim.fn.sha256(table.concat({
		tostring(vim.uv.hrtime()),
		tostring(next_generated_id),
		tostring(seed or ""),
	}, ":")):sub(1, 32)
end

local function encode_options(options)
	return vim.json.encode(options or {})
end

local function cell_key(cell)
	return table.concat({
		tostring(cell.name or "_"),
		encode_options(cell.options or {}),
		tostring(cell.code or ""),
	}, "\0")
end

local function copy_cell(cell)
	return vim.deepcopy(cell)
end

local function dedupe_empty_cells(cells)
	local deduped = {}
	local previous_empty = false
	for _, cell in ipairs(cells or {}) do
		local is_empty = (cell.code or "") == ""
		if not (is_empty and previous_empty) then
			table.insert(deduped, cell)
		end
		previous_empty = is_empty
	end
	return deduped
end

local function drop_empty_cells(cells)
	local kept = {}
	for _, cell in ipairs(cells or {}) do
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

function M.reconcile_cell_ids(previous_cells, parsed_cells)
	if not previous_cells or #previous_cells == 0 then
		local fresh = {}
		for _, cell in ipairs(parsed_cells or {}) do
			local next_cell = copy_cell(cell)
			next_cell.id = next_cell.id or new_cell_id(next_cell.code)
			next_cell.editor_status = "clean"
			table.insert(fresh, next_cell)
		end
		return fresh
	end

	local previous_by_key = {}
	for _, old in ipairs(previous_cells) do
		local key = cell_key(old)
		previous_by_key[key] = previous_by_key[key] or {}
		table.insert(previous_by_key[key], old)
	end

	local matched_ids = {}
	local provisional = {}
	local unmatched_indices = {}

	for idx, cell in ipairs(parsed_cells or {}) do
		local key = cell_key(cell)
		local queue = previous_by_key[key] or {}
		local matched = nil
		while #queue > 0 do
			local candidate = table.remove(queue, 1)
			if matched_ids[candidate.id] ~= true then
				matched = candidate
				break
			end
		end
		if matched == nil then
			table.insert(provisional, copy_cell(cell))
			table.insert(unmatched_indices, idx)
		else
			matched_ids[matched.id] = true
			local next_cell = copy_cell(cell)
			next_cell.id = matched.id
			next_cell.editor_status = (
				matched.code == cell.code
				and vim.deep_equal(matched.options or {}, cell.options or {})
				and matched.name == cell.name
			) and "clean" or "edited"
			table.insert(provisional, next_cell)
		end
	end

	local remaining_previous = {}
	for _, cell in ipairs(previous_cells) do
		if matched_ids[cell.id] ~= true then
			table.insert(remaining_previous, cell)
		end
	end

	local previous_position = 1
	for _, idx in ipairs(unmatched_indices) do
		local cell = provisional[idx]
		local matched = nil
		for search_idx = previous_position, #remaining_previous do
			local candidate = remaining_previous[search_idx]
			if candidate.name == cell.name and vim.deep_equal(candidate.options or {}, cell.options or {}) then
				matched = candidate
				previous_position = search_idx + 1
				break
			end
		end
		if matched == nil then
			cell.id = new_cell_id(cell.code)
			cell.editor_status = "edited"
		else
			cell.id = matched.id
			cell.editor_status = "edited"
		end
	end

	return provisional
end

function M.parse_projected_lines(lines, previous_cells)
	local parsed = markers.parse_projected_cells(lines)
	return M.reconcile_cell_ids(previous_cells, drop_empty_cells(dedupe_empty_cells(parsed)))
end

function M.from_manual_python(content)
	local lines = vim.split(content, "\n", { plain = true })
	if markers.has_any_projected_markers(lines) then
		local promoted, changed = markers.promote_first_marker_to_marimo(lines)
		if not changed then
			error("failed to promote projected markers to marimo cells")
		end
		return M.parse_projected_lines(promoted, nil)
	end
	return {
		{
			id = new_cell_id(content),
			name = "_",
			code = content,
			options = {},
			editor_status = "clean",
		},
	}
end

function M.build_snapshot(path, project_root, header, app_options, cells)
	local normalized_cells = {}
	for _, cell in ipairs(cells or {}) do
		local next_cell = copy_cell(cell)
		next_cell.options = as_json_object(next_cell.options or {})
		table.insert(normalized_cells, next_cell)
	end
	return {
		session_id = path,
		path = path,
		project_root = project_root,
		header = header,
		app_options = as_json_object(app_options or {}),
		cells = normalized_cells,
	}
end

function M.apply_codec_cells(cells, codec_cells)
	local codec_by_id = {}
	for _, cell in ipairs(codec_cells or {}) do
		codec_by_id[cell.id] = cell
	end
	local merged = {}
	for idx, cell in ipairs(cells or {}) do
		local next_cell = copy_cell(cell)
		local codec_cell = codec_by_id[next_cell.id] or codec_cells[idx]
		if codec_cell then
			next_cell.canonical_range = vim.deepcopy(codec_cell.canonical_range)
			next_cell.disabled_transitively = codec_cell.disabled_transitively == true
			next_cell.index = codec_cell.index or (idx - 1)
		else
			next_cell.index = idx - 1
		end
		table.insert(merged, next_cell)
	end
	return merged
end

function M.apply_projection_ranges(cells, lines)
	local parsed = markers.parse_projected_cells(lines or {})
	local merged = {}
	for idx, cell in ipairs(cells or {}) do
		local next_cell = copy_cell(cell)
		next_cell.projection_range = vim.deepcopy((parsed[idx] or {}).projection_range or next_cell.projection_range)
		table.insert(merged, next_cell)
	end
	return merged
end

function M.build_projection_map(cells)
	return {
		cells = vim.tbl_map(function(cell)
			return {
				id = cell.id,
				name = cell.name,
				projection_range = vim.deepcopy(cell.projection_range),
				canonical_range = vim.deepcopy(cell.canonical_range),
			}
		end, cells or {}),
	}
end

function M.compute_changed_ids(previous_cells, current_cells)
	if not previous_cells then
		return vim.tbl_map(function(cell)
			return cell.id
		end, current_cells or {}), {}
	end

	local previous_by_id = {}
	for _, cell in ipairs(previous_cells) do
		previous_by_id[cell.id] = cell
	end

	local current_ids = {}
	local changed_ids = {}
	for _, cell in ipairs(current_cells or {}) do
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

	local delete_ids = {}
	for _, cell in ipairs(previous_cells or {}) do
		if current_ids[cell.id] ~= true then
			table.insert(delete_ids, cell.id)
		end
	end

	return changed_ids, delete_ids
end

function M.render_projected_lines(cells)
	return markers.render_projected_buffer_lines(cells)
end

function M.build_session_payload(snapshot, runtime_kind, codec_payload)
	local cells = M.apply_codec_cells(snapshot.cells, codec_payload.cells or {})
	local projected_lines = M.render_projected_lines(cells)
	cells = M.apply_projection_ranges(cells, projected_lines)
	return {
		session_id = snapshot.session_id,
		path = snapshot.path,
		project_root = snapshot.project_root,
		runtime_kind = runtime_kind,
		header = snapshot.header,
		app_options = snapshot.app_options,
		cells = cells,
		projected_lines = projected_lines,
		canonical_source = codec_payload.canonical_source or "",
		projection_map = M.build_projection_map(cells),
		last_saved_source_hash = codec_payload.last_saved_source_hash,
	}
end

return M
