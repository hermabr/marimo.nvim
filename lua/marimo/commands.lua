local source = debug.getinfo(1, "S").source:sub(2)
local dir = vim.fn.fnamemodify(source, ":h")
local util = dofile(dir .. "/util.lua")
local markers = dofile(dir .. "/markers.lua")
local state = dofile(dir .. "/state.lua")

local M = {}

function M.setup(opts)
	local group = opts.group
	local api = opts.api

	vim.api.nvim_create_autocmd("BufReadPost", {
		group = group,
		pattern = "*.py",
		callback = function(args)
			if not state.is_enabled(args.buf) then
				return
			end
			local lines = vim.api.nvim_buf_get_lines(args.buf, 0, -1, false)
			if markers.looks_like_marimo(lines) then
				api.project_buffer(args.buf, { ensure_write_autocmd = opts.ensure_write_autocmd })
				util.echo("activated marimo for " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(args.buf), ":~:."))
			end
		end,
	})

	vim.api.nvim_create_user_command("Marimo", function(command_opts)
		local arg = vim.trim(command_opts.args)
		local enabled = nil
		if arg == "on" then
			enabled = true
		elseif arg == "off" then
			enabled = false
		elseif arg == "" or arg == "toggle" then
			if vim.b.marimo_projected then
				enabled = false
			else
				enabled = true
			end
		else
			util.notify("usage: MarimoMode [on|off|toggle]", vim.log.levels.ERROR)
			return
		end

		local ok, err = api.set_mode(enabled, {
			bufnr = 0,
			ensure_write_autocmd = opts.ensure_write_autocmd,
			manual = true,
		})
		if not ok then
			util.notify(err, vim.log.levels.WARN)
			return
		end

		util.echo(string.format("marimo mode %s for this buffer", enabled and "enabled" or "disabled"))
	end, {
		nargs = "?",
		complete = function()
			return { "on", "off", "toggle" }
		end,
	})
end

return M
