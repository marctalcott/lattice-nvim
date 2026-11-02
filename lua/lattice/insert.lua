-- Explicit, user-triggered edits to the current note. Nothing here saves to disk.
local config = require("lattice.config")
local dashboard = require("lattice.dashboard")
local keywords = require("lattice.keywords")
local parser = require("lattice.parser")

local M = {}

local function warn(message)
  vim.notify("Lattice: " .. message, vim.log.levels.WARN)
end

local function current_markdown_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local markdown = vim.bo[buf].filetype == "markdown" or vim.api.nvim_buf_get_name(buf):match("%.md$")
  if dashboard.is_dashboard(buf) or vim.bo[buf].buftype ~= "" or not markdown then
    warn("open a Markdown note to add a task")
    return nil
  end
  if not vim.bo[buf].modifiable then
    warn("this buffer is not modifiable")
    return nil
  end
  return buf
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

--- Chooses among several sections of the same kind, relative to the 1-based
--- cursor line: the section containing the cursor; else the nearest one that
--- starts above it; else the first one below it.
--- @param sections { line: integer, stop: integer }[]  in file order
function M.pick_section(sections, cursor)
  local above
  for _, section in ipairs(sections) do
    if cursor >= section.line and cursor <= section.stop then
      return section
    end
    if section.line < cursor then
      above = section
    end
  end
  return above or sections[1]
end

--- Sections of `kind` in the buffer, in file order.
local function find_sections(lines, kind, cfg)
  local parsed = parser.parse(lines, cfg)
  local found = {}
  for _, section in ipairs(parsed.sections) do
    if section.kind == kind then
      found[#found + 1] = section
    end
  end
  return found
end

--- Adds `entry` at the end of the chosen section (after its last non-blank
--- line). Returns the new 1-based line, or nil, changing nothing, when the
--- section is missing.
function M.insert(buf, kind, entry, cfg, cursor)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local sections = find_sections(lines, kind, cfg)
  if #sections == 0 then
    return nil
  end
  local section = M.pick_section(sections, cursor or 1)
  vim.api.nvim_buf_set_lines(buf, section.last, section.last, false, { entry })
  return section.last + 1
end

--- Appends a new `## <heading>` section with `entry` at the end of the note.
--- Returns the entry's 1-based line.
function M.append_section(buf, kind, entry, cfg)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local block = { "## " .. cfg.headings[kind], entry }
  if #lines == 1 and lines[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, block)
    return 2
  end
  if vim.trim(lines[#lines]) ~= "" then
    table.insert(block, 1, "")
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, block)
  return #lines + #block
end

--- Warns when the entry at `line` is not read back as a task, which happens
--- when it lands inside a code block (for example one that is never closed).
function M.check_visible(buf, line, cfg)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, task in ipairs(parser.parse(lines, cfg).tasks) do
    if task.line == line then
      return true
    end
  end
  warn(("line %d was added, but Lattice won't list it: it is inside a code block (```). Move it out, or close the block if it is never closed."):format(line))
  return false
end

local function confirm(question, on_yes)
  vim.ui.select({ "Yes", "No" }, { prompt = question }, function(choice)
    if choice == "Yes" then
      on_yes()
    end
  end)
end

--- Adds "- <KEYWORD> <text>" on the line below `cursor`, using the note's
--- first open keyword (from its front matter, else the root sequences). On
--- a list item it matches that item's indent; inside front matter it goes
--- just after it. Returns the new 1-based line, or nil and an error.
function M.insert_todo(buf, text, cfg, cursor)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local keyword = parser.parse(lines, cfg).keywords.first_open
  if not keyword then
    return nil, "this note's keyword sequences have no open state (a word before |)"
  end
  local _, _, front_end = keywords.front_matter(lines)
  cursor = math.max(cursor, front_end)
  local indent = (lines[cursor] or ""):match("^([ \t]*)[-*+][ \t]") or ""
  local entry = ("%s- %s %s"):format(indent, keyword, text)
  if #lines == 1 and lines[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { entry })
    return 1
  end
  vim.api.nvim_buf_set_lines(buf, cursor, cursor, false, { entry })
  return cursor + 1
end

local function usable(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable then
    warn("the note is no longer available; task not added")
    return false
  end
  return true
end

-- Inserts a Waiting On item once all prompts are answered. The cursor line
-- is captured when the command starts, so the choice of section matches
-- what the user saw.
local function finish_waiting(buf, entry, cursor)
  if not usable(buf) then
    return
  end
  local cfg = load_config()
  if not cfg then
    return
  end
  local line = M.insert(buf, "waiting", entry, cfg, cursor)
  if line then
    M.check_visible(buf, line, cfg)
    return
  end
  confirm(('This note has no "%s" heading. Add one at the end?'):format(cfg.headings.waiting), function()
    if usable(buf) then
      M.check_visible(buf, M.append_section(buf, "waiting", entry, cfg), cfg)
    end
  end)
end

-- nil means cancelled; "" means left blank.
local function ask(label, on_value)
  vim.ui.input({ prompt = label }, function(value)
    if type(value) == "string" then
      on_value(vim.trim(value))
    end
  end)
end

function M.add_todo()
  local buf = current_markdown_buffer()
  if not buf then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  ask("TODO: ", function(text)
    if text == "" or not usable(buf) then
      return
    end
    local cfg = load_config()
    if not cfg then
      return
    end
    local line, err = M.insert_todo(buf, text, cfg, cursor)
    if line then
      M.check_visible(buf, line, cfg)
    else
      warn(err .. "; task not added")
    end
  end)
end

function M.add_waiting()
  local buf = current_markdown_buffer()
  if not buf then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  ask("Waiting on (name, optional): ", function(person)
    person = person:gsub("^@", "")
    if person ~= "" and not person:match("^%S+$") then
      warn("the name must be one word, e.g. Raju or Asha-Lee; task not added")
      return
    end
    ask("Waiting On: ", function(text)
      if text == "" then
        return
      end
      local entry = person ~= "" and ("- [ ] @%s %s"):format(person, text) or ("- [ ] " .. text)
      finish_waiting(buf, entry, cursor)
    end)
  end)
end

return M
