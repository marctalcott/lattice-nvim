-- Org-mode style TODO keyword sequences, e.g. "TODO NEXT | DONE CANCELED".
-- Pure Lua: no Neovim API, so it is easy to test.
local M = {}

M.DEFAULT = { "TODO | DONE" }

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
--- @return { states: table<string, "open"|"done">, first_open: string|nil, sequences: string[] }|nil
--- @return string|nil err
function M.build(sequences)
  if type(sequences) == "string" then
    sequences = { sequences }
  end
  if type(sequences) ~= "table" or #sequences == 0 then
    return nil, "expected a sequence string or a list of them"
  end
  local result = { states = {}, sequences = {} }
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
  end
  return result
end

local function unquote(value)
  value = value:gsub("^%s+", ""):gsub("%s+$", "")
  local inner = value:match('^"(.*)"$') or value:match("^'(.*)'$")
  return inner or value
end

--- Reads the `todo` key from YAML front matter at the top of a note:
---
---     ---
---     todo: TODO NEXT | DONE CANCELED
---     ---
---
--- or, for several sequences, a block list:
---
---     todo:
---       - TODO NEXT | DONE
---       - BUG | FIXED
---
--- Only this key is read; the rest of the front matter is ignored.
--- @return string[]|nil sequences  nil when there is no `todo` key
--- @return integer|nil line  1-based line of the `todo` key
--- @return integer last  last line of the front matter (0 if none)
function M.front_matter(lines)
  local first = (lines[1] or ""):gsub("^\239\187\191", ""):gsub("\r$", "")
  if first ~= "---" then
    return nil, nil, 0
  end
  local close
  for i = 2, #lines do
    local line = lines[i]:gsub("\r$", "")
    if line == "---" or line == "..." then
      close = i
      break
    end
  end
  if not close then
    return nil, nil, 0
  end

  for i = 2, close - 1 do
    local line = lines[i]:gsub("\r$", "")
    local value = line:match("^todo:%s*(.-)%s*$")
    if value then
      if value ~= "" then
        return { unquote(value) }, i, close
      end
      local items = {}
      for j = i + 1, close - 1 do
        local item = lines[j]:gsub("\r$", ""):match("^%s+%-%s+(.-)%s*$")
        if not item then
          break
        end
        items[#items + 1] = unquote(item)
      end
      return items, i, close
    end
  end
  return nil, nil, close
end

return M
