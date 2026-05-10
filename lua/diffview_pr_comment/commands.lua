local M = {}

function M.register(plugin)
	vim.api.nvim_create_user_command("DiffviewPRComment", function(opts)
		plugin.open(opts.line1, opts.line2)
	end, { range = true, force = true })
	vim.api.nvim_create_user_command("DiffviewPRShowComments", plugin.show_comments_at_cursor, { force = true })
	vim.api.nvim_create_user_command("DiffviewPROpenCommentsOrEnter", plugin.open_comments_at_cursor_or_enter, { force = true })
	vim.api.nvim_create_user_command("DiffviewPRReply", plugin.reply_to_comment_at_cursor, { force = true })
	vim.api.nvim_create_user_command("DiffviewPRRefresh", plugin.refresh, { force = true })
	vim.api.nvim_create_user_command("DiffviewPRNextComment", plugin.next_comment, { force = true })
	vim.api.nvim_create_user_command("DiffviewPRPreviousComment", plugin.previous_comment, { force = true })
	vim.api.nvim_create_user_command("DiffviewPRDebugState", plugin.debug_state, { force = true })
	vim.api.nvim_create_user_command("DiffviewPRReviewApprove", plugin.approve, { force = true })
	vim.api.nvim_create_user_command("DiffviewPRReviewRequestChanges", plugin.request_changes, { force = true })
	vim.api.nvim_create_user_command("DiffviewPRReviewClose", plugin.close_pr, { force = true })
	vim.api.nvim_create_user_command("DiffviewPRCloseReviewWindows", plugin.close_review_windows, { force = true })
	vim.api.nvim_create_user_command("DiffviewPRNextReviewWindow", plugin.next_review_window, { force = true })
	vim.api.nvim_create_user_command("DiffviewPRPreviousReviewWindow", plugin.previous_review_window, { force = true })
end

return M
