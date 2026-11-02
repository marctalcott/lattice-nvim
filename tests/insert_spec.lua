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

test("adds to the end of an existing section, past blanks and subitems", function()
  reset(nil)
  note_buffer("## To Do\n- One\n  - Sub\n\n## Notes\nText")
  with_inputs({ "New task" }, lattice.add_todo)
  eq(buffer_text(), "## To Do\n- One\n  - Sub\n- [ ] New task\n\n## Notes\nText")
end)

test("adds under a heading with an empty section", function()
  reset(nil)
  note_buffer("## Waiting On\n\n## Notes")
  with_inputs({ "@Raju", "Estimate" }, lattice.add_waiting)
  eq(buffer_text(), "## Waiting On\n- [ ] @Raju Estimate\n\n## Notes")
end)

test("asks before creating a missing section at the end of the note", function()
  reset(nil)
  note_buffer("# Title\nText")
  local asked = with_inputs({ "Task" }, lattice.add_todo, "Yes")
  eq(asked, { 'This note has no "To Do" heading. Add one at the end?' })
  eq(buffer_text(), "# Title\nText\n\n## To Do\n- [ ] Task")
end)

test("declining or dismissing the heading prompt leaves the buffer untouched", function()
  reset(nil)
  note_buffer("# Title\nText")
  vim.bo.modified = false
  with_inputs({ "Task" }, lattice.add_todo, "No")
  with_inputs({ "Task" }, lattice.add_todo, nil)
  with_inputs({ "", "Task" }, lattice.add_waiting, "No")
  eq(buffer_text(), "# Title\nText")
  eq(vim.bo.modified, false)
end)

test("does not reuse a section-like heading inside a code fence", function()
  reset(nil)
  note_buffer("```\n## To Do\n```")
  with_inputs({ "Task" }, lattice.add_todo, "Yes")
  eq(buffer_text(), "```\n## To Do\n```\n\n## To Do\n- [ ] Task")
end)

test("fills an empty note after confirmation", function()
  reset(nil)
  note_buffer("")
  with_inputs({ "Task" }, lattice.add_todo, "Yes")
  eq(buffer_text(), "## To Do\n- [ ] Task")
end)

test("the assignee is optional", function()
  reset(nil)
  note_buffer("## Waiting On\n- Old")
  with_inputs({ "", "Follow up with vendor" }, lattice.add_waiting)
  eq(buffer_text(), "## Waiting On\n- Old\n- [ ] Follow up with vendor")
end)

local REPEATED = table.concat({
  "# Notes", -- 1
  "## To Do", -- 2
  "- A", -- 3
  "## Middle", -- 4
  "text", -- 5
  "### To Do", -- 6
  "- B", -- 7
  "", -- 8
  "## End", -- 9
}, "\n")

local function add_at(cursor)
  note_buffer(REPEATED)
  vim.api.nvim_win_set_cursor(0, { cursor, 0 })
  with_inputs({ "New" }, lattice.add_todo)
  return buffer_text()
end

test("with repeated sections, uses the one containing the cursor", function()
  reset(nil)
  eq(add_at(8), REPEATED:gsub("%- B", "- B\n- [ ] New"))
  eq(add_at(3), REPEATED:gsub("%- A", "- A\n- [ ] New"))
end)

test("outside any section, uses the nearest section above, else the first below", function()
  reset(nil)
  eq(add_at(5), REPEATED:gsub("%- A", "- A\n- [ ] New"))
  eq(add_at(9), REPEATED:gsub("%- B", "- B\n- [ ] New"))
  eq(add_at(1), REPEATED:gsub("%- A", "- A\n- [ ] New"))
end)

test("pick_section is deterministic", function()
  local sections = { { line = 2, stop = 3 }, { line = 6, stop = 8 } }
  eq(H.insert.pick_section(sections, 7), sections[2])
  eq(H.insert.pick_section(sections, 4), sections[1])
  eq(H.insert.pick_section(sections, 1), sections[1])
  eq(H.insert.pick_section(sections, 20), sections[2])
end)

test("uses headings from .lattice.json", function()
  local root = notes()
  write(root, ".lattice.json", '{"headings": {"todo": "Mine"}}')
  reset(root)
  note_buffer("## Mine\n- One")
  with_inputs({ "Two" }, lattice.add_todo)
  eq(buffer_text(), "## Mine\n- One\n- [ ] Two")
end)

test("rejects a multi-word assignee", function()
  reset(nil)
  note_buffer("# Title")
  with_inputs({ "Two Words", "Task" }, lattice.add_waiting)
  eq(buffer_text(), "# Title")
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
  local path = write(root, "a.md", "## To Do\n- One\n")
  reset(root)
  vim.cmd.edit(vim.fn.fnameescape(path))
  with_inputs({ "Two" }, lattice.add_todo)
  eq(vim.bo.modified, true)
  eq(read(path), "## To Do\n- One\n")
  vim.cmd("bwipeout!")
end)

test("never inserts into the dashboard or a non-Markdown buffer", function()
  local root = notes()
  write(root, "a.md", "## To Do\n- Task\n")
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
