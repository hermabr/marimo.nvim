local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local navigation = dofile(dir .. "/navigation.lua")
local session = dofile(dir .. "/session.lua")
local images = dofile(dir .. "/images.lua")
local output = dofile(dir .. "/output.lua")
local util = dofile(dir .. "/util.lua")

local M = {}

local highlight_namespace = vim.api.nvim_create_namespace("marimo.nvim.output_window")
local window_state = {}

local function state_for(bufnr)
	window_state[bufnr] = window_state[bufnr] or {}
	return window_state[bufnr]
end

local function clear_state(bufnr)
	window_state[bufnr] = nil
end

local function close_window(winid)
	if winid and vim.api.nvim_win_is_valid(winid) then
		pcall(vim.api.nvim_win_close, winid, true)
	end
end

local function close_buffer(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	end
end

local function find_cell_by_id(bufnr, cell_id)
	for _, cell in ipairs(vim.b[bufnr].marimo_cells or {}) do
		if cell.id == cell_id then
			return cell
		end
	end
	return nil
end

local function cell_display(bufnr, cell)
	if not cell then
		return nil
	end
	local runtime_by_id = session.get_runtime_cells(bufnr)
	local runtime = runtime_by_id[cell.id] or cell.runtime or {}
	local output_image = images.extract_output_image(runtime.output)
	local console_image = images.extract_console_image(runtime.console)
	local render_images = images.supports_images()
	local sections = output.runtime_sections(runtime, {
		output_image_resolved = render_images and output_image ~= nil,
		console_image_resolved = render_images and console_image ~= nil,
	})
	local lines = {}
	local anchors = {}
	if sections.status then
		table.insert(lines, sections.status)
	end
	for _, line in ipairs(sections.output) do
		table.insert(lines, line)
	end
	if render_images and output_image ~= nil then
		table.insert(lines, { text = "" })
		anchors.output = #lines
	end
	for _, line in ipairs(sections.console) do
		table.insert(lines, line)
	end
	if render_images and console_image ~= nil then
		table.insert(lines, { text = "" })
		anchors.console = #lines
	end
	if #lines == 0 then
		return nil
	end
	return {
		lines = lines,
		output_image = render_images and output_image or nil,
		console_image = render_images and console_image or nil,
		anchors = anchors,
	}
end

local function apply_lines(bufnr, lines)
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_clear_namespace(bufnr, highlight_namespace, 0, -1)
	local text_lines = {}
	for _, line in ipairs(lines or {}) do
		table.insert(text_lines, line.text)
	end
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, text_lines)
	for idx, line in ipairs(lines or {}) do
		if line.highlight then
			vim.api.nvim_buf_add_highlight(bufnr, highlight_namespace, line.highlight, idx - 1, 0, -1)
		end
	end
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].modified = false
end

local function centered_float_config()
	local width = math.max(math.min(math.floor(vim.o.columns * 0.8), vim.o.columns - 4), 40)
	local height = math.max(math.min(math.floor(vim.o.lines * 0.5), 24), 8)
	local row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0)
	local col = math.max(math.floor((vim.o.columns - width) / 2), 0)
	return {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		width = width,
		height = height,
		row = row,
		col = col,
		zindex = 60,
	}
end

local function capture_source_window_options(winid)
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return {
			number = vim.wo.number,
			relativenumber = vim.wo.relativenumber,
		}
	end
	return {
		number = vim.wo[winid].number,
		relativenumber = vim.wo[winid].relativenumber,
	}
end

local function configure_buffer(bufnr)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].filetype = "marimo-output"
end

local function configure_window(winid, window_opts)
	window_opts = window_opts or {}
	vim.wo[winid].wrap = true
	vim.wo[winid].cursorline = true
	vim.wo[winid].number = window_opts.number == true
	vim.wo[winid].relativenumber = window_opts.relativenumber == true
	vim.wo[winid].signcolumn = "no"
	vim.wo[winid].foldcolumn = "0"
	vim.wo[winid].spell = false
	pcall(function()
		vim.wo[winid].winfixbuf = true
	end)
end

local function bind_window_keys(bufnr, source_bufnr)
	vim.keymap.set("n", "q", function()
		M.close(source_bufnr)
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Marimo: close output" })
	vim.keymap.set("n", "<Esc>", function()
		M.close(source_bufnr)
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Marimo: close output" })
end

local function attach_cleanup_autocmd(source_bufnr, float_bufnr)
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = float_bufnr,
		once = true,
		callback = function()
			local entry = window_state[source_bufnr]
			if not entry or entry.float_bufnr ~= float_bufnr then
				return
			end
			images.close_placements(entry)
			clear_state(source_bufnr)
		end,
	})
end

local function ensure_entry(bufnr, cell, source_winid)
	local entry = state_for(bufnr)
	entry.window_opts = capture_source_window_options(source_winid)
	if entry.winid and vim.api.nvim_win_is_valid(entry.winid) and entry.float_bufnr and vim.api.nvim_buf_is_valid(entry.float_bufnr) then
		entry.cell_id = cell.id
		return entry
	end

	close_window(entry.winid)
	close_buffer(entry.float_bufnr)

	local float_bufnr = vim.api.nvim_create_buf(false, true)
	configure_buffer(float_bufnr)
	bind_window_keys(float_bufnr, bufnr)
	attach_cleanup_autocmd(bufnr, float_bufnr)

	local winid = vim.api.nvim_open_win(float_bufnr, true, centered_float_config())
	configure_window(winid, entry.window_opts)

	entry.float_bufnr = float_bufnr
	entry.winid = winid
	entry.cell_id = cell.id
	entry.placements = entry.placements or {}
	return entry
end

local function place_entry_images(entry, display)
	images.close_placements(entry)
	if not vim.api.nvim_win_is_valid(entry.winid) then
		return
	end
	local max_width = math.max(vim.api.nvim_win_get_width(entry.winid) - 4, 20)
	local max_height = math.max(vim.api.nvim_win_get_height(entry.winid) - 4, 8)
	if display.output_image and display.anchors.output then
		local placement = images.place_image(entry.float_bufnr, display.anchors.output, display.output_image, {
			max_width = max_width,
			max_height = max_height,
		})
		if placement then
			table.insert(entry.placements, placement)
		end
	end
	if display.console_image and display.anchors.console then
		local placement = images.place_image(entry.float_bufnr, display.anchors.console, display.console_image, {
			max_width = max_width,
			max_height = max_height,
		})
		if placement then
			table.insert(entry.placements, placement)
		end
	end
end

local function update_entry(entry, cell, display, preserve_view)
	local view = nil
	if preserve_view and vim.api.nvim_win_is_valid(entry.winid) then
		view = vim.api.nvim_win_call(entry.winid, vim.fn.winsaveview)
	end
	apply_lines(entry.float_bufnr, display.lines)
	place_entry_images(entry, display)
	if view and vim.api.nvim_win_is_valid(entry.winid) then
		pcall(vim.api.nvim_win_call, entry.winid, function()
			vim.fn.winrestview(view)
		end)
	elseif vim.api.nvim_win_is_valid(entry.winid) then
		pcall(vim.api.nvim_win_set_cursor, entry.winid, { 1, 0 })
		vim.api.nvim_win_call(entry.winid, function()
			vim.cmd("silent! normal! zt")
		end)
	end
	local title = string.format(" marimo output %s ", tostring(cell.id))
	pcall(vim.api.nvim_win_set_config, entry.winid, vim.tbl_extend("force", centered_float_config(), { title = title, title_pos = "center" }))
	configure_window(entry.winid, entry.window_opts)
	return true
end

function M.refresh(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local entry = window_state[bufnr]
	if not entry then
		return
	end
	if not entry.winid or not vim.api.nvim_win_is_valid(entry.winid) or not entry.float_bufnr or not vim.api.nvim_buf_is_valid(entry.float_bufnr) then
		clear_state(bufnr)
		return
	end
	local cell = find_cell_by_id(bufnr, entry.cell_id)
	local display = cell_display(bufnr, cell)
	if not display then
		M.close(bufnr)
		return
	end
	return update_entry(entry, cell, display, true)
end

function M.open_current(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected then
		util.notify("marimo is not active in this buffer", vim.log.levels.WARN)
		return false
	end
	local cell = navigation.find_current_cell(bufnr)
	if not cell then
		util.notify("no current marimo cell", vim.log.levels.WARN)
		return false
	end
	local display = cell_display(bufnr, cell)
	if not display then
		util.notify("current cell has no visible output", vim.log.levels.WARN)
		return false
	end
	local entry = ensure_entry(bufnr, cell, vim.api.nvim_get_current_win())
	return update_entry(entry, cell, display, false)
end

function M.close(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local entry = window_state[bufnr]
	if not entry then
		return
	end
	local winid = entry.winid
	local float_bufnr = entry.float_bufnr
	images.close_placements(entry)
	clear_state(bufnr)
	close_window(winid)
	close_buffer(float_bufnr)
end

return M
