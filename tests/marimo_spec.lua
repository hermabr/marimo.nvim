local snacks_image_calls = {
	new = {},
	closed = 0,
}

local function reset_snacks_image_calls()
	snacks_image_calls.new = {}
	snacks_image_calls.closed = 0
end

package.preload["snacks.image"] = function()
	return {
		supports_terminal = function()
			return true
		end,
		placement = {
			new = function(bufnr, src, opts)
				local placement = {}
				function placement:close()
					snacks_image_calls.closed = snacks_image_calls.closed + 1
				end
				table.insert(snacks_image_calls.new, {
					bufnr = bufnr,
					src = src,
					opts = vim.deepcopy(opts),
				})
				return placement
			end,
		},
	}
end

local marimo = require("marimo")
local private = marimo._private

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error((message or "assert_eq failed") .. string.format("\nexpected: %s\nactual: %s", vim.inspect(expected), vim.inspect(actual)))
	end
end

local function assert_truthy(value, message)
	if not value then
		error(message or ("expected truthy value, got " .. vim.inspect(value)))
	end
end

local function assert_matches(text, pattern, message)
	if not tostring(text):match(pattern) then
		error((message or "assert_matches failed") .. string.format("\npattern: %s\nactual: %s", pattern, vim.inspect(text)))
	end
end

local rendered_lines
local wait_for_match
local find_output_floating_window
local find_indicator_floating_window

local temp_root = vim.fn.tempname()
vim.fn.mkdir(temp_root, "p")

local function write_file(path, content)
	vim.fn.writefile(vim.split(content, "\n", { plain = true }), path)
end

local function read_file(path)
	return table.concat(vim.fn.readfile(path), "\n")
end

local function edit(path)
	vim.cmd("silent! %bwipeout!")
	vim.cmd("edit " .. vim.fn.fnameescape(path))
end

local function with_cwd(path, fn)
	local previous = vim.fn.getcwd()
	vim.cmd("cd " .. vim.fn.fnameescape(path))
	local ok, result = xpcall(fn, debug.traceback)
	vim.cmd("cd " .. vim.fn.fnameescape(previous))
	if not ok then
		error(result)
	end
	return result
end

local function with_confirm_result(result, fn)
	local original = vim.fn.confirm
	local calls = {}
	vim.fn.confirm = function(message, buttons, default)
		table.insert(calls, {
			message = message,
			buttons = buttons,
			default = default,
		})
		return result
	end
	local ok, value = xpcall(function()
		return fn(calls)
	end, debug.traceback)
	vim.fn.confirm = original
	if not ok then
		error(value)
	end
	return value
end

local function wait_for_truthy(fn, message, timeout)
	local matched = vim.wait(timeout or 5000, fn, 20)
	assert_truthy(matched, message or "timed out waiting for condition")
end

local function make_path(name)
	return temp_root .. "/" .. name
end

local RAW_NOTEBOOK = [[
import marimo

__generated_with = "0.21.1"
app = marimo.App()


@app.cell
def _():
    x = 1
    x
    return


if __name__ == "__main__":
    app.run()
]]

local PROJECTED_NOTEBOOK = [[
# + {marimo}

x = 1
x
]]

local GENERIC_PROJECTED = [[
# +

x = 1
]]

local PLAIN_PYTHON = [[
x = 1

y = x + 1
print(y)
]]

local LEADING_TEXT_WITH_MARKERS = [[
x = 1
y = x + 1

# +

z = y + 1
z

# +

print(z)
]]

local function test_find_project_root_prefers_uv_lock()
	local root = make_path("project")
	local nested = root .. "/nested"
	vim.fn.mkdir(nested, "p")
	write_file(root .. "/pyproject.toml", "[project]\nname='demo'\nversion='0.1.0'")
	write_file(root .. "/uv.lock", "version = 1")
	local notebook = nested .. "/notebook.py"
	write_file(notebook, PROJECTED_NOTEBOOK)
	assert_eq(private.find_project_root(notebook), root)
end

local function test_activate_raw_notebook_projects_and_populates_session_state()
	local path = make_path("raw_notebook.py")
	write_file(path, RAW_NOTEBOOK)
	edit(path)

	assert_eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "# + {marimo}")
	assert_truthy(vim.b.marimo_projected)
	assert_truthy(vim.b.marimo_session_id)
	assert_truthy(vim.b.marimo_projection_map)
	assert_truthy(vim.b.marimo_cells)
	assert_matches(vim.b.marimo_canonical_source, "@app%.cell")
	assert_truthy(vim.b.marimo_projection_map.cells[1].canonical_range.start_line > 0)
end

local function test_activate_projected_notebook_and_write_raw_marimo_file()
	local path = make_path("projected_notebook.py")
	write_file(path, PROJECTED_NOTEBOOK)
	edit(path)

	assert_truthy(not vim.b.marimo_projected)
	vim.cmd("Marimo on")
	assert_eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "# + {marimo}")
	vim.cmd("write")
	wait_for_truthy(function()
		local content = read_file(path)
		return content:match("import marimo") ~= nil and content:match("@app%.cell") ~= nil and content:match("app%.run%(%)") ~= nil
	end, "timed out waiting for projected notebook write")

	local content = read_file(path)
	assert_matches(content, "import marimo")
	assert_matches(content, "@app%.cell")
	assert_matches(content, "app%.run%(%)")
end

local function test_generic_projected_notebook_is_promoted()
	local path = make_path("generic_projected.py")
	write_file(path, GENERIC_PROJECTED)
	edit(path)

	assert_truthy(not vim.b.marimo_projected)
	vim.cmd("Marimo on")
	assert_eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "# + {marimo}")
	assert_truthy(vim.b.marimo_session_id)
end

local function test_manual_activation_wraps_plain_python_in_one_cell()
	local path = make_path("plain_python.py")
	write_file(path, PLAIN_PYTHON)
	edit(path)

	assert_truthy(not vim.b.marimo_projected)
	vim.cmd("Marimo on")
	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	assert_eq(lines[1], "# + {marimo}")
	assert_eq(lines[3], "x = 1")
	assert_matches(table.concat(lines, "\n"), "print%(y%)")
	assert_eq(#vim.b.marimo_cells, 1)
end

local function test_manual_activation_uses_leading_text_as_first_cell_before_markers()
	local path = make_path("leading_text_with_markers.py")
	write_file(path, LEADING_TEXT_WITH_MARKERS)
	edit(path)

	assert_truthy(not vim.b.marimo_projected)
	vim.cmd("Marimo on")

	local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
	assert_eq(lines[1], "# + {marimo}")
	assert_matches(table.concat(lines, "\n"), "x = 1")
	assert_matches(table.concat(lines, "\n"), "z = y %+ 1")
	assert_matches(table.concat(lines, "\n"), "print%(z%)")
	assert_eq(#vim.b.marimo_cells, 3)
	assert_eq(vim.b.marimo_cells[1].code, "x = 1\ny = x + 1")
	assert_eq(vim.b.marimo_cells[2].code, "z = y + 1\nz")
	assert_eq(vim.b.marimo_cells[3].code, "print(z)")
end

local function test_marimo_command_toggles_activation_in_one_step()
	local path = make_path("toggle_plain_python.py")
	write_file(path, PLAIN_PYTHON)
	edit(path)

	assert_truthy(not vim.b.marimo_projected)
	vim.cmd("Marimo")
	assert_truthy(vim.b.marimo_projected)
	assert_eq(#vim.b.marimo_cells, 1)

	vim.cmd("Marimo")
	assert_truthy(not vim.b.marimo_projected)
	assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1], "x = 1")
end

local function test_deactivation_clears_render_extmarks()
	local path = make_path("toggle_extmarks.py")
	write_file(path, PLAIN_PYTHON)
	edit(path)

	vim.cmd("Marimo")
	vim.cmd("MarimoRunAll")
	assert_truthy(vim.b.marimo_projected)

	vim.cmd("Marimo")
	assert_truthy(not vim.b.marimo_projected)
	assert_eq(#vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {}), 0)
end

local function test_runtime_image_outputs_use_snacks_image()
	local path = make_path("runtime_image.py")
	reset_snacks_image_calls()
	write_file(
		path,
		'# + {marimo}\n\nimport marimo as mo\nmo.image(src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn9lD8AAAAASUVORK5CYII=")'
	)
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		return #snacks_image_calls.new > 0
	end, "timed out waiting for runtime image placement")

	local call = snacks_image_calls.new[#snacks_image_calls.new]
	assert_truthy(call.bufnr == 0 or call.bufnr == vim.api.nvim_get_current_buf(), "expected current-buffer placement")
	assert_truthy(call.opts.inline)
	assert_eq(call.opts.pos[1], 4)
	assert_truthy(call.src:match("%.png$") ~= nil, "expected cached png path")
	assert_truthy(vim.fn.filereadable(call.src) == 1, "expected cached image file to exist")
end

local function test_stringified_image_bundle_outputs_use_snacks_image()
	local render = dofile(vim.fn.getcwd() .. "/lua/marimo/render.lua")
	local path = make_path("stringified_image_bundle.py")
	reset_snacks_image_calls()
	write_file(path, "# + {marimo}\n\nx = 1")
	edit(path)

	render.render(0, {
		{
			id = "cell-1",
			projection_range = { start_line = 1, end_line = 3 },
			runtime = {
				output = {
					mimetype = "text/plain",
					data = '{"image/png":"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn9lD8AAAAASUVORK5CYII="}',
				},
				console = {},
			},
		},
	})

	assert_truthy(#snacks_image_calls.new > 0, "expected stringified mimebundle placement to be immediate")
	local call = snacks_image_calls.new[#snacks_image_calls.new]
	assert_truthy(call.src:match("%.png$") ~= nil, "expected cached png path")
	assert_truthy(vim.fn.filereadable(call.src) == 1, "expected cached image file to exist")
end

local function test_console_mimebundle_outputs_render_as_images()
	local render = dofile(vim.fn.getcwd() .. "/lua/marimo/render.lua")
	local path = make_path("console_mimebundle.py")
	reset_snacks_image_calls()
	write_file(path, "# + {marimo}\n\nx = 1")
	edit(path)

	render.render(0, {
		{
			id = "cell-1",
			projection_range = { start_line = 1, end_line = 3 },
			runtime = {
				output = {
					mimetype = "text/plain",
					data = "",
				},
				console = {
					{
						channel = "media",
						mimetype = "application/vnd.marimo+mimebundle",
						data = '{"image/png": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn9lD8AAAAASUVORK5CYII=", "__metadata__": {"image/png": {"width": 543, "height": 413}}}',
					},
				},
			},
		},
	})

	wait_for_truthy(function()
		return #snacks_image_calls.new > 0
	end, "timed out waiting for console mimebundle placement")
	local marks = vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })
	local lines = {}
	for _, mark in ipairs(marks) do
		for _, virt in ipairs((mark[4] or {}).virt_lines or {}) do
			local chunks = {}
			for _, chunk in ipairs(virt) do
				table.insert(chunks, chunk[1])
			end
			table.insert(lines, table.concat(chunks, ""))
		end
	end
	lines = table.concat(lines, "\n")
	assert_truthy(not lines:match("%[widget output%]"), "expected image placeholder, not widget placeholder")
	assert_truthy(not lines:match("application/vnd%.marimo%+mimebundle"), "expected mimebundle sentinel to stay hidden")
end

local function test_marshaled_json_outputs_render_text_and_images()
	local render = dofile(vim.fn.getcwd() .. "/lua/marimo/render.lua")
	local path = make_path("marshaled_json_output.py")
	reset_snacks_image_calls()
	write_file(path, "# + {marimo}\n\nx = 1")
	edit(path)

	local token = "application/vnd.marimo+mimebundle:"
		.. vim.json.encode({
			["image/png"] = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn9lD8AAAAASUVORK5CYII=",
			__metadata__ = { ["image/png"] = { width = 543, height = 413 } },
		})

	render.render(0, {
		{
			id = "cell-1",
			projection_range = { start_line = 1, end_line = 3 },
			runtime = {
				output = {
					mimetype = "application/json",
					data = vim.json.encode({ 1, { token } }),
				},
				console = {},
			},
		},
	})

	wait_for_truthy(function()
		return #snacks_image_calls.new > 0
	end, "timed out waiting for marshaled json placement")
	local marks = vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })
	local lines = {}
	for _, mark in ipairs(marks) do
		for _, virt in ipairs((mark[4] or {}).virt_lines or {}) do
			local chunks = {}
			for _, chunk in ipairs(virt) do
				table.insert(chunks, chunk[1])
			end
			table.insert(lines, table.concat(chunks, ""))
		end
	end
	lines = table.concat(lines, "\n")
	assert_matches(lines, " %[1%]")
	assert_truthy(not lines:match("application/vnd%.marimo%+mimebundle"), "expected mimebundle sentinel to stay hidden")
end

local function test_marshaled_json_float_outputs_render_without_plaintext_sentinels()
	local render = dofile(vim.fn.getcwd() .. "/lua/marimo/render.lua")
	local path = make_path("marshaled_json_float_output.py")
	write_file(path, "# + {marimo}\n\nx = 1")
	edit(path)

	render.render(0, {
		{
			id = "cell-1",
			projection_range = { start_line = 1, end_line = 3 },
			runtime = {
				output = {
					mimetype = "application/json",
					data = vim.json.encode({
						"text/plain+float:0.0",
						"text/plain+float:1.0",
						"text/plain+float:2.5",
					}),
				},
				console = {},
			},
		},
	})

	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, "%[0%.0,1%.0,2%.5%]")
	assert_truthy(not lines:match("text/plain%+float"), "expected float sentinel to stay hidden")
end

local function test_deactivation_clears_runtime_image_placements()
	local path = make_path("runtime_image_cleanup.py")
	reset_snacks_image_calls()
	write_file(
		path,
		'# + {marimo}\n\nimport marimo as mo\nmo.image(src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn9lD8AAAAASUVORK5CYII=")'
	)
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		return #snacks_image_calls.new > 0
	end, "timed out waiting for runtime image placement")

	vim.cmd("Marimo")
	assert_truthy(snacks_image_calls.closed > 0, "expected image placements to close on deactivation")
end

local function test_failed_deactivation_keeps_worker_session_alive()
	local path = make_path("dirty_toggle.py")
	write_file(path, PLAIN_PYTHON)
	edit(path)

	vim.cmd("Marimo")
	assert_truthy(vim.b.marimo_projected)
	assert_eq(vim.b.marimo_mode, true)
	local session_id = vim.b.marimo_session_id

	vim.api.nvim_buf_set_lines(0, -1, -1, false, { "", "extra = 1" })
	assert_truthy(vim.bo.modified)

	vim.cmd("Marimo")
	assert_truthy(vim.b.marimo_projected)
	assert_eq(vim.b.marimo_session_id, session_id)
	assert_eq(vim.b.marimo_mode, true)

	vim.cmd("write")
	wait_for_truthy(function()
		return read_file(path):match("extra = 1") ~= nil
	end, "timed out waiting for dirty projected notebook write")
	local content = read_file(path)
	assert_matches(content, "extra = 1")
end

local function test_manual_activation_rejects_unnamed_buffers()
	vim.cmd("silent! %bwipeout!")
	vim.cmd("enew")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, { "x = 1" })

	vim.cmd("Marimo")
	assert_truthy(not vim.b.marimo_projected)
	assert_eq(vim.b.marimo_session_id, nil)
	assert_eq(vim.b.marimo_mode, nil)
end

local function test_manual_activation_preserves_dirty_state()
	local path = make_path("dirty_activation.py")
	write_file(path, "x = 1")
	edit(path)

	vim.api.nvim_buf_set_lines(0, -1, -1, false, { "", "y = 2" })
	assert_truthy(vim.bo.modified)

	vim.cmd("Marimo")
	assert_truthy(vim.b.marimo_projected)
	assert_truthy(vim.bo.modified)
	assert_matches(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"), "y = 2")
	assert_eq(read_file(path), "x = 1")
end

local function test_normalize_projected_buffer_lines_deletes_empty_cells()
	local normalized = private.normalize_projected_buffer_lines({
		"# + {marimo}",
		"",
		"",
		"# +",
		"",
		"",
		"# +",
		"",
		"x = 1",
		"",
	})

	assert_eq(
		vim.inspect(normalized),
		vim.inspect({
			"# + {marimo}",
			"",
			"",
			"# +",
			"",
			"x = 1",
		})
	)
end

local function test_activation_preserves_existing_projected_layout()
	local path = make_path("preserve_projected_layout.py")
	local lines = {
		"# + {marimo}",
		"",
		"",
		"x = 1",
		"",
		"# +",
		"",
		"",
		"y = 2",
	}
	write_file(path, table.concat(lines, "\n"))
	edit(path)

	vim.cmd("Marimo on")

	assert_eq(vim.inspect(vim.api.nvim_buf_get_lines(0, 0, -1, false)), vim.inspect(lines))
end

local function test_sync_buffer_preserves_existing_projected_layout()
	local path = make_path("sync_preserves_projected_layout.py")
	write_file(path, table.concat({
		"# + {marimo}",
		"",
		"",
		"x = 1",
		"",
		"# +",
		"",
		"",
		"y = x + 1",
	}, "\n"))
	edit(path)

	vim.cmd("Marimo on")
	vim.api.nvim_buf_set_lines(0, 3, 4, false, { "x = 3" })
	require("marimo").sync_buffer(0)

	assert_eq(
		vim.inspect(vim.api.nvim_buf_get_lines(0, 0, -1, false)),
		vim.inspect({
			"# + {marimo}",
			"",
			"",
			"x = 3",
			"",
			"# +",
			"",
			"",
			"y = x + 1",
		})
	)
end

local function test_marimo_format_command_normalizes_projected_layout()
	local path = make_path("format_projected_layout.py")
	write_file(path, table.concat({
		"# + {marimo}",
		"",
		"",
		"x = 1",
		"",
		"# +",
		"",
		"",
		"y = 2",
	}, "\n"))
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoFormat")

	assert_eq(
		vim.inspect(vim.api.nvim_buf_get_lines(0, 0, -1, false)),
		vim.inspect({
			"# + {marimo}",
			"",
			"x = 1",
			"",
			"# +",
			"",
			"y = 2",
		})
	)
end

local function test_navigation_commands_jump_between_cells()
	local path = make_path("navigation.py")
	write_file(path, "# + {marimo}\n\nx = 1\n\n# +\n\ny = 2\n")
	edit(path)

	vim.cmd("Marimo on")
	vim.api.nvim_win_set_cursor(0, { 6, 0 })
	vim.cmd("MarimoCellPrev")
	assert_eq(vim.api.nvim_win_get_cursor(0)[1], 3)

	vim.cmd("MarimoCellNext")
	assert_eq(vim.api.nvim_win_get_cursor(0)[1], 7)
end

local function test_navigation_keymap_callbacks_work()
	local path = make_path("navigation_keymaps.py")
	write_file(path, "# + {marimo}\n\nx = 1\n\n# +\n\ny = 2\n")
	edit(path)

	vim.cmd("Marimo on")

	local prev_map = vim.fn.maparg("[m", "n", false, true)
	local next_map = vim.fn.maparg("]m", "n", false, true)

	vim.api.nvim_win_set_cursor(0, { 6, 0 })
	prev_map.callback()
	assert_eq(vim.api.nvim_win_get_cursor(0)[1], 3)

	next_map.callback()
	assert_eq(vim.api.nvim_win_get_cursor(0)[1], 7)
end

local function test_mode_toggle_keymap_callback_works()
	local path = make_path("mode_toggle_keymap.py")
	write_file(path, PLAIN_PYTHON)
	edit(path)

	vim.cmd("Marimo")
	local toggle_map = vim.fn.maparg("<leader>mm", "n", false, true)
	assert_truthy(type(toggle_map.callback) == "function", "expected <leader>mm callback")
	assert_truthy(vim.b.marimo_projected)
	local indicator_win = find_indicator_floating_window()
	assert_truthy(indicator_win ~= nil, "expected indicator float in default mode")
	local config = vim.api.nvim_win_get_config(indicator_win)
	assert_eq(config.relative, "win")
	assert_eq(config.anchor, "NE")
	assert_truthy(config.border == nil or config.border == "" or config.border == "none", "expected indicator float without a border")
	assert_eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(indicator_win), 0, -1, false)[1], "marimo")

	toggle_map.callback()
	assert_truthy(not vim.b.marimo_projected)
	assert_eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1], "x = 1")
	assert_truthy(find_indicator_floating_window() == nil, "expected indicator float to close")

	toggle_map.callback()
	assert_truthy(vim.b.marimo_projected)
	assert_eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "# + {marimo}")
	indicator_win = find_indicator_floating_window()
	assert_truthy(indicator_win ~= nil, "expected indicator float after reactivation in default mode")
	assert_eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(indicator_win), 0, -1, false)[1], "marimo")
end

local function test_execution_toggle_keymap_callback_works()
	local path = make_path("execution_toggle_keymap.py")
	write_file(path, "# + {marimo}\n\nx = 1\nx")
	edit(path)

	vim.cmd("Marimo on")
	assert_eq(marimo.execution_mode(0), "eager")

	local toggle_map = vim.fn.maparg("<leader>ml", "n", false, true)
	assert_truthy(type(toggle_map.callback) == "function", "expected <leader>ml callback")

	toggle_map.callback()
	assert_eq(marimo.execution_mode(0), "lazy")
	local indicator_win = find_indicator_floating_window()
	assert_truthy(indicator_win ~= nil, "expected indicator float in lazy mode")
	assert_eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(indicator_win), 0, -1, false)[1], "marimo (lazy)")
	local config = vim.api.nvim_win_get_config(indicator_win)
	assert_eq(config.relative, "win")
	assert_eq(config.anchor, "NE")
	assert_truthy(config.border == nil or config.border == "" or config.border == "none", "expected indicator float without a border")

	toggle_map.callback()
	assert_eq(marimo.execution_mode(0), "eager")
	indicator_win = find_indicator_floating_window()
	assert_truthy(indicator_win ~= nil, "expected indicator float in eager mode")
	assert_eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(indicator_win), 0, -1, false)[1], "marimo")
end

local function test_indicator_shows_eager_when_default_is_lazy()
	local path = make_path("indicator_default_lazy.py")
	write_file(path, "# + {marimo}\n\nx = 1\nx")
	edit(path)

	marimo.setup({
		execution = {
			mode = "lazy",
		},
	})
	vim.cmd("Marimo on")
	local indicator_win = find_indicator_floating_window()
	assert_truthy(indicator_win ~= nil, "expected indicator float in lazy default mode")
	assert_eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(indicator_win), 0, -1, false)[1], "marimo")

	vim.cmd("MarimoExecution eager")
	assert_eq(marimo.execution_mode(0), "eager")
	indicator_win = find_indicator_floating_window()
	assert_truthy(indicator_win ~= nil, "expected indicator float after eager override")
	assert_eq(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(indicator_win), 0, -1, false)[1], "marimo (eager)")
	marimo.setup({
		execution = {
			mode = "eager",
		},
	})
end

local function test_run_current_cell_keymap_callback_works()
	local path = make_path("run_current_keymap.py")
	write_file(path, "# + {marimo}\n\nx = 1\nx")
	edit(path)

	vim.cmd("Marimo on")
	vim.api.nvim_buf_set_lines(0, 2, 3, false, { "x = 9" })
	vim.api.nvim_win_set_cursor(0, { 3, 0 })

	local run_map = vim.fn.maparg("<leader>mr", "n", false, true)
	assert_truthy(type(run_map.callback) == "function", "expected <leader>mr callback")
	run_map.callback()

	wait_for_match(" 9")
end

local function test_run_all_cells_keymap_callback_works()
	local path = make_path("run_all_keymap.py")
	write_file(path, "# + {marimo}\n\nx = 1\nx\n\n# +\n\ny = x + 1\ny")
	edit(path)

	vim.cmd("Marimo on")
	local run_map = vim.fn.maparg("<leader>mR", "n", false, true)
	assert_truthy(type(run_map.callback) == "function", "expected <leader>mR callback")
	run_map.callback()

	wait_for_match(" 1")
	wait_for_match(" 2")
end

local function test_restart_command_restarts_kernel_after_confirmation()
	local path = make_path("restart_command.py")
	write_file(path, '# + {marimo}\n\ncounter = globals().get("counter", 40) + 2\ncounter')
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" 42")

	with_confirm_result(1, function(calls)
		vim.cmd("MarimoRestart")
		assert_eq(#calls, 1)
		assert_eq(calls[1].message, "Restart marimo kernel? [Y/n]")
		assert_eq(calls[1].buttons, "&Yes\n&No")
		assert_eq(calls[1].default, 1)
	end)

	wait_for_truthy(function()
		return vim.b.marimo_runtime_enabled == true and next(vim.b.marimo_runtime_cells or {}) == nil
	end, "timed out waiting for marimo kernel restart")

	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return lines:match(" 42") ~= nil and lines:match(" 44") == nil
	end, "timed out waiting for rerun after restart")
end

local function test_restart_keymap_callback_respects_confirmation()
	local path = make_path("restart_keymap.py")
	write_file(path, '# + {marimo}\n\ncounter = globals().get("counter", 40) + 2\ncounter')
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" 42")

	local restart_map = vim.fn.maparg("<leader>mk", "n", false, true)
	assert_truthy(type(restart_map.callback) == "function", "expected <leader>mk callback")

	with_confirm_result(2, function(calls)
		restart_map.callback()
		assert_eq(#calls, 1)
		assert_eq(calls[1].message, "Restart marimo kernel? [Y/n]")
	end)
	assert_truthy(vim.b.marimo_runtime_enabled == true, "expected declined restart to keep runtime enabled")
	assert_truthy(next(vim.b.marimo_runtime_cells or {}) ~= nil, "expected declined restart to keep runtime state")
	wait_for_match(" 42")
end

local function test_format_keymap_callback_works()
	local path = make_path("format_keymap.py")
	write_file(path, table.concat({
		"# + {marimo}",
		"",
		"",
		"x = 1",
		"",
		"# +",
		"",
		"",
		"y = 2",
	}, "\n"))
	edit(path)

	vim.cmd("Marimo on")
	local format_map = vim.fn.maparg("<leader>mf", "n", false, true)
	assert_truthy(type(format_map.callback) == "function", "expected <leader>mf callback")
	format_map.callback()

	assert_eq(
		vim.inspect(vim.api.nvim_buf_get_lines(0, 0, -1, false)),
		vim.inspect({
			"# + {marimo}",
			"",
			"x = 1",
			"",
			"# +",
			"",
			"y = 2",
		})
	)
end

local function test_interrupt_keymap_callback_works()
	local path = make_path("interrupt_keymap.py")
	write_file(path, "# + {marimo}\n\nimport time\ntime.sleep(5)\n1")
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return lines:match("marimo queued") ~= nil or lines:match("marimo running") ~= nil
	end, "timed out waiting for running placeholder")

	local interrupt_map = vim.fn.maparg("<leader>mi", "n", false, true)
	assert_truthy(type(interrupt_map.callback) == "function", "expected <leader>mi callback")
	interrupt_map.callback()

	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return not lines:match("marimo queued") and not lines:match("marimo running")
	end, "timed out waiting for interrupt keymap to clear running state", 5000)
end

local function test_toggle_disabled_keymap_updates_marker_and_runtime_status()
	local path = make_path("toggle_disabled_keymap.py")
	write_file(path, "# + {marimo}\n\nx = 1\nx\n\n# +\n\ny = x + 1\ny")
	edit(path)

	vim.cmd("Marimo on")
	vim.api.nvim_win_set_cursor(0, { 3, 0 })

	local toggle_map = vim.fn.maparg("<leader>md", "n", false, true)
	assert_truthy(type(toggle_map.callback) == "function", "expected <leader>md callback")
	toggle_map.callback()

	wait_for_truthy(function()
		return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "# + {marimo,marimo_disabled}"
	end, "timed out waiting for disabled marker")
	wait_for_match("marimo disabled")

	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, "marimo disabled")
	assert_truthy(not lines:match("marimo stale"), "expected disabled cells to suppress stale label")

	toggle_map.callback()
	wait_for_truthy(function()
		return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "# + {marimo}"
	end, "timed out waiting for enabled marker")
end

local function find_floating_window(predicate)
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		local config = vim.api.nvim_win_get_config(winid)
		if config.relative and config.relative ~= "" then
			local bufnr = vim.api.nvim_win_get_buf(winid)
			if predicate == nil or predicate(winid, bufnr, config) then
				return winid
			end
		end
	end
	return nil
end

find_output_floating_window = function()
	return find_floating_window(function(_, bufnr)
		return vim.b[bufnr].marimo_output_float == true
	end)
end

find_indicator_floating_window = function()
	return find_floating_window(function(_, bufnr)
		return vim.b[bufnr].marimo_indicator_float == true
	end)
end

local function floating_window_title(winid)
	local title = vim.api.nvim_win_get_config(winid).title
	if type(title) == "string" then
		return title
	end
	if type(title) ~= "table" then
		return ""
	end
	local chunks = {}
	for _, chunk in ipairs(title) do
		if type(chunk) == "string" then
			table.insert(chunks, chunk)
		elseif type(chunk) == "table" and chunk[1] ~= nil then
			table.insert(chunks, tostring(chunk[1]))
		end
	end
	return table.concat(chunks, "")
end

local function test_output_keymap_opens_scrollable_float()
	local path = make_path("output_keymap.py")
	write_file(path, '# + {marimo}\n\nprint("\\n".join(str(i) for i in range(80)))')
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" 0")
	wait_for_match("%[output truncated%]")
	vim.api.nvim_win_set_cursor(0, { 3, 0 })

	local output_map = vim.fn.maparg("<leader>mo", "n", false, true)
	assert_truthy(type(output_map.callback) == "function", "expected <leader>mo callback")
	output_map.callback()

	local winid = find_output_floating_window()
	assert_truthy(winid ~= nil, "expected output to open in a floating window")
	local config = vim.api.nvim_win_get_config(winid)
	assert_truthy(config.relative ~= "", "expected output to open in a floating window")

	local float_bufnr = vim.api.nvim_win_get_buf(winid)
	local lines = vim.api.nvim_buf_get_lines(float_bufnr, 0, -1, false)
	assert_truthy(#lines > vim.api.nvim_win_get_height(winid), "expected float output to be scrollable")
	assert_eq(lines[1], "0")
	assert_eq(lines[#lines], "79")
	assert_truthy(not table.concat(lines, "\n"):match("%[output truncated%]"), "expected full output in float")

	vim.api.nvim_set_current_win(winid)
	vim.cmd("normal! G")
	assert_eq(vim.api.nvim_win_get_cursor(winid)[1], #lines)
	vim.cmd("normal! gg")
	assert_eq(vim.api.nvim_win_get_cursor(winid)[1], 1)
end

local function test_marimo_output_command_opens_current_cell_output()
	local path = make_path("output_command.py")
	write_file(path, '# + {marimo}\n\nprint("hello")\n\n# +\n\nprint("goodbye")')
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" hello")
	wait_for_match(" goodbye")

	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	vim.cmd("MarimoOutput")
	local first_win = find_output_floating_window()
	assert_truthy(first_win ~= nil, "expected first output float")
	local first_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(first_win), 0, -1, false)
	assert_eq(first_lines[1], "hello")
	vim.api.nvim_win_close(first_win, true)

	vim.api.nvim_win_set_cursor(0, { 7, 0 })
	vim.cmd("MarimoOutput")
	local second_win = find_output_floating_window()
	assert_truthy(second_win ~= nil, "expected second output float")
	local second_lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(second_win), 0, -1, false)
	assert_eq(second_lines[1], "goodbye")
	vim.api.nvim_win_close(second_win, true)
end

local function test_marimo_output_title_shows_last_runtime()
	local path = make_path("output_runtime_last.py")
	write_file(path, '# + {marimo}\n\nimport time\ntime.sleep(0.2)\nprint("hello")')
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" hello")

	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	vim.cmd("MarimoOutput")
	local winid = find_output_floating_window()
	assert_truthy(winid ~= nil, "expected output float for runtime title test")
	assert_matches(floating_window_title(winid), "took [0-9]", "expected completed runtime in output title")
end

local function test_marimo_output_title_updates_current_runtime_while_running()
	local path = make_path("output_runtime_running.py")
	write_file(path, '# + {marimo}\n\nimport time\ntime.sleep(5.0)\nprint("hello")')
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return lines:match("marimo queued") ~= nil or lines:match("marimo running") ~= nil
	end, "timed out waiting for running cell before opening output")

	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	vim.cmd("MarimoOutput")
	local winid = find_output_floating_window()
	assert_truthy(winid ~= nil, "expected output float for running runtime title test")
	wait_for_truthy(function()
		return floating_window_title(winid):match("runtime [0-9]") ~= nil
	end, "timed out waiting for live runtime in output title")
	local initial_title = floating_window_title(winid)
	wait_for_truthy(function()
		return floating_window_title(winid) ~= initial_title
	end, "timed out waiting for output runtime title to refresh", 1500)

	vim.cmd("MarimoInterrupt")
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return not lines:match("marimo queued") and not lines:match("marimo running")
	end, "timed out waiting for runtime title test interrupt", 5000)
end

local function test_marimo_output_preserves_relative_numbers_and_wraps_lines()
	local path = make_path("output_window_options.py")
	write_file(path, '# + {marimo}\n\nprint("' .. string.rep("wrap-me-", 40) .. '")')
	edit(path)

	vim.wo.number = true
	vim.wo.relativenumber = true

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" wrap%-me%-")
	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	vim.cmd("MarimoOutput")

	local float_win = find_output_floating_window()
	assert_truthy(float_win ~= nil, "expected output float for window option test")
	assert_truthy(vim.wo[float_win].wrap, "expected output float to wrap long lines")
	assert_truthy(vim.wo[float_win].number, "expected output float to keep line numbers")
	assert_truthy(vim.wo[float_win].relativenumber, "expected output float to keep relative line numbers")

	vim.api.nvim_win_close(float_win, true)
end

local function test_marimo_output_renders_images_in_float()
	local path = make_path("output_float_image.py")
	reset_snacks_image_calls()
	write_file(
		path,
		'# + {marimo}\n\nimport marimo as mo\nmo.image(src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn9lD8AAAAASUVORK5CYII=")'
	)
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		return #snacks_image_calls.new > 0
	end, "timed out waiting for inline image placement")

	local initial_calls = #snacks_image_calls.new
	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	vim.cmd("MarimoOutput")
	wait_for_truthy(function()
		return #snacks_image_calls.new > initial_calls
	end, "timed out waiting for float image placement")

	local float_win = find_output_floating_window()
	assert_truthy(float_win ~= nil, "expected image output float")
	local float_bufnr = vim.api.nvim_win_get_buf(float_win)
	local call = snacks_image_calls.new[#snacks_image_calls.new]
	assert_eq(call.bufnr, float_bufnr)
	assert_truthy(call.opts.inline)
	assert_truthy(call.opts.pos[1] >= 1, "expected float image line anchor")

	local lines = vim.api.nvim_buf_get_lines(float_bufnr, 0, -1, false)
	assert_truthy(not table.concat(lines, "\n"):match("%[image/png output%]"), "expected image placeholder to be replaced in float")

	local closed_before = snacks_image_calls.closed
	vim.cmd("q")
	assert_truthy(snacks_image_calls.closed > closed_before, "expected float image placement to close")
end

local function test_marimo_output_table_float_supports_paging_and_rows_per_page()
	local path = make_path("output_float_table.py")
	write_file(
		path,
		[[# + {marimo}

import marimo as mo
rows = [{"value": i} for i in range(1, 151)]
mo.ui.table(rows, pagination=True, page_size=10)
]]
	)
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match("│ value │")
	wait_for_match("│ 1%s+│")
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return not lines:match("marimo queued") and not lines:match("marimo running")
	end, "timed out waiting for table output to settle")

	vim.api.nvim_win_set_cursor(0, { 5, 0 })
	vim.cmd("MarimoOutput")
	local float_win = find_output_floating_window()
	assert_truthy(float_win ~= nil, "expected output float for table paging test")
	vim.api.nvim_set_current_win(float_win)

	local float_bufnr = vim.api.nvim_win_get_buf(float_win)
	wait_for_truthy(function()
		local lines = vim.api.nvim_buf_get_lines(float_bufnr, 0, -1, false)
		return table.concat(lines, "\n"):match("rows 1%-25 of 150") ~= nil
	end, "timed out waiting for expanded table header")
	local lines = vim.api.nvim_buf_get_lines(float_bufnr, 0, -1, false)
	local text = table.concat(lines, "\n")
	assert_matches(text, "rows 1%-25 of 150")
	assert_matches(text, "page size 25")
	assert_matches(text, "│ value │")
	assert_matches(text, "╞")
	assert_matches(text, "│ 25%s+│")
	assert_eq(select(2, text:gsub("│ %.%.%.%s*│", "")), 1, "expected first page to show a bottom ellipsis row")

	local next_map = vim.fn.maparg("]", "n", false, true)
	assert_truthy(type(next_map.callback) == "function", "expected next table page callback")
	next_map.callback()

	lines = vim.api.nvim_buf_get_lines(float_bufnr, 0, -1, false)
	text = table.concat(lines, "\n")
	assert_matches(text, "rows 26%-50 of 150")
	assert_matches(text, "│ 50%s+│")
	assert_eq(select(2, text:gsub("│ %.%.%.%s*│", "")), 2, "expected middle page to show top and bottom ellipsis rows")

	local resize_map = vim.fn.maparg("=", "n", false, true)
	assert_truthy(type(resize_map.callback) == "function", "expected rows per page callback")
	local original_input = vim.fn.input
	vim.fn.input = function()
		return "50"
	end
	resize_map.callback()
	vim.fn.input = original_input

	lines = vim.api.nvim_buf_get_lines(float_bufnr, 0, -1, false)
	text = table.concat(lines, "\n")
	assert_matches(text, "rows 1%-50 of 150")
	assert_matches(text, "page size 50")
	assert_matches(text, "│ 50%s+│")
	assert_eq(select(2, text:gsub("│ %.%.%.%s*│", "")), 1, "expected resized first page to show a bottom ellipsis row")
end

local function test_jump_next_cell_appends_new_cell_and_enters_insert_mode()
	local path = make_path("navigation_append.py")
	write_file(path, "# + {marimo}\n\nx = 1\n")
	edit(path)

	vim.cmd("Marimo on")
	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	local original_cmd = vim.cmd
	local startinsert_called = false
	vim.cmd = function(command)
		if command == "startinsert" then
			startinsert_called = true
			return
		end
		return original_cmd(command)
	end
	vim.cmd("MarimoCellNext")
	vim.cmd = original_cmd

	assert_eq(
		vim.inspect(vim.api.nvim_buf_get_lines(0, 0, -1, false)),
		vim.inspect({
			"# + {marimo}",
			"",
			"x = 1",
			"",
			"# +",
			"",
			"",
		})
	)
	assert_eq(vim.api.nvim_win_get_cursor(0)[1], 7)
	assert_truthy(startinsert_called, "expected ]m at the last cell to request insert mode")
end

rendered_lines = function()
	local marks = vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })
	local lines = {}
	for _, mark in ipairs(marks) do
		local details = mark[4] or {}
		for _, virt in ipairs(details.virt_lines or {}) do
			local chunks = {}
			for _, chunk in ipairs(virt) do
				table.insert(chunks, chunk[1])
			end
			table.insert(lines, table.concat(chunks, ""))
		end
	end
	return lines
end

local function render_extmarks()
	local marks = vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })
	table.sort(marks, function(left, right)
		if left[2] == right[2] then
			return left[1] < right[1]
		end
		return left[2] < right[2]
	end)
	return marks
end

wait_for_match = function(pattern, timeout)
	local matched = vim.wait(timeout or 5000, function()
		return table.concat(rendered_lines(), "\n"):match(pattern) ~= nil
	end, 20)
	assert_truthy(matched, "timed out waiting for pattern: " .. pattern)
end

local function test_render_partial_updates_preserve_unrelated_extmarks()
	local render = dofile(vim.fn.getcwd() .. "/lua/marimo/render.lua")
	local path = make_path("render_partial.py")
	write_file(path, "# + {marimo}\n\nx = 1\n\n# +\n\ny = 2")
	edit(path)
	render.clear(0)

	local cells = {
		{
			id = "cell-1",
			projection_range = { start_line = 1, end_line = 3 },
			runtime = {
				output = { mimetype = "text/plain", data = "1" },
				console = {},
			},
		},
		{
			id = "cell-2",
			projection_range = { start_line = 5, end_line = 7 },
			runtime = {
				output = { mimetype = "text/plain", data = "2" },
				console = {},
			},
		},
	}

	render.render(0, cells)
	local initial_marks = render_extmarks()
	assert_eq(#initial_marks, 2)
	local first_mark = initial_marks[1][1]
	local second_mark = initial_marks[2][1]

	cells[1].runtime.output.data = "7"
	render.render(0, cells, {
		changed_ids = { "cell-1" },
	})

	local updated_marks = render_extmarks()
	assert_eq(#updated_marks, 2)
	assert_truthy(updated_marks[1][1] ~= first_mark, "expected changed cell extmark to be replaced")
	assert_eq(updated_marks[2][1], second_mark)
end

local function test_completed_run_clears_pending_runtime_without_idle_status()
	local runtime = dofile(vim.fn.getcwd() .. "/lua/marimo/runtime.lua")
	local runtime_by_id = {
		["cell-1"] = { status = "queued", console = {} },
		["cell-2"] = { status = "running", console = {}, _running_timestamp = 123 },
		["cell-3"] = { status = "idle", console = {} },
	}

	local next_runtime, changed, changed_ids = runtime.apply_operation(runtime_by_id, {
		op = "completed-run",
	})

	assert_truthy(changed, "expected completed-run to clear pending runtime state")
	assert_eq(next_runtime["cell-1"].status, "idle")
	assert_eq(next_runtime["cell-2"].status, "idle")
	assert_eq(next_runtime["cell-2"]._running_timestamp, nil)
	assert_eq(next_runtime["cell-3"].status, "idle")
	assert_truthy(vim.tbl_contains(changed_ids or {}, "cell-1"))
	assert_truthy(vim.tbl_contains(changed_ids or {}, "cell-2"))
	assert_truthy(not vim.tbl_contains(changed_ids or {}, "cell-3"))
end

local function test_runtime_outputs_render_below_cells()
	local path = make_path("runtime_outputs.py")
	write_file(path, "# + {marimo}\n\nx = 1\nx\n\n# +\n\ny = x + 1\ny")
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" 1")
	wait_for_match(" 2")
	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, " 1")
	assert_matches(lines, " 2")
	assert_truthy(not lines:match("marimo idle"))
end

local function test_write_does_not_block_while_runtime_is_running()
	local path = make_path("nonblocking_write.py")
	write_file(path, "# + {marimo}\n\nimport time\n\n# +\n\ntime.sleep(2)\nx = 1\nx")
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	local started = vim.uv.hrtime()
	vim.cmd("write")
	local elapsed_ms = (vim.uv.hrtime() - started) / 1000000
	assert_truthy(elapsed_ms < 1000, "expected write to return without waiting for the running cell")
	wait_for_truthy(function()
		local content = read_file(path)
		return content:match("import marimo") ~= nil and content:match("@app%.cell") ~= nil
	end, "timed out waiting for async write")
end

local function test_editing_running_cell_and_autosync_do_not_block()
	local path = make_path("nonblocking_edit.py")
	write_file(path, "# + {marimo}\n\nimport time\ntime.sleep(2.0)\nx = 1\nx")
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return lines:match("marimo queued") ~= nil or lines:match("marimo running") ~= nil
	end, "timed out waiting for running placeholder")

	local started = vim.uv.hrtime()
	vim.api.nvim_buf_set_lines(0, 4, 5, false, { "x = 7" })
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0, modeline = false })
	vim.api.nvim_exec_autocmds("InsertLeave", { buffer = 0, modeline = false })
	local elapsed_ms = (vim.uv.hrtime() - started) / 1000000
	assert_truthy(elapsed_ms < 1000, "expected edit autosync to return without waiting for the running cell")

	wait_for_match(" 7", 7000)
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return not lines:match("marimo queued") and not lines:match("marimo running")
	end, "timed out waiting for edited cell run to settle", 7000)
end

local function test_edits_interrupt_run_all_before_lower_cells_finish()
	local path = make_path("interrupts_run_all.py")
	local counter_path = make_path("interrupts_run_all_counter.txt")
	write_file(
		path,
		string.format(
			"# + {marimo}\n\nimport time\ndelay = 2.0\nx = 1\ntime.sleep(delay)\nx\n\n# +\n\ny = x + 1\ny\n\n# +\n\nfrom pathlib import Path\ncounter_path = Path(%q)\ncounter = int(counter_path.read_text()) if counter_path.exists() else 0\ncounter_path.write_text(str(counter + 1))\ncounter + 1",
			counter_path
		)
	)
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return lines:match("marimo queued") ~= nil or lines:match("marimo running") ~= nil
	end, "timed out waiting for run-all placeholder")

	vim.api.nvim_buf_set_lines(0, 3, 5, false, {
		"delay = 0.0",
		"x = 7",
	})
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0, modeline = false })
	vim.api.nvim_exec_autocmds("InsertLeave", { buffer = 0, modeline = false })

	wait_for_truthy(function()
		local cells = vim.b.marimo_cells or {}
		local second_runtime = cells[2] and cells[2].runtime or {}
		return second_runtime.stale_inputs == true or second_runtime.status == "queued"
	end, "timed out waiting for dependent cell to be marked stale or queued during run-all", 1000)

	wait_for_match(" 7", 7000)
	wait_for_match(" 8", 7000)
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return not lines:match("marimo queued") and not lines:match("marimo running")
	end, "timed out waiting for run-all interruption rerun to settle", 7000)

	assert_truthy(
		vim.fn.filereadable(counter_path) == 0,
		"expected lower unrelated run-all work to be cancelled after edit"
	)
end

local function test_run_all_shows_per_cell_running_placeholders()
	local path = make_path("runtime_pending.py")
	write_file(path, "# + {marimo}\n\nx = 1\nx\n\n# +\n\nimport time\ntime.sleep(2.0)\ny = x + 1\ny")
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" 1", 1000)
	local early_lines = table.concat(rendered_lines(), "\n")
	assert_truthy(early_lines:match("marimo queued") or early_lines:match("marimo running"))
	if early_lines:match(" 2") then
		error("expected second cell output to remain pending while its placeholder is visible")
	end
	wait_for_match(" 2", 5000)
end

local function test_new_cell_autorun_streams_runtime_updates()
	local path = make_path("runtime_new_cell.py")
	write_file(path, "# + {marimo}\n\nx = 1\nx")
	edit(path)

	vim.cmd("Marimo on")
	vim.api.nvim_buf_set_lines(0, -1, -1, false, {
		"",
		"# +",
		"",
		"import time",
		"time.sleep(2.0)",
		"y = x + 1",
		"y",
	})
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0, modeline = false })

	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return lines:match("marimo queued") ~= nil or lines:match("marimo running") ~= nil
	end, "timed out waiting for new cell runtime placeholder")
	wait_for_match(" 2", 5000)
end

local function test_opening_without_running_does_not_render_idle_placeholders()
	local path = make_path("runtime_idle_hidden.py")
	write_file(path, "# + {marimo}\n\nx = 1\nx")
	edit(path)

	vim.cmd("Marimo on")
	assert_eq(#rendered_lines(), 0)
end

local function test_sync_buffer_updates_reactive_outputs()
	local path = make_path("runtime_sync.py")
	write_file(path, "# + {marimo}\n\nx = 1\nx\n\n# +\n\ny = x + 1\ny")
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" 1")
	wait_for_match(" 2")
	vim.api.nvim_buf_set_lines(0, 2, 3, false, { "x = 3" })
	require("marimo").sync_buffer(0)
	wait_for_match(" 3")
	wait_for_match(" 4")

	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, " 3")
	assert_matches(lines, " 4")
end

local function test_sync_buffer_does_not_rerun_unrelated_lower_cells()
	local path = make_path("runtime_sync_unrelated.py")
	local counter_path = make_path("runtime_sync_unrelated_counter.txt")
	write_file(
		path,
		string.format(
			"# + {marimo}\n\nn = 2\nn\n\n# +\n\nfrom pathlib import Path\ncounter_path = Path(%q)\ncounter = int(counter_path.read_text()) if counter_path.exists() else 0\ncounter_path.write_text(str(counter + 1))\ncounter + 1",
			counter_path
		)
	)
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		local cells = vim.b.marimo_cells or {}
		return cells[2]
			and cells[2].runtime
			and cells[2].runtime.output
			and cells[2].runtime.output.data ~= nil
	end, "timed out waiting for unrelated cell output")

	local output_before = vim.b.marimo_cells[2].runtime.output.data

	vim.api.nvim_buf_set_lines(0, 2, 3, false, { "n = 3" })
	require("marimo").sync_buffer(0)

	wait_for_match(" 3")
	wait_for_truthy(function()
		local cells = vim.b.marimo_cells or {}
		local second_runtime = cells[2] and cells[2].runtime or {}
		return second_runtime.status ~= "queued"
			and second_runtime.status ~= "running"
	end, "timed out waiting for unrelated sync to settle")

	assert_eq(vim.b.marimo_cells[2].runtime.output.data, output_before)
end

local function test_sync_buffer_skips_rerun_for_comment_only_cell_changes()
	local path = make_path("runtime_sync_comment_only.py")
	local first_counter_path = make_path("runtime_sync_comment_only_first.txt")
	local second_counter_path = make_path("runtime_sync_comment_only_second.txt")
	write_file(
		path,
		string.format(
			"# + {marimo}\n\nfrom pathlib import Path as FirstPath\nfirst_counter_path = FirstPath(%q)\nfirst_counter = int(first_counter_path.read_text()) if first_counter_path.exists() else 0\nfirst_counter_path.write_text(str(first_counter + 1))\nn = 2\nn\n\n# +\n\nfrom pathlib import Path as SecondPath\nsecond_counter_path = SecondPath(%q)\nsecond_counter = int(second_counter_path.read_text()) if second_counter_path.exists() else 0\nsecond_counter_path.write_text(str(second_counter + 1))\ny = n + 1\ny",
			first_counter_path,
			second_counter_path
		)
	)
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" 2")
	wait_for_match(" 3")
	wait_for_truthy(function()
		return read_file(first_counter_path) == "1" and read_file(second_counter_path) == "1"
	end, "timed out waiting for initial counters")

	local extmarks_before = render_extmarks()
	assert_eq(#extmarks_before, 2)

	local target_row = nil
	for idx, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
		if line == "n = 2" then
			target_row = idx - 1
			break
		end
	end
	assert_truthy(target_row ~= nil, "expected to find first cell body")

	vim.api.nvim_buf_set_lines(0, target_row, target_row, false, {
		"# comment-only change",
	})
	require("marimo").sync_buffer(0)
	vim.wait(400, function()
		return false
	end, 20)

	assert_eq(read_file(first_counter_path), "1")
	assert_eq(read_file(second_counter_path), "1")

	local extmarks_after = render_extmarks()
	assert_eq(#extmarks_after, 2)
	assert_eq(extmarks_after[1][2], extmarks_before[1][2] + 1)
	assert_eq(extmarks_after[2][2], extmarks_before[2][2] + 1)

	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, " 2")
	assert_matches(lines, " 3")
	assert_truthy(not lines:match("marimo queued"), "expected comment-only sync to avoid rerun placeholders")
	assert_truthy(not lines:match("marimo running"), "expected comment-only sync to avoid rerun placeholders")
end

local function test_sync_buffer_clears_stale_cell_output_while_rerunning()
	local path = make_path("runtime_sync_clears_stale.py")
	write_file(
		path,
		"# + {marimo}\n\nimport time\ndelay = 0.0\nn = 1\ntime.sleep(delay)\nprint(f\"n={n}\")\nn"
	)
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" 1")
	wait_for_match(" n=1")

	vim.api.nvim_buf_set_lines(0, 3, 5, false, {
		"delay = 2.0",
		"n = 7",
	})
	require("marimo").sync_buffer(0)

	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return lines:match("marimo queued") ~= nil or lines:match("marimo running") ~= nil
	end, "timed out waiting for rerun placeholder")

	local pending_lines = table.concat(rendered_lines(), "\n")
	assert_truthy(not pending_lines:match(" 1"), "expected stale output to clear while rerunning")
	assert_truthy(not pending_lines:match(" n=1"), "expected stale stdout to clear while rerunning")

	wait_for_match(" 7", 7000)
	wait_for_match(" n=7", 7000)

	local final_lines = table.concat(rendered_lines(), "\n")
	assert_truthy(not final_lines:match(" n=1"), "expected old stdout to stay cleared after rerun")
end

local function test_sync_buffer_interrupts_running_changed_cell_and_dependents()
	local path = make_path("runtime_sync_interrupts_dependents.py")
	write_file(
		path,
		"# + {marimo}\n\nimport time\ndelay = 4.0\nx = 1\ntime.sleep(delay)\nx\n\n# +\n\ny = x + 1\ny"
	)
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return lines:match("marimo queued") ~= nil or lines:match("marimo running") ~= nil
	end, "timed out waiting for running placeholder")

	local started = vim.uv.hrtime()
	vim.api.nvim_buf_set_lines(0, 3, 5, false, {
		"delay = 0.0",
		"x = 7",
	})
	require("marimo").sync_buffer(0)
	local elapsed_ms = (vim.uv.hrtime() - started) / 1000000
	assert_truthy(elapsed_ms < 1000, "expected sync_buffer to return without waiting for interruption")

	wait_for_match(" 7", 2000)
	wait_for_match(" 8", 2000)
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return not lines:match("marimo queued") and not lines:match("marimo running")
	end, "timed out waiting for interrupted sync to settle", 2000)
end

local function test_sync_buffer_marks_dependent_cells_stale_or_queued_before_rerun()
	local path = make_path("runtime_sync_marks_dependents.py")
	write_file(
		path,
		"# + {marimo}\n\nimport time\ndelay = 0.0\nx = 1\ntime.sleep(delay)\nx\n\n# +\n\ny = x + 1\ny"
	)
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" 1")
	wait_for_match(" 2")

	vim.api.nvim_buf_set_lines(0, 3, 5, false, {
		"delay = 1.5",
		"x = 7",
	})
	require("marimo").sync_buffer(0)

	wait_for_truthy(function()
		local cells = vim.b.marimo_cells or {}
		local second_runtime = cells[2] and cells[2].runtime or {}
		return second_runtime.stale_inputs == true or second_runtime.status == "queued"
	end, "timed out waiting for dependent cell to be marked stale or queued", 1000)

	wait_for_match(" 8", 7000)
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return not lines:match("marimo queued") and not lines:match("marimo running")
	end, "timed out waiting for dependent rerun to settle", 7000)
end

local function test_sync_buffer_recovers_after_syntax_error()
	local path = make_path("runtime_syntax_recovery.py")
	write_file(path, "# + {marimo}\n\nn = 1\nprint(n)\nn\n\n# +\n\nm = n + 1\nm")
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" 1")
	wait_for_match(" 2")

	vim.api.nvim_buf_set_lines(0, 2, 4, false, {
		"n = 7",
		"print(n",
	})
	require("marimo").sync_buffer(0)

	wait_for_match("was never closed", 7000)
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return not lines:match("marimo queued") and not lines:match("marimo running")
	end, "timed out waiting for syntax error run to settle", 7000)

	vim.api.nvim_buf_set_lines(0, 3, 4, false, { "print(n)" })
	require("marimo").sync_buffer(0)

	wait_for_match(" 7", 7000)
	wait_for_match(" 8", 7000)
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return not lines:match("marimo queued") and not lines:match("marimo running")
	end, "timed out waiting for syntax recovery run to settle", 7000)

	local lines = table.concat(rendered_lines(), "\n")
	assert_truthy(not lines:match("SyntaxError"), "expected syntax error output to clear after fixing code")
	assert_truthy(not lines:match("marimo queued"), "expected queued placeholder to clear after syntax recovery")
	assert_truthy(not lines:match("marimo running"), "expected running placeholder to clear after syntax recovery")
end

local function test_reentering_reprojects_after_raw_reload()
	local path = make_path("reenter_reload.py")
	local other = make_path("reenter_other.py")
	write_file(path, RAW_NOTEBOOK)
	write_file(other, "value = 1")
	edit(path)

	assert_eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "# + {marimo}")
	assert_truthy(vim.b.marimo_projected)
	local session_id = vim.b.marimo_session_id
	local bufnr = vim.api.nvim_get_current_buf()
	local previous_hidden = vim.o.hidden

	vim.o.hidden = true
	vim.fn.writefile(vim.split(RAW_NOTEBOOK, "\n", { plain = true }), path)
	vim.cmd("edit " .. vim.fn.fnameescape(other))
	vim.cmd("buffer " .. bufnr)
	vim.cmd("checktime")
	vim.api.nvim_exec_autocmds("BufEnter", { buffer = bufnr, modeline = false })
	vim.o.hidden = previous_hidden

	assert_eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "# + {marimo}")
	assert_truthy(vim.b.marimo_projected)
	assert_eq(vim.b.marimo_session_id, session_id)
end

local function test_reentering_buffer_does_not_rerun_runtime()
	local path = make_path("reenter_runtime.py")
	local other = make_path("reenter_runtime_other.py")
	write_file(path, "# + {marimo}\n\nimport random\nrandom.random()")
	write_file(other, "value = 1")
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		local runtime_cells = vim.b.marimo_runtime_cells or {}
		for _, runtime in pairs(runtime_cells) do
			if runtime.output and runtime.output.data ~= nil then
				return true
			end
		end
		return false
	end, "timed out waiting for runtime output")

	local session_id = vim.b.marimo_session_id
	local output_before = nil
	for _, runtime in pairs(vim.b.marimo_runtime_cells or {}) do
		if runtime.output and runtime.output.data ~= nil then
			output_before = runtime.output.data
			break
		end
	end
	assert_truthy(output_before ~= nil, "expected runtime output before buffer switch")

	local bufnr = vim.api.nvim_get_current_buf()
	local previous_hidden = vim.o.hidden
	vim.o.hidden = true
	vim.cmd("edit " .. vim.fn.fnameescape(other))
	vim.cmd("buffer " .. bufnr)
	vim.api.nvim_exec_autocmds("BufEnter", { buffer = bufnr, modeline = false })
	vim.o.hidden = previous_hidden

	local output_after = nil
	for _, runtime in pairs(vim.b.marimo_runtime_cells or {}) do
		if runtime.output and runtime.output.data ~= nil then
			output_after = runtime.output.data
			break
		end
	end
	assert_truthy(vim.b.marimo_projected)
	assert_eq(vim.b.marimo_session_id, session_id)
	assert_eq(output_after, output_before)
end

local function test_runtime_outputs_include_stdout()
	local path = make_path("runtime_stdout.py")
	write_file(path, '# + {marimo}\n\nprint("hello")\n1')
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" 1")
	wait_for_match(" hello")
	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, " 1")
	assert_matches(lines, " hello")
	assert_truthy(not lines:match("marimo idle"))
end

local function test_runtime_outputs_include_stdout_after_html_output()
	local path = make_path("runtime_stdout_after_html.py")
	write_file(path, '# + {marimo}\n\nimport marimo as mo\nmo.md("# hello")\n\n# +\n\nprint("HEY")')
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" HEY")
	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, " HEY")
end

local function test_runtime_uses_neovim_cwd_as_launch_cwd()
	local dir = make_path("cwd_runtime")
	local launch_dir = vim.fn.resolve(dir)
	local notebook_dir = vim.fn.resolve(dir .. "/nested")
	vim.fn.mkdir(notebook_dir, "p")
	write_file(notebook_dir .. "/notebook.py", '# + {marimo}\n\nfrom pathlib import Path\nPath(".").resolve()')

	with_cwd(launch_dir, function()
		edit("nested/notebook.py")
		vim.cmd("Marimo on")
		vim.cmd("MarimoRunAll")
		wait_for_match(vim.pesc(launch_dir))

		local lines = table.concat(rendered_lines(), "\n")
		assert_matches(lines, vim.pesc(launch_dir))
		assert_truthy(not lines:match(vim.pesc(notebook_dir)), "expected runtime cwd to follow Neovim cwd, not notebook directory")
	end)
end

local function test_runtime_html_tables_are_summarized_as_text()
	local path = make_path("runtime_html_table.py")
	write_file(
		path,
		[[# + {marimo}

class Thing:
    def _repr_html_(self):
        return """<div><style>
.dataframe > thead > tr,
.dataframe > tbody > tr {
  text-align: right;
  white-space: pre-wrap;
}
</style><small>shape: (7, 1)</small><table border="1" class="dataframe"><thead><tr><th>number</th></tr><tr><td>i64</td></tr></thead><tbody><tr><td>1</td></tr><tr><td>2</td></tr><tr><td>3</td></tr><tr><td>4</td></tr><tr><td>5</td></tr><tr><td>6</td></tr><tr><td>7</td></tr></tbody></table></div>"""

Thing()
]]
	)
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" shape: %(7, 1%)")
	wait_for_match(" number")
	wait_for_match(" i64")
	wait_for_match(" 7")

	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, " shape: %(7, 1%)")
	assert_matches(lines, "│ number │")
	assert_matches(lines, "│ i64%s+│")
	assert_matches(lines, "│ 7%s+│")
	assert_matches(lines, "╞")
	assert_truthy(not lines:match("%.dataframe"), "expected table styles to be removed")
	assert_truthy(not lines:match("%[html output%]"), "expected html table summary instead of placeholder")
end

local function test_runtime_markdown_html_is_summarized_as_text()
	local path = make_path("runtime_markdown_html.py")
	write_file(path, '# + {marimo}\n\nimport marimo as mo\nmo.md("# hello")')
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" hello")

	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, " hello")
	assert_truthy(not lines:match("<span"), "expected markdown html wrapper to be stripped")
	assert_truthy(not lines:match("<h1"), "expected markdown html headings to be stripped")
	assert_truthy(not lines:match("%[html output%]"), "expected markdown html to render as text")
end

local function test_runtime_tracebacks_are_summarized_as_text()
	local render = dofile(vim.fn.getcwd() .. "/lua/marimo/render.lua")
	local path = make_path("runtime_traceback_html.py")
	write_file(path, "# + {marimo}\n\nx = 1")
	edit(path)

	render.render(0, {
		{
			id = "cell-1",
			projection_range = { start_line = 1, end_line = 3 },
			runtime = {
				output = {
					mimetype = "text/plain",
					data = "",
				},
				console = {
					{
						channel = "stderr",
						mimetype = "application/vnd.marimo+traceback",
						data = '<span class="codehilite"><pre>Traceback (most recent call last):\n  File "/tmp/__marimo__cell.py", line 1, in &lt;module&gt;\n    raise ValueError(&quot;boom&quot;)\nValueError: boom\n</pre></span>',
					},
				},
			},
		},
	})

	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, "Traceback %(most recent call last%)")
	assert_matches(lines, 'File "/tmp/__marimo__cell%.py", line 1, in <module>')
	assert_matches(lines, 'raise ValueError%("boom"%)')
	assert_matches(lines, "ValueError: boom")
	assert_truthy(not lines:match("<span"), "expected traceback html wrapper to be stripped")
	assert_truthy(not lines:match("<pre"), "expected traceback pre tag to be stripped")
	assert_truthy(not lines:match("codehilite"), "expected traceback styling class to be stripped")
end

local function test_runtime_marimo_table_html_is_summarized_as_text()
	local render = dofile(vim.fn.getcwd() .. "/lua/marimo/render.lua")
	local path = make_path("runtime_marimo_table.py")
	write_file(path, "# + {marimo}\n\ndf = None")
	edit(path)

	render.render(0, {
		{
			id = "cell-1",
			projection_range = { start_line = 1, end_line = 3 },
			runtime = {
				output = {
					mimetype = "text/html",
					data = "<marimo-ui-element object-id='table-1' random-id='table-2'><marimo-table data-initial-value='[]' data-label='null' data-data='&quot;[{&#92;&quot;number&#92;&quot;:1},{&#92;&quot;number&#92;&quot;:2},{&#92;&quot;number&#92;&quot;:3},{&#92;&quot;number&#92;&quot;:4},{&#92;&quot;number&#92;&quot;:5},{&#92;&quot;number&#92;&quot;:6},{&#92;&quot;number&#92;&quot;:7}]&quot;' data-total-rows='7' data-total-columns='1' data-max-columns='50' data-banner-text='&quot;&quot;' data-pagination='true' data-page-size='10' data-field-types='[[&quot;number&quot;,[&quot;integer&quot;,&quot;i64&quot;]]]' data-show-filters='true' data-show-download='true' data-show-column-summaries='false' data-show-data-types='true' data-show-page-size-selector='true' data-show-column-explorer='true' data-show-chart-builder='false' data-row-headers='[]' data-has-stable-row-id='false' data-lazy='false' data-preload='false' data-download-file-name='&quot;df&quot;'></marimo-table></marimo-ui-element>",
				},
				console = {},
			},
		},
	})

	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, " shape: %(7, 1%)")
	assert_matches(lines, "│ number │")
	assert_matches(lines, "│ i64%s+│")
	assert_matches(lines, "│ 7%s+│")
	assert_matches(lines, "╞")
	assert_truthy(not lines:match("%[html output%]"), "expected marimo table summary instead of placeholder")
	assert_truthy(not lines:match("marimo%-table"), "expected custom element markup to be stripped")
end

local function test_runtime_errors_include_descriptive_stderr_context()
	local path = make_path("runtime_error_details.py")
	write_file(path, "# + {marimo}\n\nimport numpy as np\n= np.array(object=[1, 2, 3])\nx")
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		local runtime_cells = vim.b.marimo_runtime_cells or {}
		for _, runtime in pairs(runtime_cells) do
			if runtime.output and runtime.output.mimetype == "application/vnd.marimo+error" then
				return true
			end
		end
		return false
	end, "timed out waiting for runtime syntax error")
end

local function test_runtime_errors_show_multiple_definition_details()
	local path = make_path("runtime_multiple_defs.py")
	write_file(path, "# + {marimo}\n\nx = 1\n\n# +\n\nx = 2")
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match("defined by another cell")
end

local function test_run_current_cell_command_refreshes_output()
	local path = make_path("runtime_run_current.py")
	write_file(path, "# + {marimo}\n\nx = 1\nx")
	edit(path)

	vim.cmd("Marimo on")
	vim.api.nvim_buf_set_lines(0, 2, 3, false, { "x = 7" })
	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	vim.cmd("MarimoRunCell")
	wait_for_match(" 7")

	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, " 7")
end

local function test_run_current_cell_marks_untouched_cells_stale_on_fresh_runtime()
	local path = make_path("runtime_run_current_stale.py")
	write_file(
		path,
		"# + {marimo}\n\nx = 1\nx\n\n# +\n\ny = x + 1\ny\n\n# +\n\nz = 10\nz"
	)
	edit(path)

	vim.cmd("Marimo on")
	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	vim.cmd("MarimoRunCell")

	wait_for_match(" 1")
	wait_for_truthy(function()
		local cells = vim.b.marimo_cells or {}
		local second_runtime = cells[2] and cells[2].runtime or {}
		local third_runtime = cells[3] and cells[3].runtime or {}
		return second_runtime.stale_inputs == true and third_runtime.stale_inputs == true
	end, "timed out waiting for untouched cells to be marked stale", 1000)

	local stale_count = select(2, table.concat(rendered_lines(), "\n"):gsub("marimo stale", ""))
	assert_eq(stale_count, 2)
end

local function test_run_current_cell_does_not_recreate_unrelated_image_placements()
	local path = make_path("runtime_run_current_image_stability.py")
	reset_snacks_image_calls()
	write_file(
		path,
		'# + {marimo}\n\nimport marimo as mo\nmo.image(src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wn9lD8AAAAASUVORK5CYII=")\n\n# +\n\nimport random\nrandom.random()'
	)
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		if #snacks_image_calls.new == 0 then
			return false
		end
		local cells = vim.b.marimo_cells or {}
		local runtime_cells = vim.b.marimo_runtime_cells or {}
		local target = cells[2] and runtime_cells[cells[2].id] or nil
		return target ~= nil and target.output ~= nil and target.output.data ~= nil
	end, "timed out waiting for image notebook to finish running")

	local target_cell_id = vim.b.marimo_cells[2].id
	local previous_output = tostring(vim.b.marimo_runtime_cells[target_cell_id].output.data)
	local initial_calls = #snacks_image_calls.new
	local initial_closed = snacks_image_calls.closed

	vim.api.nvim_win_set_cursor(0, { 9, 0 })
	vim.cmd("MarimoRunCell")
	wait_for_truthy(function()
		local runtime = (vim.b.marimo_runtime_cells or {})[target_cell_id] or {}
		return runtime.status == "idle" and runtime.output and tostring(runtime.output.data) ~= previous_output
	end, "timed out waiting for targeted rerun")

	assert_eq(#snacks_image_calls.new, initial_calls)
	assert_eq(snacks_image_calls.closed, initial_closed)
end

local function test_interrupt_clears_running_placeholder()
	local path = make_path("runtime_interrupt_render.py")
	write_file(path, "# + {marimo}\n\nimport time\ntime.sleep(5)\n1")
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return lines:match("marimo queued") ~= nil or lines:match("marimo running") ~= nil
	end, "timed out waiting for running placeholder")

	vim.cmd("MarimoInterrupt")
	wait_for_truthy(function()
		local lines = table.concat(rendered_lines(), "\n")
		return not lines:match("marimo queued") and not lines:match("marimo running")
	end, "timed out waiting for interrupt to clear running state", 5000)
end

local function test_lazy_execution_marks_stale_cells_without_autorun()
	local path = make_path("lazy_execution_stale.py")
	local counter_path = make_path("lazy_execution_counter.txt")
	write_file(
		path,
		string.format(
			[[
# + {marimo}

from pathlib import Path
counter_path = Path(%q)
counter = int(counter_path.read_text()) if counter_path.exists() else 0
counter_path.write_text(str(counter + 1))
x = 1
x

# +

y = x + 1
y
]],
			counter_path
		)
	)
	edit(path)

	marimo.setup({
		execution = {
			mode = "lazy",
		},
	})
	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" 1")
	wait_for_match(" 2")
	wait_for_truthy(function()
		return read_file(counter_path) == "1"
	end, "timed out waiting for initial lazy run")

	for idx, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
		if line == "x = 1" then
			vim.api.nvim_buf_set_lines(0, idx - 1, idx, false, { "x = 7" })
			break
		end
	end
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0, modeline = false })

	wait_for_truthy(function()
		local cells = vim.b.marimo_cells or {}
		local first_runtime = cells[1] and cells[1].runtime or {}
		local second_runtime = cells[2] and cells[2].runtime or {}
		return first_runtime.stale_inputs == true and second_runtime.stale_inputs == true
	end, "timed out waiting for lazy stale markers", 2000)

	vim.wait(1000, function()
		return false
	end, 20)

	assert_eq(read_file(counter_path), "1")
	local lines = table.concat(rendered_lines(), "\n")
	local stale_count = select(2, lines:gsub("marimo stale", ""))
	assert_eq(stale_count, 2)
	assert_truthy(not lines:match(" 7"), "expected lazy edit to avoid rerunning changed cell")
	assert_truthy(not lines:match(" 8"), "expected lazy edit to avoid rerunning dependent cell")
end

local function test_lazy_run_current_syncs_deleted_cells_before_execution()
	local path = make_path("lazy_execution_deleted_sync.py")
	write_file(
		path,
		"# + {marimo}\n\nx = 1\nx\n\n# +\n\ny = x + 1\ny\n\n# +\n\nz = y + 1\nz"
	)
	edit(path)

	marimo.setup({
		execution = {
			mode = "lazy",
		},
	})
	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_match(" 1")
	wait_for_match(" 2")
	wait_for_match(" 3")

	vim.api.nvim_buf_set_lines(0, 0, -1, false, {
		"# + {marimo}",
		"",
		"x = 1",
		"x",
		"",
		"# +",
		"",
		"z = y + 1",
		"z",
	})
	vim.api.nvim_exec_autocmds("TextChanged", { buffer = 0, modeline = false })

	wait_for_truthy(function()
		local cells = vim.b.marimo_cells or {}
		local second_runtime = cells[2] and cells[2].runtime or {}
		return second_runtime.stale_inputs == true
	end, "timed out waiting for deleted dependent to become stale", 2000)

	for idx, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
		if line == "z = y + 1" then
			vim.api.nvim_win_set_cursor(0, { idx, 0 })
			break
		end
	end
	vim.cmd("MarimoRunCell")

	wait_for_match("NameError", 7000)
	local lines = table.concat(rendered_lines(), "\n")
	assert_truthy(not lines:match(" 3"), "expected deleted upstream cell to be removed before rerunning")
end

marimo.setup()

local tests = {
	test_find_project_root_prefers_uv_lock,
	test_activate_raw_notebook_projects_and_populates_session_state,
	test_activate_projected_notebook_and_write_raw_marimo_file,
	test_generic_projected_notebook_is_promoted,
	test_manual_activation_wraps_plain_python_in_one_cell,
	test_manual_activation_uses_leading_text_as_first_cell_before_markers,
	test_marimo_command_toggles_activation_in_one_step,
	test_deactivation_clears_render_extmarks,
	test_failed_deactivation_keeps_worker_session_alive,
	test_manual_activation_rejects_unnamed_buffers,
	test_manual_activation_preserves_dirty_state,
	test_normalize_projected_buffer_lines_deletes_empty_cells,
	test_activation_preserves_existing_projected_layout,
	test_sync_buffer_preserves_existing_projected_layout,
	test_marimo_format_command_normalizes_projected_layout,
	test_navigation_commands_jump_between_cells,
	test_navigation_keymap_callbacks_work,
	test_mode_toggle_keymap_callback_works,
	test_execution_toggle_keymap_callback_works,
	test_indicator_shows_eager_when_default_is_lazy,
	test_run_current_cell_keymap_callback_works,
	test_run_all_cells_keymap_callback_works,
	test_restart_command_restarts_kernel_after_confirmation,
	test_restart_keymap_callback_respects_confirmation,
	test_format_keymap_callback_works,
	test_interrupt_keymap_callback_works,
	test_toggle_disabled_keymap_updates_marker_and_runtime_status,
	test_output_keymap_opens_scrollable_float,
	test_marimo_output_command_opens_current_cell_output,
	test_marimo_output_title_shows_last_runtime,
	test_marimo_output_title_updates_current_runtime_while_running,
	test_marimo_output_preserves_relative_numbers_and_wraps_lines,
	test_marimo_output_renders_images_in_float,
	test_marimo_output_table_float_supports_paging_and_rows_per_page,
	test_jump_next_cell_appends_new_cell_and_enters_insert_mode,
	test_render_partial_updates_preserve_unrelated_extmarks,
	test_completed_run_clears_pending_runtime_without_idle_status,
	test_runtime_outputs_render_below_cells,
	test_runtime_image_outputs_use_snacks_image,
	test_stringified_image_bundle_outputs_use_snacks_image,
	test_console_mimebundle_outputs_render_as_images,
	test_marshaled_json_outputs_render_text_and_images,
	test_marshaled_json_float_outputs_render_without_plaintext_sentinels,
	test_write_does_not_block_while_runtime_is_running,
	test_editing_running_cell_and_autosync_do_not_block,
	test_edits_interrupt_run_all_before_lower_cells_finish,
	test_run_all_shows_per_cell_running_placeholders,
	test_new_cell_autorun_streams_runtime_updates,
	test_opening_without_running_does_not_render_idle_placeholders,
	test_sync_buffer_updates_reactive_outputs,
	test_sync_buffer_does_not_rerun_unrelated_lower_cells,
	test_sync_buffer_skips_rerun_for_comment_only_cell_changes,
	test_sync_buffer_clears_stale_cell_output_while_rerunning,
	test_sync_buffer_interrupts_running_changed_cell_and_dependents,
	test_sync_buffer_marks_dependent_cells_stale_or_queued_before_rerun,
	test_sync_buffer_recovers_after_syntax_error,
	test_reentering_reprojects_after_raw_reload,
	test_reentering_buffer_does_not_rerun_runtime,
	test_runtime_outputs_include_stdout,
	test_runtime_outputs_include_stdout_after_html_output,
	test_runtime_uses_neovim_cwd_as_launch_cwd,
	test_runtime_html_tables_are_summarized_as_text,
	test_runtime_markdown_html_is_summarized_as_text,
	test_runtime_tracebacks_are_summarized_as_text,
	test_runtime_marimo_table_html_is_summarized_as_text,
	test_runtime_errors_include_descriptive_stderr_context,
	test_runtime_errors_show_multiple_definition_details,
	test_run_current_cell_command_refreshes_output,
	test_run_current_cell_marks_untouched_cells_stale_on_fresh_runtime,
	test_run_current_cell_does_not_recreate_unrelated_image_placements,
	test_deactivation_clears_runtime_image_placements,
	test_interrupt_clears_running_placeholder,
	test_lazy_execution_marks_stale_cells_without_autorun,
	test_lazy_run_current_syncs_deleted_cells_before_execution,
}

for _, test in ipairs(tests) do
	test()
end

print(string.format("marimo_spec: %d tests passed", #tests))
