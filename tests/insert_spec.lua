local H = require("helpers")
local config, dashboard, lattice, parser, scanner = H.config, H.dashboard, H.lattice, H.parser, H.scanner
local test, eq, parse, texts, write, read = H.test, H.eq, H.parse, H.texts, H.write, H.read
local notes, reset, dashboard_text, press_enter_on = H.notes, H.reset, H.dashboard_text, H.press_enter_on

-- Insertion ------------------------------------------------------------------

-- Scripts answers to vim.ui.input and the yes/no vim.ui.select confirmation.
-- `select` defaults to nil (dismissed); any unexpected confirmation fails.
local function with_inputs(values, fn, select)
  local saved_input, saved_select = vim.ui.input, vim.ui.select
  local asked = {}
  vim.ui.input = function(_, callback)
    callback(table.remove(values, 1))
  end
  vim.ui.select = function(items, opts, callback)
    asked[#asked + 1] = opts.prompt
    eq(items, { "Yes", "No" })
    callback(select)
  end
  fn()
  vim.ui.input, vim.ui.select = saved_input, saved_select
  return asked
end

local function note_buffer(text)
  vim.cmd("enew!")
  vim.bo.filetype = "markdown"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, "\n", { plain = true }))
end

local function buffer_text()
  return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

local function at(cursor)
  vim.api.nvim_win_set_cursor(0, { cursor, 0 })
end

-- TODO headings (<leader>ot) -------------------------------------------------

test("adds a TODO heading at the enclosing heading's level, after its subtree", function()
  reset(nil)
  note_buffer("# Title\n## Plan\ntext\n- step\n### Detail\nmore\n\n## Next")
  at(3)
  local asked = with_inputs({ "Send update" }, lattice.add_todo)
  eq(asked, {})
  eq(buffer_text(), "# Title\n## Plan\ntext\n- step\n### Detail\nmore\n\n## TODO Send update\n\n## Next")
end)

test("inside a nested heading the new task is its sibling", function()
  reset(nil)
  note_buffer("## Plan\n### Detail\nmore\n## Next")
  at(3)
  with_inputs({ "Sub" }, lattice.add_todo)
  eq(buffer_text(), "## Plan\n### Detail\nmore\n\n### TODO Sub\n\n## Next")
end)

test("with no heading above, a level-2 heading goes below the cursor, after front matter", function()
  reset(nil)
  note_buffer("Intro text\nmore")
  at(1)
  with_inputs({ "First" }, lattice.add_todo)
  eq(buffer_text(), "Intro text\n\n## TODO First\n\nmore")
  note_buffer("---\ntitle: x\n---\nBody")
  at(2)
  with_inputs({ "Second" }, lattice.add_todo)
  eq(buffer_text(), "---\ntitle: x\n---\n\n## TODO Second\n\nBody")
end)

test("fills an empty note", function()
  reset(nil)
  note_buffer("")
  with_inputs({ "Task" }, lattice.add_todo)
  eq(buffer_text(), "## TODO Task")
end)

test("uses the first active state of the workflow in effect", function()
  reset(nil)
  note_buffer("---\ntodo: NEXT WAIT | DONE\n---\n# Title")
  at(4)
  with_inputs({ "Draft" }, lattice.add_todo)
  eq(buffer_text(), "---\ntodo: NEXT WAIT | DONE\n---\n# Title\n\n# NEXT Draft")
  local root = notes()
  write(root, ".lattice.json", '{"workflows": {"etna": {"active": ["BACKLOG"], "done": ["COMPLETE"]}}}')
  reset(root)
  note_buffer("# Etna\n## Work")
  at(2)
  with_inputs({ "Idea" }, lattice.add_todo)
  eq(buffer_text(), "# Etna\n## Work\n\n## BACKLOG Idea")
end)

test("a workflow with no active state adds nothing and warns", function()
  reset(nil)
  note_buffer("---\ntodo: \"| DONE\"\n---\n# Title")
  at(4)
  with_inputs({ "Task" }, lattice.add_todo)
  eq(buffer_text(), "---\ntodo: \"| DONE\"\n---\n# Title")
  assert(H.last_notify().message:find("no active state", 1, true), H.last_notify().message)
end)

test("warns when the new heading lands inside an unclosed code block", function()
  reset(nil)
  note_buffer("## Plan\n```\ncode never closed")
  at(1)
  with_inputs({ "Hidden" }, lattice.add_todo)
  eq(buffer_text(), "## Plan\n```\ncode never closed\n\n## TODO Hidden")
  assert(H.last_notify().message:find("line 5 was added, but Lattice won't list it", 1, true), H.last_notify().message)
end)

test("a normal insertion gives no warning", function()
  reset(nil)
  note_buffer("## Plan\nText")
  at(2)
  vim.notify("sentinel")
  with_inputs({ "Visible" }, lattice.add_todo)
  eq(H.last_notify().message, "sentinel")
end)

-- WAITING headings (<leader>oW) -----------------------------------------------

test("adds a WAITING heading with the person in an :ASSIGNED: drawer", function()
  reset(nil)
  note_buffer("## Team\nnotes")
  at(2)
  with_inputs({ "Elira Voss", "Venue reply" }, lattice.add_waiting)
  eq(buffer_text(), "## Team\nnotes\n\n## WAITING Venue reply\n:PROPERTIES:\n:ASSIGNED: Elira Voss\n:END:")
  local r = assert(H.parser.parse(vim.api.nvim_buf_get_lines(0, 0, -1, false), config.defaults()))
  eq({ r.tasks[1].state, r.tasks[1].section, r.tasks[1].person }, { "WAITING", "waiting", "Elira Voss" })
end)

test("the person is optional, and a leading @ is dropped", function()
  reset(nil)
  note_buffer("## Team")
  with_inputs({ "", "Vendor follow-up" }, lattice.add_waiting)
  eq(buffer_text(), "## Team\n\n## WAITING Vendor follow-up")
  note_buffer("## Team")
  with_inputs({ "@Raju", "Estimate" }, lattice.add_waiting)
  eq(buffer_text(), "## Team\n\n## WAITING Estimate\n:PROPERTIES:\n:ASSIGNED: Raju\n:END:")
end)

test("a workflow without WAITING adds nothing and says so", function()
  reset(nil)
  note_buffer("---\ntodo: TODO | DONE\n---\n## Team")
  at(4)
  with_inputs({ "", "Thing" }, lattice.add_waiting)
  eq(buffer_text(), "---\ntodo: TODO | DONE\n---\n## Team")
  assert(H.last_notify().message:find("no WAITING state", 1, true), H.last_notify().message)
end)

test("cancelled prompts change nothing", function()
  reset(nil)
  note_buffer("# Title")
  with_inputs({ false }, lattice.add_todo)
  with_inputs({ "" }, lattice.add_todo)
  with_inputs({ false }, lattice.add_waiting)
  with_inputs({ "Raju", false }, lattice.add_waiting)
  with_inputs({ "Raju", "" }, lattice.add_waiting)
  eq(buffer_text(), "# Title")
end)

test("insertion leaves the buffer unsaved and the file untouched", function()
  local root = notes()
  local path = write(root, "a.md", "## Plan\n- One\n")
  reset(root)
  vim.cmd.edit(vim.fn.fnameescape(path))
  with_inputs({ "Two" }, lattice.add_todo)
  eq(buffer_text(), "## Plan\n- One\n\n## TODO Two")
  eq(vim.bo.modified, true)
  eq(read(path), "## Plan\n- One\n")
  vim.cmd("bwipeout!")
end)

test("never inserts into the dashboard or a non-Markdown buffer", function()
  local root = notes()
  write(root, "a.md", "## TODO Task\n")
  reset(root)
  lattice.open()
  local before = dashboard_text()
  with_inputs({ "Nope" }, lattice.add_todo)
  eq(dashboard_text(), before)

  vim.cmd("enew!")
  vim.bo.filetype = "lua"
  with_inputs({ "Nope" }, lattice.add_todo)
  eq(buffer_text(), "")
end)

-- Cycling states ----------------------------------------------------------------

-- Runs a cycle command `times` times on `row` and returns the line.
local function cycle_at(row, fn, times)
  at(row)
  for _ = 1, times or 1 do
    fn()
  end
  return vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
end

test("next state cycles none -> TODO -> NEXT -> WAITING -> DONE -> CANCELED -> none on a heading", function()
  reset(nil)
  note_buffer("## Send update")
  for _, state in ipairs({ "TODO ", "NEXT ", "WAITING ", "DONE ", "CANCELED ", "" }) do
    eq(cycle_at(1, lattice.next_state), "## " .. state .. "Send update")
  end
end)

test("previous state goes the other way", function()
  reset(nil)
  note_buffer("## Send update")
  eq(cycle_at(1, lattice.prev_state), "## CANCELED Send update")
  eq(cycle_at(1, lattice.prev_state), "## DONE Send update")
  eq(cycle_at(1, lattice.prev_state, 4), "## Send update")
end)

test("follows the workflow in effect, staying in the heading's own sequence", function()
  reset(nil)
  note_buffer("---\ntodo:\n  - TODO NEXT | DONE CANCELED\n  - BUG | FIXED\n---\n## BUG crash\n## task")
  eq(cycle_at(6, lattice.next_state), "## FIXED crash")
  eq(cycle_at(6, lattice.next_state), "## crash")
  eq(cycle_at(7, lattice.next_state, 4), "## CANCELED task")
  eq(cycle_at(7, lattice.prev_state, 2), "## NEXT task")
  local root = notes()
  write(root, ".lattice.json", '{"workflows": {"etna": {"active": ["BACKLOG", "IN PROGRESS"], "done": ["COMPLETE"]}}}')
  reset(root)
  note_buffer("# Etna\n## Migrate")
  eq(cycle_at(2, lattice.next_state, 2), "## IN PROGRESS Migrate")
end)

test("keeps priority, tags and closing hashes", function()
  reset(nil)
  note_buffer("## [#A] Draft plan :etna: ##")
  eq(cycle_at(1, lattice.next_state), "## TODO [#A] Draft plan :etna: ##")
end)

test("a v0.1 keyword bullet can change or drop its state; a plain item never gains one", function()
  reset(nil)
  note_buffer("- TODO legacy\n- [ ] plain box\n- plain")
  eq(cycle_at(1, lattice.next_state), "- NEXT legacy")
  eq(cycle_at(1, lattice.prev_state, 2), "- legacy")
  for _, row in ipairs({ 1, 2, 3 }) do
    local before = buffer_text()
    cycle_at(row, lattice.next_state)
    eq(buffer_text(), before)
    assert(H.last_notify().message:find("list items aren't tasks in Org", 1, true), H.last_notify().message)
  end
end)

test("the change is a single undo step and keeps the cursor on the line", function()
  reset(nil)
  note_buffer("text\n## Send update")
  vim.cmd("let &undolevels = &undolevels")
  eq(cycle_at(2, lattice.next_state), "## TODO Send update")
  eq(vim.api.nvim_win_get_cursor(0)[1], 2)
  vim.cmd("silent undo")
  eq(buffer_text(), "text\n## Send update")
end)

test("a word that is not a state is left as text", function()
  reset(nil)
  note_buffer("## todo lowercase\n## TODOS plural")
  eq(cycle_at(1, lattice.next_state), "## TODO todo lowercase")
  eq(cycle_at(2, lattice.next_state), "## TODO TODOS plural")
end)

test("refuses lines Lattice wouldn't list, changing nothing", function()
  reset(nil)
  for _, case in ipairs({ { "plain paragraph", "heading" }, { "##", "heading" }, { "## ", "no text" } }) do
    note_buffer(case[1])
    cycle_at(1, lattice.next_state)
    eq(buffer_text(), case[1])
    assert(H.last_notify().message:find(case[2], 1, true), case[1] .. ": " .. H.last_notify().message)
  end
  note_buffer("```\n## inside a fence\n```")
  cycle_at(2, lattice.next_state)
  eq(buffer_text(), "```\n## inside a fence\n```")
  assert(H.last_notify().message:find("inside a code block", 1, true), H.last_notify().message)
  note_buffer("---\ntodo:\n  - TODO | DONE\n---\n## task")
  cycle_at(3, lattice.next_state)
  assert(H.last_notify().message:find("front matter", 1, true), H.last_notify().message)
end)

test("never changes the dashboard or a non-Markdown buffer", function()
  local root = notes()
  write(root, "a.md", "## TODO Task\n")
  reset(root)
  lattice.open()
  local before = dashboard_text()
  lattice.next_state()
  eq(dashboard_text(), before)
  vim.cmd("enew!")
  vim.bo.filetype = "lua"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "## item" })
  lattice.next_state()
  eq(buffer_text(), "## item")
end)

test("cycle_line reports the replaced span", function()
  local kws = assert(H.keywords.build({ "TODO | DONE" }))
  eq({ H.insert.cycle_line("  - [ ] TODO a", kws, 1) }, { "  - [ ] DONE a", 8, 13, "DONE", "DONE " })
  eq({ H.insert.cycle_line("# a", kws, 1) }, { "# TODO a", 2, 2, "TODO", "TODO " })
end)
