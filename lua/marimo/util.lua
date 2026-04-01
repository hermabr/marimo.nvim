local M = {}
local next_local_id = 0

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
	vim.schedule(function()
		pcall(vim.cmd, "redraw")
	end)
end

function M.new_local_id()
	next_local_id = next_local_id + 1
	return string.format("marimo-nvim-%d-%d", vim.uv.hrtime(), next_local_id)
end

return M
