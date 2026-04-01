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
	local matched = vim.wait(timeout or 10000, fn, 20)
	assert_truthy(matched, message or "timed out waiting for condition")
end

local function make_path(name)
	return temp_root .. "/" .. name
end

local function current_runtime_cell(index)
	local cell = vim.b.marimo_cells[index]
	return (vim.b.marimo_runtime_cells or {})[cell.id]
end

local function runtime_output_text(index)
	local runtime = current_runtime_cell(index) or {}
	local output = runtime.output
	if type(output) ~= "table" then
		return ""
	end
	local data = output.data
	if type(data) ~= "string" then
		return ""
	end
	return data:gsub("<[^>]+>", "")
end

local RAW_NOTEBOOK = [[
import marimo

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

local PLAIN_PYTHON = [[
x = 1
y = x + 1
print(y)
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

local function test_activate_raw_notebook_projects_with_lua_owned_projection()
	local path = make_path("raw_notebook.py")
	write_file(path, RAW_NOTEBOOK)
	edit(path)

	assert_truthy(vim.b.marimo_projected)
	assert_eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "# + {marimo}")
	assert_eq(vim.b.marimo_runtime_enabled, false)
	assert_truthy(vim.b.marimo_cells[1].id ~= nil)
	assert_matches(vim.b.marimo_canonical_source, "@app%.cell")
	assert_truthy(vim.b.marimo_projection_map.cells[1].canonical_range.start_line > 0)
end

local function test_activate_projected_notebook_and_write_raw_file_from_lua()
	local path = make_path("projected_notebook.py")
	write_file(path, PROJECTED_NOTEBOOK)
	edit(path)

	vim.cmd("Marimo on")
	assert_truthy(vim.b.marimo_projected)
	assert_eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "# + {marimo}")

	vim.cmd("write")
	wait_for_truthy(function()
		local content = read_file(path)
		return content:match("import marimo") ~= nil and content:match("@app%.cell") ~= nil
	end, "timed out waiting for projected notebook write")

	local content = read_file(path)
	assert_matches(content, "import marimo")
	assert_matches(content, "@app%.cell")
	assert_matches(content, "app%.run%(%)")
end

local function test_manual_activation_wraps_plain_python_in_one_cell()
	local path = make_path("plain_python.py")
	write_file(path, PLAIN_PYTHON)
	edit(path)

	vim.cmd("Marimo on")
	assert_truthy(vim.b.marimo_projected)
	assert_eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "# + {marimo}")
	assert_eq(#vim.b.marimo_cells, 1)
	assert_matches(vim.b.marimo_cells[1].code, "print%(y%)")
end

local function test_runtime_stays_lazy_until_run_and_renders_output_from_raw_operations()
	local path = make_path("runtime_lazy.py")
	write_file(path, PROJECTED_NOTEBOOK)
	edit(path)

	vim.cmd("Marimo on")
	assert_eq(vim.b.marimo_runtime_enabled, false)

	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		return runtime_output_text(1):match("1") ~= nil
	end, "timed out waiting for runtime output")

	assert_eq(vim.b.marimo_runtime_enabled, true)
	assert_truthy((vim.b.marimo_runtime_cells or {})[vim.b.marimo_cells[1].id] ~= nil)
end

local function test_sync_buffer_updates_outputs_after_edit()
	local path = make_path("runtime_sync.py")
	write_file(path, "# + {marimo}\n\nx = 1\nx\n\n# +\n\ny = x + 1\ny")
	edit(path)

	vim.cmd("Marimo on")
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		return runtime_output_text(2):match("2") ~= nil
	end, "timed out waiting for initial runtime output")

	vim.api.nvim_buf_set_lines(0, 2, 3, false, { "x = 3" })
	vim.cmd("MarimoRunAll")
	wait_for_truthy(function()
		return runtime_output_text(1):match("3") ~= nil and runtime_output_text(2):match("4") ~= nil
	end, "timed out waiting for synced runtime output")
end

marimo.setup()

local tests = {
	test_find_project_root_prefers_uv_lock,
	test_activate_raw_notebook_projects_with_lua_owned_projection,
	test_activate_projected_notebook_and_write_raw_file_from_lua,
	test_manual_activation_wraps_plain_python_in_one_cell,
	test_runtime_stays_lazy_until_run_and_renders_output_from_raw_operations,
	test_sync_buffer_updates_outputs_after_edit,
}

for _, test in ipairs(tests) do
	test()
end

vim.cmd("qa!")
