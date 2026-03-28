local M = {}

local namespace = vim.api.nvim_create_namespace("marimo.nvim.cells")
local output = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/output.lua")
local images = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/images.lua")
local util = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/util.lua")

local image_state = {}
local render_state = {}

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
	local output_image = images.extract_output_image(runtime.output)
	local console_image = images.extract_console_image(runtime.console)
	local rendered = output.runtime_lines(runtime, {
		max_lines = 12,
		max_line_chars = 160,
		output_image_resolved = output_image ~= nil,
		console_image_resolved = console_image ~= nil,
	})
	if #rendered == 0 and output_image == nil and console_image == nil then
		return nil, nil
	end

	local lines = {}
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
	render_state[bufnr] = (render_state[bufnr] or 0) + 1
	local generation = render_state[bufnr]
	local line_count = math.max(vim.api.nvim_buf_line_count(bufnr), 1)
	local pending_images = {}
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
			table.insert(pending_images, {
				line = line,
				image_line = math.min(line + 1, line_count),
				src = image_src,
			})
		end
		::continue::
	end
	if #pending_images > 0 then
		vim.schedule(function()
			if not vim.api.nvim_buf_is_valid(bufnr) or render_state[bufnr] ~= generation then
				return
			end
			for _, image in ipairs(pending_images) do
				if not place_output_image(bufnr, image.image_line, image.src) then
					vim.api.nvim_buf_set_extmark(bufnr, namespace, image.line, 0, {
						virt_lines = {
							{ { " [image/png output]", "Comment" } },
						},
						virt_lines_above = false,
					})
				end
			end
			util.request_redraw()
		end)
	end
end

return M
