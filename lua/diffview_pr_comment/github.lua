local M = {}

local function system(args, opts)
	opts = opts or {}
	local result = vim.system(args, { text = true, cwd = opts.cwd }):wait()
	local stdout = vim.trim(result.stdout or "")
	local stderr = vim.trim(result.stderr or "")

	if result.code ~= 0 then
		return nil, stderr ~= "" and stderr or stdout
	end

	return stdout, nil
end

function M.git(args)
	local cmd = { "git" }
	vim.list_extend(cmd, args)
	return system(cmd)
end

function M.gh(args)
	local cmd = { "gh" }
	vim.list_extend(cmd, args)
	return system(cmd)
end

function M.gh_async(args, callback)
	local cmd = { "gh" }
	vim.list_extend(cmd, args)

	vim.system(cmd, { text = true }, function(result)
		vim.schedule(function()
			local stdout = vim.trim(result.stdout or "")
			local stderr = vim.trim(result.stderr or "")
			if result.code ~= 0 then
				callback(nil, stderr ~= "" and stderr or stdout)
				return
			end

			callback(stdout, nil)
		end)
	end)
end

function M.is_no_pr_error(err)
	return type(err) == "string" and err:lower():find("no pull requests", 1, true) ~= nil
end

return M
