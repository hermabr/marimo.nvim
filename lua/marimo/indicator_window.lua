local M = {}

local window_state = {}

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

local function close_entry(source_winid)
	local entry = window_state[source_winid]
	if not entry then
		return
	end
	window_state[source_winid] = nil
	close_window(entry.float_winid)
	close_buffer(entry.float_bufnr)
end

local function truncate_label(label, max_width)
	if type(label) ~= "string" then
		return ""
	end
	if max_width <= 0 then
		return ""
	end
	if vim.fn.strdisplaywidth(label) <= max_width then
		return label
	end
	if max_width <= 3 then
		return label:sub(1, max_width)
	end
	local out = {}
	local width = 0
	for _, char in ipairs(vim.fn.split(label, [[\zs]])) do
		local char_width = vim.fn.strdisplaywidth(char)
		if width + char_width > max_width - 3 then
			break
		end
		table.insert(out, char)
		width = width + char_width
	end
	table.insert(out, "...")
	return table.concat(out, "")
end

local function configure_buffer(bufnr)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].filetype = "marimo-indicator"
	vim.b[bufnr].marimo_indicator_float = true
end

local function configure_window(winid)
	vim.wo[winid].wrap = false
	vim.wo[winid].cursorline = false
	vim.wo[winid].number = false
	vim.wo[winid].relativenumber = false
	vim.wo[winid].signcolumn = "no"
	vim.wo[winid].foldcolumn = "0"
	vim.wo[winid].spell = false
	pcall(function()
		vim.wo[winid].winfixbuf = true
	end)
	pcall(function()
		vim.wo[winid].winhl = "Normal:NormalFloat"
	end)
end

local function indicator_config(source_winid, label)
	local source_width = math.max(vim.api.nvim_win_get_width(source_winid), 1)
	local display_label = truncate_label(label, source_width)
	local width = math.max(vim.fn.strdisplaywidth(display_label), 1)
	return display_label, {
		relative = "win",
		win = source_winid,
		anchor = "NE",
		row = 0,
		col = source_width,
		width = width,
		height = 1,
		style = "minimal",
		focusable = false,
		noautocmd = true,
		zindex = 50,
	}
end

local function ensure_entry(source_winid, source_bufnr, label)
	local entry = window_state[source_winid] or {}
	window_state[source_winid] = entry
	entry.source_bufnr = source_bufnr

	local display_label, config = indicator_config(source_winid, label)
	if not entry.float_bufnr or not vim.api.nvim_buf_is_valid(entry.float_bufnr) then
		entry.float_bufnr = vim.api.nvim_create_buf(false, true)
		configure_buffer(entry.float_bufnr)
	end
	if not entry.float_winid or not vim.api.nvim_win_is_valid(entry.float_winid) then
		entry.float_winid = vim.api.nvim_open_win(entry.float_bufnr, false, config)
		configure_window(entry.float_winid)
	else
		local updated_config = vim.deepcopy(config)
		updated_config.noautocmd = nil
		vim.api.nvim_win_set_config(entry.float_winid, updated_config)
	end

	if entry.label ~= display_label then
		vim.bo[entry.float_bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(entry.float_bufnr, 0, -1, false, { display_label })
		vim.bo[entry.float_bufnr].modifiable = false
		vim.bo[entry.float_bufnr].modified = false
		entry.label = display_label
	end

	configure_window(entry.float_winid)
end

function M.refresh_buffer(bufnr, label_fn)
	local label = label_fn(bufnr)
	local visible_windows = {}
	for _, source_winid in ipairs(vim.fn.win_findbuf(bufnr)) do
		visible_windows[source_winid] = true
		if label == nil or label == "" then
			close_entry(source_winid)
		else
			ensure_entry(source_winid, bufnr, label)
		end
	end
	for source_winid, entry in pairs(window_state) do
		if entry.source_bufnr == bufnr and not visible_windows[source_winid] then
			close_entry(source_winid)
		end
	end
end

function M.reconcile(label_fn)
	for source_winid, entry in pairs(vim.deepcopy(window_state)) do
		if not vim.api.nvim_win_is_valid(source_winid) then
			close_entry(source_winid)
		else
			local bufnr = vim.api.nvim_win_get_buf(source_winid)
			local label = label_fn(bufnr)
			if label == nil or label == "" then
				close_entry(source_winid)
			else
				ensure_entry(source_winid, bufnr, label)
			end
		end
	end
end

function M.close_buffer(bufnr)
	if bufnr == nil or bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end
	for source_winid, entry in pairs(vim.deepcopy(window_state)) do
		if entry.source_bufnr == bufnr then
			close_entry(source_winid)
		end
	end
end

return M
