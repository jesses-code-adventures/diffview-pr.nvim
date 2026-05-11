# diffview-pr.nvim

Review, comment on, and reply to threads in PRs inline in [diffview.nvim](https://github.com/dlyongemallo/diffview.nvim).

> Note: The original [sindrets diffview.nvim](https://github.com/sindrets/diffview.nvim) is unmaintained, so we point to the [dyongemallo fork](https://github.com/dlyongemallo/diffview.nvim) above instead.

## How it works

1. When you open a diffview with an associated PR branch, the plugin detects the PR via `gh pr view`.
2. Review comments are fetched via the GitHub API (`gh api repos/{owner}/{repo}/pulls/{number}/comments`).
3. Comments are rendered above the corresponding lines in the diff buffers.
4. Comments & replies are sent using `gh api`.

## Requirements

- [diffview.nvim](https://github.com/dlyongemallo/diffview.nvim)
- [gh](https://cli.github.com/) – GitHub CLI (authenticated)
- Neovim >= 0.10 (uses `vim.system`)

## Installation

```lua
-- vim.pack (nvim 0.12+)
vim.pack.add {
	{ src = "https://github.com/jesses-code-adventures/diffview-pr.nvim" },
}

-- lazy.nvim
{ "jesses-code-adventures/diffview-pr.nvim" }
```

## Setup

The plugin activates through diffview.nvim's `hooks.diff_buf_win_enter` callback. Wire it up in your diffview setup:

```lua
require("diffview_pr").setup({
  -- "expanded" shows full inline comment threads.
  -- "minimal" shows the previous collapsed one-line summary.
  comment_style = "minimal",
  -- "inline" shows virtual text on the same line as the code position.
  -- "overlay" shows virtual text on top of the code.
  virtual_text_position = "inline",

  -- Set to false to skip installing the default buffer-local mappings.
  keymaps = {
    enabled = true,
  },
})

require("diffview").setup({
  hooks = {
    diff_buf_win_enter = require("diffview_pr").diff_buf_win_enter,
  },
})
```

## Commands

| Command | Mode | Default Keymap | Description |
|---|---|---|---|
| `:DiffviewPRComment` | visual | `<leader>pc` | Create a PR comment from the selected lines |
| `:DiffviewPRShowComments` | normal | `<leader>po` | Show PR comments at cursor |
| `:DiffviewPROpenCommentsOrEnter` | normal | `<CR>` | Show PR comments at cursor, or pass through `<CR>` |
| `:DiffviewPRReply` | normal | `<leader>pR` | Reply to the PR comment thread at cursor |
| `:DiffviewPRRefresh` | normal | `<leader>pf` | Re-fetch PR comments from GitHub |
| `:DiffviewPRNextComment` | normal | `]r` | Jump to the next PR comment in the current Diffview |
| `:DiffviewPRPreviousComment` | normal | `[r` | Jump to the previous PR comment in the current Diffview |
| `:DiffviewPRReviewApprove` | normal | `<leader>pa` | Approve the PR with an optional message |
| `:DiffviewPRReviewRequestChanges` | normal | `<leader>pr` | Request changes with a required message |
| `:DiffviewPRReviewClose` | normal | `<leader>px` | Close the PR with an optional comment |
| `:DiffviewPRCloseReviewWindows` | normal | `<leader>pq` | Close the open review/thread float |
| `:DiffviewPRNextReviewWindow` | normal | `<leader>pn` | Focus the next review/thread float pane |
| `:DiffviewPRPreviousReviewWindow` | normal | `<leader>pp` | Focus the previous review/thread float pane |

Use native `:w`, `:q`, and `:wq` in comment, reply, and review editor floats. Saving submits the content; `:wq` submits and closes the float.

## License

MIT
