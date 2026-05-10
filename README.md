# diffview-pr.nvim

Browse, create, and reply to GitHub PR comments inline from [diffview.nvim](https://github.com/sindrets/diffview.nvim).

![demo](https://github.com/user-attachments/assets/71a18cc1-2f79-4ca1-9ac8-2c0aa5e8a9b5)

## Requirements

- [diffview.nvim](https://github.com/sindrets/diffview.nvim)
- [gh](https://cli.github.com/) – GitHub CLI (authenticated)
- Neovim >= 0.10 (uses `vim.system`)

## Installation

```lua
-- vim.pack
vim.pack.add {
	{ src = "https://github.com/jesses-code-adventures/diffview-pr.nvim" },
}

-- lazy.nvim
{
  "jesses-code-adventures/diffview-pr.nvim",
  lazy = true,
}

-- packer.nvim
use "jesses-code-adventures/diffview-pr.vim"
```

## Setup

The plugin activates through diffview.nvim's `hooks.diff_buf_win_enter` callback. Wire it up in your diffview setup:

```lua
require("diffview_pr_comment").setup({
  -- "expanded" shows full inline comment threads.
  -- "minimal" shows the previous collapsed one-line summary.
  comment_style = "minimal",

  -- Set to false to skip installing the default buffer-local mappings.
  keymaps = {
    enabled = true,
  },
})

require("diffview").setup({
  hooks = {
    diff_buf_win_enter = require("diffview_pr_comment").diff_buf_win_enter,
  },
})
```

Default keymaps installed by the hook:

| Key | Mode | Command |
|---|---|---|
| `<leader>pc` | visual | `:DiffviewPRComment` |
| `<leader>po` | normal | `:DiffviewPRShowComments` |
| `<CR>` | normal | `:DiffviewPROpenCommentsOrEnter` |
| `<leader>pR` | normal | `:DiffviewPRReply` |
| `<leader>pf` | normal | `:DiffviewPRRefresh` |
| `]r` | normal | `:DiffviewPRNextComment` |
| `[r` | normal | `:DiffviewPRPreviousComment` |
| `<leader>pa` | normal | `:DiffviewPRReviewApprove` |
| `<leader>pr` | normal | `:DiffviewPRReviewRequestChanges` |
| `<leader>px` | normal | `:DiffviewPRReviewClose` |
| `<leader>pq` | normal | `:DiffviewPRCloseReviewWindows` |
| `<leader>pn` | normal | `:DiffviewPRNextReviewWindow` |
| `<leader>pp` | normal | `:DiffviewPRPreviousReviewWindow` |

## Commands

| Command | Mode | Description |
|---|---|---|
| `:DiffviewPRComment` | visual | Create a PR comment from the selected lines |
| `:DiffviewPRShowComments` | normal | Show PR comments at cursor |
| `:DiffviewPROpenCommentsOrEnter` | normal | Show PR comments at cursor, or pass through `<CR>` |
| `:DiffviewPRReply` | normal | Reply to the PR comment thread at cursor |
| `:DiffviewPRRefresh` | normal | Re-fetch PR comments from GitHub |
| `:DiffviewPRNextComment` | normal | Jump to the next PR comment in the current Diffview |
| `:DiffviewPRPreviousComment` | normal | Jump to the previous PR comment in the current Diffview |
| `:DiffviewPRReviewApprove` | normal | Approve the PR with an optional message |
| `:DiffviewPRReviewRequestChanges` | normal | Request changes with a required message |
| `:DiffviewPRReviewClose` | normal | Close the PR with an optional comment |
| `:DiffviewPRCloseReviewWindows` | normal | Close the open review/thread float |
| `:DiffviewPRNextReviewWindow` | normal | Focus the next review/thread float pane |
| `:DiffviewPRPreviousReviewWindow` | normal | Focus the previous review/thread float pane |
| `:DiffviewPRDebugState` | normal | Print internal plugin state |

Use native `:w`, `:q`, and `:wq` in comment, reply, and review editor floats. Saving submits the content; `:wq` submits and closes the float.

## Features

- **Inline annotations** – PR comments appear as virtual text in diff buffers. Use `comment_style = "expanded"` for full inline threads or `"minimal"` for collapsed summaries.
- **Side-aware comments** – Correctly targets the left (deletion) or right (addition) side of a diff.
- **Thread view** – Opens a floating window with the full thread, diff hunk preview, and a reply editor.
- **File panel badges** – Shows comment counts next to files in the diffview file panel.
- **Multi-line comments** – Supports commenting on a range of lines.
- **Async fetching** – PR and comment data is fetched asynchronously via `gh`.

## API

```lua
local pr = require("diffview_pr_comment")

pr.setup({ comment_style = "minimal" }) -- Configure inline comment rendering
pr.diff_buf_win_enter(bufnr, winid, ctx) -- Diffview hook entrypoint with default keymaps
pr.attach_diffview_buffer(bufnr, ctx) -- Attach comment overlay to a diff buffer
pr.refresh()                     -- Re-fetch comments from GitHub
pr.next_comment()                -- Jump to next PR comment in the current Diffview
pr.previous_comment()            -- Jump to previous PR comment in the current Diffview
pr.show_comments_at_cursor()     -- Open floating thread for comments on current line
pr.open_comments_at_cursor_or_enter() -- Show comments or pass through <CR>
pr.reply_to_comment_at_cursor()  -- Open reply float for thread at cursor
pr.debug_state()                 -- Print internal state for debugging
```

## How it works

1. When you open a diffview with an associated PR branch, the plugin detects the PR via `gh pr view`.
2. It fetches review comments via the GitHub API (`gh api repos/{owner}/{repo}/pulls/{number}/comments`).
3. Comments are rendered as virtual text above the corresponding lines in the diff buffers.
4. Creating/reply to comments uses `gh api` to POST to the GitHub API.

## License

MIT
