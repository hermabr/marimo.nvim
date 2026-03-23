local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local util = dofile(dir .. "/util.lua")
local markers = dofile(dir .. "/markers.lua")
local state = dofile(dir .. "/state.lua")
local buffer = dofile(dir .. "/buffer.lua")
local commands = dofile(dir .. "/commands.lua")
local worker = dofile(dir .. "/worker.lua")

local M = {}

local group = vim.api.nvim_create_augroup("marimo.nvim", { clear = true })

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
			if vim.b[args.buf].marimo_projected then
				M.sync_buffer(args.buf)
			end
		end,
	})
	vim.b[bufnr].marimo_sync_hook = true
end

M.project_buffer = function(bufnr, opts)
	opts = opts or {}
	opts.ensure_write_autocmd = opts.ensure_write_autocmd or ensure_write_autocmd
	opts.ensure_sync_autocmd = opts.ensure_sync_autocmd or ensure_sync_autocmd
	return buffer.project_buffer(bufnr, opts)
end

M.write_buffer = buffer.write_buffer
M.sync_buffer = buffer.sync_buffer

M.mark_projected = function(bufnr)
	return state.mark_projected(bufnr, ensure_write_autocmd)
end

M.activate = function(bufnr, opts)
	opts = opts or {}
	opts.ensure_write_autocmd = opts.ensure_write_autocmd or ensure_write_autocmd
	opts.ensure_sync_autocmd = opts.ensure_sync_autocmd or ensure_sync_autocmd
	return buffer.activate(bufnr, opts)
end

M.set_mode = function(enabled, opts)
	opts = opts or {}
	opts.ensure_write_autocmd = opts.ensure_write_autocmd or ensure_write_autocmd
	opts.ensure_sync_autocmd = opts.ensure_sync_autocmd or ensure_sync_autocmd
	return buffer.set_mode(enabled, opts)
end

function M.setup()
	commands.setup({
		group = group,
		api = M,
		ensure_write_autocmd = ensure_write_autocmd,
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
	find_project_root = worker._private.find_project_root,
}

return M
