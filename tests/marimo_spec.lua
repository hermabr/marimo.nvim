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
	assert_truthy(vim.b.marimo_projected)
	assert_truthy(#vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {}) > 0)

	vim.cmd("Marimo")
	assert_truthy(not vim.b.marimo_projected)
	assert_eq(#vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, {}), 0)
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

local function test_runtime_outputs_render_below_cells()
	local path = make_path("runtime_outputs.py")
	write_file(path, "# + {marimo}\n\nx = 1\nx\n\n# +\n\ny = x + 1\ny")
	edit(path)

	vim.cmd("Marimo on")
	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, "marimo idle")
	assert_matches(lines, " 1")
	assert_matches(lines, " 2")
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

local function test_run_current_cell_command_refreshes_output()
	local path = make_path("runtime_run_current.py")
	write_file(path, "# + {marimo}\n\nx = 1\nx")
	edit(path)

	vim.cmd("Marimo on")
	vim.api.nvim_buf_set_lines(0, 2, 3, false, { "x = 7" })
	vim.api.nvim_win_set_cursor(0, { 3, 0 })
	vim.cmd("MarimoRunCell")

	local lines = table.concat(rendered_lines(), "\n")
	assert_matches(lines, " 7")
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
	test_sync_buffer_updates_reactive_outputs,
	test_run_current_cell_command_refreshes_output,
}

for _, test in ipairs(tests) do
	test()
end

print(string.format("marimo_spec: %d tests passed", #tests))
