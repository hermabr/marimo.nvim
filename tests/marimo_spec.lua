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

local function assert_falsy(value, message)
	if value then
		error(message or ("expected falsy value, got " .. vim.inspect(value)))
	end
end

local function test_looks_like_marimo_with_bare_import()
	assert_truthy(private.looks_like_marimo({
		"import marimo",
		'__generated_with = "0.21.1"',
		'app = marimo.App(width="medium")',
	}))
end

local function test_looks_like_projected_with_plain_markers()
	assert_truthy(private.looks_like_projected({
		"# + {marimo}",
		"print('x')",
	}))
end

local function test_looks_like_projected_rejects_generic_notebooks()
	assert_falsy(private.looks_like_projected({
		"# +",
		"print('x')",
	}))
end

local function test_promote_generic_projected_notebook_to_marimo()
	assert_truthy(private.has_any_projected_markers({
		"# +",
		"print('x')",
	}))

	local promoted, changed = private.promote_first_marker_to_marimo({
		"# +",
		"print('x')",
		"",
		"# +",
		"y = 2",
	})

	assert_truthy(changed)
	assert_eq(promoted[1], "# + {marimo}")
	assert_eq(promoted[4], "# +")
end

local function test_promote_leading_code_to_first_marimo_cell()
	local promoted, changed = private.promote_first_marker_to_marimo({
		'print("HEY")',
		"",
		"# +",
		"",
		"a = 1",
	})

	assert_truthy(changed)
	assert_eq(promoted[1], "# + {marimo}")
	assert_eq(promoted[2], "")
	assert_eq(promoted[3], 'print("HEY")')
end

local function test_parse_marker_line_supports_plain_and_options()
	local is_marker, opts = private.parse_marker_line("# +")
	assert_truthy(is_marker)
	assert_eq(opts, nil)

	is_marker, opts = private.parse_marker_line("# + {marimo, setup=True, hide_code=True}")
	assert_truthy(is_marker)
	assert_eq(opts, "{marimo, setup=True, hide_code=True}")
end

local function test_parse_projected_cells_supports_plain_markers()
	local cells = private.parse_projected_cells({
		"# + {marimo}",
		'print("HEY")',
		"",
		"# +",
		"a = 5",
		"a",
		"",
		"# +",
		"b = 2",
		"",
		"# +",
		"c = a / b",
		"c",
	})

	assert_eq(#cells, 4)
	assert_eq(cells[1].name, "_")
	assert_eq(cells[1].code, 'print("HEY")')
	assert_eq(vim.json.encode(cells[1].options), "{}")
	assert_eq(cells[4].code, "c = a / b\nc")
end

local function test_parse_projected_cells_supports_setup_cell()
	local cells = private.parse_projected_cells({
		"# + {marimo, setup=True, hide_code=True}",
		"import marimo as mo",
		"",
		"# +",
		"x = mo.ui.slider(1, 10)",
		"x",
	})

	assert_eq(#cells, 2)
	assert_eq(cells[1].name, "setup")
	assert_eq(cells[1].code, "import marimo as mo")
	assert_eq(cells[1].options.hide_code, true)
	assert_eq(cells[2].name, "_")
end

local function test_as_json_object_encodes_empty_tables_as_dicts()
	assert_eq(vim.json.encode(private.as_json_object({})), "{}")
	assert_eq(vim.json.encode(private.as_json_object(nil)), "{}")
	assert_eq(vim.json.encode(private.as_json_object({ hide_code = true })), '{"hide_code":true}')
end

local function test_normalize_projected_buffer_spacing()
	local normalized = private.normalize_projected_buffer_lines({
		"# + {marimo}",
		"",
		"",
		'print("HEY")',
		"",
		"",
		"# +",
		"",
		"",
		"a = 5",
		"a",
		"",
		"",
	})

	assert_eq(normalized[1], "# + {marimo}")
	assert_eq(normalized[2], "")
	assert_eq(normalized[3], 'print("HEY")')
	assert_eq(normalized[4], "")
	assert_eq(normalized[5], "# +")
	assert_eq(normalized[6], "")
	assert_eq(normalized[7], "a = 5")
	assert_eq(normalized[8], "a")
	assert_eq(normalized[9], nil)
end

local function test_dedupes_consecutive_empty_cells()
	local normalized = private.normalize_projected_buffer_lines({
		"# + {marimo}",
		"",
		"",
		"# +",
		"",
		"",
		"# +",
		"",
		"value = 1",
	})

	assert_eq(normalized[1], "# + {marimo}")
	assert_eq(normalized[2], "")
	assert_eq(normalized[3], "")
	assert_eq(normalized[4], "# +")
	assert_eq(normalized[5], "")
	assert_eq(normalized[6], "value = 1")
	assert_eq(normalized[7], nil)
end

local function test_find_cell_start_rows_supports_optioned_markers()
	local starts = private.find_cell_start_rows({
		"# + {marimo}",
		"",
		"x = 1",
		"",
		"# + {hide_code=True}",
		"",
		"y = 2",
	})

	assert_eq(vim.inspect(starts), vim.inspect({ 1, 5 }))
end

local function test_first_content_row_after_marker_skips_blank_lines()
	local row = private.first_content_row_after_marker({
		"# + {marimo}",
		"",
		"",
		"x = 1",
		"",
		"# +",
		"",
	}, 1)

	assert_eq(row, 4)
end

local function test_normalize_collapses_trailing_empty_cells()
	local normalized = private.normalize_projected_buffer_lines({
		"# + {marimo}",
		"",
		"x = 1",
		"",
		"# +",
		"",
		"# +",
		"",
	})

	assert_eq(normalized[1], "# + {marimo}")
	assert_eq(normalized[2], "")
	assert_eq(normalized[3], "x = 1")
	assert_eq(normalized[4], "")
	assert_eq(normalized[5], "# +")
	assert_eq(normalized[6], nil)
end

local tests = {
	test_looks_like_marimo_with_bare_import,
	test_looks_like_projected_with_plain_markers,
	test_looks_like_projected_rejects_generic_notebooks,
	test_promote_generic_projected_notebook_to_marimo,
	test_promote_leading_code_to_first_marimo_cell,
	test_parse_marker_line_supports_plain_and_options,
	test_parse_projected_cells_supports_plain_markers,
	test_parse_projected_cells_supports_setup_cell,
	test_as_json_object_encodes_empty_tables_as_dicts,
	test_normalize_projected_buffer_spacing,
	test_dedupes_consecutive_empty_cells,
	test_find_cell_start_rows_supports_optioned_markers,
	test_first_content_row_after_marker_skips_blank_lines,
	test_normalize_collapses_trailing_empty_cells,
}

for _, test in ipairs(tests) do
	test()
end

print(string.format("marimo_spec: %d tests passed", #tests))
