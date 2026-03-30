#!/usr/bin/env luajit
--- Analyze Claude Code transcript files to compare token usage with/without codescan tools.
---
--- Parses JSONL transcript files from ~/.claude/projects/*/sessions/ and reports:
--- - Per-tool token usage (input + output)
--- - Codescan MCP tools vs built-in tools (Read/Grep/Glob/Edit)
--- - Session-level summaries
---
--- Usage:
---     luajit scripts/token-usage-analyzer.lua [--last N] [--all]

local cjson = require("cjson")

-- CLI argument parsing
local function parse_args()
	local args = { last = 10 }
	local i = 1
	while i <= #arg do
		if arg[i] == "--last" then
			i = i + 1
			args.last = tonumber(arg[i]) or 10
		elseif arg[i] == "--all" then
			args.all = true
		elseif arg[i] == "--sessions-dir" then
			i = i + 1
			args.sessions_dir = arg[i]
		elseif arg[i] == "--help" or arg[i] == "-h" then
			print("Usage: luajit token-usage-analyzer.lua [--last N] [--all] [--sessions-dir DIR]")
			os.exit(0)
		end
		i = i + 1
	end
	return args
end

-- Find session JSONL files
local function find_session_files(sessions_dir)
	local home = os.getenv("HOME") or "/tmp"
	local base = sessions_dir or (home .. "/.claude/projects")

	local files = {}
	-- Use find to locate JSONL files
	local handle = io.popen('find "' .. base .. '" -name "*.jsonl" -type f 2>/dev/null | head -500')
	if not handle then return files end
	for line in handle:lines() do
		-- Get mtime for sorting
		local mtime_handle = io.popen('stat -f "%m" "' .. line .. '" 2>/dev/null || stat -c "%Y" "' .. line .. '" 2>/dev/null')
		local mtime = 0
		if mtime_handle then
			mtime = tonumber(mtime_handle:read("*l")) or 0
			mtime_handle:close()
		end
		files[#files + 1] = { path = line, mtime = mtime }
	end
	handle:close()

	-- Sort by mtime descending (newest first)
	table.sort(files, function(a, b) return a.mtime > b.mtime end)
	return files
end

-- Parse a single transcript JSONL file
local function parse_transcript(path)
	local tool_stats = {} -- tool_name -> {calls, input_tokens, output_tokens}
	local totals = { input_tokens = 0, output_tokens = 0, turns = 0 }
	local session_date = nil

	local f = io.open(path, "r")
	if not f then return nil end

	for line in f:lines() do
		if line == "" then goto continue end

		local ok, entry = pcall(cjson.decode, line)
		if not ok then goto continue end

		if not session_date and entry.timestamp then
			session_date = entry.timestamp:sub(1, 10)
		end

		if entry.type ~= "assistant" then goto continue end

		local msg = entry.message or {}
		local usage = msg.usage or {}

		local input_tokens = (usage.input_tokens or 0)
			+ (usage.cache_read_input_tokens or 0)
			+ (usage.cache_creation_input_tokens or 0)
		local output_tokens = usage.output_tokens or 0

		totals.input_tokens = totals.input_tokens + input_tokens
		totals.output_tokens = totals.output_tokens + output_tokens
		totals.turns = totals.turns + 1

		-- Extract tool calls
		local content = msg.content or {}
		for _, block in ipairs(content) do
			if block.type == "tool_use" then
				local name = block.name or "unknown"
				if not tool_stats[name] then
					tool_stats[name] = { calls = 0, input_tokens = 0, output_tokens = 0 }
				end
				local ts = tool_stats[name]
				ts.calls = ts.calls + 1
				ts.input_tokens = ts.input_tokens + input_tokens
				ts.output_tokens = ts.output_tokens + output_tokens
			end
		end

		::continue::
	end
	f:close()

	-- Check if any tools were found
	local has_tools = false
	for _ in pairs(tool_stats) do has_tools = true; break end
	if not has_tools then return nil end

	return {
		path = path,
		date = session_date,
		tools = tool_stats,
		totals = totals,
	}
end

-- Tool categorization
local BUILTIN_TOOLS = {
	Read = true, Grep = true, Glob = true, Edit = true, Write = true, Agent = true,
}

local function categorize_tool(name)
	if BUILTIN_TOOLS[name] then return "builtin" end
	if name:match("^mcp__codescan__") then return "codescan" end
	return "other"
end

-- Format number with commas
local function commify(n)
	local s = tostring(math.floor(n))
	local pos = #s % 3
	if pos == 0 then pos = 3 end
	local parts = { s:sub(1, pos) }
	for i = pos + 1, #s, 3 do
		parts[#parts + 1] = s:sub(i, i + 2)
	end
	return table.concat(parts, ",")
end

-- Right-align string to width
local function rpad(s, w)
	s = tostring(s)
	if #s >= w then return s end
	return string.rep(" ", w - #s) .. s
end

-- Left-pad string to width
local function lpad(s, w)
	s = tostring(s)
	if #s >= w then return s end
	return s .. string.rep(" ", w - #s)
end

-- Print report
local function print_report(sessions, last_n)
	if last_n and not sessions.all then
		local limited = {}
		for i = 1, math.min(last_n, #sessions) do
			limited[i] = sessions[i]
		end
		sessions = limited
	end

	print(string.rep("=", 70))
	print(string.format("Claude Code Token Usage Report — %d session(s)", #sessions))
	print(string.rep("=", 70))
	print()

	-- Aggregate
	local agg = {
		builtin = { calls = 0, input_tokens = 0, output_tokens = 0 },
		codescan = { calls = 0, input_tokens = 0, output_tokens = 0 },
		other = { calls = 0, input_tokens = 0, output_tokens = 0 },
	}
	local tool_details = {}
	local total_tokens = 0

	for _, session in ipairs(sessions) do
		for tool_name, stats in pairs(session.tools) do
			local cat = categorize_tool(tool_name)
			local a = agg[cat]
			a.calls = a.calls + stats.calls
			a.input_tokens = a.input_tokens + stats.input_tokens
			a.output_tokens = a.output_tokens + stats.output_tokens

			if not tool_details[tool_name] then
				tool_details[tool_name] = { calls = 0, input_tokens = 0, output_tokens = 0 }
			end
			local td = tool_details[tool_name]
			td.calls = td.calls + stats.calls
			td.input_tokens = td.input_tokens + stats.input_tokens
			td.output_tokens = td.output_tokens + stats.output_tokens
		end
		total_tokens = total_tokens + session.totals.input_tokens + session.totals.output_tokens
	end

	-- Category summary
	print("Category Summary (tokens = input + output attributed to tool-call turns):\n")
	print(string.format("  %s %s %s %s %s",
		lpad("Category", 20), rpad("Calls", 8), rpad("Input Tokens", 14), rpad("Output Tokens", 14), rpad("Total", 14)))
	print(string.format("  %s %s %s %s %s",
		string.rep("-", 20), string.rep("-", 8), string.rep("-", 14), string.rep("-", 14), string.rep("-", 14)))

	for _, pair in ipairs({
		{ "Built-in tools", agg.builtin },
		{ "Codescan MCP", agg.codescan },
		{ "Other", agg.other },
	}) do
		local label, a = pair[1], pair[2]
		local total = a.input_tokens + a.output_tokens
		print(string.format("  %s %s %s %s %s",
			lpad(label, 20), rpad(commify(a.calls), 8),
			rpad(commify(a.input_tokens), 14), rpad(commify(a.output_tokens), 14),
			rpad(commify(total), 14)))
	end
	print(string.format("\n  Total session tokens: %s\n", commify(total_tokens)))

	-- Top tools by call count
	local sorted_tools = {}
	for name, stats in pairs(tool_details) do
		sorted_tools[#sorted_tools + 1] = { name = name, stats = stats }
	end
	table.sort(sorted_tools, function(a, b) return a.stats.calls > b.stats.calls end)

	print("Top tools by call count:\n")
	print(string.format("  %s %s %s %s",
		lpad("Tool", 40), lpad("Cat", 10), rpad("Calls", 8), rpad("Tokens", 14)))
	print(string.format("  %s %s %s %s",
		string.rep("-", 40), string.rep("-", 10), string.rep("-", 8), string.rep("-", 14)))

	for i = 1, math.min(20, #sorted_tools) do
		local t = sorted_tools[i]
		local cat = categorize_tool(t.name)
		local total = t.stats.input_tokens + t.stats.output_tokens
		print(string.format("  %s %s %s %s",
			lpad(t.name, 40), lpad(cat, 10),
			rpad(commify(t.stats.calls), 8), rpad(commify(total), 14)))
	end

	-- Codescan adoption ratios
	local nav_tools = { "Read", "Grep", "Glob" }
	local builtin_nav = 0
	for _, t in ipairs(nav_tools) do
		if tool_details[t] then builtin_nav = builtin_nav + tool_details[t].calls end
	end

	local codescan_nav_tools = {
		"mcp__codescan__search", "mcp__codescan__symbols",
		"mcp__codescan__read_file", "mcp__codescan__query",
	}
	local codescan_nav = 0
	for _, t in ipairs(codescan_nav_tools) do
		if tool_details[t] then codescan_nav = codescan_nav + tool_details[t].calls end
	end

	if builtin_nav + codescan_nav > 0 then
		local ratio = codescan_nav / (builtin_nav + codescan_nav) * 100
		print(string.format("\n  Codescan adoption (navigation): %d/%d calls (%.1f%%)",
			codescan_nav, builtin_nav + codescan_nav, ratio))
	end

	local edit_builtin_tools = { "Edit", "Write" }
	local builtin_edit = 0
	for _, t in ipairs(edit_builtin_tools) do
		if tool_details[t] then builtin_edit = builtin_edit + tool_details[t].calls end
	end

	local codescan_edit_tools = {
		"mcp__codescan__replace_content", "mcp__codescan__replace_symbol",
		"mcp__codescan__replace_lines", "mcp__codescan__insert_at",
		"mcp__codescan__insert_after", "mcp__codescan__insert_before",
		"mcp__codescan__create_file", "mcp__codescan__destroy_file",
	}
	local codescan_edit = 0
	for _, t in ipairs(codescan_edit_tools) do
		if tool_details[t] then codescan_edit = codescan_edit + tool_details[t].calls end
	end

	if builtin_edit + codescan_edit > 0 then
		local ratio = codescan_edit / (builtin_edit + codescan_edit) * 100
		print(string.format("  Codescan adoption (editing):    %d/%d calls (%.1f%%)",
			codescan_edit, builtin_edit + codescan_edit, ratio))
	end

	print()
end

-- Main
local args = parse_args()
local session_files = find_session_files(args.sessions_dir)
io.stderr:write(string.format("Found %d session file(s)\n", #session_files))

local sessions = {}
for _, entry in ipairs(session_files) do
	local session = parse_transcript(entry.path)
	if session then
		sessions[#sessions + 1] = session
	end
end

if #sessions == 0 then
	io.stderr:write("No sessions with tool usage found.\n")
	os.exit(1)
end

local last_n = args.all and #sessions or args.last
print_report(sessions, last_n)
