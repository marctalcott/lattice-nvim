-- Public entry point: setup, commands, and keymaps.
local config = require("lattice.config")
local dashboard = require("lattice.dashboard")
local health = require("lattice.health")
local insert = require("lattice.insert")
local inbox_sync = require("lattice.inbox_sync")

local M = {}

M.open = dashboard.open
M.refresh = dashboard.refresh
M.add_todo = insert.add_todo
M.add_waiting = insert.add_waiting
M.next_state = insert.next_state
M.prev_state = insert.prev_state
M.set_state = insert.set_state
M.toggle_checkbox = insert.toggle_checkbox
M.schedule = insert.schedule
M.deadline = insert.deadline
M.priority_up = insert.priority_up
M.priority_down = insert.priority_down
M.migrate = insert.migrate
M.refile = insert.refile
M.archive = insert.archive
M.inbox_refresh = inbox_sync.refresh
M.inbox_status = inbox_sync.status

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
    { "next_state", M.next_state, "Lattice: next TODO state" },
    { "prev_state", M.prev_state, "Lattice: previous TODO state" },
    { "set_state", M.set_state, "Lattice: choose TODO state" },
    { "toggle_checkbox", M.toggle_checkbox, "Lattice: toggle checkbox" },
    { "schedule", M.schedule, "Lattice: schedule" },
    { "deadline", M.deadline, "Lattice: deadline" },
    { "priority_up", M.priority_up, "Lattice: raise priority" },
    { "priority_down", M.priority_down, "Lattice: lower priority" },
    { "refile", M.refile, "Lattice: refile subtree" },
    { "archive", M.archive, "Lattice: archive subtree" },
    { "inbox_refresh", M.inbox_refresh, "Lattice: refresh inbox" },
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

--- @param opts? { root: string, keymaps?: false|table<string, string|false>, inbox_sync?: { config?: string } }
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
  command("LatticeAddTodo", M.add_todo, "Add a TODO heading after the current heading's subtree")
  command("LatticeAddWaiting", M.add_waiting, "Add a WAITING heading, with an optional :ASSIGNED: person")
  command("LatticeNextState", M.next_state, "Move the heading under the cursor to its next TODO state")
  command("LatticePrevState", M.prev_state, "Move the heading under the cursor to its previous TODO state")
  command("LatticeSetState", M.set_state, "Choose the state of the heading under the cursor")
  command("LatticeToggleCheckbox", M.toggle_checkbox, "Toggle the checkbox under the cursor")
  command("LatticeSchedule", M.schedule, "Set or remove SCHEDULED on the heading under the cursor")
  command("LatticeDeadline", M.deadline, "Set or remove DEADLINE on the heading under the cursor")
  command("LatticePriorityUp", M.priority_up, "Raise the priority of the heading under the cursor")
  command("LatticePriorityDown", M.priority_down, "Lower the priority of the heading under the cursor")
  command("LatticeMigrate", M.migrate, "Convert this note's Lattice v0.1 items to Org headings")
  command("LatticeRefile", M.refile, "Move the subtree under the cursor under another heading")
  command("LatticeArchive", M.archive, "Move the subtree under the cursor to the archive note")
  command("LatticeInboxRefresh", M.inbox_refresh, "Fetch captures from the GitHub inbox repositories")
  command("LatticeInboxStatus", M.inbox_status, "Show each inbox repository's sync status")
  set_keymaps(options.keymaps)
  -- Incremental refresh: an open dashboard follows saved notes.
  local group = vim.api.nvim_create_augroup("lattice", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.md",
    callback = function(args)
      dashboard.on_note_saved(args.match)
    end,
  })
  -- Inbox: fetch once at startup when inbox.json exists (opt-in).
  inbox_sync.on_startup()
end

return M
