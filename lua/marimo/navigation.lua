local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local markers = dofile(dir .. "/markers.lua")
local util = dofile(dir .. "/util.lua")

local M = {}

function M.find_cell_start_rows(lines)
	local rows = {}
	for idx, line in ipairs(lines) do
		local is_marker = markers.parse_marker_line(line)
		if is_marker then
			table.insert(rows, idx)
		end
	end
	return rows
end

function M.first_content_row_after_marker(lines, marker_row)
	local row = marker_row + 1
	while row <= #lines do
		local line = lines[row]
		local is_marker = markers.parse_marker_line(line)
		if is_marker then
			break
		end
		if not line:match("^%s*$") then
			return row
		end
		row = row + 1
	end
	return math.min(marker_row + 1, math.max(#lines, 1))
end

local function restore_view(bufnr, view, replacement)
	if replacement then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, replacement)
	end
	if bufnr == vim.api.nvim_get_current_buf() then
		pcall(vim.fn.winrestview, view)
	end
end

function M.normalize_buffer(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not markers.has_any_projected_markers(lines) then
		return false
	end

	local ok, normalized_or_err = pcall(markers.normalize_projected_buffer_lines, lines)
	if not ok then
		return false, normalized_or_err
	end

	local replacement = nil
	if vim.deep_equal(lines, normalized_or_err) then
		replacement = nil
	else
		replacement = normalized_or_err
	end

	local view = nil
	if bufnr == vim.api.nvim_get_current_buf() then
		view = vim.fn.winsaveview()
	end
	restore_view(bufnr, view, replacement)
	return true, normalized_or_err
end

local function append_empty_cell(bufnr)
	local ok, normalized_or_err = M.normalize_buffer(bufnr)
	if not ok and normalized_or_err then
		return nil, normalized_or_err
	end

	local lines = normalized_or_err or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local appended = vim.deepcopy(lines)
	if #appended > 0 and appended[#appended] ~= "" then
		table.insert(appended, "")
	end
	vim.list_extend(appended, { "# +", "", "" })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, appended)
	return appended
end

function M.jump_prev_cell(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local ok, normalized_or_err = M.normalize_buffer(bufnr)
	if not ok and normalized_or_err then
		util.notify(normalized_or_err, vim.log.levels.WARN)
		return
	end

	local lines = normalized_or_err or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local starts = M.find_cell_start_rows(lines)
	if #starts == 0 then
		return
	end

	local row = vim.api.nvim_win_get_cursor(0)[1]
	local current_idx = 1
	for idx, start_row in ipairs(starts) do
		if start_row <= row then
			current_idx = idx
		else
			break
		end
	end

	local target_row
	if current_idx > 1 then
		target_row = M.first_content_row_after_marker(lines, starts[current_idx - 1])
	else
		target_row = M.first_content_row_after_marker(lines, starts[1])
	end

	vim.api.nvim_win_set_cursor(0, { target_row, 0 })
	vim.cmd("normal! zz")
	vim.cmd("nohlsearch")
end

function M.jump_next_cell(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local ok, normalized_or_err = M.normalize_buffer(bufnr)
	if not ok and normalized_or_err then
		util.notify(normalized_or_err, vim.log.levels.WARN)
		return
	end

	local lines = normalized_or_err or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local starts = M.find_cell_start_rows(lines)
	if #starts == 0 then
		return
	end

	local row = vim.api.nvim_win_get_cursor(0)[1]
	for idx, start_row in ipairs(starts) do
		if start_row > row then
			vim.api.nvim_win_set_cursor(0, { M.first_content_row_after_marker(lines, start_row), 0 })
			vim.cmd("normal! zz")
			vim.cmd("nohlsearch")
			return
		end
		if start_row == row and idx < #starts then
			vim.api.nvim_win_set_cursor(0, { M.first_content_row_after_marker(lines, starts[idx + 1]), 0 })
			vim.cmd("normal! zz")
			vim.cmd("nohlsearch")
			return
		end
	end

	local appended_lines, err = append_empty_cell(bufnr)
	if not appended_lines then
		util.notify(err, vim.log.levels.WARN)
		return
	end

	local appended_starts = M.find_cell_start_rows(appended_lines)
	local target_marker = appended_starts[#appended_starts]
	local target_row = math.min(target_marker + 2, vim.api.nvim_buf_line_count(bufnr))
	vim.api.nvim_win_set_cursor(0, { target_row, 0 })
	vim.cmd("normal! zz")
	vim.cmd("nohlsearch")
	vim.cmd("startinsert")
end

return M
