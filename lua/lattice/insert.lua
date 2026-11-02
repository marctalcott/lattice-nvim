-- Explicit, user-triggered edits to the current note. Nothing here saves to disk.
local config = require("lattice.config")
local dashboard = require("lattice.dashboard")
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

local function load_headings()
  local root = config.options.root
  if not root then
    return config.defaults().headings
  end
  local cfg, _, err = config.load(root)
  if not cfg then
    vim.notify("Lattice: " .. err, vim.log.levels.ERROR)
    return nil
  end
  return cfg.headings
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
local function find_sections(lines, kind, headings)
  local parsed = parser.parse(lines, headings)
  local found = {}
  for _, section in ipairs(parsed.sections) do
    if section.kind == kind then
      found[#found + 1] = section
    end
  end
  return found
end

--- Adds `entry` at the end of the chosen section (after its last non-blank
--- line). Returns false, changing nothing, when the section is missing.
function M.insert(buf, kind, entry, headings, cursor)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local sections = find_sections(lines, kind, headings)
  if #sections == 0 then
    return false
  end
  local section = M.pick_section(sections, cursor or 1)
  vim.api.nvim_buf_set_lines(buf, section.last, section.last, false, { entry })
  return true
end

--- Appends a new `## <heading>` section with `entry` at the end of the note.
function M.append_section(buf, kind, entry, headings)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local block = { "## " .. headings[kind], entry }
  if #lines == 1 and lines[1] == "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, block)
    return
  end
  if vim.trim(lines[#lines]) ~= "" then
    table.insert(block, 1, "")
  end
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, block)
end

local function confirm(question, on_yes)
  vim.ui.select({ "Yes", "No" }, { prompt = question }, function(choice)
    if choice == "Yes" then
      on_yes()
    end
  end)
end

-- Inserts once all prompts are answered. The cursor line is captured when
-- the command starts, so the choice of section matches what the user saw.
local function finish(buf, kind, entry, cursor)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable then
    warn("the note is no longer available; task not added")
    return
  end
  local headings = load_headings()
  if not headings then
    return
  end
  if M.insert(buf, kind, entry, headings, cursor) then
    return
  end
  confirm(('This note has no "%s" heading. Add one at the end?'):format(headings[kind]), function()
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modifiable then
      M.append_section(buf, kind, entry, headings)
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
  ask("To Do: ", function(text)
    if text ~= "" then
      finish(buf, "todo", "- [ ] " .. text, cursor)
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
      finish(buf, "waiting", entry, cursor)
    end)
  end)
end

return M
