local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local navigation = dofile(dir .. "/navigation.lua")
local images = dofile(dir .. "/images.lua")
local output = dofile(dir .. "/output.lua")
local util = dofile(dir .. "/util.lua")
local worker = dofile(dir .. "/worker.lua")

local M = {}
local uv = vim.uv or vim.loop

local highlight_namespace = vim.api.nvim_create_namespace("marimo.nvim.output_window")
local window_state = {}
local runtime_refresh_interval_ms = 200
local preferred_table_page_size = 25
local centered_float_config
local find_cell_by_id
local cell_display
local update_entry

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

local function table_page_index(table_view)
	local page_index = math.floor(tonumber(table_view and table_view.page_index) or 0)
	if page_index < 0 then
		return 0
	end
	return page_index
end

local function table_page_size(table_view)
	local page_size = math.floor(tonumber(table_view and table_view.page_size) or 0)
	if page_size > 0 then
		return page_size
	end
	local row_count = #(table_view and table_view.rows_data or {})
	if row_count > 0 then
		return row_count
	end
	return 1
end

local function table_total_pages(table_view)
	if type(table_view) ~= "table" or type(table_view.total_rows) ~= "number" then
		return nil
	end
	return math.max(math.ceil(table_view.total_rows / table_page_size(table_view)), 1)
end

local function table_row_range(table_view)
	local row_count = #(table_view and table_view.rows_data or {})
	if row_count == 0 then
		return 0, 0
	end
	local start_row = (table_page_index(table_view) * table_page_size(table_view)) + 1
	return start_row, start_row + row_count - 1
end

local function table_has_previous_page(table_view)
	return table_page_index(table_view) > 0
end

local function table_has_next_page(table_view)
	if type(table_view) ~= "table" then
		return false
	end
	local row_count = #(table_view.rows_data or {})
	if row_count == 0 then
		return false
	end
	local total_pages = table_total_pages(table_view)
	if total_pages ~= nil then
		return table_page_index(table_view) < (total_pages - 1)
	end
	return row_count >= table_page_size(table_view)
end

local function table_controls_line(table_view)
	local total_rows = table_view.total_rows
	local total_rows_label = type(total_rows) == "number" and tostring(total_rows) or "many"
	local start_row, end_row = table_row_range(table_view)
	local total_pages = table_total_pages(table_view)
	local page_label
	if total_pages ~= nil then
		page_label = string.format("page %d/%d", table_page_index(table_view) + 1, total_pages)
	else
		page_label = string.format("page %d", table_page_index(table_view) + 1)
	end
	local prefix
	if type(table_view.namespace) == "string" and table_view.namespace ~= "" then
		prefix = "[ prev ] next { first } last = rows/page"
	else
		prefix = "table preview"
	end
	if start_row == 0 then
		return string.format("%s | rows 0 of %s | page size %d | %s", prefix, total_rows_label, table_page_size(table_view), page_label)
	end
	return string.format(
		"%s | rows %d-%d of %s | page size %d | %s",
		prefix,
		start_row,
		end_row,
		total_rows_label,
		table_page_size(table_view),
		page_label
	)
end

local function request_table_view(source_bufnr, entry, page_index, page_size)
	local table_view = entry and entry.table_view or nil
	if type(table_view) ~= "table" then
		return nil, "current output is not a marimo table"
	end
	if type(table_view.namespace) ~= "string" or table_view.namespace == "" then
		return nil, "current table output does not support paging"
	end
	local filepath = vim.api.nvim_buf_get_name(source_bufnr)
	local session_id = vim.b[source_bufnr].marimo_session_id
	if filepath == "" or type(session_id) ~= "string" or session_id == "" then
		return nil, "marimo session is not available"
	end
	local normalized_page_size = math.max(math.floor(tonumber(page_size) or table_page_size(table_view)), 1)
	local normalized_page_index = math.max(math.floor(tonumber(page_index) or table_page_index(table_view)), 0)
	local total_pages = table_total_pages({
		total_rows = table_view.total_rows,
		page_size = normalized_page_size,
		rows_data = table_view.rows_data,
	})
	if total_pages ~= nil then
		normalized_page_index = math.min(normalized_page_index, total_pages - 1)
	end
	local result, err = worker.request(filepath, "invoke_function", {
		session_id = session_id,
		namespace = table_view.namespace,
		function_name = "search",
		args = {
			page_number = normalized_page_index,
			page_size = normalized_page_size,
		},
	})
	if err then
		return nil, err
	end
	local status = type(result.status) == "table" and result.status or nil
	if status and status.code == "error" then
		return nil, status.message or status.title or "marimo table request failed"
	end
	local return_value = type(result.return_value) == "table" and result.return_value or nil
	if return_value == nil then
		return nil, "marimo table request returned no data"
	end
	local next_view = output.apply_table_search_result(table_view, return_value, normalized_page_index, normalized_page_size)
	if type(next_view) ~= "table" then
		return nil, "failed to parse marimo table page"
	end
	entry.table_view = next_view
	return next_view, nil
end

local function ensure_preferred_table_page(source_bufnr, entry)
	local table_view = entry and entry.table_view or nil
	if type(table_view) ~= "table" then
		return false
	end
	if type(table_view.namespace) ~= "string" or table_view.namespace == "" then
		return false
	end
	local row_count = #(table_view.rows_data or {})
	if type(table_view.total_rows) == "number" and table_view.total_rows <= row_count then
		return false
	end
	local desired_page_size = math.max(table_page_size(table_view), preferred_table_page_size)
	if desired_page_size == table_page_size(table_view) then
		return false
	end
	local _, err = request_table_view(source_bufnr, entry, 0, desired_page_size)
	if err then
		util.notify("failed to load table rows: " .. err, vim.log.levels.WARN)
		return false
	end
	return true
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

cell_display = function(bufnr, cell, entry)
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
	local table_view = output.extract_table_view(runtime.output)
	if type(table_view) == "table" then
		local current_table_view = entry and entry.table_view or nil
		if type(current_table_view) == "table" and current_table_view.namespace == table_view.namespace then
			table_view.page_index = current_table_view.page_index or table_view.page_index
			table_view.page_size = current_table_view.page_size or table_view.page_size
			table_view.total_rows = current_table_view.total_rows or table_view.total_rows
			table_view.rows_data = current_table_view.rows_data or table_view.rows_data
		end
		if entry then
			entry.table_view = table_view
		end
		sections.output = {
			{
				text = table_controls_line(table_view),
				highlight = "Comment",
			},
		}
		for _, line in ipairs(output.table_view_lines(table_view)) do
			table.insert(sections.output, {
				text = line,
				highlight = "String",
			})
		end
	elseif entry then
		entry.table_view = nil
	end
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
		table_view = table_view,
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

local function refresh_table_display(source_bufnr, preserve_view)
	local entry = window_state[source_bufnr]
	if not entry then
		return false
	end
	local cell = find_cell_by_id(source_bufnr, entry.cell_id)
	local display = cell_display(source_bufnr, cell, entry)
	if not display then
		M.close(source_bufnr)
		return false
	end
	return update_entry(source_bufnr, entry, cell, display, preserve_view)
end

local function shift_table_page(source_bufnr, delta)
	local entry = window_state[source_bufnr]
	local table_view = entry and entry.table_view or nil
	if type(table_view) ~= "table" then
		return
	end
	local current_page = table_page_index(table_view)
	local target_page = math.max(current_page + delta, 0)
	if target_page == current_page then
		return
	end
	if delta < 0 and not table_has_previous_page(table_view) then
		return
	end
	if delta > 0 and not table_has_next_page(table_view) then
		return
	end
	local _, err = request_table_view(source_bufnr, entry, target_page, table_page_size(table_view))
	if err then
		util.notify("failed to load table page: " .. err, vim.log.levels.WARN)
		return
	end
	refresh_table_display(source_bufnr, false)
end

local function move_table_to_first_page(source_bufnr)
	local entry = window_state[source_bufnr]
	local table_view = entry and entry.table_view or nil
	if type(table_view) ~= "table" or not table_has_previous_page(table_view) then
		return
	end
	local _, err = request_table_view(source_bufnr, entry, 0, table_page_size(table_view))
	if err then
		util.notify("failed to load table page: " .. err, vim.log.levels.WARN)
		return
	end
	refresh_table_display(source_bufnr, false)
end

local function move_table_to_last_page(source_bufnr)
	local entry = window_state[source_bufnr]
	local table_view = entry and entry.table_view or nil
	if type(table_view) ~= "table" then
		return
	end
	local total_pages = table_total_pages(table_view)
	if total_pages == nil then
		util.notify("table row count is unknown; last page is unavailable", vim.log.levels.WARN)
		return
	end
	local target_page = math.max(total_pages - 1, 0)
	if target_page == table_page_index(table_view) then
		return
	end
	local _, err = request_table_view(source_bufnr, entry, target_page, table_page_size(table_view))
	if err then
		util.notify("failed to load table page: " .. err, vim.log.levels.WARN)
		return
	end
	refresh_table_display(source_bufnr, false)
end

local function prompt_table_page_size(source_bufnr)
	local entry = window_state[source_bufnr]
	local table_view = entry and entry.table_view or nil
	if type(table_view) ~= "table" then
		return
	end
	local response = vim.fn.input("Rows per page: ", tostring(table_page_size(table_view)))
	if response == nil then
		return
	end
	response = vim.trim(tostring(response))
	if response == "" then
		return
	end
	local next_page_size = tonumber(response)
	if next_page_size == nil or next_page_size < 1 then
		util.notify("rows per page must be a positive integer", vim.log.levels.WARN)
		return
	end
	local _, err = request_table_view(source_bufnr, entry, 0, next_page_size)
	if err then
		util.notify("failed to update rows per page: " .. err, vim.log.levels.WARN)
		return
	end
	refresh_table_display(source_bufnr, false)
end

local function bind_window_keys(bufnr, source_bufnr)
	vim.keymap.set("n", "q", function()
		M.close(source_bufnr)
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Marimo: close output" })
	vim.keymap.set("n", "<Esc>", function()
		M.close(source_bufnr)
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Marimo: close output" })
	vim.keymap.set("n", "[", function()
		shift_table_page(source_bufnr, -1)
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Marimo: previous table page" })
	vim.keymap.set("n", "]", function()
		shift_table_page(source_bufnr, 1)
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Marimo: next table page" })
	vim.keymap.set("n", "{", function()
		move_table_to_first_page(source_bufnr)
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Marimo: first table page" })
	vim.keymap.set("n", "}", function()
		move_table_to_last_page(source_bufnr)
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Marimo: last table page" })
	vim.keymap.set("n", "=", function()
		prompt_table_page_size(source_bufnr)
	end, { buffer = bufnr, silent = true, nowait = true, desc = "Marimo: set table page size" })
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
		if entry.cell_id ~= cell.id then
			entry.table_view = nil
		end
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

update_entry = function(source_bufnr, entry, cell, display, preserve_view)
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
	local display = cell_display(bufnr, cell, entry)
	if not display then
		M.close(bufnr)
		return
	end
	if type(entry.table_view) == "table" and ensure_preferred_table_page(bufnr, entry) then
		display = cell_display(bufnr, cell, entry)
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
	local entry = state_for(bufnr)
	if entry.cell_id ~= cell.id then
		entry.table_view = nil
	end
	entry.cell_id = cell.id
	local display = cell_display(bufnr, cell, entry)
	if not display then
		util.notify("current cell has no visible output", vim.log.levels.WARN)
		return false
	end
	entry = ensure_entry(bufnr, cell, vim.api.nvim_get_current_win())
	if type(entry.table_view) == "table" and ensure_preferred_table_page(bufnr, entry) then
		display = cell_display(bufnr, cell, entry)
	end
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
