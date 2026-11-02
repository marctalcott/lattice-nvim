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

local function is_ours(lhs)
  local existing = vim.fn.maparg(lhs, "n", false, true)
  return vim.tbl_isempty(existing) or (existing.desc or ""):match("^Lattice: ") ~= nil
end

-- Sets each keymap unless the key already does something else, in which
-- case it is skipped with a warning (also listed in :LatticeHealth).
local function set_keymaps(keymaps)
  health.keymap_conflicts = {}
  if not keymaps then
    return
  end
  local actions = {
    { "open", M.open, "Lattice: open dashboard" },
    { "add_todo", M.add_todo, "Lattice: add To Do" },
    { "add_waiting", M.add_waiting, "Lattice: add Waiting On" },
    { "refresh", M.refresh, "Lattice: refresh" },
  }
  local skipped = {}
  for _, action in ipairs(actions) do
    local lhs = keymaps[action[1]]
    if lhs then
      if is_ours(lhs) then
        vim.keymap.set("n", lhs, action[2], { desc = action[3] })
      else
        health.keymap_conflicts[#health.keymap_conflicts + 1] = { lhs = lhs, action = action[1] }
        skipped[#skipped + 1] = ("%s (%s)"):format(lhs, action[1])
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
  command("LatticeAddTodo", M.add_todo, "Add a task under To Do in the current note")
  command("LatticeAddWaiting", M.add_waiting, "Add an item under Waiting On in the current note")
  set_keymaps(options.keymaps)
end

return M
