local M = {}

M.parse_script = [[
import json
import sys

from marimo._ast.parse import parse_notebook

payload = json.loads(sys.stdin.read())
content = payload["content"]
filepath = payload["filepath"]
notebook = parse_notebook(content, filepath=filepath)

if notebook is None:
    raise SystemExit(json.dumps({"error": "empty notebook"}))
if not notebook.valid:
    raise SystemExit(json.dumps({"error": "invalid marimo notebook"}))

print(json.dumps({
    "header": notebook.header.value if notebook.header else None,
    "app_options": notebook.app.options,
    "cells": [
        {
            "name": cell.name,
            "code": cell.code,
            "options": cell.options,
        }
        for cell in notebook.cells
    ],
}))
]]

M.generate_script = [[
import json
import sys

from marimo._ast.codegen import generate_filecontents_from_ir
from marimo._schemas.serialization import AppInstantiation, CellDef, Header, NotebookSerializationV1

payload = json.loads(sys.stdin.read())
header_value = payload.get("header")
header = Header(value=header_value) if header_value else None
cells = [
    CellDef(code=cell["code"], name=cell["name"], options=cell.get("options", {}))
    for cell in payload["cells"]
]
notebook = NotebookSerializationV1(
    app=AppInstantiation(options=payload.get("app_options", {})),
    header=header,
    cells=cells,
    filename=payload.get("filepath"),
)
print(generate_filecontents_from_ir(notebook), end="")
]]

local function decode_error_message(result)
	local stderr = vim.trim(result.stderr or "")
	local stdout = vim.trim(result.stdout or "")
	local message = stderr ~= "" and stderr or stdout
	if message ~= "" then
		local ok, decoded = pcall(vim.json.decode, message)
		if ok and type(decoded) == "table" and decoded.error then
			message = decoded.error
		end
	end
	return message ~= "" and message or "python marimo command failed"
end

function M.run(script, payload)
	local payload_json = vim.json.encode(payload)
	local commands = {
		{ "python3", "-c", script },
		{ "uv", "run", "--with", "marimo", "python", "-c", script },
	}

	local last_err = nil
	for _, cmd in ipairs(commands) do
		local result = vim.system(cmd, {
			stdin = payload_json,
			text = true,
		}):wait()

		if result.code == 0 then
			local ok, decoded = pcall(vim.json.decode, result.stdout)
			if not ok then
				return result.stdout, nil
			end
			return decoded, nil
		end

		last_err = decode_error_message(result)
		if not last_err:match("ModuleNotFoundError")
			and not last_err:match("No module named 'marimo'")
			and not last_err:match('No module named "marimo"')
		then
			break
		end
	end

	return nil, last_err or "python marimo command failed"
end

return M
