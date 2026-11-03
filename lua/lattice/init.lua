-- Public entry point: setup, commands, and keymaps.
local config = require("lattice.config")
local dashboard = require("lattice.dashboard")
local health = require("lattice.health")
local insert = require("lattice.insert")

local M = {}

M.open = dashboard.open
M.refresh = dashboard.refresh
M.add_todo = insert.add_todo
M.add_waiting = insert.add_waiting

function M.health()
  vim.cmd("checkhealth lattice")
end

-- The global normal-mode mapping for `lhs`, ignoring buffer-local ones:
-- maparg() prefers the current buffer's mappings, so ask from a scratch
-- buffer that has none.
local function global_mapping(lhs)
  local scratch = vim.api.nvim_create_buf(false, true)
  local found = vim.api.nvim_buf_call(scratch, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
  vim.api.nvim_buf_delete(scratch, { force = true })
  return not vim.tbl_isempty(found) and found or nil
end

local function is_lattice(mapping)
  return mapping ~= nil and (mapping.desc or ""):match("^Lattice: ") ~= nil
end

-- Removes the mappings an earlier setup() created, so a reload with other
-- keys or `keymaps = false` leaves nothing stale. Mappings the user has
-- since replaced are left alone.
local function clear_keymaps()
  for _, lhs in pairs(config.active_keymaps) do
    if is_lattice(global_mapping(lhs)) then
      pcall(vim.keymap.del, "n", lhs)
    end
  end
  config.active_keymaps = {}
  health.keymap_conflicts = {}
end

-- Sets each keymap unless the key already does something else, in which
-- case it is skipped with a warning (also listed in :LatticeHealth).
-- config.active_keymaps records what was actually mapped.
local function set_keymaps(keymaps)
  clear_keymaps()
  if not keymaps then
    return
  end
  local actions = {
    { "open", M.open, "Lattice: open dashboard" },
    { "add_todo", M.add_todo, "Lattice: add TODO" },
    { "add_waiting", M.add_waiting, "Lattice: add Waiting On" },
    { "refresh", M.refresh, "Lattice: refresh" },
  }
  local skipped = {}
  for _, action in ipairs(actions) do
    local name, lhs = action[1], keymaps[action[1]]
    if lhs then
      local existing = global_mapping(lhs)
      if existing == nil or is_lattice(existing) then
        vim.keymap.set("n", lhs, action[2], { desc = action[3] })
        config.active_keymaps[name] = lhs
      else
        health.keymap_conflicts[#health.keymap_conflicts + 1] = { lhs = lhs, action = name }
        skipped[#skipped + 1] = ("%s (%s)"):format(lhs, name)
      end
    end
  end
  if #skipped > 0 then
    vim.notify(
      ("Lattice: kept your existing mapping for %s; set keymaps.<name> to another key or false"):format(
        table.concat(skipped, ", ")
      ),
      vim.log.levels.WARN
    )
  end
end

--- @param opts? { root: string, keymaps?: false|table<string, string|false> }
function M.setup(opts)
  local options = config.setup(opts)
  local function command(name, fn, desc)
    vim.api.nvim_create_user_command(name, function()
      fn()
    end, { desc = desc })
  end
  command("Lattice", M.open, "Open the Lattice dashboard")
  command("LatticeRefresh", M.refresh, "Rescan notes and .lattice.json")
  command("LatticeHealth", M.health, "Show Lattice config and scan warnings")
  command("LatticeAddTodo", M.add_todo, "Add a TODO item below the cursor")
  command("LatticeAddWaiting", M.add_waiting, "Add an item under Waiting On in the current note")
  set_keymaps(options.keymaps)
end

return M
