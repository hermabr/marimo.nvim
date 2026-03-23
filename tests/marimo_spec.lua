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

marimo.setup()

local tests = {
	test_find_project_root_prefers_uv_lock,
	test_activate_raw_notebook_projects_and_populates_session_state,
	test_activate_projected_notebook_and_write_raw_marimo_file,
	test_generic_projected_notebook_is_promoted,
	test_manual_activation_wraps_plain_python_in_one_cell,
}

for _, test in ipairs(tests) do
	test()
end

print(string.format("marimo_spec: %d tests passed", #tests))
