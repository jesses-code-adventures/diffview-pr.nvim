local M = {}
local config = require("diffview_pr.config").values
local state = require("diffview_pr.state")
local comments = require("diffview_pr.comments")

M.ns = vim.api.nvim_create_namespace("diffview_pr_comments")
M.panel_ns = vim.api.nvim_create_namespace("diffview_pr_comment_panel")
local ns = M.ns
local panel_ns = M.panel_ns
local augroup = vim.api.nvim_create_augroup("diffview_pr", { clear = false })
local deps = {}

---@alias DiffviewPRVirtTextChunk [string, string]
---@alias DiffviewPRVirtLine DiffviewPRVirtTextChunk[]

---@param comment_list DiffviewPRComment[]
---@param active boolean
---@return DiffviewPRVirtLine[]
local function inline_comment_lines(comment_list, active)
	local lines = {}
	local header_hl = active and "DiffviewPRCommentActive" or "DiffviewFilePanelTitle"
	local body_hl = active and "DiffviewPRCommentActive" or "Comment"

	for index, comment in ipairs(comment_list) do
		table.insert(lines, { { "  " .. comments.author_with_timestamp(comment) .. " commented:", header_hl } })

		local body_lines = vim.split(comment.body or "", "\n", { plain = true })
		if #body_lines == 0 then
			body_lines = { "" }
		end

		for _, body_line in ipairs(body_lines) do
			table.insert(lines, { { "  " .. body_line, body_hl } })
		end

		if index ~= #comment_list then
			table.insert(lines, { { "", body_hl } })
		end
	end

	return lines
end

---@param comment_list DiffviewPRComment[]
---@param active boolean
---@return DiffviewPRVirtLine[]
local function minimal_comment_lines(comment_list, active)
	local first = comment_list[1]
	local username = first and comments.author(first) or "someone"
	local display_name = first and comments.author_with_timestamp(first) or "someone"
	local other_users = {}

	for _, comment in ipairs(comment_list) do
		local user = comments.author(comment)
		if user ~= username then
			other_users[user] = true
		end
	end

	local others = vim.tbl_count(other_users)
	local suffix = others == 0 and "" or " (and " .. others .. " other" .. (others == 1 and "" or "s") .. ")"
	local hl = active and "DiffviewPRCommentActive" or "DiffviewFilePanelTitle"
	return { { { "  " .. display_name .. " commented" .. suffix .. "...", hl } } }
end

---@param comment_list DiffviewPRComment[]
---@param active boolean
---@return DiffviewPRVirtLine[]
local function comment_virt_lines(comment_list, active)
	if config.comment_style == "minimal" then
		return minimal_comment_lines(comment_list, active)
	end

	return inline_comment_lines(comment_list, active)
end

---@param virt_lines DiffviewPRVirtLine[]
---@return table
local function comment_extmark_opts(virt_lines)
	local position = config.virtual_text_position == "inline" and "eol" or "overlay"
	local opts = {
		virt_text = virt_lines[1],
		virt_text_pos = position,
	}

	if #virt_lines > 1 then
		opts.virt_lines = vim.list_slice(virt_lines, 2)
	end

	return opts
end

---@param bufnr integer
---@return nil
local function rerender_buffer(bufnr)
	local render_ctx = state.render_context_by_buf[bufnr]
	if render_ctx then
		M.render_comments(bufnr, render_ctx)
	end
end

---@param winid integer
---@return integer
local function textoff(winid)
	return vim.api.nvim_win_call(winid, function()
		return vim.fn.getwininfo(winid)[1].textoff
	end)
end

---@param bufnr integer
---@param ctx DiffviewPRContext
function M.render_comments(bufnr, ctx)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	local line_comments = comments.for_context(ctx)
	state.comments_by_buf[bufnr] = {}
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	local comments_by_line = {}
	for _, comment in ipairs(line_comments) do
		local line = math.min(comments.line(comment) or 1, line_count)
		comment._render_line = line
		comments_by_line[line] = comments_by_line[line] or {}
		table.insert(comments_by_line[line], comment)
		state.comments_by_buf[bufnr][line] = state.comments_by_buf[bufnr][line] or {}
		table.insert(state.comments_by_buf[bufnr][line], comment)
	end

	local active_line = vim.api.nvim_get_current_buf() == bufnr and vim.api.nvim_win_get_cursor(0)[1] or nil

	for line, line_comments in pairs(comments_by_line) do
		vim.api.nvim_buf_set_extmark(bufnr, ns, line - 1, 0, comment_extmark_opts(comment_virt_lines(line_comments, line == active_line)))
	end
end

---@param opts table?
---@return nil
function M.setup(opts)
	deps = opts or {}
end

---@param reply DiffviewPRInlineReply?
---@return nil
local function close_inline_reply(reply)
	reply = reply or state.inline_reply
	if not reply then
		return
	end
	state.inline_reply = nil
	if vim.api.nvim_win_is_valid(reply.winid) then
		vim.api.nvim_win_close(reply.winid, true)
	end
	if vim.api.nvim_buf_is_valid(reply.input_bufnr) then
		vim.api.nvim_buf_delete(reply.input_bufnr, { force = true })
	end
	if vim.uv.fs_stat(reply.temp_path) then
		vim.fn.delete(reply.temp_path)
	end
	rerender_buffer(reply.bufnr)
end

---@param reply DiffviewPRInlineReply
---@return nil
local function resize_inline_reply(reply)
	if not vim.api.nvim_win_is_valid(reply.winid) or not vim.api.nvim_buf_is_valid(reply.input_bufnr) then
		return
	end

	local source_win = vim.fn.bufwinid(reply.bufnr)
	if source_win == -1 then
		return
	end

	local source_winline = vim.api.nvim_win_call(source_win, function()
		return vim.fn.winline()
	end)
	local col = textoff(source_win)
	local height = math.max(1, vim.api.nvim_buf_line_count(reply.input_bufnr))
	local max_height = math.max(1, vim.api.nvim_win_get_height(source_win) - source_winline)
	vim.api.nvim_win_set_config(reply.winid, {
		relative = "win",
		win = source_win,
		row = source_winline + #inline_comment_lines(reply.comments, true),
		col = col,
		width = math.max(1, vim.api.nvim_win_get_width(source_win) - col - 2),
		height = math.min(height, max_height),
	})
end

---@param reply DiffviewPRInlineReply
---@return string
local function inline_reply_body(reply)
	if not vim.api.nvim_buf_is_valid(reply.input_bufnr) then
		return ""
	end
	return vim.trim(table.concat(vim.api.nvim_buf_get_lines(reply.input_bufnr, 0, -1, false), "\n"))
end

---@param reply DiffviewPRInlineReply
---@param body string
---@return nil
local function submit_inline_reply_body(reply, body)
	close_inline_reply(reply)
	if body == "" or not deps.submit or not state.pr then
		return
	end

	local parent = reply.comments[1]
	deps.submit({
		pr_number = state.pr.number,
		body = body,
		reply_to_id = parent._thread_root_id or parent.in_reply_to_id or parent.id,
	}, function()
		rerender_buffer(reply.bufnr)
	end)
end

---@param reply DiffviewPRInlineReply
---@return nil
local function submit_inline_reply(reply)
	submit_inline_reply_body(reply, inline_reply_body(reply))
end

---@param bufnr integer
---@param line integer
---@param comment_list DiffviewPRComment[]
---@param title? string
---@return nil
function M.start_inline_reply(bufnr, line, comment_list, title)
	if config.comment_style ~= "expanded" then
		return
	end
	if state.inline_reply then
		close_inline_reply(state.inline_reply)
	end
	local source_win = vim.fn.bufwinid(bufnr)
	if source_win == -1 then
		return
	end

	local temp_path = vim.fn.tempname() .. ".md"
	local input_bufnr = vim.api.nvim_create_buf(false, false)
	vim.api.nvim_buf_set_name(input_bufnr, temp_path)
	vim.bo[input_bufnr].buftype = "acwrite"
	vim.bo[input_bufnr].bufhidden = "wipe"
	vim.bo[input_bufnr].filetype = "markdown"
	vim.bo[input_bufnr].swapfile = false
	vim.api.nvim_buf_set_lines(input_bufnr, 0, -1, false, { "" })

	state.inline_reply = {
		bufnr = bufnr,
		line = line,
		comments = comment_list,
		input_bufnr = input_bufnr,
		winid = -1,
		title = title or "Reply",
		temp_path = temp_path,
	}

	local reply = state.inline_reply
	local col = textoff(source_win)
	reply.winid = vim.api.nvim_open_win(input_bufnr, true, {
		relative = "win",
		win = source_win,
		row = vim.fn.winline() + #inline_comment_lines(comment_list, true),
		col = col,
		width = math.max(1, vim.api.nvim_win_get_width(source_win) - col - 2),
		height = 1,
		style = "minimal",
		border = "rounded",
		title = " " .. reply.title .. " ",
		title_pos = "center",
		zindex = 60,
	})
	vim.wo[reply.winid].wrap = true
	vim.wo[reply.winid].number = false
	vim.wo[reply.winid].relativenumber = false
	vim.wo[reply.winid].signcolumn = "no"
	vim.wo[reply.winid].winhighlight = "Normal:Normal,EndOfBuffer:Normal"

	vim.keymap.set({ "n", "i" }, "<C-s>", function()
		submit_inline_reply(reply)
	end, { buffer = input_bufnr, desc = "Submit PR reply" })
	vim.keymap.set({ "n", "i" }, "<C-c>", function()
		close_inline_reply(reply)
	end, { buffer = input_bufnr, desc = "Cancel PR reply" })
	vim.keymap.set("n", "q", function()
		close_inline_reply(reply)
	end, { buffer = input_bufnr, desc = "Cancel PR reply" })
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = augroup,
		buffer = input_bufnr,
		callback = function()
			local body = inline_reply_body(reply)
			vim.bo[input_bufnr].modified = false
			vim.schedule(function()
				submit_inline_reply_body(reply, body)
			end)
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = augroup,
		buffer = input_bufnr,
		callback = function()
			resize_inline_reply(reply)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = augroup,
		buffer = input_bufnr,
		once = true,
		callback = function()
			if state.inline_reply == reply then
				state.inline_reply = nil
			end
			if vim.uv.fs_stat(reply.temp_path) then
				vim.fn.delete(reply.temp_path)
			end
		end,
	})

	vim.cmd("startinsert")
end

---@param bufnr integer
---@param ctx DiffviewPRContext
function M.track_buffer(bufnr, ctx)
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
				M.render_comments(bufnr, render_ctx)
			end
		end,
	})
end

---@return table<string, integer>
local function file_comment_counts()
	local counts = {}
	for _, comment in ipairs(state.comments or {}) do
		if comment.path then
			counts[comment.path] = (counts[comment.path] or 0) + 1
		end
	end

	return counts
end

---@return nil
function M.render_panel_comments()
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

return M
