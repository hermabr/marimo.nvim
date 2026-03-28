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
				api.project_buffer(args.buf, { ensure_projected_buffer_setup = opts.ensure_projected_buffer_setup })
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
			manual = true,
			ensure_projected_buffer_setup = opts.ensure_projected_buffer_setup,
		})
		if not ok then
			util.notify(err, vim.log.levels.WARN)
			return
		end

		util.notify(string.format("marimo %s", enabled and "enabled" or "disabled"))
	end, {
		nargs = "?",
		complete = function()
			return { "on", "off", "toggle" }
		end,
	})

	vim.api.nvim_create_user_command("MarimoCellPrev", function()
		api.jump_prev_cell(0)
	end, {})

	vim.api.nvim_create_user_command("MarimoCellNext", function()
		api.jump_next_cell(0)
	end, {})

	vim.api.nvim_create_user_command("MarimoRunCell", function()
		api.run_current_cell(0)
	end, {})

	vim.api.nvim_create_user_command("MarimoRunAll", function()
		api.run_all_cells(0)
	end, {})

	vim.api.nvim_create_user_command("MarimoOutput", function()
		api.open_current_output(0)
	end, {})

	vim.api.nvim_create_user_command("MarimoInterrupt", function()
		api.interrupt(0)
	end, {})

	vim.api.nvim_create_user_command("MarimoFormat", function()
		local ok, err = api.format_buffer(0)
		if not ok and err then
			util.notify(err, vim.log.levels.WARN)
		end
	end, {})
end

return M
