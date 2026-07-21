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
local task_clean_baselines = {}
local task_state_augroup = api.nvim_create_augroup("LivePreviewTaskState", { clear = true })

api.nvim_create_autocmd("BufWipeout", {
	group = task_state_augroup,
	callback = function(event)
		task_clean_baselines[event.buf] = nil
	end,
})

---@param bufnr number
---@return string[]
local function buffer_lines(bufnr)
	return api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

---@param bufnr number
---@return table
local function buffer_file_options(bufnr)
	return {
		bomb = vim.bo[bufnr].bomb,
		endofline = vim.bo[bufnr].endofline,
		fileencoding = vim.bo[bufnr].fileencoding,
		fileformat = vim.bo[bufnr].fileformat,
	}
end

---@param text string
---@return string? prefix
---@return string? marker
---@return string? suffix
local function parse_task_line(text)
	local prefix, marker, suffix = text:match("^(%s*[%-%+%*]%s+)(%[[ xX]%])(.*)$")
	if not prefix then
		prefix, marker, suffix = text:match("^(%s*%d+[%.%)]%s+)(%[[ xX]%])(.*)$")
	end
	return prefix, marker, suffix
end

---@param filepath string
---@return number?
local function find_loaded_buffer(filepath)
	local direct_match = vim.fn.bufnr(filepath)
	if direct_match >= 0 and api.nvim_buf_is_loaded(direct_match) then
		return direct_match
	end

	filepath = vim.fs.normalize(filepath)
	for _, bufnr in ipairs(api.nvim_list_bufs()) do
		if api.nvim_buf_is_loaded(bufnr) and vim.fs.normalize(api.nvim_buf_get_name(bufnr)) == filepath then
			return bufnr
		end
	end
end

---@param path string
---@return string?
local function filepath_for_preview_path(path)
	path = vim.uri_decode(path)
	for _, bufnr in ipairs(api.nvim_list_bufs()) do
		local filepath = api.nvim_buf_get_name(bufnr)
		if api.nvim_buf_is_loaded(bufnr) and utils.supported_filetype(filepath) == "markdown" then
			local preview_path = M.preview_path(filepath)
			if preview_path and vim.uri_decode(preview_path) == path then
				return filepath
			end
		end
	end
end

---@param client uv_tcp_t
---@param bufnr number
local function send_buffer_update(client, bufnr)
	if client:is_closing() then
		return
	end
	server.websocket.send_json(client, {
		filepath = api.nvim_buf_get_name(bufnr),
		type = "update",
		content = table.concat(buffer_lines(bufnr), "\n"),
	})
end

--- Toggle a Markdown task marker in a loaded buffer.
---@param filepath string
---@param line number zero-based source line
---@param checked boolean
---@return boolean
---@return number? bufnr
function M.toggle_task(filepath, line, checked)
	if utils.supported_filetype(filepath) ~= "markdown" or line < 0 or line % 1 ~= 0 then
		return false
	end

	local bufnr = find_loaded_buffer(filepath)
	if not bufnr or line >= api.nvim_buf_line_count(bufnr) then
		return false
	end

	local current = api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
	local prefix, marker, suffix = parse_task_line(current)
	if not prefix then
		return false
	end
	if checked == (marker ~= "[ ]") then
		return true, bufnr
	end

	if not vim.bo[bufnr].modified then
		task_clean_baselines[bufnr] = {
			filepath = vim.fs.normalize(filepath),
			lines = buffer_lines(bufnr),
			options = buffer_file_options(bufnr),
		}
	end

	local baseline = task_clean_baselines[bufnr]
	local replacement = prefix .. (checked and "[x]" or "[ ]") .. suffix
	if baseline and baseline.filepath == vim.fs.normalize(filepath) then
		local baseline_line = baseline.lines[line + 1]
		local baseline_prefix, baseline_marker, baseline_suffix = parse_task_line(baseline_line or "")
		if baseline_prefix == prefix
			and baseline_suffix == suffix
			and checked == (baseline_marker ~= "[ ]")
		then
			replacement = baseline_line
		end
	end

	api.nvim_buf_set_lines(bufnr, line, line + 1, false, { replacement })
	if baseline
		and baseline.filepath == vim.fs.normalize(filepath)
		and vim.deep_equal(baseline.lines, buffer_lines(bufnr))
		and vim.deep_equal(baseline.options, buffer_file_options(bufnr))
	then
		vim.bo[bufnr].modified = false
	end

	return true, bufnr
end

---@param client uv_tcp_t
---@param message table
local function on_client_message(client, message)
	if message.type ~= "task_toggle" then
		return
	end

	local valid = type(message.path) == "string"
		and type(message.line) == "number"
		and type(message.checked) == "boolean"
	local filepath = valid and filepath_for_preview_path(message.path) or nil
	local ok, bufnr = false, nil
	if filepath then
		ok, bufnr = M.toggle_task(filepath, message.line, message.checked)
	end

	if not client:is_closing() then
		server.websocket.send_json(client, {
			type = "task_toggle_result",
			id = message.id,
			ok = ok,
		})
	end
	if ok and bufnr then
		for _, connected_client in ipairs(server.connecting_clients) do
			send_buffer_update(connected_client, bufnr)
		end
	end
end

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

	local preview_port = port or (M.serverObj and M.serverObj.port) or config.config.port
	return ("http://%s:%d%s"):format(config.config.address, preview_port, path)
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

---@param port number
---@return boolean
local function port_is_used_by_other_process(port)
	for _, process in ipairs(utils.processes_listening_on_port(port)) do
		if process.pid ~= vim.uv.os_getpid() then
			return true
		end
	end
	return false
end

---@param port number
---@return number?
local function first_available_port(port)
	local max_port = port + 100
	for candidate = port, max_port do
		if not port_is_used_by_other_process(candidate) then
			return candidate
		end
	end
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
		vim.notify("live-preview.nvim: cannot follow a file outside the current preview root", vim.log.levels.WARN)
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
---@param port number?: starting port to run the server on
---@param opts? {watch_dir?: boolean}
---@return boolean?
function M.start(filepath, port, opts)
	filepath = vim.fs.normalize(filepath)
	opts = opts or {}
	port = port or config.config.port
	local actual_port = first_available_port(port)
	if not actual_port then
		vim.notify(
			("live-preview.nvim: no available port found from %d to %d"):format(port, port + 100),
			vim.log.levels.ERROR
		)
		return
	end
	if actual_port ~= port then
		vim.notify(
			("live-preview.nvim: port %d is in use; using port %d instead"):format(port, actual_port),
			vim.log.levels.INFO
		)
	end
	M.close()

	M.serverObj = server.Server:new(config.config.dynamic_root and vim.fs.dirname(filepath) or nil)
	local function onTextChanged(client)
		local bufnr = api.nvim_get_current_buf()
		local bufname = api.nvim_buf_get_name(bufnr)
		if not utils.supported_filetype(bufname) or utils.supported_filetype(bufname) == "html" then
			return
		end
		send_buffer_update(client, bufnr)
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

	M.serverObj:start(config.config.address, actual_port, {
		on_events = on_events,
		on_message = on_client_message,
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
		vim.notify("live-preview.nvim: cannot follow a file outside the current preview root", vim.log.levels.WARN)
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
		local url = M.preview_url(filepath)
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
	print_help(
		[[  :%s follow [filepath] - Preview a file and navigate the browser as you enter other supported buffers.]]
	)
	print("  :che[ckhealth] livepreview - Check the health of the plugin")
	print("  :h[elp] livepreview - Open the documentation")
end

--- @deprecated Use `require('livepreview.config').set(opts)` instead
function M.setup(opts)
	config.set(opts)
end

return M
