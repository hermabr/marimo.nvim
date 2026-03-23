local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local util = dofile(dir .. "/util.lua")
local markers = dofile(dir .. "/markers.lua")
local state = dofile(dir .. "/state.lua")
local buffer = dofile(dir .. "/buffer.lua")
local commands = dofile(dir .. "/commands.lua")
local navigation = dofile(dir .. "/navigation.lua")

local M = {}

local group = vim.api.nvim_create_augroup("marimo.nvim", { clear = true })
local setup_opts = {
	keymaps = {
		prev_cell = "[m",
		next_cell = "]m",
	},
}

local function ensure_write_autocmd(bufnr)
	if vim.b[bufnr].marimo_write_hook then
		return
	end
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = bufnr,
		callback = function(args)
			M.write_buffer(args.buf)
		end,
	})
	vim.b[bufnr].marimo_write_hook = true
end

local function ensure_navigation_keymaps(bufnr)
	if vim.b[bufnr].marimo_navigation_keymaps then
		return
	end

	local keymaps = setup_opts.keymaps or {}
	if keymaps.prev_cell then
		vim.keymap.set("n", keymaps.prev_cell, function()
			M.jump_prev_cell(bufnr)
		end, { buffer = bufnr, silent = true, desc = "Marimo: previous cell" })
	end
	if keymaps.next_cell then
		vim.keymap.set("n", keymaps.next_cell, function()
			M.jump_next_cell(bufnr)
		end, { buffer = bufnr, silent = true, desc = "Marimo: next cell" })
	end

	vim.b[bufnr].marimo_navigation_keymaps = true
end

local function ensure_projected_buffer_setup(bufnr)
	ensure_write_autocmd(bufnr)
	ensure_navigation_keymaps(bufnr)
end

M.project_buffer = function(bufnr, opts)
	opts = opts or {}
	opts.ensure_projected_buffer_setup = opts.ensure_projected_buffer_setup or ensure_projected_buffer_setup
	return buffer.project_buffer(bufnr, opts)
end

M.write_buffer = buffer.write_buffer

M.mark_projected = function(bufnr)
	return state.mark_projected(bufnr, ensure_projected_buffer_setup)
end

M.activate = function(bufnr, opts)
	opts = opts or {}
	opts.ensure_projected_buffer_setup = opts.ensure_projected_buffer_setup or ensure_projected_buffer_setup
	return buffer.activate(bufnr, opts)
end

M.set_mode = function(enabled, opts)
	opts = opts or {}
	opts.ensure_projected_buffer_setup = opts.ensure_projected_buffer_setup or ensure_projected_buffer_setup
	return buffer.set_mode(enabled, opts)
end

M.normalize_buffer = navigation.normalize_buffer
M.jump_prev_cell = navigation.jump_prev_cell
M.jump_next_cell = navigation.jump_next_cell

function M.setup(opts)
	opts = opts or {}
	setup_opts = vim.tbl_deep_extend("force", setup_opts, opts)
	commands.setup({
		group = group,
		api = M,
		ensure_projected_buffer_setup = ensure_projected_buffer_setup,
	})
end

M._private = {
	looks_like_marimo = markers.looks_like_marimo,
	looks_like_projected = markers.looks_like_projected,
	has_any_projected_markers = markers.has_any_projected_markers,
	parse_marker_line = markers.parse_marker_line,
	parse_options_text = markers.parse_options_text,
	parse_projected_cells = markers.parse_projected_cells,
	dedupe_empty_cells = markers.dedupe_empty_cells,
	as_json_object = util.as_json_object,
	render_projected_lines = markers.render_projected_lines,
	normalize_projected_buffer_lines = markers.normalize_projected_buffer_lines,
	promote_first_marker_to_marimo = markers.promote_first_marker_to_marimo,
	find_cell_start_rows = navigation.find_cell_start_rows,
	first_content_row_after_marker = navigation.first_content_row_after_marker,
}

return M
