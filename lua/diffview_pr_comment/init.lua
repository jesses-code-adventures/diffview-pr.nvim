local M = {}
local config_module = require("diffview_pr_comment.config")
local state = require("diffview_pr_comment.state")
local notify = require("diffview_pr_comment.notify")
local github = require("diffview_pr_comment.github")
local highlights = require("diffview_pr_comment.highlights")
local commands = require("diffview_pr_comment.commands")

local ns = vim.api.nvim_create_namespace("diffview_pr_comments")
local panel_ns = vim.api.nvim_create_namespace("diffview_pr_comment_panel")
local augroup = vim.api.nvim_create_augroup("diffview_pr_comment", { clear = true })
local defaults = config_module.defaults
local config = config_module.values
local current_diffview_view

local setup_highlights = highlights.setup

local git = github.git
local gh = github.gh
local gh_async = github.gh_async
local is_no_pr_error = github.is_no_pr_error

local function ensure_remote_contains_head()
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

local function current_diffview_context(bufnr)
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

	local side = bufnr and vim.b[bufnr].diffview_pr_comment_side or vim.b.diffview_pr_comment_side
	if side ~= "LEFT" and side ~= "RIGHT" then
		return nil, "focus a Diffview diff buffer before commenting"
	end

	local path = side == "LEFT" and (file.oldpath or file.path) or file.path
	if not path or path == "" then
		return nil, "could not determine the current Diffview path"
	end

	return { side = side, path = path }
end

local function attach_diffview_context(bufnr, ctx)
	if not ctx then
		return
	end

	if ctx.symbol == "a" then
		vim.b[bufnr].diffview_pr_comment_side = "LEFT"
	elseif ctx.symbol == "b" then
		vim.b[bufnr].diffview_pr_comment_side = "RIGHT"
	end
end

local function set_keymap(mode, lhs, rhs, bufnr, desc)
	if not lhs or lhs == false then
		return
	end

	vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
end

local function setup_buffer_keymaps(bufnr)
	local keymaps = config.keymaps
	if not keymaps or keymaps.enabled == false then
		return
	end
	if state.keymaps_by_buf[bufnr] then
		return
	end

	state.keymaps_by_buf[bufnr] = true

	set_keymap("x", keymaps.create_comment, ":DiffviewPRComment<CR>", bufnr, "Create PR comment from selection")
	set_keymap("n", keymaps.show_comments, ":DiffviewPRShowComments<CR>", bufnr, "Open PR comments at cursor")
	set_keymap("n", keymaps.open_comments_or_enter, ":DiffviewPROpenCommentsOrEnter<CR>", bufnr, "Open PR comments at cursor")
	set_keymap("n", keymaps.reply, ":DiffviewPRReply<CR>", bufnr, "Reply to PR comment at cursor")
	set_keymap("n", keymaps.refresh, ":DiffviewPRRefresh<CR>", bufnr, "Refresh PR comments")
	set_keymap("n", keymaps.next_comment, ":DiffviewPRNextComment<CR>", bufnr, "Next PR comment")
	set_keymap("n", keymaps.previous_comment, ":DiffviewPRPreviousComment<CR>", bufnr, "Previous PR comment")
	set_keymap("n", keymaps.approve, ":DiffviewPRReviewApprove<CR>", bufnr, "Approve PR")
	set_keymap("n", keymaps.request_changes, ":DiffviewPRReviewRequestChanges<CR>", bufnr, "Request PR changes")
	set_keymap("n", keymaps.close_pr, ":DiffviewPRReviewClose<CR>", bufnr, "Close PR")
	set_keymap("n", keymaps.close_review_windows, ":DiffviewPRCloseReviewWindows<CR>", bufnr, "Close PR review windows")
	set_keymap("n", keymaps.next_review_window, ":DiffviewPRNextReviewWindow<CR>", bufnr, "Next PR review window")
	set_keymap("n", keymaps.previous_review_window, ":DiffviewPRPreviousReviewWindow<CR>", bufnr, "Previous PR review window")
	set_keymap("n", "g?", function()
		local ok, actions = pcall(require, "diffview.actions")
		local view = current_diffview_view()
		local layout = view and view.cur_layout and view.cur_layout.name or "diff2"
		local layout_group = layout:match("^(diff%d)") or "diff2"
		if ok then
			actions.help({ "view", layout_group, "diffview_pr" })()
		end
	end, bufnr, "Open the help panel")
end

local function setup_panel_keymaps()
	local keymaps = config.keymaps
	if not keymaps or keymaps.enabled == false then
		return
	end

	local ok, lib = pcall(require, "diffview.lib")
	local view = ok and lib.get_current_view() or nil
	local panel = view and view.panel
	local bufnr = panel and panel.bufid
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or state.keymaps_by_buf[bufnr] then
		return
	end

	state.keymaps_by_buf[bufnr] = true
	set_keymap("n", keymaps.next_comment, ":DiffviewPRNextComment<CR>", bufnr, "Next PR comment")
	set_keymap("n", keymaps.previous_comment, ":DiffviewPRPreviousComment<CR>", bufnr, "Previous PR comment")
	set_keymap("n", "g?", function()
		local ok, actions = pcall(require, "diffview.actions")
		if ok then
			actions.help({ "file_panel", "diffview_pr" })()
		end
	end, bufnr, "Open the help panel")
end

local function add_diffview_help_keymap(diffview_keymaps, group, lhs, rhs, desc)
	if not lhs or lhs == false then
		return
	end
	diffview_keymaps[group] = diffview_keymaps[group] or {}

	for _, mapping in ipairs(diffview_keymaps[group]) do
		if mapping[1] == "n" and mapping[2] == lhs then
			return
		end
	end

	table.insert(diffview_keymaps[group], { "n", lhs, rhs, { desc = desc } })
end

local function replace_diffview_help_mapping(diffview_keymaps, group, help_groups)
	local ok, actions = pcall(require, "diffview.actions")
	if not ok or not diffview_keymaps[group] then
		return
	end

	for _, mapping in ipairs(diffview_keymaps[group]) do
		if mapping[1] == "n" and mapping[2] == "g?" then
			mapping[3] = actions.help(help_groups)
			return
		end
	end
end

local function register_diffview_help_keymaps()
	local keymaps = config.keymaps
	if state.registered_diffview_help or not keymaps or keymaps.enabled == false then
		return
	end

	local ok, diffview_config = pcall(require, "diffview.config")
	if not ok then
		return
	end

	state.registered_diffview_help = true
	local diffview_keymaps = diffview_config.get_config().keymaps
	local mappings = {
		{ keymaps.show_comments, ":DiffviewPRShowComments<CR>", "Open PR comments at cursor" },
		{ keymaps.open_comments_or_enter, ":DiffviewPROpenCommentsOrEnter<CR>", "Open PR comments at cursor" },
		{ keymaps.reply, ":DiffviewPRReply<CR>", "Reply to PR comment at cursor" },
		{ keymaps.refresh, ":DiffviewPRRefresh<CR>", "Refresh PR comments" },
		{ keymaps.next_comment, ":DiffviewPRNextComment<CR>", "Next PR comment" },
		{ keymaps.previous_comment, ":DiffviewPRPreviousComment<CR>", "Previous PR comment" },
		{ keymaps.approve, ":DiffviewPRReviewApprove<CR>", "Approve PR" },
		{ keymaps.request_changes, ":DiffviewPRReviewRequestChanges<CR>", "Request PR changes" },
		{ keymaps.close_pr, ":DiffviewPRReviewClose<CR>", "Close PR" },
		{ keymaps.close_review_windows, ":DiffviewPRCloseReviewWindows<CR>", "Close PR review windows" },
		{ keymaps.next_review_window, ":DiffviewPRNextReviewWindow<CR>", "Next PR review window" },
		{ keymaps.previous_review_window, ":DiffviewPRPreviousReviewWindow<CR>", "Previous PR review window" },
	}

	for _, mapping in ipairs(mappings) do
		add_diffview_help_keymap(diffview_keymaps, "diffview_pr", mapping[1], mapping[2], mapping[3])
	end

	replace_diffview_help_mapping(diffview_keymaps, "diff1", { "view", "diff1", "diffview_pr" })
	replace_diffview_help_mapping(diffview_keymaps, "diff2", { "view", "diff2", "diffview_pr" })
	replace_diffview_help_mapping(diffview_keymaps, "diff3", { "view", "diff3", "diffview_pr" })
	replace_diffview_help_mapping(diffview_keymaps, "diff4", { "view", "diff4", "diffview_pr" })
	replace_diffview_help_mapping(diffview_keymaps, "file_panel", { "file_panel", "diffview_pr" })
end

local function current_pr()
	if state.pr then
		return state.pr
	end

	local out, err = gh({ "pr", "view", "--json", "number,url" })
	if not out then
		return nil, err, is_no_pr_error(err)
	end

	local ok, pr = pcall(vim.json.decode, out)
	if not ok or not pr.number then
		return nil, "could not parse `gh pr view` output"
	end

	state.pr = pr
	return pr
end

local function pr_display_name(pr_or_number)
	local number = type(pr_or_number) == "table" and pr_or_number.number or pr_or_number
	return "PR #" .. tostring(number)
end

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

local function comment_line(comment)
	return comment.line or comment.original_line
end

local function comment_side(comment)
	return comment.side or comment.original_side or "RIGHT"
end

local function comment_author(comment)
	return comment.user and comment.user.login or "unknown"
end

local function inline_comment_lines(comments, active)
	local lines = {}
	local header_hl = active and "DiffviewPRCommentActive" or "DiffviewFilePanelTitle"
	local body_hl = active and "DiffviewPRCommentActive" or "Comment"

	for index, comment in ipairs(comments) do
		table.insert(lines, { { "  " .. comment_author(comment) .. " commented:", header_hl } })

		local body_lines = vim.split(comment.body or "", "\n", { plain = true })
		if #body_lines == 0 then
			body_lines = { "" }
		end

		for _, body_line in ipairs(body_lines) do
			table.insert(lines, { { "  " .. body_line, body_hl } })
		end

		if index ~= #comments then
			table.insert(lines, { { "", body_hl } })
		end
	end

	return lines
end

local function minimal_comment_lines(comments, active)
	local first = comments[1]
	local username = first and comment_author(first) or "someone"
	local other_users = {}

	for _, comment in ipairs(comments) do
		local user = comment_author(comment)
		if user ~= username then
			other_users[user] = true
		end
	end

	local others = vim.tbl_count(other_users)
	local suffix = others == 0 and "" or " (and " .. others .. " other" .. (others == 1 and "" or "s") .. ")"
	local hl = active and "DiffviewPRCommentActive" or "DiffviewFilePanelTitle"
	return { { { "  " .. username .. " commented" .. suffix .. "...", hl } } }
end

local function comment_virt_lines(comments, active)
	if config.comment_style == "minimal" then
		return minimal_comment_lines(comments, active)
	end

	return inline_comment_lines(comments, active)
end

local function hydrate_comment_threads(comments)
	local by_id = {}
	for _, comment in ipairs(comments) do
		if comment.id then
			by_id[comment.id] = comment
		end
	end

	for _, comment in ipairs(comments) do
		local parent = comment.in_reply_to_id and by_id[comment.in_reply_to_id]
		if parent then
			comment.path = comment.path or parent.path
			comment.side = comment.side or parent.side
			comment.original_side = comment.original_side or parent.original_side
			comment.line = comment.line or parent.line
			comment.original_line = comment.original_line or parent.original_line
			comment._thread_root_id = parent._thread_root_id or parent.id
		else
			comment._thread_root_id = comment.id
		end
	end

	table.sort(comments, function(a, b)
		if a._thread_root_id == b._thread_root_id then
			return (a.created_at or "") < (b.created_at or "")
		end

		return tostring(a._thread_root_id) < tostring(b._thread_root_id)
	end)

	return comments
end

local function comments_for_context(ctx)
	if not state.comments then
		return {}
	end

	local comments = {}
	for _, comment in ipairs(state.comments) do
		if comment.path == ctx.path and comment_side(comment) == ctx.side and comment_line(comment) then
			table.insert(comments, comment)
		end
	end

	return comments
end

local function render_comments(bufnr, ctx)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	local comments = comments_for_context(ctx)
	state.comments_by_buf[bufnr] = {}
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	local comments_by_line = {}
	for _, comment in ipairs(comments) do
		local line = math.min(comment_line(comment), line_count)
		comment._render_line = line
		comments_by_line[line] = comments_by_line[line] or {}
		table.insert(comments_by_line[line], comment)
		state.comments_by_buf[bufnr][line] = state.comments_by_buf[bufnr][line] or {}
		table.insert(state.comments_by_buf[bufnr][line], comment)
	end

	local active_line = vim.api.nvim_get_current_buf() == bufnr and vim.api.nvim_win_get_cursor(0)[1] or nil

	for line, line_comments in pairs(comments_by_line) do
		vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
			virt_lines = comment_virt_lines(line_comments, line == active_line),
			virt_lines_above = config.comment_style == "minimal",
		})
	end
end

local function track_buffer(bufnr, ctx)
	state.render_context_by_buf[bufnr] = ctx
	if state.tracked_buffers[bufnr] then
		return
	end

	state.tracked_buffers[bufnr] = true
	vim.api.nvim_create_autocmd({ "CursorMoved", "WinEnter" }, {
		group = augroup,
		buffer = bufnr,
		callback = function()
			local render_ctx = state.render_context_by_buf[bufnr]
			if render_ctx then
				render_comments(bufnr, render_ctx)
			end
		end,
	})
end

local function file_comment_counts()
	local counts = {}
	for _, comment in ipairs(state.comments or {}) do
		if comment.path then
			counts[comment.path] = (counts[comment.path] or 0) + 1
		end
	end

	return counts
end

local function render_panel_comments()
	local ok, lib = pcall(require, "diffview.lib")
	if not ok then
		return
	end

	local view = lib.get_current_view()
	local panel = view and view.panel
	if not panel or not panel.bufid or not vim.api.nvim_buf_is_valid(panel.bufid) then
		return
	end

	local counts = file_comment_counts()
	local files = panel.ordered_file_list and panel:ordered_file_list() or {}
	local lines = vim.api.nvim_buf_get_lines(panel.bufid, 0, -1, false)
	local used_lines = {}

	vim.api.nvim_buf_clear_namespace(panel.bufid, panel_ns, 0, -1)

	for _, file in ipairs(files) do
		local count = counts[file.path]
		if count then
			for index, line in ipairs(lines) do
				if not used_lines[index] and line:find(vim.pesc(file.basename), 1, false) then
					used_lines[index] = true
					vim.api.nvim_buf_set_extmark(panel.bufid, panel_ns, index - 1, 0, {
						virt_lines = {
							{ { "   " .. count .. " comment" .. (count == 1 and "" or "s"), "DiffviewFilePanelTitle" } },
						},
						virt_lines_above = true,
					})
					break
				end
			end
		end
	end
end

current_diffview_view = function()
	local ok, lib = pcall(require, "diffview.lib")
	if not ok then
		return nil
	end

	return lib.get_current_view()
end

local function diffview_file_order(view)
	local files = view and view.panel and view.panel.ordered_file_list and view.panel:ordered_file_list() or {}
	local order = {}

	for index, file in ipairs(files) do
		if file.path then
			order[file.path] = { index = index, file = file }
		end
		if file.oldpath then
			order[file.oldpath] = { index = index, file = file }
		end
	end

	return order
end

local function comment_targets_for_view(view)
	local order = diffview_file_order(view)
	local seen = {}
	local targets = {}

	for _, comment in ipairs(state.comments or {}) do
		local line = comment_line(comment)
		local file_info = comment.path and order[comment.path]
		if line and file_info then
			local side = comment_side(comment)
			local key = table.concat({ comment.path, side, tostring(line) }, "\0")
			if not seen[key] then
				seen[key] = true
				table.insert(targets, {
					file = file_info.file,
					file_index = file_info.index,
					path = comment.path,
					side = side,
					line = line,
				})
			end
		end
	end

	table.sort(targets, function(a, b)
		if a.file_index ~= b.file_index then
			return a.file_index < b.file_index
		end

		if a.side ~= b.side then
			return a.side < b.side
		end

		return a.line < b.line
	end)

	return targets
end

local function current_comment_position(view)
	local ctx = current_diffview_context(vim.api.nvim_get_current_buf())
	if ctx then
		local order = diffview_file_order(view)
		local file_info = order[ctx.path]
		if file_info then
			return {
				file_index = file_info.index,
				path = ctx.path,
				side = ctx.side,
				line = vim.api.nvim_win_get_cursor(0)[1],
			}
		end
	end
end

local function target_after(targets, pos)
	if not pos then
		return targets[1]
	end

	for _, target in ipairs(targets) do
		if target.file_index > pos.file_index
			or (target.file_index == pos.file_index and target.side > pos.side)
			or (target.file_index == pos.file_index and target.side == pos.side and target.line > pos.line)
		then
			return target
		end
	end

	return targets[1]
end

local function target_before(targets, pos)
	if not pos then
		return targets[1]
	end

	for index = #targets, 1, -1 do
		local target = targets[index]
		if target.file_index < pos.file_index
			or (target.file_index == pos.file_index and target.side < pos.side)
			or (target.file_index == pos.file_index and target.side == pos.side and target.line < pos.line)
		then
			return target
		end
	end

	return targets[#targets]
end

local function focus_target(target)
	local view = current_diffview_view()
	if not view then
		return notify("this command can only be used from Diffview", vim.log.levels.WARN)
	end

	local function focus_loaded_target()
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
			local bufnr = vim.api.nvim_win_get_buf(win)
			if vim.b[bufnr].diffview_pr_comment_side == target.side then
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

			local ok, comments = pcall(vim.json.decode, out)
			if not ok or type(comments) ~= "table" then
				notify("could not parse PR comments", vim.log.levels.WARN)
				return
			end

			state.comments = hydrate_comment_threads(comments)
			local callbacks = state.fetch_callbacks
			state.fetch_callbacks = {}
			for _, cb in ipairs(callbacks) do
				cb()
			end
		end)
	end)
end

local function close_review_windows()
	for _, win in ipairs(state.review_windows) do
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end
	state.review_windows = {}
end

local function focus_review_window(direction)
	local wins = vim.tbl_filter(function(win)
		return vim.api.nvim_win_is_valid(win)
	end, state.review_windows)
	state.review_windows = wins

	if #wins == 0 then
		return notify("no PR review window is open", vim.log.levels.INFO)
	end

	local current = vim.api.nvim_get_current_win()
	local current_index = 1

	for index, win in ipairs(wins) do
		if win == current then
			current_index = index
			break
		end
	end

	local next_index = ((current_index + direction - 1) % #wins) + 1
	vim.api.nvim_set_current_win(wins[next_index])
end

local function open_thread_float(comments)
	local pr, pr_err = current_pr()
	if not pr then
		return notify(pr_err, vim.log.levels.ERROR)
	end

	local width = math.floor(vim.o.columns * 0.92)
	local height = math.floor(vim.o.lines * 0.86)
	local diff_height = math.max(8, math.floor(height * 0.36))
	local reply_height = 8
	local comments_height = math.max(8, height - diff_height - reply_height - 4)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)
	local wins = {}
	local temp_path = vim.fn.tempname() .. ".md"
	local root_id = comments[1] and (comments[1]._thread_root_id or comments[1].in_reply_to_id or comments[1].id)

	local function open_panel(buf, panel_row, panel_height, title, enter)
		local win = vim.api.nvim_open_win(buf, enter, {
			relative = "editor",
			row = panel_row,
			col = col,
			width = width,
			height = panel_height,
			style = "minimal",
			border = "rounded",
			title = " " .. title .. " ",
			title_pos = "center",
		})
		vim.wo[win].winhighlight = "Normal:Normal,NormalFloat:Normal"
		vim.wo[win].wrap = true
		table.insert(wins, win)
		return win
	end

	local diff_buf = vim.api.nvim_create_buf(false, true)
	local diff_lines = comments[1] and vim.split(comments[1].diff_hunk or "", "\n", { plain = true }) or {}
	if #diff_lines == 0 then
		diff_lines = { "No diff preview available" }
	end
	vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, diff_lines)
	vim.bo[diff_buf].bufhidden = "wipe"
	vim.bo[diff_buf].filetype = "diff"
	vim.bo[diff_buf].modifiable = false
	open_panel(diff_buf, row, diff_height, "Diff", false)

	local thread_buf = vim.api.nvim_create_buf(false, true)
	local thread_lines = {}

	for i, comment in ipairs(comments) do
		local user = comment.user and comment.user.login or "unknown"
		table.insert(thread_lines, string.format("%s commented:", user))
		vim.list_extend(thread_lines, vim.split(comment.body or "", "\n", { plain = true }))
		if i ~= #comments then
			table.insert(thread_lines, "")
			table.insert(thread_lines, string.rep("-", 32))
			table.insert(thread_lines, "")
		end
	end

	vim.api.nvim_buf_set_lines(thread_buf, 0, -1, false, thread_lines)
	vim.bo[thread_buf].bufhidden = "wipe"
	vim.bo[thread_buf].filetype = "markdown"
	vim.bo[thread_buf].modifiable = false
	open_panel(thread_buf, row + diff_height + 2, comments_height, "Thread", false)

	local reply_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(reply_buf, temp_path)
	vim.bo[reply_buf].buftype = "acwrite"
	vim.bo[reply_buf].bufhidden = "wipe"
	vim.bo[reply_buf].filetype = "markdown"
	vim.bo[reply_buf].swapfile = false
	open_panel(reply_buf, row + diff_height + comments_height + 4, reply_height, "Reply", true)
	state.review_windows = wins

	local function cleanup_temp_file()
		if vim.uv.fs_stat(temp_path) then
			vim.fn.delete(temp_path)
		end
	end

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = reply_buf,
		once = true,
		callback = function()
			cleanup_temp_file()
			close_review_windows()
		end,
	})

	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = reply_buf,
		callback = function()
			local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(reply_buf, 0, -1, false), "\n"))
			if body == "" then
				notify("reply body is empty", vim.log.levels.WARN)
				return
			end

			if M.submit({ pr_number = pr.number, reply_to_id = root_id, body = body }) then
				cleanup_temp_file()
				vim.bo[reply_buf].modified = false
			end
		end,
	})

end

local function open_comment_float(comment, title)
	local temp_path = vim.fn.tempname() .. ".md"
	local width = math.min(88, math.floor(vim.o.columns * 0.75))
	local height = math.min(18, math.floor(vim.o.lines * 0.45))
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " " .. (title or "PR comment") .. " ",
		title_pos = "center",
	})

	vim.api.nvim_buf_set_name(buf, temp_path)
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].swapfile = false
	vim.wo[win].winhighlight = "Normal:Normal,NormalFloat:Normal"
	vim.wo[win].wrap = true

	local function cleanup_temp_file()
		if vim.uv.fs_stat(temp_path) then
			vim.fn.delete(temp_path)
		end
	end

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = cleanup_temp_file,
	})

	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
			if body == "" then
				notify("comment body is empty", vim.log.levels.WARN)
				return
			end

			comment.body = body
			if M.submit(comment) then
				cleanup_temp_file()
				vim.bo[buf].modified = false
			end
		end,
	})

end

local function open_reply_float(parent_comment)
	open_thread_float({ parent_comment })
end

local function open_review_float(config)
	local temp_path = vim.fn.tempname() .. ".md"
	local width = math.min(88, math.floor(vim.o.columns * 0.75))
	local height = math.min(12, math.floor(vim.o.lines * 0.3))
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)
	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " " .. config.title .. " ",
		title_pos = "center",
	})

	vim.api.nvim_buf_set_name(buf, temp_path)
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].swapfile = false
	vim.wo[win].winhighlight = "Normal:Normal,NormalFloat:Normal"
	vim.wo[win].wrap = true

	if config.placeholder then
		vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
			virt_lines = { { { config.placeholder, "Comment" } } },
			virt_lines_above = true,
		})
	end

	local function cleanup_temp_file()
		if vim.uv.fs_stat(temp_path) then
			vim.fn.delete(temp_path)
		end
	end

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = cleanup_temp_file,
	})

	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			local body = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
			if config.require_body and body == "" then
				notify("a reason is required for " .. config.title, vim.log.levels.WARN)
				return
			end

			if config.submit_fn(body) then
				cleanup_temp_file()
				vim.bo[buf].modified = false
			end
		end,
	})

end

function M.setup(opts)
	config = config_module.setup(opts)
	setup_highlights()

	if config.comment_style ~= "minimal" and config.comment_style ~= "expanded" then
		notify("invalid comment_style: " .. tostring(config.comment_style), vim.log.levels.WARN)
		config.comment_style = defaults.comment_style
	end
end

function M.open(line1, line2)
	local head, head_err = ensure_remote_contains_head()
	if not head then
		return notify(head_err, vim.log.levels.ERROR)
	end

	local ctx, ctx_err = current_diffview_context()
	if not ctx then
		return notify(ctx_err, vim.log.levels.ERROR)
	end

	local pr, pr_err = current_pr()
	if not pr then
		return notify(pr_err, vim.log.levels.ERROR)
	end

	open_comment_float({
		commit_id = head,
		pr_number = pr.number,
		pr_url = pr.url,
		path = ctx.path,
		side = ctx.side,
		start_line = math.min(line1, line2),
		line = math.max(line1, line2),
	})
end

function M.submit(comment)
	if comment.reply_to_id then
		local _, err = gh({
			"api",
			"repos/{owner}/{repo}/pulls/" .. comment.pr_number .. "/comments/" .. comment.reply_to_id .. "/replies",
			"-f",
			"body=" .. comment.body,
		})
		if err then
			notify(err, vim.log.levels.ERROR)
			return false
		end

		notify("reply created on " .. pr_display_name(comment.pr_number))
		state.comments = nil
		return true
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

	local _, err = gh(args)
	if err then
		notify(err, vim.log.levels.ERROR)
		return false
	end

	notify("comment created on " .. pr_display_name(comment.pr_number))
	state.comments = nil
	return true
end

function M.pr_display_name(pr_or_number)
	return pr_display_name(pr_or_number)
end

function M.approve()
	local head, head_err = ensure_remote_contains_head()
	if not head then
		return notify(head_err, vim.log.levels.ERROR)
	end

	local pr, pr_err = current_pr()
	if not pr then
		return notify(pr_err, vim.log.levels.ERROR)
	end

	open_review_float({
		title = "Approve " .. pr_display_name(pr),
		placeholder = "Leave an optional approval message...",
		require_body = false,
		submit_fn = function(body)
			local args = { "pr", "review", tostring(pr.number), "--approve" }
			if body and body ~= "" then
				vim.list_extend(args, { "--body", body })
			end
			local _, err = gh(args)
			if err then
				notify(err, vim.log.levels.ERROR)
				return false
			end
			notify("Approved " .. pr_display_name(pr))
			state.comments = nil
			return true
		end,
	})
end

function M.request_changes()
	local head, head_err = ensure_remote_contains_head()
	if not head then
		return notify(head_err, vim.log.levels.ERROR)
	end

	local pr, pr_err = current_pr()
	if not pr then
		return notify(pr_err, vim.log.levels.ERROR)
	end

	open_review_float({
		title = "Request Changes on " .. pr_display_name(pr),
		placeholder = "Explain what needs to change...",
		require_body = true,
		submit_fn = function(body)
			local _, err = gh({ "pr", "review", tostring(pr.number), "--request-changes", "--body", body })
			if err then
				notify(err, vim.log.levels.ERROR)
				return false
			end
			notify("Requested changes on " .. pr_display_name(pr))
			state.comments = nil
			return true
		end,
	})
end

function M.close_pr()
	local pr, pr_err = current_pr()
	if not pr then
		return notify(pr_err, vim.log.levels.ERROR)
	end

	open_review_float({
		title = "Close " .. pr_display_name(pr),
		placeholder = "Leave an optional comment...",
		require_body = false,
		submit_fn = function(body)
			local args = { "pr", "close", tostring(pr.number) }
			if body and body ~= "" then
				vim.list_extend(args, { "--comment", body })
			end
			local _, err = gh(args)
			if err then
				notify(err, vim.log.levels.ERROR)
				return false
			end
			notify("Closed " .. pr_display_name(pr))
			state.comments = nil
			state.pr = nil
			return true
		end,
	})
end

function M.attach_diffview_buffer(bufnr, ctx)
	attach_diffview_context(bufnr, ctx)

	vim.defer_fn(function()
		local ctx, ctx_err = current_diffview_context(bufnr)
		if not ctx then
			return notify(ctx_err, vim.log.levels.WARN)
		end

		track_buffer(bufnr, ctx)
		fetch_comments(function()
			if state.pr and not state.notified_pr then
				notify(pr_display_name(state.pr) .. " associated with this branch")
				state.notified_pr = true
			end

			render_comments(bufnr, ctx)
			render_panel_comments()
		end)
	end, 100)
end

function M.diff_buf_win_enter(bufnr, _, ctx)
	register_diffview_help_keymaps()
	setup_buffer_keymaps(bufnr)
	setup_panel_keymaps()
	M.attach_diffview_buffer(bufnr, ctx)
end

function M.clear_buffer(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		state.comments_by_buf[bufnr] = nil
		state.render_context_by_buf[bufnr] = nil
		state.tracked_buffers[bufnr] = nil
	end
end

function M.debug_state()
	local ok, lib = pcall(require, "diffview.lib")
	local view = ok and lib.get_current_view() or nil
	local panel = view and view.panel
	local panel_marks = {}
	if panel and panel.bufid and vim.api.nvim_buf_is_valid(panel.bufid) then
		panel_marks = vim.api.nvim_buf_get_extmarks(panel.bufid, panel_ns, 0, -1, { details = true })
	end

	local diff_buffers = {}
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.b[bufnr].diffview_pr_comment_side then
			table.insert(diff_buffers, {
				bufnr = bufnr,
				name = vim.api.nvim_buf_get_name(bufnr),
				side = vim.b[bufnr].diffview_pr_comment_side,
				markers = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true }),
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

function M.refresh()
	state.comments = nil
	local ok, lib = pcall(require, "diffview.lib")
	if not ok or not lib.get_current_view() then
		return notify("this command can only be used from Diffview", vim.log.levels.WARN)
	end

	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) and vim.b[bufnr].diffview_pr_comment_side then
			vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		end
	end

	local ok_view, lib = pcall(require, "diffview.lib")
	local panel = ok_view and lib.get_current_view() and lib.get_current_view().panel
	if panel and panel.bufid and vim.api.nvim_buf_is_valid(panel.bufid) then
		vim.api.nvim_buf_clear_namespace(panel.bufid, panel_ns, 0, -1)
	end

	M.attach_diffview_buffer(vim.api.nvim_get_current_buf())
end

function M.show_comments_at_cursor()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local comments = state.comments_by_buf[bufnr] and state.comments_by_buf[bufnr][line] or {}

	if #comments == 0 then
		return notify("no PR comments on this line", vim.log.levels.INFO)
	end

	open_thread_float(comments)
end

function M.open_comments_at_cursor_or_enter()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]

	if state.comments_by_buf[bufnr] and state.comments_by_buf[bufnr][line] then
		M.show_comments_at_cursor()
		return
	end

	local keys = vim.api.nvim_replace_termcodes("<CR>", true, false, true)
	vim.api.nvim_feedkeys(keys, "n", false)
end

local function navigate_comment(direction)
	fetch_comments(function()
		local view = current_diffview_view()
		if not view then
			return notify("this command can only be used from Diffview", vim.log.levels.WARN)
		end

		local targets = comment_targets_for_view(view)
		if #targets == 0 then
			return notify("no PR comments in this Diffview", vim.log.levels.INFO)
		end

		local pos = current_comment_position(view)
		local target = direction > 0 and target_after(targets, pos) or target_before(targets, pos)
		focus_target(target)
	end)
end

function M.next_comment()
	navigate_comment(1)
end

function M.previous_comment()
	navigate_comment(-1)
end

function M.reply_to_comment_at_cursor()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local comments = state.comments_by_buf[bufnr] and state.comments_by_buf[bufnr][line] or {}

	if #comments == 0 then
		return notify("no PR comments on this line", vim.log.levels.INFO)
	end

	open_reply_float(comments[1])
end

function M.close_review_windows()
	close_review_windows()
end

function M.next_review_window()
	focus_review_window(1)
end

function M.previous_review_window()
	focus_review_window(-1)
end

commands.register(M)
setup_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = augroup,
	callback = setup_highlights,
})

return M
