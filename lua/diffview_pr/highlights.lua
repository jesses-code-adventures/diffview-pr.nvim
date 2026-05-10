local M = {}

function M.setup()
	local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
	local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
	local cursor_line = vim.api.nvim_get_hl(0, { name = "CursorLine", link = false })

	vim.api.nvim_set_hl(0, "DiffviewPRCommentActive", {
		fg = comment.fg or normal.fg,
		bg = cursor_line.bg or normal.bg,
	})
end

return M
