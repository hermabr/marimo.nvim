local M = {}

local function mirror_path(bufnr)
	local cache_dir = vim.fn.stdpath("cache") .. "/marimo.nvim/mirror"
	vim.fn.mkdir(cache_dir, "p")
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local hash = vim.fn.sha256(filepath)
	return cache_dir .. "/" .. hash .. ".py"
end

function M.sync_mirror(bufnr, canonical_source)
	if not canonical_source or canonical_source == "" then
		return nil
	end
	local path = mirror_path(bufnr)
	vim.fn.writefile(vim.split(canonical_source, "\n", { plain = true }), path)
	vim.b[bufnr].marimo_mirror_path = path
	return path
end

return M
