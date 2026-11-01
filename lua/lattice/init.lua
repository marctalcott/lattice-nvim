-- Public entry point: setup, commands, keymaps, and task insertion.
local config = require("lattice.config")
local dashboard = require("lattice.dashboard")
local parser = require("lattice.parser")

local M = {}

M.open = dashboard.open
M.refresh = dashboard.refresh

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

--- Adds `entry` to the end of the section, creating it at the end of the note
--- if missing. Changes the buffer only; saving stays with the user.
function M.insert(buf, kind, entry, headings)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for _, section in ipairs(parser.parse(lines, headings).sections) do
    if section.kind == kind then
      vim.api.nvim_buf_set_lines(buf, section.last, section.last, false, { entry })
      return
    end
  end

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

local function prompt(label, on_value)
  vim.ui.input({ prompt = label }, function(value)
    value = value and vim.trim(value) or ""
    if value ~= "" then
      on_value(value)
    end
  end)
end

local function insert_when_valid(buf, kind, entry)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable then
    warn("the note is no longer available; task not added")
    return
  end
  local headings = load_headings()
  if headings then
    M.insert(buf, kind, entry, headings)
  end
end

function M.add_todo()
  local buf = current_markdown_buffer()
  if not buf then
    return
  end
  prompt("To Do: ", function(description)
    insert_when_valid(buf, "todo", "- [ ] " .. description)
  end)
end

function M.add_waiting()
  local buf = current_markdown_buffer()
  if not buf then
    return
  end
  prompt("Waiting On: ", function(description)
    prompt("Assignee: ", function(person)
      person = person:gsub("^@", "")
      if not person:match("^%S+$") then
        warn("assignee must be a single word; task not added")
        return
      end
      insert_when_valid(buf, "waiting", ("- [ ] @%s %s"):format(person, description))
    end)
  end)
end

local function set_keymaps(keymaps)
  if not keymaps then
    return
  end
  local actions = {
    { keymaps.open, M.open, "Lattice: open dashboard" },
    { keymaps.add_todo, M.add_todo, "Lattice: add To Do" },
    { keymaps.add_waiting, M.add_waiting, "Lattice: add Waiting On" },
    { keymaps.refresh, M.refresh, "Lattice: refresh" },
  }
  for _, action in ipairs(actions) do
    if action[1] then
      vim.keymap.set("n", action[1], action[2], { desc = action[3] })
    end
  end
end

--- @param opts? { root: string, keymaps?: false|table<string, string|false> }
function M.setup(opts)
  local options = config.setup(opts)
  vim.api.nvim_create_user_command("Lattice", M.open, { desc = "Open the Lattice dashboard" })
  vim.api.nvim_create_user_command("LatticeRefresh", M.refresh, { desc = "Rescan notes and .lattice.json" })
  set_keymaps(options.keymaps)
end

return M
