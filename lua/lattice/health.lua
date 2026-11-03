-- :checkhealth lattice (also :LatticeHealth). Runs a fresh, read-only scan.
local config = require("lattice.config")
local scanner = require("lattice.scanner")

local M = {}

-- Keymaps skipped at setup because the key was already mapped.
M.keymap_conflicts = {}

--- Turns a scan result into { level, message } entries. Paths are relative
--- to the notes root, which is reported first.
function M.report(result)
  local items = {}
  local function add(level, message)
    items[#items + 1] = { level = level, message = message }
  end

  add("info", "Neovim " .. tostring(vim.version()))
  if result.error then
    add("error", result.error)
    return items
  end
  add("ok", ("Notes root: %s (%d Markdown notes scanned)"):format(vim.fn.fnamemodify(result.root, ":~"), result.files or 0))
  if result.notice then
    add("warn", result.notice)
  else
    add("ok", ("Config: %s"):format(config.filename))
  end

  local open = vim.tbl_filter(function(task)
    return not task.done
  end, result.tasks)
  add("ok", ("%d open tasks, %d completed"):format(#open, #result.tasks - #open))

  if #result.unreadable == 0 then
    add("ok", "All files and folders were readable")
  end
  for _, item in ipairs(result.unreadable) do
    add("warn", ("Could not read %s: %s"):format(item.path, item.message))
  end

  if #result.date_errors == 0 then
    add("ok", "No invalid dates")
  end
  for _, item in ipairs(result.date_errors) do
    add("warn", ("Invalid date ignored, task shown undated: [%s:%s] in %s line %d"):format(
      item.tag,
      item.value,
      item.rel,
      item.line
    ))
  end

  for _, item in ipairs(result.warnings or {}) do
    add("warn", ("%s line %d: %s"):format(item.rel, item.line, item.message))
  end

  add("info", "Keyword sequences (root): " .. table.concat(result.keywords.sequences, "; "))

  for _, conflict in ipairs(M.keymap_conflicts) do
    add("warn", ("Keymap %s (%s) not set: the key was already mapped"):format(conflict.lhs, conflict.action))
  end
  return items
end

function M.check()
  local health = vim.health
  health.start("lattice")
  for _, item in ipairs(M.report(scanner.collect(config.options.root))) do
    health[item.level](item.message)
  end
end

return M
