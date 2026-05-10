local M = {}
local state = require("diffview_pr_comment.state")
local diffview = require("diffview_pr_comment.diffview")

function M.pr_display_name(pr_or_number)
	local number = type(pr_or_number) == "table" and pr_or_number.number or pr_or_number
	return "PR #" .. tostring(number)
end

function M.line(comment)
	return comment.line or comment.original_line
end

function M.side(comment)
	return comment.side or comment.original_side or "RIGHT"
end

function M.author(comment)
	return comment.user and comment.user.login or "unknown"
end

function M.hydrate_threads(comments)
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

function M.for_context(ctx)
	if not state.comments then
		return {}
	end

	local comments = {}
	for _, comment in ipairs(state.comments) do
		if comment.path == ctx.path and M.side(comment) == ctx.side and M.line(comment) then
			table.insert(comments, comment)
		end
	end

	return comments
end

function M.file_order(view)
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

function M.targets_for_view(view)
	local order = M.file_order(view)
	local seen = {}
	local targets = {}

	for _, comment in ipairs(state.comments or {}) do
		local line = M.line(comment)
		local file_info = comment.path and order[comment.path]
		if line and file_info then
			local side = M.side(comment)
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

function M.current_position(view)
	local ctx = diffview.current_context(vim.api.nvim_get_current_buf())
	if ctx then
		local order = M.file_order(view)
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

function M.target_after(targets, pos)
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

function M.target_before(targets, pos)
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

return M
