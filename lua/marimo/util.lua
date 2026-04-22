local M = {}
local next_local_id = 0
local redraw_pending = false

function M.notify(msg, level)
	if vim.g.marimo_shutting_down == true or tonumber(vim.v.exiting) ~= 0 then
		return
	end
	vim.notify("marimo.nvim: " .. msg, level or vim.log.levels.INFO)
end

function M.echo(msg)
	vim.api.nvim_echo({ { "marimo.nvim: " .. msg } }, false, {})
end

function M.show_write_message(bufnr)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local label = filepath ~= "" and vim.fn.fnamemodify(filepath, ":~:.") or "[No Name]"
	local lines = vim.api.nvim_buf_line_count(bufnr)
	vim.api.nvim_echo({ { string.format([["%s" %dL, written]], label, lines) } }, false, {})
end

function M.join_lines(lines)
	return table.concat(lines, "\n")
end

function M.split_lines(text)
	return vim.split(text, "\n", { plain = true })
end

local function display_width_prefix(text, max_width)
	if type(text) ~= "string" or max_width <= 0 then
		return ""
	end
	if vim.fn.strdisplaywidth(text) <= max_width then
		return text
	end
	local out = {}
	local width = 0
	for _, char in ipairs(vim.fn.split(text, [[\zs]])) do
		local char_width = vim.fn.strdisplaywidth(char)
		if width + char_width > max_width then
			break
		end
		table.insert(out, char)
		width = width + char_width
	end
	return table.concat(out, "")
end

function M.truncate_display_text(text, max_width, suffix)
	if type(text) ~= "string" then
		return ""
	end
	max_width = math.floor(tonumber(max_width) or 0)
	if max_width <= 0 then
		return ""
	end
	if vim.fn.strdisplaywidth(text) <= max_width then
		return text
	end
	suffix = type(suffix) == "string" and suffix or "..."
	local suffix_width = vim.fn.strdisplaywidth(suffix)
	if suffix_width >= max_width then
		return display_width_prefix(text, max_width)
	end
	return display_width_prefix(text, max_width - suffix_width) .. suffix
end

function M.as_json_object(tbl)
	if tbl == nil then
		return vim.empty_dict()
	end
	if vim.tbl_isempty(tbl) then
		return vim.empty_dict()
	end
	return tbl
end

function M.request_redraw()
	if redraw_pending then
		return
	end
	redraw_pending = true
	vim.schedule(function()
		redraw_pending = false
		pcall(vim.cmd, "redraw")
	end)
end

function M.new_local_id()
	next_local_id = next_local_id + 1
	return string.format("marimo-nvim-%d-%d", vim.uv.hrtime(), next_local_id)
end

return M
