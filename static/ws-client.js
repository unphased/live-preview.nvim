const wsUrl = getWebSocketUrl();
let socket = new WebSocket(wsUrl);
let connected = true;

function getWebSocketUrl() {
	const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
	const hostname = window.location.hostname;
	const port = window.location.port ? `:${window.location.port}` : "";
	return `${protocol}//${hostname}${port}`;
}

/**
 * Normalize Windows file path to use forward slashes
 * @param {string} filepath - The file path to normalize
 * @returns {string} - The normalized file path
 */
const normalizePath = (filepath) => {
    if (!filepath) return '';

    const isWindows = /^[a-zA-Z]:\\/.test(filepath) ||
                      filepath.startsWith('\\\\');

    return isWindows ? filepath.replace(/\\/g, '/') : filepath;
};

/**
 * Check if browser should handle websocket message from server
 * @param {string} filepath - The path of the file
 * @returns {boolean} - True if the browser should handle the message, false otherwise
 */
const isRightPath = (filepath) => {
	const decodedPath = decodeURIComponent(window.location.pathname)
	console.log("Checking path:", filepath, "against", decodedPath);
    const normalized = normalizePath(filepath);
    return normalized.endsWith(decodedPath);
};

let livepreview_reload
let livepreviewActiveSourceLine = null;
let livepreviewLastCursor = null;

const findClosestSourceLine = (cursor) => {
	const cursorLine = Number(cursor?.[0]);
	if (!Number.isFinite(cursorLine)) return null;

	const sourceLine = Math.max(cursorLine - 1, 0);
	const exactLine = document.querySelector(`[data-source-line="${sourceLine}"]`);
	if (exactLine) return exactLine;

	const lineNumbers = document.querySelectorAll(".source-line[data-source-line]");
	let closest = null;
	let minDiff = Infinity;
	lineNumbers.forEach((lineNumber) => {
		const line = parseInt(lineNumber.getAttribute("data-source-line"), 10);
		if (!Number.isFinite(line)) return;

		const diff = Math.abs(sourceLine - line);
		if (diff < minDiff) {
			minDiff = diff;
			closest = lineNumber;
		}
	});

	return closest;
};

const setActiveSourceLine = (line) => {
	if (livepreviewActiveSourceLine && livepreviewActiveSourceLine !== line) {
		livepreviewActiveSourceLine.classList.remove("livepreview-active-source-line");
	}

	livepreviewActiveSourceLine = line;
	if (livepreviewActiveSourceLine) {
		livepreviewActiveSourceLine.classList.add("livepreview-active-source-line");
	}
};

const refreshActiveSourceLine = () => {
	if (!livepreviewLastCursor) return;

	const line = findClosestSourceLine(livepreviewLastCursor);
	setActiveSourceLine(line);
};

async function connectWebSocket() {
	socket = new WebSocket(wsUrl);

	socket.onopen = () => {
		if (!connected) {
			window.location.reload();
		}
		connected = true;
		console.log("Connected to server");
		console.log("connected: ", connected);
		livepreview_reload = 0;
	};

	socket.onmessage = (event) => {
		const message = JSON.parse(event.data);

		if (message.type === "reload") {
			console.log("Reload message received");
			if (livepreview_reload === 0) {
				livepreview_reload = 1;
				connected = false;
				socket.close();
				return;
			}
		} else if (message.type === "update") {
			console.log("Update message received");
			let { filepath, content } = message;
			if (isRightPath(filepath)) {
				// Check if the render function is defined before calling it
				if (typeof livepreview_render !== "undefined") {
					livepreview_render(content);
					refreshActiveSourceLine();
					if (typeof livepreview_renderKatex !== "undefined") {
						livepreview_renderKatex();
					}
					if (typeof livepreview_renderMermaid !== "undefined") {
						livepreview_renderMermaid();
					}
				} else {
					// Check if viewing svg
					if (window.location.pathname.endsWith(".svg")) {
						const livepreview_render = (text) => {
							document.querySelector('.markdown-body').innerHTML = text;
						}
						livepreview_render(content);
						refreshActiveSourceLine();
					}
					else {
						console.error("livepreview_render function is not defined");
					}
				}
			}
		} else if (message.type === "scroll") {
			console.log("Scroll message received");
			const { filepath, cursor } = message;
			if (isRightPath(filepath)) {
				livepreviewLastCursor = cursor;
				const line = findClosestSourceLine(cursor);
				setActiveSourceLine(line);
				if (line) {
					line.scrollIntoView({ behavior: "smooth", block: "center" });
				}
			}
		}
	};

	socket.onclose = () => {
		connected = false;
		console.log("Disconnected from server");
		window.location.reload();
	};

	socket.onerror = (error) => {
		console.error("WebSocket error:", error);
	};
}

window.onload = () => {
	connectWebSocket();
	setInterval(() => {
		if (!connected) {
			connectWebSocket();
		}
	}, 1000);
};
