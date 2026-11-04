-- Planning lines and property drawers (LATTICE_SYNTAX_SPEC §3.4, §3.5, §7).
--
-- Metadata sits directly below a heading. Reading stops at the first line
-- that is neither a planning line nor part of a drawer, so prose that
-- merely looks like metadata further down is never read (§13.3 rule 2).
--
-- Adapted from Org: blank lines may separate the heading, its planning
-- lines and its drawer, because Markdown formatters (markdownlint MD022,
-- Prettier) insert a blank line after every heading. A blank line is
-- skipped only when the next non-blank line is metadata.
local timestamp = require("lattice.timestamp")

local M = {}

local PLANNING = { SCHEDULED = "scheduled", DEADLINE = "deadline", CLOSED = "closed" }

-- A planning line: one or more "KEYWORD: <timestamp>" pairs and nothing
-- else. Returns the pairs, or nil for any other line.
local function planning_pairs(text)
  local pairs_found = {}
  local rest = text:gsub("(%u+):%s*([<%[][^>%]]*[>%]])", function(keyword, raw)
    if PLANNING[keyword] then
      pairs_found[#pairs_found + 1] = { keyword = keyword, raw = raw }
      return ""
    end
  end)
  if #pairs_found > 0 and vim.trim(rest) == "" then
    return pairs_found
  end
end

--- Reads metadata from lines[first..last].
--- @param diagnose fun(line: integer, category: string, message: string)
--- @return table meta  { scheduled, deadline, closed: lattice.Timestamp|nil,
---   properties: table<string, string> (UPPERCASE keys), names: table<string, string>
---   (original spelling), planning_lines: integer[], drawer: {start, stop}|nil,
---   last: integer (last metadata line, or first - 1) }
function M.read(lines, first, last, diagnose)
  local meta = { properties = {}, names = {}, planning_lines = {}, last = first - 1 }
  local i = first
  local function trimmed(n)
    return vim.trim((lines[n] or ""):gsub("\r$", ""))
  end
  local function starts_metadata(text)
    return planning_pairs(text) ~= nil or text:upper() == ":PROPERTIES:"
  end
  while i <= last do
    local text = trimmed(i)
    if text == "" then
      local j = i
      while j <= last and trimmed(j) == "" do
        j = j + 1
      end
      if j > last or not starts_metadata(trimmed(j)) then
        break
      end
      i = j
      text = trimmed(i)
    end
    local found = planning_pairs(text)
    if found then
      for _, pair in ipairs(found) do
        local field = PLANNING[pair.keyword]
        local ts, err = timestamp.parse(pair.raw)
        if not ts then
          diagnose(i, "invalid-timestamp", ("%s: %s"):format(pair.keyword, err))
        elseif meta[field] then
          diagnose(i, "duplicate-planning", ("%s appears more than once"):format(pair.keyword))
        else
          local actual = timestamp.weekday_mismatch(ts)
          if actual then
            diagnose(i, "weekday-mismatch", ("%s %s is a %s, not %s"):format(pair.keyword, ts.date, actual, ts.weekday))
          end
          ts.line = i
          meta[field] = ts
        end
      end
      meta.planning_lines[#meta.planning_lines + 1] = i
      meta.last = i
      i = i + 1
    elseif text:upper() == ":PROPERTIES:" then
      local stop
      for j = i + 1, last do
        if vim.trim((lines[j] or ""):gsub("\r$", "")):upper() == ":END:" then
          stop = j
          break
        end
      end
      if not stop then
        diagnose(i, "malformed-drawer", ":PROPERTIES: has no matching :END:; its properties were ignored")
        break
      end
      for j = i + 1, stop - 1 do
        local entry = vim.trim((lines[j] or ""):gsub("\r$", ""))
        local name, value = entry:match("^:([^:%s]+):%s+(.-)$")
        if not name then
          name = entry:match("^:([^:%s]+):$")
          value = ""
        end
        if not name then
          diagnose(j, "malformed-drawer", ("%q is not a :NAME: value line"):format(entry))
        else
          local append = name:sub(-1) == "+"
          if append then
            name = name:sub(1, -2)
          end
          local key = name:upper()
          if append and meta.properties[key] then
            meta.properties[key] = meta.properties[key] .. " " .. value
          else
            if meta.properties[key] and not append then
              diagnose(j, "duplicate-property", (":%s: appears more than once in this drawer"):format(name))
            end
            meta.properties[key] = value
            meta.names[key] = meta.names[key] or name
          end
        end
      end
      meta.drawer = { start = i, stop = stop }
      meta.last = stop
      i = stop + 1
    else
      break
    end
  end
  return meta
end

return M
