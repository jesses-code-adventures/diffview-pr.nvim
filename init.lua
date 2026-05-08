local M = {}

local ns = vim.api.nvim_create_namespace("diffview_pr_comments")
local panel_ns = vim.api.nvim_create_namespace("diffview_pr_comment_panel")
local state = {
	pr = nil,
	comments = nil,
	comments_by_buf = {},
	pr_fetching = false,
	pr_callbacks = {},
	fetching = false,
	fetch_callbacks = {},
	notified_pr = false,
}

local function notify(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Diffview PR Comment" })
end

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

local function git(args)
	local cmd = { "git" }
	vim.list_extend(cmd, args)
	return system(cmd)
end

local function gh(args)
	local cmd = { "gh" }
	vim.list_extend(cmd, args)
	return system(cmd)
end

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

local function current_diffview_context()
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

	local side = vim.b.diffview_pr_comment_side
	if side ~= "LEFT" and side ~= "RIGHT" then
		return nil, "focus a Diffview diff buffer before commenting"
	end

	local path = side == "LEFT" and (file.oldpath or file.path) or file.path
	if not path or path == "" then
		return nil, "could not determine the current Diffview path"
	end

	return { side = side, path = path }
end

local function current_pr()
	if state.pr then
		return state.pr
	end

	local out, err = gh({ "pr", "view", "--json", "number,url" })
	if not out then
		return nil, err
	end

	local ok, pr = pcall(vim.json.decode, out)
	if not ok or not pr.number then
		return nil, "could not parse `gh pr view` output"
	end

	state.pr = pr
	return pr
end

local function gh_async(args, callback)
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
				cb(nil, err)
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

	for line, line_comments in pairs(comments_by_line) do
		local first = line_comments[1]
		local username = first.user and first.user.login or "someone"
		local other_users = {}
		for _, comment in ipairs(line_comments) do
			local comment_user = comment.user and comment.user.login or "someone"
			if comment_user ~= username then
				other_users[comment_user] = true
			end
		end

		local others = vim.tbl_count(other_users)
		local suffix = others == 0 and "" or " (and " .. others .. " other" .. (others == 1 and "" or "s") .. ")"
		vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, {
			virt_lines = {
				{ { "  " .. username .. " commented" .. suffix .. "...", "DiffviewFilePanelTitle" } },
			},
			virt_lines_above = true,
		})
	end
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
	current_pr_async(function(pr, pr_err)
		if not pr then
			state.fetching = false
			notify(pr_err, vim.log.levels.WARN)
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

	local function close_review_windows()
		for _, win in ipairs(wins) do
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end
	end

	local function focus_review_window(direction)
		local current = vim.api.nvim_get_current_win()
		local current_index = 1

		for index, win in ipairs(wins) do
			if win == current then
				current_index = index
				break
			end
		end

		local next_index = ((current_index + direction - 1) % #wins) + 1
		local next_win = wins[next_index]
		if next_win and vim.api.nvim_win_is_valid(next_win) then
			vim.api.nvim_set_current_win(next_win)
		end
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

	local function cleanup_temp_file()
		if vim.uv.fs_stat(temp_path) then
			vim.fn.delete(temp_path)
		end
	end

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = reply_buf,
		once = true,
		callback = cleanup_temp_file,
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
				close_review_windows()
			end
		end,
	})

	for _, buf in ipairs({ diff_buf, thread_buf, reply_buf }) do
		vim.keymap.set("n", "q", close_review_windows, { buffer = buf, desc = "Close PR review" })
		vim.keymap.set("n", "<C-w>j", function() focus_review_window(1) end,
			{ buffer = buf, desc = "Next PR review pane" })
		vim.keymap.set("n", "<C-w><Down>", function() focus_review_window(1) end,
			{ buffer = buf, desc = "Next PR review pane" })
		vim.keymap.set("n", "<C-w>l", function() focus_review_window(1) end,
			{ buffer = buf, desc = "Next PR review pane" })
		vim.keymap.set("n", "<C-w><Right>", function() focus_review_window(1) end,
			{ buffer = buf, desc = "Next PR review pane" })
		vim.keymap.set("n", "<C-w>k", function() focus_review_window(-1) end,
			{ buffer = buf, desc = "Previous PR review pane" })
		vim.keymap.set("n", "<C-w><Up>", function() focus_review_window(-1) end,
			{ buffer = buf, desc = "Previous PR review pane" })
		vim.keymap.set("n", "<C-w>h", function() focus_review_window(-1) end,
			{ buffer = buf, desc = "Previous PR review pane" })
		vim.keymap.set("n", "<C-w><Left>", function() focus_review_window(-1) end,
			{ buffer = buf, desc = "Previous PR review pane" })
	end

	vim.cmd.startinsert()
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

	vim.api.nvim_buf_create_user_command(buf, "Wq", function()
		vim.cmd.write()
		vim.cmd.quit()
	end, {})

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

	vim.cmd.startinsert()
end

local function open_reply_float(parent_comment)
	open_thread_float({ parent_comment })
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

		notify("reply created on PR #" .. comment.pr_number)
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

	notify("comment created on PR #" .. comment.pr_number)
	state.comments = nil
	return true
end

function M.attach_diffview_buffer(bufnr)
	local ctx, ctx_err = current_diffview_context()
	if not ctx then
		return notify(ctx_err, vim.log.levels.WARN)
	end

	vim.defer_fn(function()
		fetch_comments(function()
			if state.pr and not state.notified_pr then
				notify("PR #" .. state.pr.number .. " associated with this branch")
				state.notified_pr = true
			end

			render_comments(bufnr, ctx)
			render_panel_comments()
		end)
	end, 100)
end

function M.clear_buffer(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		state.comments_by_buf[bufnr] = nil
	end
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

function M.reply_to_comment_at_cursor()
	local bufnr = vim.api.nvim_get_current_buf()
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local comments = state.comments_by_buf[bufnr] and state.comments_by_buf[bufnr][line] or {}

	if #comments == 0 then
		return notify("no PR comments on this line", vim.log.levels.INFO)
	end

	open_reply_float(comments[1])
end

return M

