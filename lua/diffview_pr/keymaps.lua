local M = {}
local config = require("diffview_pr.config").values
local state = require("diffview_pr.state")
local diffview = require("diffview_pr.diffview")

local function set_keymap(mode, lhs, rhs, bufnr, desc)
	if not lhs or lhs == false then
		return
	end

	vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
end

function M.setup_buffer(bufnr)
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
		local view = diffview.current_view()
		local layout = view and view.cur_layout and view.cur_layout.name or "diff2"
		local layout_group = layout:match("^(diff%d)") or "diff2"
		if ok then
			actions.help({ "view", layout_group, "diffview_pr" })()
		end
	end, bufnr, "Open the help panel")
end

function M.setup_panel()
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

function M.register_diffview_help()
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

return M
