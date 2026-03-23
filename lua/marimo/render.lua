local M = {}

local namespace = vim.api.nvim_create_namespace("marimo.nvim.cells")

function M.render(bufnr, cells)
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
	for _, cell in ipairs(cells or {}) do
		local line = math.max((cell.projection_range or {}).start_line or 1, 1) - 1
		local status = cell.editor_status or "clean"
		local virt = string.format(" marimo:%s ", status)
		vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
			virt_text = { { virt, "Comment" } },
			virt_text_pos = "eol",
		})
	end
end

return M
