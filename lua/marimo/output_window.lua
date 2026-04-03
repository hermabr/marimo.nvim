local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local navigation = dofile(dir .. "/navigation.lua")
local images = dofile(dir .. "/images.lua")
local output = dofile(dir .. "/output.lua")
local util = dofile(dir .. "/util.lua")

local M = {}
local uv = vim.uv or vim.loop

local highlight_namespace = vim.api.nvim_create_namespace("marimo.nvim.output_window")
local window_state = {}
local runtime_refresh_interval_ms = 200
local centered_float_config
local find_cell_by_id

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

local function runtime_for_cell(bufnr, cell)
	if not cell then
		return {}
	end
	local runtime_by_id = vim.b[bufnr].marimo_runtime_cells or {}
	return runtime_by_id[cell.id] or cell.runtime or {}
end

local function format_duration(ms)
	if type(ms) ~= "number" then
		return nil
	end
	local rounded_ms = math.max(math.floor(ms + 0.5), 0)
	if rounded_ms < 1000 then
		return string.format("%dms", rounded_ms)
	end
	if rounded_ms < 10000 then
		return string.format("%.2fs", rounded_ms / 1000)
	end
	if rounded_ms < 60000 then
		return string.format("%.1fs", rounded_ms / 1000)
	end
	local total_seconds = math.floor((rounded_ms + 500) / 1000)
	local minutes = math.floor(total_seconds / 60)
	local seconds = total_seconds % 60
	if minutes < 60 then
		return string.format("%dm %02ds", minutes, seconds)
	end
	local hours = math.floor(minutes / 60)
	minutes = minutes % 60
	return string.format("%dh %02dm", hours, minutes)
end

local function runtime_title_fragment(runtime)
	runtime = runtime or {}
	if runtime.status == "running" and type(runtime._running_started_at_ns) == "number" and uv and type(uv.hrtime) == "function" then
		local elapsed_ms = math.max((uv.hrtime() - runtime._running_started_at_ns) / 1000000, 0)
		local formatted = format_duration(elapsed_ms)
		if formatted then
			return "runtime " .. formatted, true
		end
		return nil, true
	end
	if runtime.status == "queued" then
		return nil, false
	end
	if type(runtime.last_execution_time_ms) == "number" then
		local formatted = format_duration(runtime.last_execution_time_ms)
		if formatted then
			return "took " .. formatted, false
		end
	end
	return nil, false
end

local function build_window_title(cell, runtime)
	local title = " marimo output "
	local runtime_title, is_running = runtime_title_fragment(runtime)
	if runtime_title then
		title = string.format(" marimo output | %s ", runtime_title)
	end
	return title, is_running
end

local function apply_window_title(entry, cell, runtime)
	if not entry or not entry.winid or not vim.api.nvim_win_is_valid(entry.winid) then
		return false
	end
	local title, is_running = build_window_title(cell, runtime)
	if entry.title ~= title then
		entry.title = title
		pcall(vim.api.nvim_win_set_config, entry.winid, {
			title = title,
			title_pos = "center",
		})
	end
	return is_running
end

local function stop_runtime_timer(entry)
	if not entry or not entry.runtime_timer then
		return
	end
	local timer = entry.runtime_timer
	entry.runtime_timer = nil
	pcall(function()
		timer:stop()
	end)
	pcall(function()
		timer:close()
	end)
end

local function sync_runtime_timer(source_bufnr, entry, cell, runtime)
	local is_running = apply_window_title(entry, cell, runtime)
	if not is_running or not uv or type(uv.new_timer) ~= "function" then
		stop_runtime_timer(entry)
		return
	end
	if entry.runtime_timer then
		return
	end
	local timer = uv.new_timer()
	if not timer then
		return
	end
	entry.runtime_timer = timer
	timer:start(runtime_refresh_interval_ms, runtime_refresh_interval_ms, vim.schedule_wrap(function()
		if window_state[source_bufnr] ~= entry then
			stop_runtime_timer(entry)
			return
		end
		if not vim.api.nvim_buf_is_valid(source_bufnr) or not entry.winid or not vim.api.nvim_win_is_valid(entry.winid) then
			stop_runtime_timer(entry)
			return
		end
		local current_cell = find_cell_by_id(source_bufnr, entry.cell_id)
		if not current_cell then
			stop_runtime_timer(entry)
			return
		end
		local current_runtime = runtime_for_cell(source_bufnr, current_cell)
		if not apply_window_title(entry, current_cell, current_runtime) then
			stop_runtime_timer(entry)
		end
	end))
end

find_cell_by_id = function(bufnr, cell_id)
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
	local runtime = runtime_for_cell(bufnr, cell)
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

centered_float_config = function()
	local width = math.max(math.min(math.floor(vim.o.columns * 0.8), vim.o.columns - 4), 40)
	local height = math.max(math.min(math.floor(vim.o.lines * 0.8), vim.o.lines - 4), 8)
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
	vim.b[bufnr].marimo_output_float = true
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
			stop_runtime_timer(entry)
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

local function update_entry(source_bufnr, entry, cell, display, preserve_view)
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
	configure_window(entry.winid, entry.window_opts)
	sync_runtime_timer(source_bufnr, entry, cell, runtime_for_cell(source_bufnr, cell))
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
	return update_entry(bufnr, entry, cell, display, true)
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
	return update_entry(bufnr, entry, cell, display, false)
end

function M.close(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local entry = window_state[bufnr]
	if not entry then
		return
	end
	local winid = entry.winid
	local float_bufnr = entry.float_bufnr
	stop_runtime_timer(entry)
	images.close_placements(entry)
	clear_state(bufnr)
	close_window(winid)
	close_buffer(float_bufnr)
end

return M
