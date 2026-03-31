local M = {}

local namespace = vim.api.nvim_create_namespace("marimo.nvim.cells")
local output = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/output.lua")
local images = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/images.lua")

local render_state = {}

local function state_for(bufnr)
	render_state[bufnr] = render_state[bufnr] or {
		extmarks = {},
		images = {},
	}
	return render_state[bufnr]
end

local function close_image_placements(entry)
	if not entry then
		return
	end
	images.close_placements(entry)
end

local function place_output_image(bufnr, line, src)
	local placement = images.place_image(bufnr, line, src, {
		max_width = 80,
		max_height = 24,
	})
	if placement == nil then
		return false
	end
	return placement
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

function M.clear(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
	local state = render_state[bufnr]
	if not state then
		return
	end
	for _, entry in pairs(state.images) do
		close_image_placements(entry)
	end
	render_state[bufnr] = nil
end

local function clear_cell_render(bufnr, cell_id)
	local state = render_state[bufnr]
	if not state or cell_id == nil then
		return
	end
	local extmark_id = state.extmarks[cell_id]
	if extmark_id ~= nil then
		pcall(vim.api.nvim_buf_del_extmark, bufnr, namespace, extmark_id)
		state.extmarks[cell_id] = nil
	end
	close_image_placements(state.images[cell_id])
	state.images[cell_id] = nil
end

local function render_cell(bufnr, cell, line_count)
	if type(cell) ~= "table" or cell.id == nil then
		return
	end
	local state = state_for(bufnr)
	clear_cell_render(bufnr, cell.id)
	line_count = line_count or math.max(vim.api.nvim_buf_line_count(bufnr), 1)
	local range = cell.projection_range or {}
	local line = math.max((range.end_line or range.start_line or 1) - 1, 0)
	line = math.min(line, line_count - 1)
	local lines, image_src = virtual_lines(cell)
	if lines == nil and image_src == nil then
		return
	end
	if lines and #lines > 0 then
		state.extmarks[cell.id] = vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
			virt_lines = lines,
			virt_lines_above = false,
		})
	end
	if image_src then
		local image_line = math.min(line + 1, line_count)
		local placement = place_output_image(bufnr, image_line, image_src)
		if placement then
			state.images[cell.id] = { placements = { placement } }
			return
		end
		state.extmarks[cell.id] = vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
			virt_lines = {
				{ { " [image/png output]", "Comment" } },
			},
			virt_lines_above = false,
		})
	end
end

function M.render(bufnr, cells, opts)
	opts = opts or {}
	local changed_ids = opts.changed_ids
	if changed_ids ~= nil then
		local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
		local cells_by_id = {}
		for _, cell in ipairs(cells or {}) do
			cells_by_id[cell.id] = cell
		end
		for _, cell_id in ipairs(changed_ids) do
			local cell = cells_by_id[cell_id]
			if cell ~= nil then
				render_cell(bufnr, cell, line_count)
			else
				clear_cell_render(bufnr, cell_id)
			end
		end
		return
	end

	M.clear(bufnr)
	local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
	for _, cell in ipairs(cells or {}) do
		render_cell(bufnr, cell, line_count)
	end
end

return M
