-- Default keymaps, conflicts and the agenda entry point
-- (specs/LATTICE_KEYBINDINGS_SPEC.md §8).
local H = require("helpers")
local config, lattice = H.config, H.lattice
local test, eq, write, notes, reset, dashboard_text = H.test, H.eq, H.write, H.notes, H.reset, H.dashboard_text
local lazyvim = require("lazyvim_keymaps")

local DEFAULTS = {
  { "<leader>ol", "open", "Lattice: open dashboard" },
  { "<leader>oa", "agenda", "Lattice: open week agenda" },
  { "<leader>or", "refresh", "Lattice: refresh" },
  { "<leader>ot", "add_todo", "Lattice: add TODO" },
  { "<leader>oW", "add_waiting", "Lattice: add WAITING task" },
  { "<leader>on", "next_state", "Lattice: next TODO state" },
  { "<leader>op", "prev_state", "Lattice: previous TODO state" },
  { "<leader>os", "set_state", "Lattice: choose TODO state" },
  { "<leader>ox", "toggle_checkbox", "Lattice: toggle checkbox" },
  { "<leader>oS", "schedule", "Lattice: schedule" },
  { "<leader>oD", "deadline", "Lattice: deadline" },
  { "<leader>o+", "priority_up", "Lattice: raise priority" },
  { "<leader>o-", "priority_down", "Lattice: lower priority" },
  { "<leader>ow", "refile", "Lattice: refile subtree" },
  { "<leader>oA", "archive", "Lattice: archive subtree" },
  { "<leader>oi", "inbox", "Lattice: open inbox" },
  { "<leader>oR", "inbox_refresh", "Lattice: refresh inbox" },
}

local OLD = {
  "<leader>ll", "<leader>lr", "<leader>lt", "<leader>ld", "<leader>ln", "<leader>lp", "<leader>ls", "<leader>lx",
  "<leader>lS", "<leader>lD", "<leader>l+", "<leader>l-", "<leader>lw", "<leader>lA", "<leader>li", "<leader>lR",
}

local function mapping(lhs)
  vim.cmd("enew!")
  local found = vim.fn.maparg(lhs, "n", false, true)
  return not vim.tbl_isempty(found) and found or nil
end

-- Runs fn with Lattice set up as `opts` and the given keys pre-mapped,
-- then removes every mapping and restores the options.
local function with_setup(opts, premapped, fn)
  local saved = vim.deepcopy(config.options)
  for _, lhs in ipairs(premapped) do
    vim.keymap.set("n", lhs, "<Nop>", { desc = "other " .. lhs })
  end
  local ok, err = pcall(function()
    lattice.setup(vim.tbl_extend("force", { root = "~/x" }, opts))
    fn()
  end)
  lattice.setup({ root = "~/x", keymaps = false })
  for _, lhs in ipairs(premapped) do
    pcall(vim.keymap.del, "n", lhs)
  end
  config.options = saved
  if not ok then
    error(err, 0)
  end
end

local function warnings()
  return vim.tbl_map(function(item)
    return item.message
  end, vim.tbl_filter(function(item)
    return item.level == "warn" and item.message:find("^Keymap ") ~= nil
  end, H.health.report(H.scanner.collect(notes()))))
end

-- 1-3. Defaults, old keys, case ---------------------------------------------

test("keymaps: the 17 defaults are set under <leader>o with their actions", function()
  with_setup({}, {}, function()
    eq(vim.tbl_count(config.active_keymaps), 17)
    for _, item in ipairs(DEFAULTS) do
      local map = mapping(item[1])
      assert(map, item[1] .. " is not mapped")
      eq(map.desc, item[3])
      eq(config.active_keymaps[item[2]], item[1])
    end
    eq(H.health.keymap_conflicts, {})
  end)
end)

test("keymaps: nothing is mapped under the old <leader>l prefix", function()
  with_setup({}, {}, function()
    for _, lhs in ipairs(OLD) do
      eq(mapping(lhs), nil)
    end
  end)
end)

test("keymaps: upper and lower case are different actions", function()
  with_setup({}, {}, function()
    eq(mapping("<leader>oa").callback, lattice.agenda)
    eq(mapping("<leader>oA").callback, lattice.archive)
    eq(mapping("<leader>ow").callback, lattice.refile)
    eq(mapping("<leader>oW").callback, lattice.add_waiting)
    eq(mapping("<leader>os").callback, lattice.set_state)
    eq(mapping("<leader>oS").callback, lattice.schedule)
    eq(mapping("<leader>oD").callback, lattice.deadline)
    eq(mapping("<leader>od"), nil)
  end)
end)

-- 6-9. The keys run the same functions as the commands, unchanged.
test("keymaps: refile, WAITING, dates and archive run the command functions", function()
  with_setup({}, {}, function()
    local insert = require("lattice.insert")
    eq(mapping("<leader>ow").callback, insert.refile)
    eq(mapping("<leader>oW").callback, insert.add_waiting)
    eq(mapping("<leader>oS").callback, insert.schedule)
    eq(mapping("<leader>oD").callback, insert.deadline)
    eq(mapping("<leader>oA").callback, insert.archive)
  end)
end)

-- 4-5. Dashboard and agenda -------------------------------------------------

local function status()
  return dashboard_text():match("View: [^\n]*")
end

test("agenda: <leader>oa opens the dashboard's week view; <leader>ol the overview", function()
  local root = notes()
  write(root, "a.md", "## TODO Task\nSCHEDULED: <2026-11-12 Thu>\n")
  with_setup({}, {}, function()
    reset(root)
    lattice.agenda()
    eq(vim.bo.filetype, "lattice")
    eq(status(), "View: Week agenda")
    local buf = vim.api.nvim_get_current_buf()
    -- An open dashboard is reused and switched, not duplicated.
    lattice.open_overview()
    eq(vim.api.nvim_get_current_buf(), buf)
    eq(status(), nil)
    lattice.agenda()
    eq(vim.api.nvim_get_current_buf(), buf)
    eq(status(), "View: Week agenda")
    -- From another buffer, the agenda key comes back to the same dashboard.
    vim.cmd("enew")
    lattice.agenda()
    eq(vim.api.nvim_get_current_buf(), buf)
    -- :Lattice keeps the current view, as before.
    vim.cmd("enew")
    vim.cmd("Lattice")
    eq(status(), "View: Week agenda")
    eq(#vim.tbl_filter(function(b)
      return vim.bo[b].filetype == "lattice"
    end, vim.api.nvim_list_bufs()), 1)
    reset(root)
  end)
end)

test("agenda: the dashboard still opens in the overview", function()
  local root = notes()
  write(root, "a.md", "## TODO Task\n")
  with_setup({}, {}, function()
    reset(root)
    lattice.open_overview()
    eq(status(), nil)
    assert(dashboard_text():find("Task", 1, true))
    reset(root)
    vim.cmd("Lattice")
    eq(status(), nil)
    vim.cmd("LatticeAgenda")
    eq(status(), "View: Week agenda")
    reset(root)
  end)
end)

-- 10. Configuration ---------------------------------------------------------

test("keymaps: keymaps_prefix moves every default; a full key in keymaps wins", function()
  with_setup({ keymaps_prefix = "<leader>l", keymaps = { add_waiting = "<leader>ld", agenda = false } }, {}, function()
    eq(config.options.keymaps_prefix, "<leader>l")
    eq(mapping("<leader>ll").desc, "Lattice: open dashboard")
    eq(mapping("<leader>ld").desc, "Lattice: add WAITING task")
    eq(mapping("<leader>lA").desc, "Lattice: archive subtree")
    eq(mapping("<leader>la"), nil)
    eq(mapping("<leader>ol"), nil)
  end)
end)

test("keymaps: an invalid keymaps_prefix is reported and the default used", function()
  with_setup({ keymaps_prefix = 5 }, {}, function()
    local message = H.last_notify().message
    assert(message:find("keymaps_prefix must be a key string, not 5; using <leader>o", 1, true), message)
    eq(config.options.keymaps.open, "<leader>ol")
  end)
end)

test("keymaps: the list-item hint names the active add_todo key", function()
  with_setup({ keymaps = { add_todo = "<leader>zt" } }, {}, function()
    vim.cmd("edit! " .. vim.fn.fnameescape(write(notes(), "n.md", "- plain item\n")))
    lattice.next_state()
    assert(H.last_notify().message:find("use <leader>zt to add one", 1, true), H.last_notify().message)
  end)
  with_setup({ keymaps = { add_todo = false } }, {}, function()
    vim.cmd("edit! " .. vim.fn.fnameescape(write(notes(), "n.md", "- plain item\n")))
    lattice.next_state()
    assert(H.last_notify().message:find("use :LatticeAddTodo to add one", 1, true), H.last_notify().message)
  end)
end)

-- 11-15. Conflicts ----------------------------------------------------------

test("keymaps: standard LazyVim leaves every Lattice default free", function()
  with_setup({}, lazyvim.core, function()
    eq(H.health.keymap_conflicts, {})
    eq(H.health.keymap_overlaps, {})
    eq(vim.tbl_count(config.active_keymaps), 17)
    eq(mapping("<leader>l").desc, "other <leader>l")
  end)
end)

test("keymaps: the old prefix would have made LazyVim's <leader>l wait", function()
  with_setup({ keymaps_prefix = "<leader>l" }, lazyvim.core, function()
    -- <leader>l (Lazy) prefixes every old key; <leader>ll also extends <leader>l…
    local open = vim.tbl_filter(function(o)
      return o.action == "open"
    end, H.health.keymap_overlaps)
    eq(open[1].other, vim.fn.maparg("<leader>l", "n", false, true).lhs)
    eq(open[1].prefix, true)
  end)
end)

test("keymaps: the Overseer extra keeps <leader>ot and <leader>ow; the rest are set", function()
  with_setup({}, lazyvim.overseer, function()
    eq(H.health.keymap_conflicts, {
      { lhs = "<leader>ot", action = "add_todo" },
      { lhs = "<leader>ow", action = "refile" },
    })
    eq(mapping("<leader>ot").desc, "other <leader>ot")
    eq(mapping("<leader>ow").desc, "other <leader>ow")
    eq(mapping("<leader>oo").desc, "other <leader>oo")
    eq(mapping("<leader>oW").desc, "Lattice: add WAITING task")
    eq(vim.tbl_count(config.active_keymaps), 15)
    local message = H.last_notify().message
    assert(message:find("kept your existing mapping for <leader>ot (add_todo), <leader>ow (refile)", 1, true), message)
    local report = table.concat(warnings(), "\n")
    assert(report:find("Keymap <leader>ot (add_todo) not set: the key was already mapped; set keymaps.add_todo", 1, true), report)
    assert(report:find("Keymap <leader>ow (refile) not set", 1, true), report)
  end)
end)

test("keymaps: Overseer users can move the colliding keys", function()
  with_setup({ keymaps = { add_todo = "<leader>oT", refile = "<leader>oF" } }, lazyvim.overseer, function()
    eq(H.health.keymap_conflicts, {})
    eq(mapping("<leader>oT").desc, "Lattice: add TODO")
    eq(mapping("<leader>oF").desc, "Lattice: refile subtree")
  end)
end)

test("keymaps: a mapping on the prefix itself is an overlap, not a conflict", function()
  with_setup({}, { "<leader>o" }, function()
    eq(H.health.keymap_conflicts, {})
    eq(vim.tbl_count(config.active_keymaps), 17)
    eq(#H.health.keymap_overlaps, 17)
    local report = table.concat(warnings(), "\n")
    assert(report:find("Keymap <leader>ol (open) waits for 'timeoutlen': ", 1, true), report)
    assert(report:find("(other <leader>o) is mapped too", 1, true), report)
  end)
end)

test("keymaps: a longer mapping that starts with a Lattice key is an overlap", function()
  with_setup({}, { "<leader>olx" }, function()
    eq(#H.health.keymap_overlaps, 1)
    eq(H.health.keymap_overlaps[1].action, "open")
    eq(H.health.keymap_overlaps[1].prefix, false)
    assert(table.concat(warnings(), "\n"):find("(open) waits for 'timeoutlen' because ", 1, true))
  end)
end)

test("keymaps: overlap detection uses the configured leader", function()
  local leader = vim.g.mapleader
  vim.g.mapleader = " "
  local ok, err = pcall(with_setup, {}, { "<Space>o" }, function()
    eq(#H.health.keymap_overlaps, 17)
    eq(mapping(" ol").desc, "Lattice: open dashboard")
  end)
  vim.g.mapleader = leader
  assert(ok, err)
end)

test("keymaps: health reports a Lattice key another plugin replaced after setup", function()
  with_setup({}, {}, function()
    vim.keymap.set("n", "<leader>oa", "<Nop>", { desc = "late plugin" })
    local report = table.concat(warnings(), "\n")
    assert(report:find("Keymap <leader>oa (agenda) was replaced after setup by late plugin", 1, true), report)
    vim.keymap.del("n", "<leader>oa")
    assert(table.concat(warnings(), "\n"):find("(agenda) was removed after setup", 1, true))
  end)
end)
