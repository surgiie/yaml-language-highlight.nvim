--- yaml-language-highlight: comment-based language highlighting for YAML block scalars using treesitter.
---
--- Usage: place `# lang: <language>` on the line immediately before a YAML block
--- scalar key to apply treesitter-based syntax highlighting to its content:
---
---   # lang: xml
---   schema: |
---     <?xml version="1.0"?>
---
--- Highlights are applied at any nesting depth via nvim extmarks using the
--- target language's treesitter `highlights` query.

local M = {}

--- Namespace for all extmarks written by this plugin.
--- Using a dedicated namespace makes it easy to clear/replace highlights on each update.
local ns = vim.api.nvim_create_namespace("yaml-language-highlight")

--- Parse and highlight a region of text in the buffer using a foreign language's
--- treesitter grammar.
---
--- @param bufnr     number   Buffer to write extmarks into.
--- @param lang      string   Treesitter language name (e.g. "xml", "python").
--- @param stripped  string[] Content lines with leading indent removed (used for parsing).
--- @param buf_start_row number  0-indexed row in the buffer where content begins.
--- @param col_offset    number  Number of columns that were stripped from each line
---                              (the minimum indent). Added back when placing extmarks.
--- @param buf_lines     string[] All lines of the buffer (used for clamping column positions).
local function highlight_region(bufnr, lang, stripped, buf_start_row, col_offset, buf_lines)
	local content = table.concat(stripped, "\n")

	-- `pcall` because the language parser may not be installed; bail silently if so.
	local ok, parser = pcall(vim.treesitter.get_string_parser, content, lang)
	if not ok or not parser then
		return
	end

	local trees = parser:parse()
	if not trees or not trees[1] then
		return
	end

	local query = vim.treesitter.query.get(lang, "highlights")
	if not query then
		return
	end

	for capture_id, node, metadata in query:iter_captures(trees[1]:root(), content) do
		-- Prefer the language-specific group (e.g. `@keyword.lua`); fall back to generic `@keyword`.
		local capture_name = query.captures[capture_id]
		local hl_group = "@" .. capture_name .. "." .. lang
		if vim.api.nvim_get_hl_id_by_name(hl_group) == 0 then
			hl_group = "@" .. capture_name
		end

		-- `get_range` returns { start_row, start_col, _, end_row, end_col, _ } relative to the parsed string.
		local range = vim.treesitter.get_range(node, content, metadata[capture_id])
		local sr, sc, er, ec = range[1], range[2], range[4], range[5]

		-- Translate from parsed-content space back to buffer space.
		local buf_sr = buf_start_row + sr
		local buf_er = buf_start_row + er
		local buf_sc = sc + col_offset
		local buf_ec = ec + col_offset

		-- Clamp to actual line length to avoid out-of-bounds extmarks.
		buf_sc = math.min(buf_sc, #(buf_lines[buf_sr + 1] or ""))
		buf_ec = math.min(buf_ec, #(buf_lines[buf_er + 1] or ""))

		-- Priority above the default treesitter level so injected highlights win.
		vim.api.nvim_buf_set_extmark(bufnr, ns, buf_sr, buf_sc, {
			end_row = buf_er,
			end_col = buf_ec,
			hl_group = hl_group,
			priority = vim.hl.priorities.treesitter + 50,
		})
	end
end

--- Scan the entire buffer for `# lang:` comment annotations and apply
--- treesitter highlights to the YAML block scalar that follows each one.
---
--- @param bufnr number  Buffer to process.
local function apply_highlights(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	-- Holds the language from a `# lang:` comment until we find (or fail to find) its block scalar.
	local pending_lang = nil

	for i, line in ipairs(lines) do
		local lang = line:match("^%s*#%s*lang:%s*(%a+)%s*$")
		if lang then
			pending_lang = lang
		elseif pending_lang then
			if line:match("^%s*$") then
				-- Blank lines between the comment and the key are tolerated.
			elseif line:match("^%s*[%w%-%._]+:%s*|") then
				local key_indent = #line:match("^(%s*)")
				local content_lines = {}
				-- `i` is 1-indexed; first content line is at 0-indexed buffer row `i`.
				local buf_start_row = i

				-- A block scalar line belongs if it is blank or indented deeper than the key.
				for j = i + 1, #lines do
					local l = lines[j]
					if l:match("^%s*$") or #l:match("^(%s*)") > key_indent then
						table.insert(content_lines, l)
					else
						break
					end
				end

				if #content_lines > 0 then
					-- Strip common leading indent before parsing; restore it when placing extmarks.
					local min_indent = math.huge
					for _, cl in ipairs(content_lines) do
						if not cl:match("^%s*$") then
							local ind = #cl:match("^(%s*)")
							if ind < min_indent then min_indent = ind end
						end
					end
					if min_indent == math.huge then min_indent = 0 end

					local stripped = {}
					for _, cl in ipairs(content_lines) do
						table.insert(stripped, cl:sub(min_indent + 1))
					end

					highlight_region(bufnr, pending_lang, stripped, buf_start_row, min_indent, lines)
				end

				pending_lang = nil
			else
				-- Not a blank line or block scalar key — annotation doesn't apply here.
				pending_lang = nil
			end
		end
	end
end

--- Convert a glob-style keyword pattern to a regex string suitable for `#match?`.
--- Only `*` (any characters) is treated as a wildcard; everything else is literal.
--- @param glob string
--- @return string
local function glob_to_regex(glob)
	local result = ""
	for i = 1, #glob do
		local c = glob:sub(i, i)
		if c == "*" then
			result = result .. ".*"
		elseif c:match("[%.%+%?%(%)%[%]%{%}%^%$%|%\\]") then
			result = result .. "\\" .. c
		else
			result = result .. c
		end
	end
	return result
end

--- Write treesitter injection blocks for the given lang->keywords map into
--- `stdpath("data")/site/queries/yaml/injections.scm`.
--- ~/.local/share/nvim/site is in the runtimepath, is never touched by
--- plugin managers, and is not inside the user's config tree.
---
--- @param injections table<string, string[]>  e.g. { php = { "php", "php_script" } }
local function write_injections(injections)
	local dir = vim.fn.stdpath("data") .. "/site/queries/yaml"
	local path = dir .. "/injections.scm"

	vim.fn.mkdir(dir, "p")

	local existing = ""
	local f = io.open(path, "r")
	if f then
		existing = f:read("*a")
		f:close()
	end

	-- Strip all previously-written plugin blocks so they can be cleanly rewritten.
	local base_lines = {}
	local in_block = false
	for _, line in ipairs(vim.split(existing, "\n", { plain = true })) do
		if line:match("^; %[yaml%-language%-highlight:[%w%-_]+%]$") then
			in_block = true
		end
		if not in_block then
			table.insert(base_lines, line)
		end
		if line:match("^; %[/yaml%-language%-highlight:[%w%-_]+%]$") then
			in_block = false
		end
	end

	local base = table.concat(base_lines, "\n"):gsub("%s+$", "")

	-- Rebuild blocks in sorted order for deterministic output.
	local langs = vim.tbl_keys(injections)
	table.sort(langs)

	local content = base
	for _, lang in ipairs(langs) do
		local keywords = injections[lang]
		if #keywords > 0 then
			local parts = {}
			for _, kw in ipairs(keywords) do
				table.insert(parts, glob_to_regex(kw))
			end
			local pattern = "^(" .. table.concat(parts, "|") .. ")$"
			content = content .. "\n\n" .. table.concat({
				"; [yaml-language-highlight:" .. lang .. "]",
				"((block_mapping_pair",
				"  key: (flow_node (plain_scalar (string_scalar) @_key))",
				"  value: (block_node (block_scalar) @injection.content))",
				" (#match? @_key " .. string.format("%q", pattern) .. ")",
				" (#set! injection.language " .. string.format("%q", lang) .. ")",
				" (#set! injection.include-children true))",
				"; [/yaml-language-highlight:" .. lang .. "]",
			}, "\n")
		end
	end
	content = content .. "\n"

	if content == existing then
		return
	end

	local out = io.open(path, "w")
	if not out then
		vim.notify("yaml-language-highlight: could not write " .. path, vim.log.levels.WARN)
		return
	end
	out:write(content)
	out:close()
end

--- Plugin entry point. Call once from your Neovim config or plugin loader.
---
--- @param opts? { injections?: table<string, string[]> }
function M.setup(opts)
	opts = opts or {}

	if opts.injections then
		write_injections(opts.injections)
	end

	vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost", "TextChanged", "InsertLeave" }, {
		group = vim.api.nvim_create_augroup("yaml-language-highlight", { clear = true }),
		pattern = { "*.yaml", "*.yml" },
		callback = function(ev)
			apply_highlights(ev.buf)
		end,
	})
end

return M
