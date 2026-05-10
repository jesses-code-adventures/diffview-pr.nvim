return function(msg, level)
	vim.notify(msg, level or vim.log.levels.INFO, { title = "Diffview PR Comment" })
end
