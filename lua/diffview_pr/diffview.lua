local M = {}
local github = require("diffview_pr.github")
local notify = require("diffview_pr.notify")
local git = github.git

function M.ensure_remote_contains_head()
	local head, head_err = git({ "rev-parse", "HEAD" })
	if not head then
		return nil, head_err
	end

	local remotes, remotes_err = git({ "branch", "-r", "--contains", head })
	if not remotes then
		return nil, remotes_err
	end

	if remotes == "" then
		return nil, "HEAD is not contained in any remote branch"
	end

	return head
end

function M.current_context(bufnr)
	local ok, lib = pcall(require, "diffview.lib")
	if not ok then
		return nil, "diffview.nvim is not available"
	end

	local view = lib.get_current_view()
	if not view then
		return nil, "this command can only be used from Diffview"
	end

	local file = view:infer_cur_file()
	if not file then
		return nil, "could not determine the current Diffview file"
	end

	local side = bufnr and vim.b[bufnr].diffview_pr_side or vim.b.diffview_pr_side
	if side ~= "LEFT" and side ~= "RIGHT" then
		return nil, "focus a Diffview diff buffer before commenting"
	end

	local path = side == "LEFT" and (file.oldpath or file.path) or file.path
	if not path or path == "" then
		return nil, "could not determine the current Diffview path"
	end

	return { side = side, path = path }
end

function M.attach_context(bufnr, ctx)
	if not ctx then
		return
	end

	if ctx.symbol == "a" then
		vim.b[bufnr].diffview_pr_side = "LEFT"
	elseif ctx.symbol == "b" then
		vim.b[bufnr].diffview_pr_side = "RIGHT"
	end
end

function M.current_view()
	local ok, lib = pcall(require, "diffview.lib")
	if not ok then
		return nil
	end

	return lib.get_current_view()
end

function M.focus_target(target)
	local view = M.current_view()
	if not view then
		return notify("this command can only be used from Diffview", vim.log.levels.WARN)
	end

	local function focus_loaded_target()
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			local bufnr = vim.api.nvim_win_get_buf(win)
			if vim.b[bufnr].diffview_pr_side == target.side then
				vim.api.nvim_set_current_win(win)
				vim.api.nvim_win_set_cursor(win, { target.line, 0 })
				return true
			end
		end

		return false
	end

	if view.panel and view.panel.cur_file ~= target.file then
		view:set_file(target.file, true, true)
		vim.defer_fn(focus_loaded_target, 150)
		return
	end

	if not focus_loaded_target() then
		view:set_file(target.file, true, true)
		vim.defer_fn(focus_loaded_target, 150)
	end
end

return M
