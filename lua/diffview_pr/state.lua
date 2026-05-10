---@class DiffviewPRConfigKeymaps
---@field enabled boolean
---@field create_comment string|false
---@field show_comments string|false
---@field open_comments_or_enter string|false
---@field reply string|false
---@field refresh string|false
---@field next_comment string|false
---@field previous_comment string|false
---@field approve string|false
---@field request_changes string|false
---@field close_pr string|false
---@field close_review_windows string|false
---@field next_review_window string|false
---@field previous_review_window string|false

---@class DiffviewPRConfig
---@field comment_style "minimal"|"expanded"|string
---@field keymaps DiffviewPRConfigKeymaps

---@class DiffviewPRPullRequest
---@field number integer
---@field url string

---@class DiffviewPRCommentUser
---@field login string

---@class DiffviewPRComment
---@field id? integer|string
---@field in_reply_to_id? integer|string
---@field path? string
---@field side? "LEFT"|"RIGHT"|string
---@field original_side? "LEFT"|"RIGHT"|string
---@field line? integer
---@field original_line? integer
---@field body? string
---@field user? DiffviewPRCommentUser
---@field created_at? string
---@field diff_hunk? string
---@field _thread_root_id? integer|string
---@field _render_line? integer

---@class DiffviewPRContext
---@field side "LEFT"|"RIGHT"
---@field path string

---@class DiffviewPRAttachContext
---@field symbol? string

---@class DiffviewPRTarget
---@field file any
---@field file_index integer
---@field path string
---@field side string
---@field line integer

---@class DiffviewPRSubmitComment
---@field pr_number integer
---@field body string
---@field reply_to_id? integer|string
---@field commit_id? string
---@field path? string
---@field side? string
---@field start_line? integer
---@field line? integer

---@alias DiffviewPRAsyncCallback fun(out: string?, err: string?)
---@alias DiffviewPRCurrentPRCallback fun(pr: DiffviewPRPullRequest?, err: string?, no_pr?: boolean)
---@alias DiffviewPRDoneCallback fun()
---@alias DiffviewPRSubmitCallback fun(success: boolean)

---@class DiffviewPRState
---@field pr DiffviewPRPullRequest?
---@field comments DiffviewPRComment[]?
---@field comments_by_buf table<integer, table<integer, DiffviewPRComment[]>>
---@field pr_fetching boolean
---@field pr_callbacks DiffviewPRCurrentPRCallback[]
---@field fetching boolean
---@field fetch_callbacks DiffviewPRDoneCallback[]
---@field notified_pr boolean
---@field review_windows integer[]
---@field render_context_by_buf table<integer, DiffviewPRContext>
---@field tracked_buffers table<integer, boolean>
---@field keymaps_by_buf table<integer, boolean>
---@field registered_diffview_help boolean
---@field inline_reply DiffviewPRInlineReply?

---@class DiffviewPRInlineReply
---@field bufnr integer
---@field line integer
---@field comments DiffviewPRComment[]
---@field input_bufnr integer
---@field winid integer
---@field title string
---@field temp_path string

---@type DiffviewPRState
return {
	pr = nil,
	comments = nil,
	comments_by_buf = {},
	pr_fetching = false,
	pr_callbacks = {},
	fetching = false,
	fetch_callbacks = {},
	notified_pr = false,
	review_windows = {},
	render_context_by_buf = {},
	tracked_buffers = {},
	keymaps_by_buf = {},
	registered_diffview_help = false,
	inline_reply = nil,
}
