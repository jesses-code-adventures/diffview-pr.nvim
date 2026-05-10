local M = {}
local config = require("diffview_pr.config").values
local state = require("diffview_pr.state")
local comments = require("diffview_pr.comments")

M.ns = vim.api.nvim_create_namespace("diffview_pr_comments")
M.panel_ns = vim.api.nvim_create_namespace("diffview_pr_comment_panel")
local ns = M.ns
local panel_ns = M.panel_ns
local augroup = vim.api.nvim_create_augroup("diffview_pr", { clear = false })

local function inline_comment_lines(comment_list, active)
	local lines = {}
	local header_hl = active and "DiffviewPRCommentActive" or "DiffviewFilePanelTitle"
	local body_hl = active and "DiffviewPRCommentActive" or "Comment"

	for index, comment in ipairs(comment_list) do
		table.insert(lines, { { "  " .. comments.author(comment) .. " commented:", header_hl } })

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

local function minimal_comment_lines(comment_list, active)
	local first = comment_list[1]
	local username = first and comments.author(first) or "someone"
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
	return { { { "  " .. username .. " commented" .. suffix .. "...", hl } } }
end

local function comment_virt_lines(comment_list, active)
	if config.comment_style == "minimal" then
		return minimal_comment_lines(comment_list, active)
	end

	return inline_comment_lines(comment_list, active)
end

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
		local line = math.min(comments.line(comment), line_count)
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

local function file_comment_counts()
	local counts = {}
	for _, comment in ipairs(state.comments or {}) do
		if comment.path then
			counts[comment.path] = (counts[comment.path] or 0) + 1
		end
	end

	return counts
end

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
