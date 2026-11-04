-- Org-mode style TODO keyword sequences, e.g. "TODO NEXT | DONE CANCELED".
-- Pure Lua: no Neovim API, so it is easy to test.
local M = {}

-- LATTICE_SYNTAX_SPEC §4.1 default workflow.
M.DEFAULT = { "TODO NEXT WAITING | DONE CANCELED" }

local function words(text)
  local list = {}
  for word in text:gmatch("%S+") do
    list[#list + 1] = word
  end
  return list
end

--- Parses one sequence. As in org: words before "|" are open states, words
--- after it are done states; without "|" the last word is the only done
--- state. A fast-access suffix such as "TODO(t)" or "DONE(d!)" is dropped.
--- @return { open: string[], done: string[] }|nil
--- @return string|nil err
function M.parse_sequence(text)
  if type(text) ~= "string" then
    return nil, "a sequence must be a string"
  end
  local open, done, seen_bar = {}, {}, false
  for _, word in ipairs(words(text)) do
    if word == "|" then
      if seen_bar then
        return nil, ("%q has more than one |"):format(text)
      end
      seen_bar = true
    else
      local keyword = word:gsub("%b()$", "")
      if keyword == "" or not keyword:match("^[%w_%-]+$") then
        return nil, ("%q is not a valid keyword in %q"):format(word, text)
      end
      table.insert(seen_bar and done or open, keyword)
    end
  end
  if not seen_bar then
    if #open < 1 then
      return nil, "a sequence needs at least one keyword"
    end
    done[1] = table.remove(open)
  end
  if #open + #done == 0 then
    return nil, "a sequence needs at least one keyword"
  end
  return { open = open, done = done }
end

--- Builds the keyword table from one or more sequence strings.
--- @param sequences string|string[]
--- @return { states: table<string, "open"|"done">, first_open: string|nil, sequences: string[], cycles: string[][] }|nil
--- @return string|nil err
function M.build(sequences)
  if type(sequences) == "string" then
    sequences = { sequences }
  end
  if type(sequences) ~= "table" or #sequences == 0 then
    return nil, "expected a sequence string or a list of them"
  end
  -- cycles: each sequence's keywords in order (open, then done), for
  -- stepping an item through its states.
  local result = { states = {}, sequences = {}, cycles = {} }
  for _, text in ipairs(sequences) do
    local sequence, err = M.parse_sequence(text)
    if not sequence then
      return nil, err
    end
    for kind, list in pairs({ open = sequence.open, done = sequence.done }) do
      for _, keyword in ipairs(list) do
        if result.states[keyword] and result.states[keyword] ~= kind then
          return nil, ("%s is both an open and a done state"):format(keyword)
        end
        result.states[keyword] = kind
      end
    end
    result.first_open = result.first_open or sequence.open[1]
    result.sequences[#result.sequences + 1] = text
    local cycle = {}
    for _, list in ipairs({ sequence.open, sequence.done }) do
      for _, keyword in ipairs(list) do
        cycle[#cycle + 1] = keyword
      end
    end
    result.cycles[#result.cycles + 1] = cycle
  end
  return result
end

local function is_list(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for _ in pairs(value) do
    count = count + 1
  end
  return count == #value
end

--- Builds a keyword table from a workflow in the spec's shape,
--- `{ active = { "TODO", "IN PROGRESS" }, done = { "DONE" } }`. States may
--- contain spaces (Extended: Org keywords cannot).
--- @return table|nil kws  same shape as build()
--- @return string|nil err
function M.from_workflow(workflow)
  if type(workflow) ~= "table" then
    return nil, "a workflow must be an object with active and done lists"
  end
  local result = { states = {}, sequences = {}, cycles = {} }
  local cycle = {}
  for _, kind in ipairs({ "active", "done" }) do
    local list = workflow[kind]
    if list == nil then
      list = {}
    end
    if not is_list(list) then
      return nil, kind .. " must be a list of state names"
    end
    for _, state in ipairs(list) do
      if type(state) ~= "string" then
        return nil, ("%s contains a non-string state"):format(kind)
      end
      state = state:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
      if state == "" or state:find("|", 1, true) or not state:match("^[%w_%- ]+$") then
        return nil, ("%q is not a valid state name"):format(state)
      end
      local value = kind == "active" and "open" or "done"
      if result.states[state] and result.states[state] ~= value then
        return nil, ("%s is both an active and a done state"):format(state)
      end
      if not result.states[state] then
        cycle[#cycle + 1] = state
      end
      result.states[state] = value
      if value == "open" then
        result.first_open = result.first_open or state
      end
    end
  end
  if #cycle == 0 then
    return nil, "a workflow needs at least one state"
  end
  result.cycles[1] = cycle
  result.sequences[1] = table.concat(workflow.active or {}, " ") .. " | " .. table.concat(workflow.done or {}, " ")
  return result
end

-- A scalar from YAML: trims, drops a trailing " # comment" outside quotes,
-- and removes surrounding quotes.
local function scalar(value)
  value = value:gsub("^%s+", ""):gsub("%s+$", "")
  local quoted = value:match('^"(.-)"') or value:match("^'(.-)'")
  if quoted then
    return quoted
  end
  return (value:gsub("%s+#.*$", ""))
end

-- Items of a flow list "[a, b]", or nil when `value` is not one.
local function flow_list(value)
  local inner = value:match("^%[(.*)%]$")
  if not inner then
    return nil
  end
  local items = {}
  for item in inner:gmatch("[^,]+") do
    item = scalar(item)
    if item ~= "" then
      items[#items + 1] = item
    end
  end
  return items
end

-- YAML front matter keys: a single word, optionally quoted, then ":".
local function key_line(line)
  return line:match("^[%w_%-]+:%s") or line:match("^[%w_%-]+:$") or line:match("^[\"'][^\"']+[\"']:")
end

-- True when a front matter line looks like YAML: a key, an indented line, a
-- list item, or blank. A Markdown heading or prose line means the block is
-- not front matter (for example a note that opens with a horizontal rule).
local function yaml_line(line)
  return line:match("^%s*$") or key_line(line) or line:match("^%s") or line:match("^%-%s") or line:match("^%-$")
end

--- The value of a scalar key such as `project:` in the note's YAML front
--- matter, or nil. Only simple `key: value` lines are read.
function M.front_matter_scalar(lines, key)
  local _, _, last = M.front_matter(lines)
  for i = 2, last - 1 do
    local value = (lines[i] or ""):gsub("\r$", ""):match("^" .. key .. ":%s*(.-)%s*$")
    if value then
      value = scalar((value:gsub("^#.*$", "")))
      if value ~= "" then
        return value, i
      end
      return nil
    end
  end
end

--- Reads the `todo` key from YAML front matter at the top of a note:
---
---     ---
---     todo: TODO NEXT | DONE CANCELED   # optional comment
---     ---
---
--- or, for several sequences, a block list (indented or not) or flow list:
---
---     todo:
---       - TODO NEXT | DONE
---       - BUG | FIXED
---     todo: [TODO NEXT | DONE, BUG | FIXED]
---
--- Only this key is read; the rest of the front matter is ignored. The block
--- counts as front matter only when it starts with a `key:` line and every
--- line looks like YAML (keys, indented lines, list items, blanks).
--- @return string[]|nil sequences  nil when there is no `todo` key
--- @return integer|nil line  1-based line of the `todo` key
--- @return integer last  last line of the front matter (0 if none)
function M.front_matter(lines)
  local function line_at(i)
    local line = (lines[i] or ""):gsub("\r$", "")
    if i == 1 then
      line = line:gsub("^\239\187\191", "")
    end
    return line
  end
  if line_at(1) ~= "---" then
    return nil, nil, 0
  end
  local close, seen_key
  for i = 2, #lines do
    local line = line_at(i)
    if line == "---" or line == "..." then
      close = i
      break
    end
    -- Front matter is a mapping: its first content line must be a key.
    if not yaml_line(line) or (not seen_key and not line:match("^%s*$") and not key_line(line)) then
      return nil, nil, 0
    end
    seen_key = seen_key or key_line(line) ~= nil
  end
  if not close then
    return nil, nil, 0
  end

  for i = 2, close - 1 do
    local value = line_at(i):match("^todo:%s*(.-)%s*$")
    if value then
      value = value:gsub("^#.*$", "")
      local flow = flow_list(value)
      if flow then
        return flow, i, close
      end
      if scalar(value) ~= "" then
        return { scalar(value) }, i, close
      end
      local items = {}
      for j = i + 1, close - 1 do
        local line = line_at(j)
        local item = line:match("^%s*%-%s+(.-)%s*$")
        if item then
          items[#items + 1] = scalar(item)
        elseif not line:match("^%s*$") and not line:match("^%s*#") then
          break
        end
      end
      return items, i, close
    end
  end
  return nil, nil, close
end

--- The choices for picking a state (Org's C-c C-t with selection): every
--- state of the workflow in sequence order, then "(no state)".
M.NO_STATE = "(no state)"
function M.choices(kws)
  local list = {}
  for _, cycle in ipairs(kws.cycles) do
    vim.list_extend(list, cycle)
  end
  list[#list + 1] = M.NO_STATE
  return list
end

return M
