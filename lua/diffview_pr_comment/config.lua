local M = {}

M.defaults = {
	comment_style = "minimal",
	keymaps = {
		enabled = true,
		create_comment = "<leader>pc",
		show_comments = "<leader>po",
		open_comments_or_enter = "<CR>",
		reply = "<leader>pR",
		refresh = "<leader>pf",
		next_comment = "]r",
		previous_comment = "[r",
		approve = "<leader>pa",
		request_changes = "<leader>pr",
		close_pr = "<leader>px",
		close_review_windows = "<leader>pq",
		next_review_window = "<leader>pn",
		previous_review_window = "<leader>pp",
	},
}

M.values = vim.deepcopy(M.defaults)

function M.setup(opts)
	local values = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
	for key in pairs(M.values) do
		M.values[key] = nil
	end
	for key, value in pairs(values) do
		M.values[key] = value
	end
	return M.values
end

return M
