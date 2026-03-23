local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local util = dofile(dir .. "/util.lua")
local markers = dofile(dir .. "/markers.lua")
local python = dofile(dir .. "/python.lua")
local state = dofile(dir .. "/state.lua")

local M = {}

local function is_file_buffer(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	return name ~= "" and vim.bo[bufnr].buftype == ""
end

function M.reload_raw_buffer(bufnr)
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	if filepath == "" then
		return false, "current buffer has no file path"
	end
	if vim.bo[bufnr].modified then
		return false, "buffer has unsaved changes"
	end

	local raw_lines = vim.fn.readfile(filepath)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, raw_lines)
	state.clear_projected_state(bufnr)
	vim.bo[bufnr].modified = false
	return true
end

function M.project_buffer(bufnr, opts)
	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not state.is_enabled(bufnr) then
		return
	end
	if vim.b[bufnr].marimo_projected then
		util.notify("already projected: " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:."))
		return
	end
	if not is_file_buffer(bufnr) then
		util.notify("current buffer is not a file buffer", vim.log.levels.WARN)
		return
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if not markers.looks_like_marimo(lines) then
		util.notify("no marimo notebook detected in " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:."), vim.log.levels.WARN)
		return
	end

	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local parsed, err = python.run(python.parse_script, {
		content = util.join_lines(lines),
		filepath = filepath,
	})
	if err then
		util.notify("failed to parse marimo notebook: " .. err, vim.log.levels.ERROR)
		return
	end

	local projected_lines = markers.render_projected_lines(parsed)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, projected_lines)
	vim.b[bufnr].marimo_projected = true
	vim.b[bufnr].marimo_header = parsed.header
	vim.b[bufnr].marimo_app_options = util.as_json_object(parsed.app_options or {})
	vim.bo[bufnr].modified = false
	opts.ensure_projected_buffer_setup(bufnr)
end

function M.write_buffer(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not vim.b[bufnr].marimo_projected then
		vim.cmd("write")
		return
	end

	local filepath = vim.api.nvim_buf_get_name(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	if markers.looks_like_marimo(lines) and not markers.looks_like_projected(lines) then
		vim.fn.writefile(lines, filepath)
		vim.bo[bufnr].modified = false
		vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
		util.show_write_message(bufnr)
		return
	end

	local ok, cells_or_err = pcall(markers.parse_projected_cells, lines)
	if not ok then
		util.notify(cells_or_err, vim.log.levels.ERROR)
		return
	end
	cells_or_err = markers.dedupe_empty_cells(cells_or_err)

	local normalized_lines = markers.normalize_projected_buffer_lines(lines)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, normalized_lines)

	local generated, err = python.run(python.generate_script, {
		filepath = filepath,
		header = vim.b[bufnr].marimo_header,
		app_options = util.as_json_object(vim.b[bufnr].marimo_app_options or {}),
		cells = cells_or_err,
	})
	if err then
		util.notify("failed to generate marimo notebook: " .. err, vim.log.levels.ERROR)
		return
	end

	vim.fn.writefile(util.split_lines(generated), filepath)
	vim.bo[bufnr].modified = false
	vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr, modeline = false })
	util.show_write_message(bufnr)
end

function M.activate(bufnr, opts)
	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not state.is_enabled(bufnr) then
		util.notify("marimo mode is disabled for this buffer", vim.log.levels.WARN)
		return
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	if markers.looks_like_marimo(lines) then
		M.project_buffer(bufnr, opts)
		util.echo("activated marimo for " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:."))
		return
	end

	if markers.looks_like_projected(lines) then
		local normalized_lines = markers.normalize_projected_buffer_lines(lines)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, normalized_lines)
		state.mark_projected(bufnr, opts.ensure_projected_buffer_setup)
		util.echo("activated marimo for " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:."))
		return
	end

	if markers.has_any_projected_markers(lines) then
		local ok, promoted_or_err, changed = pcall(markers.promote_first_marker_to_marimo, lines)
		if not ok then
			util.notify(promoted_or_err, vim.log.levels.ERROR)
			return
		end
		if changed then
			local normalized_lines = markers.normalize_projected_buffer_lines(promoted_or_err)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, normalized_lines)
			state.mark_projected(bufnr, opts.ensure_projected_buffer_setup)
			util.echo("activated marimo for " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:."))
			return
		end
	end

	util.notify("buffer is neither a real marimo notebook nor a projected `# +` notebook", vim.log.levels.WARN)
end

function M.set_mode(enabled, opts)
	opts = opts or {}
	local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
	vim.b[bufnr].marimo_mode = enabled

	if enabled then
		M.activate(bufnr, opts)
		return true
	end

	if vim.b[bufnr].marimo_projected then
		return M.reload_raw_buffer(bufnr)
	end

	return true
end

return M
