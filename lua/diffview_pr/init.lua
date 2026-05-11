local M = {}

local commands = require("diffview_pr.commands")
local comments = require("diffview_pr.comments")
local config_module = require("diffview_pr.config")
local diffview = require("diffview_pr.diffview")
local github = require("diffview_pr.github")
local highlights = require("diffview_pr.highlights")
local keymaps = require("diffview_pr.keymaps")
local notify = require("diffview_pr.notify")
local renderer = require("diffview_pr.renderer")
local state = require("diffview_pr.state")
local windows = require("diffview_pr.windows")

local augroup = vim.api.nvim_create_augroup("diffview_pr", { clear = true })
local config = config_module.values
local defaults = config_module.defaults
local gh_async = github.gh_async
local is_no_pr_error = github.is_no_pr_error

---@param ctx DiffviewPRContext
---@param start_line integer
---@param end_line integer
---@return DiffviewPRComment?
local function overlapping_comment(ctx, start_line, end_line)
	for _, comment in ipairs(comments.for_context(ctx)) do
		local comment_start = comments.start_line(comment)
		local comment_end = comments.line(comment)
		if comment_start and comment_end then
			comment_start, comment_end = math.min(comment_start, comment_end), math.max(comment_start, comment_end)
			if start_line <= comment_end and end_line >= comment_start then
				return comment
			end
		end
	end
end

---@param callback DiffviewPRCurrentPRCallback
local function current_pr_async(callback)
	if state.pr then
		callback(state.pr, nil)
		return
	end

	table.insert(state.pr_callbacks, callback)
	if state.pr_fetching then
		return
	end

	state.pr_fetching = true
	gh_async({ "pr", "view", "--json", "number,url" }, function(out, err)
		state.pr_fetching = false
		local callbacks = state.pr_callbacks
		state.pr_callbacks = {}

		if not out then
			for _, cb in ipairs(callbacks) do
				cb(nil, err, is_no_pr_error(err))
			end
			return
		end

		local ok, pr = pcall(vim.json.decode, out)
		if not ok or not pr.number then
			for _, cb in ipairs(callbacks) do
				cb(nil, "could not parse `gh pr view` output")
			end
			return
		end

		state.pr = pr
		for _, cb in ipairs(callbacks) do
			cb(pr, nil)
		end
	end)
end

---@param callback DiffviewPRDoneCallback
local function fetch_comments(callback)
	if state.comments then
		callback()
		return
	end

	table.insert(state.fetch_callbacks, callback)
	if state.fetching then
		return
	end

	state.fetching = true
	current_pr_async(function(pr, pr_err, no_pr)
		if not pr then
			state.fetching = false
			if not no_pr then
				notify(pr_err, vim.log.levels.WARN)
			end
			return
		end

		gh_async({ "api", "--paginate", "repos/{owner}/{repo}/pulls/" .. pr.number .. "/comments" }, function(out, err)
			state.fetching = false
			if not out then
				notify(err, vim.log.levels.WARN)
				return
			end

			local ok, parsed_comments = pcall(vim.json.decode, out)
			if not ok or type(parsed_comments) ~= "table" then
				notify("could not parse PR comments", vim.log.levels.WARN)
				return
			end

			state.comments = comments.hydrate_threads(parsed_comments)
			local callbacks = state.fetch_callbacks
			state.fetch_callbacks = {}
			for _, cb in ipairs(callbacks) do
				cb()
			end
		end)
	end)
end

---@param callback? DiffviewPRDoneCallback
local function refresh_comments_async(callback)
	state.comments = nil
	state.comments_by_buf = {}

	for bufnr in pairs(state.render_context_by_buf) do
		if vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_clear_namespace(bufnr, renderer.ns, 0, -1)
		end
	end

	fetch_comments(function()
		for bufnr, render_ctx in pairs(state.render_context_by_buf) do
			if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
				renderer.render_comments(bufnr, render_ctx)
			end
		end

		renderer.render_panel_comments()
		if callback then
			callback()
		end
	end)
end

---@param direction integer
local function navigate_comment(direction)
	fetch_comments(function()
		local view = diffview.current_view()
		if not view then
			return notify("this command can only be used from Diffview", vim.log.levels.WARN)
		end

		local targets = comments.targets_for_view(view)
		if #targets == 0 then
			return notify("no PR comments in this Diffview", vim.log.levels.INFO)
		end

		local pos = comments.current_position(view)
		local target = direction > 0 and comments.target_after(targets, pos) or comments.target_before(targets, pos)
		diffview.focus_target(target)
	end)
end

---@param opts? table
function M.setup(opts)
	config = config_module.setup(opts)
	highlights.setup()

	if config.comment_style ~= "minimal" and config.comment_style ~= "expanded" then
		notify("invalid comment_style: " .. tostring(config.comment_style), vim.log.levels.WARN)
		config.comment_style = defaults.comment_style
	end
end

---@param line1 integer
---@param line2 integer
function M.open(line1, line2)
	local head, head_err = diffview.ensure_remote_contains_head()
	if not head then
		return notify(head_err, vim.log.levels.ERROR)
	end

	local ctx, ctx_err = diffview.current_context()
	if not ctx then
		return notify(ctx_err, vim.log.levels.ERROR)
	end

	local start_line = math.min(line1, line2)
	local end_line = math.max(line1, line2)
	fetch_comments(function()
		local overlap = overlapping_comment(ctx, start_line, end_line)
		if overlap then
			local overlap_start = comments.start_line(overlap)
			local overlap_end = comments.line(overlap)
			local overlap_range = overlap_start == overlap_end and tostring(overlap_end) or string.format(
				"%d-%d",
				math.min(overlap_start, overlap_end),
				math.max(overlap_start, overlap_end)
			)
			return notify("selected lines overlap an existing PR comment on line " .. overlap_range, vim.log.levels.ERROR)
		end

		current_pr_async(function(pr, pr_err)
			if not pr then
				return notify(pr_err, vim.log.levels.ERROR)
			end

			windows.open_comment({
				commit_id = head,
				pr_number = pr.number,
				pr_url = pr.url,
				path = ctx.path,
				side = ctx.side,
				start_line = start_line,
				line = end_line,
			})
		end)
	end)
end

---@param comment DiffviewPRSubmitComment
---@param callback? DiffviewPRSubmitCallback
function M.submit(comment, callback)
	callback = callback or function() end
	---@param success boolean
	local function finish(success)
		callback(success)
	end

	---@param message string
	local function on_created(message)
		notify(message)
		refresh_comments_async(function()
			finish(true)
		end)
	end

	if comment.reply_to_id then
		gh_async({
			"api",
			"repos/{owner}/{repo}/pulls/" .. comment.pr_number .. "/comments/" .. comment.reply_to_id .. "/replies",
			"-f",
			"body=" .. comment.body,
		}, function(_, err)
			if err then
				notify(err, vim.log.levels.ERROR)
				return finish(false)
			end

			on_created("reply created on " .. comments.pr_display_name(comment.pr_number))
		end)
		return
	end

	local args = {
		"api",
		"repos/{owner}/{repo}/pulls/" .. comment.pr_number .. "/comments",
		"-f",
		"body=" .. comment.body,
		"-f",
		"commit_id=" .. comment.commit_id,
		"-f",
		"path=" .. comment.path,
		"-f",
		"side=" .. comment.side,
		"-F",
		"line=" .. comment.line,
	}

	if comment.start_line ~= comment.line then
		vim.list_extend(args, {
			"-F",
			"start_line=" .. comment.start_line,
			"-f",
			"start_side=" .. comment.side,
		})
	end

	gh_async(args, function(_, err)
		if err then
			notify(err, vim.log.levels.ERROR)
			return finish(false)
		end

		on_created("comment created on " .. comments.pr_display_name(comment.pr_number))
	end)
end

---@param pr_or_number DiffviewPRPullRequest|integer|string
---@return string
function M.pr_display_name(pr_or_number)
	return comments.pr_display_name(pr_or_number)
end

---@return nil
function M.approve()
	local head, head_err = diffview.ensure_remote_contains_head()
	if not head then
		return notify(head_err, vim.log.levels.ERROR)
	end

	current_pr_async(function(pr, pr_err)
		if not pr then
			return notify(pr_err, vim.log.levels.ERROR)
		end

		windows.open_review({
			title = "Approve " .. comments.pr_display_name(pr),
			placeholder = "Leave an optional approval message...",
			require_body = false,
			submit_fn = function(body, callback)
				local args = { "pr", "review", tostring(pr.number), "--approve" }
				if body and body ~= "" then
					vim.list_extend(args, { "--body", body })
				end
				gh_async(args, function(_, err)
					if err then
						notify(err, vim.log.levels.ERROR)
						return callback(false)
					end
					notify("Approved " .. comments.pr_display_name(pr))
					state.comments = nil
					callback(true)
				end)
			end,
		})
	end)
end

---@return nil
function M.request_changes()
	local head, head_err = diffview.ensure_remote_contains_head()
	if not head then
		return notify(head_err, vim.log.levels.ERROR)
	end

	current_pr_async(function(pr, pr_err)
		if not pr then
			return notify(pr_err, vim.log.levels.ERROR)
		end

		windows.open_review({
			title = "Request Changes on " .. comments.pr_display_name(pr),
			placeholder = "Explain what needs to change...",
			require_body = true,
			submit_fn = function(body, callback)
				gh_async({ "pr", "review", tostring(pr.number), "--request-changes", "--body", body }, function(_, err)
					if err then
						notify(err, vim.log.levels.ERROR)
						return callback(false)
					end
					notify("Requested changes on " .. comments.pr_display_name(pr))
					state.comments = nil
					callback(true)
				end)
			end,
		})
	end)
end

---@return nil
function M.close_pr()
	current_pr_async(function(pr, pr_err)
		if not pr then
			return notify(pr_err, vim.log.levels.ERROR)
		end

		windows.open_review({
			title = "Close " .. comments.pr_display_name(pr),
			placeholder = "Leave an optional comment...",
			require_body = false,
			submit_fn = function(body, callback)
				local args = { "pr", "close", tostring(pr.number) }
				if body and body ~= "" then
					vim.list_extend(args, { "--comment", body })
				end
				gh_async(args, function(_, err)
					if err then
						notify(err, vim.log.levels.ERROR)
						return callback(false)
					end
					notify("Closed " .. comments.pr_display_name(pr))
					state.comments = nil
					state.pr = nil
					callback(true)
				end)
			end,
		})
	end)
end

---@param bufnr integer
---@param ctx? DiffviewPRAttachContext
function M.attach_diffview_buffer(bufnr, ctx)
	diffview.attach_context(bufnr, ctx)
	if not vim.b[bufnr].diffview_pr_side then
		return
	end

	vim.defer_fn(function()
		local render_ctx, ctx_err = diffview.current_context(bufnr)
		if not render_ctx then
			return notify(ctx_err, vim.log.levels.WARN)
		end

		renderer.track_buffer(bufnr, render_ctx)
		fetch_comments(function()
			if state.pr and not state.notified_pr then
				notify(comments.pr_display_name(state.pr) .. " associated with this branch")
				state.notified_pr = true
			end

			renderer.render_comments(bufnr, render_ctx)
			renderer.render_panel_comments()
		end)
	end, 100)
end

---@param bufnr integer
---@param _ integer
---@param ctx? DiffviewPRAttachContext
function M.diff_buf_win_enter(bufnr, _, ctx)
	keymaps.register_diffview_help()
	keymaps.setup_buffer(bufnr)
	keymaps.setup_panel()
	M.attach_diffview_buffer(bufnr, ctx)
end

---@param bufnr integer
function M.clear_buffer(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, renderer.ns, 0, -1)
		state.comments_by_buf[bufnr] = nil
		state.render_context_by_buf[bufnr] = nil
		state.tracked_buffers[bufnr] = nil
	end
end

---@return nil
function M.debug_state()
	local ok, lib = pcall(require, "diffview.lib")
	local view = ok and lib.get_current_view() or nil
	local panel = view and view.panel
	local panel_marks = {}
	if panel and panel.bufid and vim.api.nvim_buf_is_valid(panel.bufid) then
		panel_marks = vim.api.nvim_buf_get_extmarks(panel.bufid, renderer.panel_ns, 0, -1, { details = true })
	end

	local diff_buffers = {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.b[bufnr].diffview_pr_side then
			table.insert(diff_buffers, {
				bufnr = bufnr,
				name = vim.api.nvim_buf_get_name(bufnr),
				side = vim.b[bufnr].diffview_pr_side,
				markers = vim.api.nvim_buf_get_extmarks(bufnr, renderer.ns, 0, -1, { details = true }),
			})
		end
	end

	print(vim.inspect({
		module = debug.getinfo(1, "S").source,
		pr = state.pr,
		comments = state.comments and #state.comments or 0,
		fetching = state.fetching,
		pr_fetching = state.pr_fetching,
		diff_buffers = diff_buffers,
		panel_marks = panel_marks,
	}))
end

---@return nil
function M.refresh()
	local ok, lib = pcall(require, "diffview.lib")
	if not ok or not lib.get_current_view() then
		return notify("this command can only be used from Diffview", vim.log.levels.WARN)
	end

	refresh_comments_async()
end

---@return nil
function M.show_comments_at_cursor()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local cursor_comments = state.comments_by_buf[bufnr] and state.comments_by_buf[bufnr][line] or {}

	if #cursor_comments == 0 then
		return notify("no PR comments on this line", vim.log.levels.INFO)
	end

	windows.open_thread(cursor_comments)
end

---@return nil
function M.open_comments_at_cursor_or_enter()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]

	if state.comments_by_buf[bufnr] and state.comments_by_buf[bufnr][line] then
		if config.comment_style == "expanded" then
			renderer.start_inline_reply(bufnr, line, state.comments_by_buf[bufnr][line], "Reply")
			return
		end
		M.show_comments_at_cursor()
		return
	end

	local keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
	vim.api.nvim_feedkeys(keys, "n", false)
end

---@return nil
function M.next_comment()
	navigate_comment(1)
end

---@return nil
function M.previous_comment()
	navigate_comment(-1)
end

---@return nil
function M.reply_to_comment_at_cursor()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local cursor_comments = state.comments_by_buf[bufnr] and state.comments_by_buf[bufnr][line] or {}

	if #cursor_comments == 0 then
		return notify("no PR comments on this line", vim.log.levels.INFO)
	end

	windows.open_reply(cursor_comments[1])
end

---@return nil
function M.close_review_windows()
	windows.close_review()
end

---@return nil
function M.next_review_window()
	windows.focus_review(1)
end

---@return nil
function M.previous_review_window()
	windows.focus_review(-1)
end

windows.setup({ current_pr = current_pr_async, submit = M.submit })
renderer.setup({ submit = M.submit })
commands.register(M)
highlights.setup()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = augroup,
	callback = highlights.setup,
})

return M
