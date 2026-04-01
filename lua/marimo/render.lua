local M = {}

local namespace = vim.api.nvim_create_namespace("marimo.nvim.cells")
local output = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/output.lua")
local images = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/images.lua")

local render_state = {}

local function normalize_bufnr(bufnr)
	if bufnr == nil or bufnr == 0 then
		return vim.api.nvim_get_current_buf()
	end
	return bufnr
end

local function state_for(bufnr)
	bufnr = normalize_bufnr(bufnr)
	render_state[bufnr] = render_state[bufnr] or {
		extmarks_by_cell = {},
		placements_by_cell = {},
	}
	return render_state[bufnr]
end

local function clear_cell(bufnr, cell_id)
	local entry = render_state[bufnr]
	if not entry or not cell_id then
		return
	end
	local extmark_id = entry.extmarks_by_cell[cell_id]
	if extmark_id then
		pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, extmark_id)
		entry.extmarks_by_cell[cell_id] = nil
	end
	local placement_entry = entry.placements_by_cell[cell_id]
	if placement_entry then
		images.close_placements(placement_entry)
		entry.placements_by_cell[cell_id] = nil
	end
end

local function close_all_cells(bufnr)
	local entry = render_state[bufnr]
	if not entry then
		return
	end
	for cell_id in pairs(entry.placements_by_cell) do
		clear_cell(bufnr, cell_id)
	end
	for cell_id in pairs(entry.extmarks_by_cell) do
		clear_cell(bufnr, cell_id)
	end
	render_state[bufnr] = nil
end

local function place_output_image(bufnr, cell_id, line, src)
	local placement = images.place_image(bufnr, line, src, {
		max_width = 80,
		max_height = 24,
	})
	if placement == nil then
		return false
	end
	state_for(bufnr).placements_by_cell[cell_id] = { placements = { placement } }
	return true
end

local function virtual_lines(cell)
	local runtime = cell.runtime or {}
	local display_runtime = runtime
	local is_disabled = (cell.options or {}).disabled
	local is_disabled_ancestor = cell.disabled_transitively or runtime.status == "disabled-transitively"
	local status_lines = {}
	if is_disabled then
		table.insert(status_lines, {
			{ " marimo disabled", "WarningMsg" },
		})
		display_runtime = vim.deepcopy(runtime)
		display_runtime.stale_inputs = false
		display_runtime.status = nil
	elseif is_disabled_ancestor then
		table.insert(status_lines, {
			{ " marimo disabled (ancestor)", "WarningMsg" },
		})
		display_runtime = vim.deepcopy(runtime)
		display_runtime.stale_inputs = false
		display_runtime.status = nil
	end
	local output_image = images.extract_output_image(runtime.output)
	local console_image = images.extract_console_image(runtime.console)
	local rendered = output.runtime_lines(display_runtime, {
		max_lines = 12,
		max_line_chars = 160,
		output_image_resolved = output_image ~= nil,
		console_image_resolved = console_image ~= nil,
	})
	if #rendered == 0 and #status_lines == 0 and output_image == nil and console_image == nil then
		return nil, nil
	end

	local lines = vim.deepcopy(status_lines)
	for _, line in ipairs(rendered) do
		table.insert(lines, {
			{ " " .. line.text, line.highlight },
		})
	end
	return lines, output_image or console_image
end

local function render_cell(bufnr, cell)
	clear_cell(bufnr, cell.id)
	local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
	local range = cell.projection_range or {}
	local line = math.max((range.end_line or range.start_line or 1) - 1, 0)
	line = math.min(line, line_count - 1)
	local lines, image_src = virtual_lines(cell)
	local extmark_lines = lines and vim.deepcopy(lines) or {}
	if image_src then
		local image_line = math.min(line + 1, line_count)
		if not place_output_image(bufnr, cell.id, image_line, image_src) then
			table.insert(extmark_lines, {
				{ " [image/png output]", "Comment" },
			})
		end
	end
	if #extmark_lines == 0 then
		return
	end
	state_for(bufnr).extmarks_by_cell[cell.id] = vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
		virt_lines = extmark_lines,
		virt_lines_above = false,
	})
end

function M.clear(bufnr)
	bufnr = normalize_bufnr(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
	close_all_cells(bufnr)
end

function M.render(bufnr, cells, opts)
	bufnr = normalize_bufnr(bufnr)
	opts = opts or {}
	local entry = state_for(bufnr)
	local cells_by_id = {}
	local present_lookup = {}
	local target_ids = {}
	for _, cell in ipairs(cells or {}) do
		cells_by_id[cell.id] = cell
		present_lookup[cell.id] = true
		if not opts.changed_ids then
			table.insert(target_ids, cell.id)
		end
	end
	if opts.changed_ids then
		for _, cell_id in ipairs(opts.changed_ids) do
			table.insert(target_ids, cell_id)
		end
	end
	local removed_lookup = {}
	for cell_id in pairs(entry.extmarks_by_cell) do
		if not present_lookup[cell_id] then
			removed_lookup[cell_id] = true
		end
	end
	for cell_id in pairs(entry.placements_by_cell) do
		if not present_lookup[cell_id] then
			removed_lookup[cell_id] = true
		end
	end
	for _, cell_id in ipairs(opts.deleted_ids or {}) do
		removed_lookup[cell_id] = true
	end
	for cell_id in pairs(removed_lookup) do
		clear_cell(bufnr, cell_id)
	end
	local rendered_lookup = {}
	for _, cell_id in ipairs(target_ids) do
		if not rendered_lookup[cell_id] then
			rendered_lookup[cell_id] = true
			local cell = cells_by_id[cell_id]
			if cell then
				render_cell(bufnr, cell)
			else
				clear_cell(bufnr, cell_id)
			end
		end
	end
end

return M
