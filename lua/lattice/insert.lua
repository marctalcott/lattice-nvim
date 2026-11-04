-- Explicit, user-triggered edits to the current note. Nothing here saves to disk.
local config = require("lattice.config")
local dashboard = require("lattice.dashboard")
local keywords = require("lattice.keywords")
local markdown = require("lattice.markdown")
local tasks = require("lattice.tasks")

local M = {}

local function warn(message)
  vim.notify("Lattice: " .. message, vim.log.levels.WARN)
end

local function current_markdown_buffer(purpose)
  local buf = vim.api.nvim_get_current_buf()
  local markdown = vim.bo[buf].filetype == "markdown" or vim.api.nvim_buf_get_name(buf):match("%.md$")
  if dashboard.is_dashboard(buf) or vim.bo[buf].buftype ~= "" or not markdown then
    warn("open a Markdown note to " .. (purpose or "add a task"))
    return nil
  end
  if not vim.bo[buf].modifiable then
    warn("this buffer is not modifiable")
    return nil
  end
  return buf
end

-- Parses the buffer's lines. If the Markdown parser is unavailable, warns
-- and returns an empty result, so commands change nothing.
local function parse(lines, cfg)
  local result, err = tasks.parse(lines, cfg)
  if not result then
    warn(err)
    return { tasks = {}, sections = {}, keywords = cfg.keywords, keywords_at = {}, failed = true }
  end
  return result
end

local function load_config()
  local root = config.options.root
  if not root then
    return config.defaults()
  end
  local cfg, _, err = config.load(root)
  if not cfg then
    vim.notify("Lattice: " .. err, vim.log.levels.ERROR)
    return nil
  end
  return cfg
end

--- Warns when the entry at `line` is not read back as a task, which happens
--- when it lands inside a code block (for example one that is never closed).
function M.check_visible(buf, line, cfg)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, task in ipairs(parse(lines, cfg).tasks) do
    if task.line == line then
      return true
    end
  end
  warn(("line %d was added, but Lattice won't list it: it is inside a code block (```). Move it out, or close the block if it is never closed."):format(line))
  return false
end

--- Inserts an Org heading task, "<hashes> <STATE> <text>", plus any
--- `drawer` lines below it. Like Org's C-S-RET, the new heading takes the
--- level of the heading the cursor is in and goes after that heading's
--- subtree; with no heading above the cursor it is a level-2 heading on
--- the line below (after any front matter). Blank lines keep headings
--- apart, as Markdown linters expect.
--- Returns the heading's 1-based line, or nil and an error.
function M.insert_heading(buf, state, text, cfg, cursor, drawer)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local structure, err = markdown.parse(lines)
  if not structure then
    return nil, err
  end
  local parsed = parse(lines, cfg)
  cursor = math.max(cursor, structure.front_matter)

  local enclosing
  for _, heading in ipairs(structure.headings) do
    if heading.line <= cursor and heading.stop >= cursor then
      enclosing = heading -- the innermost wins: headings come in order
    end
  end

  local kws = enclosing and parsed.keywords_at[enclosing.line] or parsed.keywords
  if state == "first_open" then
    state = kws.first_open
    if not state then
      return nil, "this note's workflow has no active state"
    end
  elseif not kws.states[state] then
    return nil, ("this note's workflow has no %s state"):format(state)
  end

  local level = enclosing and enclosing.level or 2
  local after = enclosing and enclosing.stop or cursor
  if #lines == 1 and lines[1] == "" then
    after = 0
  end
  while after > 0 and vim.trim(lines[after] or "") == "" and (not enclosing or after > enclosing.line) do
    after = after - 1
  end

  local block = { ("%s %s %s"):format(("#"):rep(level), state, text) }
  vim.list_extend(block, drawer or {})
  local heading_line = after + 1
  if after > 0 then
    table.insert(block, 1, "")
    heading_line = after + 2
  end
  local next_line = lines[after + 1]
  if next_line ~= nil and vim.trim(next_line) ~= "" then
    block[#block + 1] = ""
  end
  if #lines == 1 and lines[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, block)
  else
    vim.api.nvim_buf_set_lines(buf, after, after, false, block)
  end
  return heading_line
end

-- The state after `current` (nil = no keyword) in `direction` (1 forward,
-- -1 back). Like org: an item steps through the sequence that holds its
-- keyword, then back to no keyword; an item without one starts on the
-- first sequence.
local function step(cycles, current, direction)
  local cycle = cycles[1]
  local index = 0
  for _, candidate in ipairs(cycles) do
    for i, keyword in ipairs(candidate) do
      if keyword == current then
        cycle, index = candidate, i
        break
      end
    end
    if index > 0 then
      break
    end
  end
  if index == 0 then
    index = direction > 0 and 0 or #cycle + 1
  end
  return cycle[index + direction] -- nil past either end: no keyword
end

--- Splits a list item or ATX heading into its prefix (marker and any
--- checkbox, or the hashes) and the text after it. nil for other lines.
local function item_parts(line)
  local prefix, text = line:match("^([ \t]*[-*+][ \t]+%[[ xX]%][ \t]+)(.*)$")
  if not prefix then
    prefix, text = line:match("^([ \t]*[-*+][ \t]+)(.*)$")
  end
  if not prefix then
    prefix, text = line:match("^( ? ? ?#+[ \t]+)(.*)$")
    if prefix and #prefix:match("#+") > 6 then
      prefix = nil
    end
  end
  return prefix, text
end

--- The line with its keyword moved one state in `direction` (1 forward, -1
--- back), using the note's keyword table. Returns the new line, the 0-based
--- start and end columns of the replaced span, the new state (nil when the
--- keyword was removed) and the text that replaces the span; or nil and an
--- error.
function M.cycle_line(line, kws, direction)
  local prefix, text = item_parts(line)
  if not prefix then
    return nil, "put the cursor on a list item (- …) or a heading (# …)"
  end
  local word, gap = text:match("^(%S+)([ \t]*)")
  local current = word and kws.states[word] and word or nil
  local old = current and current .. gap or ""
  local rest = text:sub(#old + 1)
  local state = step(kws.cycles, current, direction)
  if state and rest:match("^%s*$") then
    return nil, "this item has no text; type the task first"
  end
  local new = state and state .. " " or ""
  return prefix .. new .. rest, #prefix, #prefix + #old, state, new
end

--- Moves the keyword of the item on `row` (1-based) one state in
--- `direction`. Edits only that span of the line, so the change is one undo
--- step. Refuses, changing nothing, when Lattice would not list the result
--- (for example inside a code block). Returns the new state ("" for none),
--- or nil and an error.
function M.cycle(buf, row, cfg, direction)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local _, _, front_end = keywords.front_matter(lines)
  if row <= front_end then
    return nil, "the cursor is in the front matter; put it on a list item or heading"
  end
  local parsed = parse(lines, cfg)
  if parsed.failed then
    return nil, "the Markdown parser is unavailable"
  end
  -- The workflow in effect at this line (project, :WORKFLOW:, or note).
  local kws = parsed.keywords_at[row] or parsed.keywords
  if #kws.cycles == 0 then
    return nil, "this note has no keyword sequences"
  end
  local line = lines[row]
  if not line:match("^ ? ? ?#") then
    -- Org has no list-item tasks. A Lattice v0.1 keyword bullet can still
    -- change or drop its state, but a plain item never gains one.
    local _, text = item_parts(line)
    local word = text and text:match("^%[[ xX]%][ \t]+(%S.*)$") or text
    local has_state = word and tasks.split_state(word, kws) ~= nil
    if text and not has_state then
      return nil, "list items aren't tasks in Org; put the cursor on a heading (## TODO …), or use <leader>lt to add one"
    end
  end
  local new_line, start, stop, state, inserted = M.cycle_line(line, kws, direction)
  if not new_line then
    return nil, start
  end
  if state then
    lines[row] = new_line
    local listed = false
    for _, task in ipairs(parse(lines, cfg).tasks) do
      listed = listed or task.line == row
    end
    if not listed then
      return nil, "Lattice wouldn't list this line as an item: it is inside a code block or indented as code"
    end
  end
  vim.api.nvim_buf_set_text(buf, row - 1, start, row - 1, stop, { inserted })
  return state or ""
end

local function cycle_command(direction)
  local buf = current_markdown_buffer("change a task's state")
  if not buf then
    return
  end
  local cfg = load_config()
  if not cfg then
    return
  end
  local _, err = M.cycle(buf, vim.api.nvim_win_get_cursor(0)[1], cfg, direction)
  if err then
    warn(err)
  end
end

function M.next_state()
  cycle_command(1)
end

function M.prev_state()
  cycle_command(-1)
end

local function usable(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable then
    warn("the note is no longer available; task not added")
    return false
  end
  return true
end

-- nil means cancelled; "" means left blank.
local function ask(label, on_value)
  vim.ui.input({ prompt = label }, function(value)
    if type(value) == "string" then
      on_value(vim.trim(value))
    end
  end)
end

-- Inserts a heading once the prompts are answered. The cursor line is
-- captured when the command starts, so the placement matches what the
-- user saw.
local function finish(buf, state, text, cursor, drawer)
  if not usable(buf) then
    return
  end
  local cfg = load_config()
  if not cfg then
    return
  end
  local line, err = M.insert_heading(buf, state, text, cfg, cursor, drawer)
  if line then
    M.check_visible(buf, line, cfg)
  else
    warn(err .. "; task not added")
  end
end

function M.add_todo()
  local buf = current_markdown_buffer()
  if not buf then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  ask("TODO: ", function(text)
    if text ~= "" then
      finish(buf, "first_open", text, cursor)
    end
  end)
end

--- Adds "## WAITING <text>", with an :ASSIGNED: drawer when a name is
--- given: Org's way of tracking what others owe you.
function M.add_waiting()
  local buf = current_markdown_buffer()
  if not buf then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  ask("Waiting on (name, optional): ", function(person)
    person = vim.trim((person:gsub("^@", "")))
    ask("Waiting for: ", function(text)
      if text == "" then
        return
      end
      local drawer = person ~= "" and { ":PROPERTIES:", ":ASSIGNED: " .. person, ":END:" } or nil
      finish(buf, "WAITING", text, cursor, drawer)
    end)
  end)
end

return M
