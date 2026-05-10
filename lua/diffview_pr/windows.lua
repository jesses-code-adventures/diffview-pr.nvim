local M = {}
local state = require("diffview_pr.state")
local notify = require("diffview_pr.notify")
local ns = require("diffview_pr.renderer").ns
local deps = {}

function M.setup(opts)
	deps = opts or {}
end

function M.close_review()
	for _, win in ipairs(state.review_windows) do
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end
	state.review_windows = {}
end

function M.focus_review(direction)
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

function M.open_thread(comments)
	deps.current_pr(function(pr, pr_err)
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
			M.close_review()
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

			vim.bo[reply_buf].modified = false
			cleanup_temp_file()
			deps.submit({ pr_number = pr.number, reply_to_id = root_id, body = body }, function(success)
				if not success then
					return
				end
			end)
		end,
	})
	end)
end

function M.open_comment(comment, title)
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
			vim.bo[buf].modified = false
			cleanup_temp_file()
			deps.submit(comment, function(success)
				if not success then
					return
				end
			end)
		end,
	})

end

function M.open_reply(parent_comment)
	M.open_thread({ parent_comment })
end

function M.open_review(config)
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

			vim.bo[buf].modified = false
			cleanup_temp_file()
			config.submit_fn(body, function(success)
				if not success then
					return
				end
			end)
		end,
	})

end

return M
