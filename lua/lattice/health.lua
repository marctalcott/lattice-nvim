-- :checkhealth lattice (also :LatticeHealth). Runs a fresh, read-only scan.
local config = require("lattice.config")
local keymaps = require("lattice.keymaps")
local markdown = require("lattice.markdown")
local scanner = require("lattice.scanner")

local M = {}

-- Keymaps skipped at setup because the key was already mapped.
M.keymap_conflicts = {}
-- Keymaps set at setup that overlap another mapping: { lhs, action, other,
-- desc, prefix }, where `prefix` means `other` is a prefix of `lhs`.
M.keymap_overlaps = {}

--- Turns a scan result into { level, message } entries. Paths are relative
--- to the notes root, which is reported first.
function M.report(result)
  local items = {}
  local function add(level, message)
    items[#items + 1] = { level = level, message = message }
  end

  add("info", "Neovim " .. tostring(vim.version()))
  if markdown.available() then
    add("ok", "Markdown Tree-sitter parser loaded")
  else
    add("error", "No Markdown Tree-sitter parser: Lattice cannot read notes. Run :checkhealth vim.treesitter")
  end
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
  local names = vim.tbl_keys(result.workflows or {})
  table.sort(names)
  for _, name in ipairs(names) do
    if name ~= "default" then
      add("info", ("Workflow %s: %s"):format(name, table.concat(result.workflows[name].sequences, "; ")))
    end
  end

  if result.legacy and #result.legacy > 0 then
    local counts, forms = {}, {}
    for _, entry in ipairs(result.legacy) do
      if not counts[entry.form] then
        forms[#forms + 1] = entry.form
      end
      counts[entry.form] = (counts[entry.form] or 0) + 1
    end
    local parts = vim.tbl_map(function(form)
      return ("%s (%d)"):format(form, counts[form])
    end, forms)
    add("info", "Lattice v0.1 syntax still in use, read as before: " .. table.concat(parts, ", "))
  end

  for _, conflict in ipairs(M.keymap_conflicts) do
    add(
      "warn",
      ("Keymap %s (%s) not set: the key was already mapped; set keymaps.%s to another key or false"):format(
        conflict.lhs,
        conflict.action,
        conflict.action
      )
    )
  end
  for _, overlap in ipairs(M.keymap_overlaps) do
    local other = overlap.desc and ("%s (%s)"):format(overlap.other, overlap.desc) or overlap.other
    if overlap.prefix then
      add("warn", ("Keymap %s (%s) waits for 'timeoutlen': %s is mapped too, so it runs only after that delay"):format(
        overlap.lhs,
        overlap.action,
        other
      ))
    else
      add("warn", ("Keymap %s (%s) waits for 'timeoutlen' because %s starts with it"):format(
        overlap.lhs,
        overlap.action,
        other
      ))
    end
  end
  -- A plugin that maps the same key after setup replaces Lattice's mapping
  -- without Lattice seeing it; report it here instead.
  local names = vim.tbl_keys(config.active_keymaps)
  table.sort(names)
  for _, name in ipairs(names) do
    local lhs = config.active_keymaps[name]
    local current = keymaps.global_mapping(lhs)
    if not keymaps.is_lattice(current) then
      local by = current and (current.desc or current.rhs) or nil
      add(
        "warn",
        ("Keymap %s (%s) was %s after setup%s"):format(
          lhs,
          name,
          current and "replaced" or "removed",
          by and (" by %s"):format(by) or ""
        )
      )
    end
  end
  return items
end

function M.check()
  local health = vim.health
  health.start("lattice")
  for _, item in ipairs(M.report(scanner.collect(config.options.root))) do
    health[item.level](item.message)
  end
  health.start("lattice inbox")
  for _, item in ipairs(require("lattice.inbox_sync").health_items()) do
    health[item.level](item.message)
  end
end

return M
