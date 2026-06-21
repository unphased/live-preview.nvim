if vim.g.loaded_livepreview then
	return
end

vim.g.loaded_livepreview = true

local health = require("livepreview.health")
local cmd = "LivePreview"
local api = vim.api

if not health.is_nvim_compatible() then
	vim.notify_once(
		("live-preview.nvim requires Nvim %s, but you are using Nvim %s"):format(
			health.supported_nvim_ver_range,
			health.nvim_ver
		),
		vim.log.levels.ERROR
	)
	return
end

api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		require("livepreview").close()
	end,
})

api.nvim_create_user_command(cmd, function(cmd_opts)
	local utils = require("livepreview.utils")
	local lp = require("livepreview")
	local Config = require("livepreview.config").config

	local subcommand = cmd_opts.fargs[1]

	if subcommand == "start" then
		local filepath = lp.resolve_filepath(cmd_opts.fargs[2])
		if not filepath or not utils.supported_filetype(filepath) then
			vim.notify("live-preview.nvim only supports markdown, asciidoc, svg and html files", vim.log.levels.ERROR)
			return
		end
		if not lp.start(filepath, Config.port) then
			return
		end

		local url = lp.preview_url(filepath, Config.port)
		if not url then
			vim.notify("live-preview.nvim: file is outside the current working directory", vim.log.levels.ERROR)
			return
		end
		print("live-preview.nvim: Opening browser at " .. url)
		utils.open_browser(url, Config.browser)
	elseif subcommand == "close" then
		lp.close()
		print("Live preview stopped")
	elseif subcommand == "pick" then
		lp.pick()
	elseif subcommand == "follow" then
		local filepath = lp.resolve_filepath(cmd_opts.fargs[2])
		if not filepath or not utils.supported_filetype(filepath) then
			vim.notify("live-preview.nvim only supports markdown, asciidoc, svg and html files", vim.log.levels.ERROR)
			return
		end
		if not lp.follow(filepath, Config.port) then
			return
		end

		local url = lp.preview_url(filepath, Config.port)
		if not url then
			vim.notify("live-preview.nvim: file is outside the current working directory", vim.log.levels.ERROR)
			return
		end
		print("live-preview.nvim: Following buffers from " .. url)
		utils.open_browser(url, Config.browser)
	else
		lp.help()
	end
end, {
	nargs = "*",
	complete = function(ArgLead, CmdLine, CursorPos)
		local subcommands = { "start", "close", "pick", "follow", "-h", "--help" }
		local subcommand = vim.split(CmdLine, " ")[2]
		if subcommand == "" then
			return subcommands
		elseif subcommand == ArgLead then
			return vim.tbl_filter(function(subcmd)
				return vim.startswith(subcmd, ArgLead)
			end, subcommands)
		else
			if subcommand == "start" or subcommand == "follow" then
				return vim.fn.getcompletion(ArgLead, "file")
			end
		end
	end,
})

local config = require("livepreview.config")
--- Public API
LivePreview = {}
LivePreview.config = vim.deepcopy(config.default)

setmetatable(LivePreview.config, {
	__index = function(_, key)
		if config.default[key] == nil then
			vim.notify(("Error: live-preview.nvim has no config option '%s'"):format(key), vim.log.levels.ERROR)
			return
		end
		return config.config[key]
	end,
	__newindex = function(_, key, value)
		if config.default[key] == nil then
			vim.notify(("Error: live-preview.nvim has no config option '%s'"):format(key), vim.log.levels.ERROR)
			return
		end
		config.set({ [key] = value })
	end,
})
