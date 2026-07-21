local utils = require("livepreview.utils")

print("Test module livepreview.utils")

print()
print("supported_filetype()")
assert(utils.supported_filetype("test.html") == "html", "should return `html`")
assert(utils.supported_filetype("test.md") == "markdown", "should return `markdown`")
assert(utils.supported_filetype("test.markdown") == "markdown", "should return `markdown`")
assert(utils.supported_filetype("test.adoc") == "asciidoc", "should return `asciidoc`")
assert(utils.supported_filetype("test.asciidoc") == "asciidoc", "should return `asciidoc`")
assert(utils.supported_filetype("test.txt") == nil, "should return `nil`")
assert(utils.supported_filetype("test/test.html") == "html", "should return `html`")
assert(utils.supported_filetype("test/test.md") == "markdown", "should return `markdown`")
assert(utils.supported_filetype("test/test.markdown") == "markdown", "should return `markdown`")
assert(utils.supported_filetype("test/test.adoc") == "asciidoc", "should return `asciidoc`")
assert(utils.supported_filetype("test/test.asciidoc") == "asciidoc", "should return `asciidoc`")
assert(utils.supported_filetype("test/test.txt") == nil, "should return `nil`")
assert(utils.supported_filetype("test/test test with spaces.md") == "markdown", "should return `markdown`")

print()
print("get_plugin_path()")
vim.cmd.cd()
local plugin_path = utils.get_plugin_path()
assert(plugin_path:match("live%-preview%.nvim$"), "should return the path where live-preview.nvim is installed")
vim.cmd.cd("-")

print()
print("list_supported_files()")
local supported_files = utils.list_supported_files(plugin_path)
assert(type(supported_files) == "table" and #supported_files > 0, "should return a table with values")

print()
print("read_file()")
local raw_packspec = utils.read_file(vim.fs.joinpath(plugin_path, "pkg.json"))
assert(type(raw_packspec) == "string" and #raw_packspec > 0, "should return a string with content")
assert(vim.json.decode(raw_packspec), "The content of pkg.json should be a valid JSON string")

print()
print("get_relative_path()")
local relative_path =
	utils.get_relative_path("/home/user/.config/nvim/lua/livepreview/utils.lua", "/home/user/.config/nvim/")
assert(relative_path == "lua/livepreview/utils.lua", "should return the relative path")

print()
print("is_absolute_path()")
assert(utils.is_absolute_path("/home/user/.config/nvim/lua/livepreview/utils.lua"), "should return true in Unix")
assert(
	utils.is_absolute_path("C:\\Users\\user\\AppData\\Local\\nvim\\lua\\livepreview\\utils.lua"),
	"should return true in Windows"
)
assert(not utils.is_absolute_path("lua/livepreview/utils.lua"), "should return false")

------------------------------------------------------------------------------------------------------------------------------
print()
local template = require("livepreview.template")

print("Test module livepreview.template")

print()
print("md2html()")
local markdown_html = template.md2html("```mermaid\ngraph TD\n    A[First<br>Second]\n```")
assert(
	markdown_html:find(".markdown-body code.language-mermaid br{display:inline}", 1, true),
	"should preserve Mermaid label line breaks hidden by GitHub Markdown CSS"
)
assert(
	markdown_html:find("/live-preview.nvim/static/markdown/markdown-it-task-lists.js", 1, true),
	"should load the Markdown task-list plugin"
)
assert(
	vim.uv.fs_stat(vim.fs.joinpath(plugin_path, "static", "markdown", "markdown-it-task-lists.js")),
	"should include the Markdown task-list browser asset"
)

print()
print("toggle_task()")
local livepreview = require("livepreview")
local task_bufnr = vim.api.nvim_create_buf(true, false)
local task_filepath = vim.fs.joinpath(vim.uv.os_tmpdir(), ("live-preview-task-%d.md"):format(vim.uv.os_getpid()))
vim.api.nvim_buf_set_name(task_bufnr, task_filepath)
vim.api.nvim_buf_set_lines(task_bufnr, 0, -1, false, {
	"# Tasks",
	"- [ ] unfinished",
	"1. [X] finished",
	"Plain [ ] text",
})
vim.bo[task_bufnr].modified = false

assert(livepreview.toggle_task(task_filepath, 1, true), "should check a Markdown task")
assert(vim.api.nvim_buf_get_lines(task_bufnr, 1, 2, false)[1] == "- [x] unfinished", "should update the marker")
assert(vim.bo[task_bufnr].modified, "should mark the changed buffer as modified")
assert(livepreview.toggle_task(task_filepath, 1, false), "should uncheck a Markdown task")
assert(not vim.bo[task_bufnr].modified, "should restore the clean state after toggling back")

vim.api.nvim_buf_set_lines(task_bufnr, 3, 4, false, { "Unrelated edit" })
assert(livepreview.toggle_task(task_filepath, 2, false), "should toggle an ordered-list task")
assert(livepreview.toggle_task(task_filepath, 2, true), "should toggle the ordered-list task back")
assert(vim.api.nvim_buf_get_lines(task_bufnr, 2, 3, false)[1] == "1. [X] finished", "should restore exact marker text")
assert(vim.bo[task_bufnr].modified, "should preserve unrelated buffer modifications")
assert(not livepreview.toggle_task(task_filepath, 3, true), "should reject a non-task source line")
vim.api.nvim_buf_delete(task_bufnr, { force = true })

print()
print("websocket.listen()")
local websocket = require("livepreview.server.websocket")
local read_callback
local received_message
local fake_client = {
	read_start = function(_, callback)
		read_callback = callback
	end,
	read_stop = function() end,
	is_closing = function()
		return false
	end,
	close = function() end,
}
websocket.listen(fake_client, function(message)
	received_message = message
end)

local payload = '{"type":"task_toggle"}'
local mask = { 11, 22, 33, 44 }
local masked = {}
for index = 1, #payload do
	masked[index] = string.char(bit.bxor(payload:byte(index), mask[(index - 1) % 4 + 1]))
end
local frame = string.char(0x81, 0x80 + #payload, unpack(mask)) .. table.concat(masked)
read_callback(nil, frame:sub(1, 5))
assert(received_message == nil, "should buffer partial WebSocket frames")
read_callback(nil, frame:sub(6))
assert(received_message == payload, "should decode masked browser WebSocket frames")
