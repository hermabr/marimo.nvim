local M = {}

local namespace = vim.api.nvim_create_namespace("marimo.nvim.cells")
local output = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/output.lua")
local images = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/images.lua")

local image_state = {}

local function close_image_placements(bufnr)
	local entry = image_state[bufnr]
	if not entry then
		return
	end
	images.close_placements(entry)
	image_state[bufnr] = nil
end

local function place_output_image(bufnr, line, src)
	local placement = images.place_image(bufnr, line, src, {
		max_width = 80,
		max_height = 24,
	})
	if placement == nil then
		return false
	end
	image_state[bufnr] = image_state[bufnr] or { placements = {} }
	table.insert(image_state[bufnr].placements, placement)
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

function M.clear(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
	close_image_placements(bufnr)
end

function M.render(bufnr, cells)
	M.clear(bufnr)
	local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
	for _, cell in ipairs(cells or {}) do
		local range = cell.projection_range or {}
		local line = math.max((range.end_line or range.start_line or 1) - 1, 0)
		line = math.min(line, line_count - 1)
		local lines, image_src = virtual_lines(cell)
		if lines == nil and image_src == nil then
			goto continue
		end
		if lines and #lines > 0 then
			vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
				virt_lines = lines,
				virt_lines_above = false,
			})
		end
		if image_src then
			local image_line = math.min(line + 1, line_count)
			if not place_output_image(bufnr, image_line, image_src) then
				vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
					virt_lines = {
						{ { " [image/png output]", "Comment" } },
					},
					virt_lines_above = false,
				})
			end
		end
		::continue::
	end
end

return M
