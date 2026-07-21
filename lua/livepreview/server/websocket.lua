---@brief WebSocket server implementation
--- To require this module, do
--- ```lua
--- local websocket = require('livepreview.server.websocket')
--- ```

local sha1 = require("livepreview.utils").sha1

local M = {}
local MAX_CLIENT_MESSAGE_SIZE = 1024 * 1024

--- Handle a WebSocket handshake request
--- @param client uv_tcp_t: client
--- @param request string: client request
function M.handshake(client, request)
	local key = request:match("Sec%-WebSocket%-Key: ([^\r\n]+)")
	if not key then
		vim.print("Invalid WebSocket request from client")
		client:close()
		return nil
	end

	local accept = sha1(key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
	accept = vim.base64.encode(accept)
	accept = vim.trim(accept)

	local response = "HTTP/1.1 101 Switching Protocols\r\n"
		.. "Upgrade: websocket\r\n"
		.. "Connection: Upgrade\r\n"
		.. "Sec-WebSocket-Accept: "
		.. accept
		.. "\r\n\r\n"
	client:write(response)
end

---@param client uv_tcp_t
---@param opcode number
---@param message string
local function send_frame(client, opcode, message)
	local byteMessage = message
	local length = #byteMessage

	local frame = string.char(0x80 + opcode)

	if length <= 125 then
		frame = frame .. string.char(length) .. byteMessage
	elseif length <= 65535 then
		frame = frame .. string.char(126) .. string.char(bit.rshift(length, 8), length % 256) .. byteMessage
	else
		frame = frame
			.. string.char(127)
			.. string.char(
				bit.rshift(length, 56),
				bit.rshift(length, 48) % 256,
				bit.rshift(length, 40) % 256,
				bit.rshift(length, 32) % 256,
				bit.rshift(length, 24) % 256,
				bit.rshift(length, 16) % 256,
				bit.rshift(length, 8) % 256,
				length % 256
			)
			.. byteMessage
	end

	client:write(frame)
end

--- Send a message to a WebSocket client
--- @param client uv_tcp_t: client
--- @param message string: message to send
function M.send(client, message)
	send_frame(client, 0x1, message)
end

--- Send a JSON message to a WebSocket client
--- @param client uv_tcp_t: client
--- @param message table: message to send
function M.send_json(client, message)
	local json = vim.json.encode(message)
	M.send(client, json)
end

---@param buffer string
---@return {opcode: number, payload: string, consumed: number}?
---@return string?
local function decode_client_frame(buffer)
	if #buffer < 2 then
		return nil
	end

	local first, second = buffer:byte(1, 2)
	local opcode = bit.band(first, 0x0f)
	local masked = bit.band(second, 0x80) ~= 0
	local payload_length = bit.band(second, 0x7f)
	local offset = 3

	if payload_length == 126 then
		if #buffer < 4 then
			return nil
		end
		local high, low = buffer:byte(3, 4)
		payload_length = high * 256 + low
		offset = 5
	elseif payload_length == 127 then
		if #buffer < 10 then
			return nil
		end
		payload_length = 0
		for index = 3, 10 do
			payload_length = payload_length * 256 + buffer:byte(index)
		end
		offset = 11
	end

	if not masked then
		return nil, "client WebSocket frames must be masked"
	end
	if payload_length > MAX_CLIENT_MESSAGE_SIZE then
		return nil, "client WebSocket frame is too large"
	end
	if #buffer < offset + 3 + payload_length then
		return nil
	end

	local mask = { buffer:byte(offset, offset + 3) }
	local payload_start = offset + 4
	local payload = {}
	for index = 0, payload_length - 1 do
		payload[index + 1] = string.char(bit.bxor(buffer:byte(payload_start + index), mask[index % 4 + 1]))
	end

	return {
		opcode = opcode,
		payload = table.concat(payload),
		consumed = payload_start + payload_length - 1,
	}
end

--- Read messages sent by a WebSocket client.
---@param client uv_tcp_t
---@param on_message fun(message: string)
---@param on_close? fun()
function M.listen(client, on_message, on_close)
	local buffer = ""
	local closed = false

	local function close()
		if closed then
			return
		end
		closed = true
		client:read_stop()
		if not client:is_closing() then
			client:close()
		end
		if on_close then
			on_close()
		end
	end

	client:read_start(function(err, chunk)
		if err or not chunk then
			close()
			return
		end

		buffer = buffer .. chunk
		while #buffer > 0 do
			local frame, decode_error = decode_client_frame(buffer)
			if decode_error then
				close()
				return
			end
			if not frame then
				return
			end

			buffer = buffer:sub(frame.consumed + 1)
			if frame.opcode == 0x1 then
				on_message(frame.payload)
			elseif frame.opcode == 0x8 then
				close()
				return
			elseif frame.opcode == 0x9 then
				send_frame(client, 0xA, frame.payload)
			end
		end
	end)
end

return M
