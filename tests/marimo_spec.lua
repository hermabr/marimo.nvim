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

	assert_truthy(#snacks_image_calls.new > 0, "expected image placement for stringified mimebundle")
	local call = snacks_image_calls.new[#snacks_image_calls.new]
	assert_truthy(call.src:match("%.png$") ~= nil, "expected cached png path")
	assert_truthy(vim.fn.filereadable(call.src) == 1, "expected cached image file to exist")
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
	local session_id = vim.b.marimo_session_id

	vim.api.nvim_buf_set_lines(0, -1, -1, false, { "", "extra = 1" })
	assert_truthy(vim.bo.modified)

	vim.cmd("Marimo")
	assert_truthy(vim.b.marimo_projected)
	assert_eq(vim.b.marimo_session_id, session_id)

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

local function rendered_lines()
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

local function wait_for_match(pattern, timeout)
	local matched = vim.wait(timeout or 5000, function()
		return table.concat(rendered_lines(), "\n"):match(pattern) ~= nil
	end, 20)
	assert_truthy(matched, "timed out waiting for pattern: " .. pattern)
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
	vim.api.nvim_buf_set_lines(0, 2, 3, false, { "x = 3" })
	require("marimo").sync_buffer(0)

	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, " 3")
	assert_matches(lines, " 4")
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
	test_navigation_commands_jump_between_cells,
	test_navigation_keymap_callbacks_work,
	test_jump_next_cell_appends_new_cell_and_enters_insert_mode,
	test_runtime_outputs_render_below_cells,
	test_runtime_image_outputs_use_snacks_image,
	test_stringified_image_bundle_outputs_use_snacks_image,
	test_write_does_not_block_while_runtime_is_running,
	test_run_all_shows_per_cell_running_placeholders,
	test_new_cell_autorun_streams_runtime_updates,
	test_opening_without_running_does_not_render_idle_placeholders,
	test_sync_buffer_updates_reactive_outputs,
	test_runtime_outputs_include_stdout,
	test_runtime_outputs_include_stdout_after_html_output,
	test_runtime_errors_include_descriptive_stderr_context,
	test_runtime_errors_show_multiple_definition_details,
	test_run_current_cell_command_refreshes_output,
	test_deactivation_clears_runtime_image_placements,
	test_interrupt_clears_running_placeholder,
}

for _, test in ipairs(tests) do
	test()
end

print(string.format("marimo_spec: %d tests passed", #tests))
