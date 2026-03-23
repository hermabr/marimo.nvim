local M = {}

function M.notify(msg, level)
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

return M
