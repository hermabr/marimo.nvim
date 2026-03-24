local source = debug.getinfo(1, "S").source:sub(2)
local M = {}

function M.looks_like_marimo(lines)
	local has_import = false
	local has_app = false
	for _, line in ipairs(lines) do
		if line:match("^%s*import%s+marimo%s*$")
			or line:match("^%s*import%s+marimo%s+as%s+[%w_]+%s*$")
			or line:match("^%s*import%s+marimo%s*,")
		then
			has_import = true
		end
		if line:match("^%s*app%s*=%s*[%w_%.]+%.App%(") then
			has_app = true
		end
	end
	return has_import and has_app
end

function M.looks_like_projected(lines)
	local first = lines[1] or ""
	local marker = first:match("^# %+%s*(%b{})%s*$")
	return marker ~= nil and marker:match("^%{.*marimo.*%}$") ~= nil
end

function M.has_any_projected_markers(lines)
	for _, line in ipairs(lines) do
		if line:match("^# %+$") or line:match("^# %+%s*%b{}%s*$") then
			return true
		end
	end
	return false
end

function M.promote_first_marker_to_marimo(lines)
	local promoted = vim.deepcopy(lines)
	local first_marker_idx = nil
	for idx, line in ipairs(promoted) do
		if line:match("^# %+$") or line:match("^# %+%s*%b{}%s*$") then
			first_marker_idx = idx
			break
		end
	end

	if first_marker_idx == nil then
		return promoted, false
	end

	if first_marker_idx > 1 then
		table.insert(promoted, 1, "")
		table.insert(promoted, 1, "# + {marimo}")
		return promoted, true
	end

	for idx, line in ipairs(promoted) do
		if line:match("^# %+$") then
			promoted[idx] = "# + {marimo}"
			return promoted, true
		end

		local marker = line:match("^# %+%s*(%b{})%s*$")
		if marker then
			local inner = marker:sub(2, -2)
			if inner:match("%S") then
				promoted[idx] = "# + {marimo," .. inner .. "}"
			else
				promoted[idx] = "# + {marimo}"
			end
			return promoted, true
		end
	end

	return promoted, false
end

return M
