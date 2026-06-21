local M = {}

local cmd = "LivePreview"
local server = require("livepreview.server")
local utils = require("livepreview.utils")
local config = require("livepreview.config")
local api = vim.api

---@type LivePreviewServer?
M.serverObj = nil
M.following = false

local follow_augroup = "LivePreviewFollow"

--- Stop following the active buffer
function M.disable_follow()
	M.following = false
	pcall(api.nvim_del_augroup_by_name, follow_augroup)
end

--- Stop live-preview server
function M.close()
	M.disable_follow()
	if M.serverObj then
		M.serverObj:stop(function()
			print("live-preview.nvim: Server closed")
		end)
		M.serverObj = nil
	end
end

--- Check if there is a live-preview server process
--- Note: this does not check if the server is running healthy
--- @return boolean
function M.is_running()
	return not not (M.serverObj and M.serverObj.server)
end

--- Resolve the file to preview
---@param filepath string|nil
---@return string?
function M.resolve_filepath(filepath)
	if filepath and #filepath > 0 then
		if not utils.is_absolute_path(filepath) then
			filepath = vim.fs.joinpath(vim.uv.cwd(), filepath)
		end
	else
		filepath = api.nvim_buf_get_name(0)
		if not utils.supported_filetype(filepath) then
			filepath = utils.find_supported_buf()
		end
	end

	return filepath and vim.fs.normalize(filepath) or nil
end

---@param filepath string
---@return string
local function preview_root(filepath)
	if M.serverObj then
		return vim.fs.normalize(M.serverObj.webroot)
	end

	return config.config.dynamic_root and vim.fs.dirname(filepath) or vim.fs.normalize(vim.uv.cwd() or "")
end

--- Get the browser path for a preview file
---@param filepath string
---@return string?
function M.preview_path(filepath)
	filepath = vim.fs.normalize(filepath)
	local urlpath = utils.get_relative_path(filepath, preview_root(filepath))

	if not urlpath then
		return
	end

	return "/" .. vim.uri_encode(urlpath)
end

--- Get the browser URL for a preview file
---@param filepath string
---@param port number?
---@return string?
function M.preview_url(filepath, port)
	local path = M.preview_path(filepath)
	if not path then
		return
	end

	return ("http://%s:%d%s"):format(config.config.address, port or config.config.port, path)
end

---@param filepath string
---@return boolean
local function can_serve(filepath)
	if not M.serverObj then
		return false
	end

	local webroot = vim.fs.normalize(M.serverObj.webroot)
	return not not utils.get_relative_path(filepath, webroot)
end

--- Navigate connected browsers to a preview file
---@param filepath string
---@return boolean
function M.navigate(filepath)
	if not M.is_running() then
		return false
	end
	if not utils.supported_filetype(filepath) then
		return false
	end
	if not can_serve(filepath) then
		vim.notify(
			"live-preview.nvim: cannot follow a file outside the current preview root",
			vim.log.levels.WARN
		)
		return false
	end

	local path = M.preview_path(filepath)
	if not path then
		return false
	end

	for _, client in ipairs(server.connecting_clients) do
		server.websocket.send_json(client, {
			type = "navigate",
			path = path,
		})
	end

	return true
end

--- Start live-preview server
---@param filepath string: path to the file
---@param port number: port to run the server on
---@param opts? {watch_dir?: boolean}
---@return boolean?
function M.start(filepath, port, opts)
	filepath = vim.fs.normalize(filepath)
	opts = opts or {}
	local processes = utils.processes_listening_on_port(port)
	if #processes > 0 then
		for _, process in ipairs(processes) do
			if process.pid ~= vim.uv.os_getpid() then
				-- local kill_confirm = vim.fn.confirm(
				-- 	("Port %d is being listened by another process `%s` (PID %d). Kill it?"):format(port, process.name, process.pid),
				-- 	"&Yes\n&No", 2)
				-- if kill_confirm ~= 1 then return else utils.kill(process.pid) end
				vim.notify(
					("Port %d is being used by another process `%s` (PID %d). Run `:lua vim.uv.kill(%d)` to kill it or change the port with `:lua LivePreview.config.port = <new_port>`"):format(
						port,
						process.name,
						process.pid,
						process.pid
					),
					vim.log.levels.WARN
				)
			end
		end
	end
	M.close()

	M.serverObj = server.Server:new(config.config.dynamic_root and vim.fs.dirname(filepath) or nil)
	local function onTextChanged(client)
		local bufname = vim.api.nvim_buf_get_name(0)
		if not utils.supported_filetype(bufname) or utils.supported_filetype(bufname) == "html" then
			return
		end
		local message = {
			filepath = bufname,
			type = "update",
			content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"),
		}
		server.websocket.send_json(client, message)
	end

	local on_events = {
		TextChanged = vim.schedule_wrap(onTextChanged),
		TextChangedI = vim.schedule_wrap(onTextChanged),
	}
	if opts.watch_dir or utils.supported_filetype(filepath) == "html" then
		---@param client uv_tcp_t
		---@param data {filename: string, event: FsEvent}
		on_events.LivePreviewDirChanged = function(client, data)
			if not vim.regex([[\.\(html\|css\|js\)$]]):match_str(data.filename) then
				return
			end

			server.websocket.send_json(client, { type = "reload" })
		end
	end

	M.serverObj:start(config.config.address, port, {
		on_events = on_events,
	})

	return true
end

--- Start following the active buffer in connected browsers
---@param filepath string?
---@param port number
---@return boolean?
function M.follow(filepath, port)
	filepath = M.resolve_filepath(filepath)
	if not filepath or not utils.supported_filetype(filepath) then
		vim.notify("live-preview.nvim only supports markdown, asciidoc, svg and html files", vim.log.levels.ERROR)
		return
	end
	if M.is_running() and not can_serve(filepath) then
		vim.notify(
			"live-preview.nvim: cannot follow a file outside the current preview root",
			vim.log.levels.WARN
		)
		return
	end

	if not M.is_running() and not M.start(filepath, port, { watch_dir = true }) then
		return
	end

	M.disable_follow()
	M.following = true
	api.nvim_create_augroup(follow_augroup, { clear = true })
	api.nvim_create_autocmd("BufEnter", {
		group = follow_augroup,
		callback = vim.schedule_wrap(function()
			local bufname = api.nvim_buf_get_name(0)
			if utils.supported_filetype(bufname) then
				M.navigate(vim.fs.normalize(bufname))
			end
		end),
	})

	M.navigate(filepath)
	return true
end

function M.pick()
	local picker = require("livepreview.picker")

	local pick_callback = function(pick_value)
		local filepath = M.resolve_filepath(pick_value)
		if not filepath then
			vim.notify("No file picked", vim.log.levels.INFO)
			return
		end
		if not M.start(filepath, config.config.port) then
			return
		end
		vim.cmd.edit(filepath)
		local url = M.preview_url(filepath, config.config.port)
		if url then
			utils.open_browser(url, config.config.browser)
		end
	end

	local picker_funcs = {}
	for k, v in pairs(config.pickers) do
		picker_funcs[v] = picker[k]
	end

	if config.config.picker and #config.config.picker > 0 then
		if not picker_funcs[config.config.picker] then
			vim.notify("live-preview.nvim: config option 'picker' invalid", vim.log.levels.ERROR)
			return
		end
		local status, err = pcall(picker_funcs[config.config.picker], pick_callback)
		if not status then
			vim.notify("live-preview.nvim : error calling picker " .. config.config.picker, vim.log.levels.ERROR)
			vim.notify(err, vim.log.levels.ERROR)
		end
	else
		picker.pick(pick_callback)
	end
end

function M.help()
	local function print_help(text)
		print(text:format(cmd))
	end
	print("live-preview.nvim commands:")
	print_help(
		[[  :%s start [filepath] - Start live-preview server and open browser. If no filepath is given, preview the current buffer.]]
	)
	print_help([[  :%s close - Stop live-preview server]])
	print_help([[  :%s pick - Select a file to preview (using a picker like telescope.nvim, fzf-lua or mini.pick)]])
	print_help([[  :%s follow [filepath] - Preview a file and navigate the browser as you enter other supported buffers.]])
	print("  :che[ckhealth] livepreview - Check the health of the plugin")
	print("  :h[elp] livepreview - Open the documentation")
end

--- @deprecated Use `require('livepreview.config').set(opts)` instead
function M.setup(opts)
	config.set(opts)
end

return M
