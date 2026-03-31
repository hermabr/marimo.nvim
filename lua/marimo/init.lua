local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local util = dofile(dir .. "/util.lua")
local markers = dofile(dir .. "/markers.lua")
local state = dofile(dir .. "/state.lua")
local buffer = dofile(dir .. "/buffer.lua")
local commands = dofile(dir .. "/commands.lua")
local worker = dofile(dir .. "/worker.lua")
local navigation = dofile(dir .. "/navigation.lua")

local M = {}

local group = vim.api.nvim_create_augroup("marimo.nvim", { clear = true })
local setup_opts = {
	keymaps = {
		prev_cell = "[m",
		next_cell = "]m",
		toggle_disabled = "<leader>md",
		show_output = "<leader>mo",
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

local function ensure_sync_autocmd(bufnr)
	if vim.b[bufnr].marimo_sync_hook then
		return
	end
	vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
		group = group,
		buffer = bufnr,
		callback = function(args)
			if vim.b[args.buf].marimo_projected and not vim.b[args.buf].marimo_internal_update then
				buffer.schedule_sync(args.buf, { immediate = args.event == "InsertLeave" })
			end
		end,
	})
	vim.b[bufnr].marimo_sync_hook = true
end

local function ensure_reconcile_autocmd(bufnr)
	if vim.b[bufnr].marimo_reconcile_hook then
		return
	end
	vim.api.nvim_create_autocmd({ "BufEnter", "FileChangedShellPost" }, {
		group = group,
		buffer = bufnr,
		callback = function(args)
			buffer.reconcile_buffer(args.buf, {
				ensure_projected_buffer_setup = ensure_projected_buffer_setup,
			})
		end,
	})
	vim.b[bufnr].marimo_reconcile_hook = true
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
	if keymaps.toggle_disabled then
		vim.keymap.set("n", keymaps.toggle_disabled, function()
			M.toggle_current_cell_disabled(bufnr)
		end, { buffer = bufnr, silent = true, desc = "Marimo: toggle cell disabled" })
	end
	if keymaps.show_output then
		vim.keymap.set("n", keymaps.show_output, function()
			M.open_current_output(bufnr)
		end, { buffer = bufnr, silent = true, desc = "Marimo: show cell output" })
	end

	vim.b[bufnr].marimo_navigation_keymaps = true
end

local function ensure_projected_buffer_setup(bufnr)
	ensure_write_autocmd(bufnr)
	ensure_sync_autocmd(bufnr)
	ensure_reconcile_autocmd(bufnr)
	ensure_navigation_keymaps(bufnr)
end

M.project_buffer = function(bufnr, opts)
	opts = opts or {}
	opts.ensure_projected_buffer_setup = opts.ensure_projected_buffer_setup or ensure_projected_buffer_setup
	return buffer.project_buffer(bufnr, opts)
end

M.write_buffer = buffer.write_buffer
M.sync_buffer = buffer.sync_buffer
M.format_buffer = buffer.format_buffer
M.run_current_cell = buffer.run_current_cell
M.run_all_cells = buffer.run_all_cells
M.toggle_current_cell_disabled = buffer.toggle_current_cell_disabled
M.open_current_output = buffer.open_current_output
M.interrupt = buffer.interrupt

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
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			worker.shutdown_all()
		end,
	})
end

M._private = {
	looks_like_marimo = markers.looks_like_marimo,
	looks_like_projected = markers.looks_like_projected,
	has_any_projected_markers = markers.has_any_projected_markers,
	as_json_object = util.as_json_object,
	promote_first_marker_to_marimo = markers.promote_first_marker_to_marimo,
	normalize_projected_buffer_lines = markers.normalize_projected_buffer_lines,
	render_projected_buffer_lines = markers.render_projected_buffer_lines,
	find_project_root = worker._private.find_project_root,
	find_cell_start_rows = navigation.find_cell_start_rows,
	first_content_row_after_marker = navigation.first_content_row_after_marker,
}

return M
