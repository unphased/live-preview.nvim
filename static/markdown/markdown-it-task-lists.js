// Browser build of markdown-it-task-lists.
// https://github.com/revin/markdown-it-task-lists
//
// Copyright (c) 2016, Revin Guillen
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
(function(global) {
	'use strict';

	global.markdownitTaskLists = function(md, options) {
		var enabled = options && options.enabled;
		md.core.ruler.after('inline', 'github-task-lists', function(state) {
			var tokens = state.tokens;

			for (var i = 2; i < tokens.length; i++) {
				if (!isTaskListItem(tokens, i)) {
					continue;
				}

				addCheckbox(tokens[i], state.Token, enabled);
				tokens[i - 2].attrJoin('class', 'task-list-item');

				var parent = findParentList(tokens, i - 2);
				if (parent >= 0) {
					addClass(tokens[parent], 'contains-task-list');
				}
			}
		});
	};

	function isTaskListItem(tokens, index) {
		return tokens[index].type === 'inline' &&
			tokens[index - 1].type === 'paragraph_open' &&
			tokens[index - 2].type === 'list_item_open' &&
			/^\[[ xX]\] /.test(tokens[index].content);
	}

	function addCheckbox(token, Token, enabled) {
		var checked = /^\[[xX]\] /.test(token.content);
		var checkbox = new Token('html_inline', '', 0);
		checkbox.content = '<input class="task-list-item-checkbox"' +
			(enabled ? '' : ' disabled=""') + ' type="checkbox"' +
			(checked ? ' checked=""' : '') + '>';

		token.children.unshift(checkbox);
		token.children[1].content = token.children[1].content.slice(3);
		token.content = token.content.slice(3);
	}

	function addClass(token, className) {
		var classes = token.attrGet('class');
		if (!classes || classes.split(' ').indexOf(className) < 0) {
			token.attrJoin('class', className);
		}
	}

	function findParentList(tokens, index) {
		var parentLevel = tokens[index].level - 1;

		for (var i = index - 1; i >= 0; i--) {
			if (tokens[i].level === parentLevel) {
				return i;
			}
		}

		return -1;
	}
})(window);
