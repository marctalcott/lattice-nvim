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

-- TODO items -------------------------------------------------------------------

test("adds a TODO item on the line below the cursor, with no prompt to confirm", function()
  reset(nil)
  note_buffer("# Title\nSome text\n\n## Notes")
  at(2)
  local asked = with_inputs({ "Send update" }, lattice.add_todo)
  eq(asked, {})
  eq(buffer_text(), "# Title\nSome text\n- TODO Send update\n\n## Notes")
end)

test("on a list item, the new item matches its indent", function()
  reset(nil)
  note_buffer("- Project\n  - Detail\n- Other")
  at(2)
  with_inputs({ "Follow up" }, lattice.add_todo)
  eq(buffer_text(), "- Project\n  - Detail\n  - TODO Follow up\n- Other")
end)

test("fills an empty note", function()
  reset(nil)
  note_buffer("")
  with_inputs({ "Task" }, lattice.add_todo)
  eq(buffer_text(), "- TODO Task")
end)

test("uses the first open keyword from the note's front matter", function()
  reset(nil)
  note_buffer("---\ntodo: NEXT WAIT | DONE\n---\n# Title")
  at(2) -- inside the front matter: the item goes after it
  with_inputs({ "Draft" }, lattice.add_todo)
  eq(buffer_text(), "---\ntodo: NEXT WAIT | DONE\n---\n- NEXT Draft\n# Title")
end)

test("uses the root sequences from .lattice.json", function()
  local root = notes()
  write(root, ".lattice.json", '{"todo": ["WAIT NEXT | DONE"]}')
  reset(root)
  note_buffer("# Title")
  with_inputs({ "Two" }, lattice.add_todo)
  eq(buffer_text(), "# Title\n- WAIT Two")
end)

test("a sequence with no open state adds nothing and warns", function()
  reset(nil)
  note_buffer("---\ntodo: \"| DONE\"\n---\n# Title")
  at(4)
  with_inputs({ "Task" }, lattice.add_todo)
  eq(buffer_text(), "---\ntodo: \"| DONE\"\n---\n# Title")
  assert(H.last_notify().message:find("no open state", 1, true), H.last_notify().message)
end)

test("warns when the new item lands inside a code block", function()
  reset(nil)
  note_buffer("# Title\n```\ncode\n```")
  at(3)
  with_inputs({ "Hidden" }, lattice.add_todo)
  eq(buffer_text(), "# Title\n```\ncode\n- TODO Hidden\n```")
  local message = H.last_notify().message
  assert(message:find("line 4 was added, but Lattice won't list it", 1, true), message)
end)

test("a normal insertion gives no warning", function()
  reset(nil)
  note_buffer("# Title\n```\ncode\n```\nText")
  at(5)
  vim.notify("sentinel")
  with_inputs({ "Visible" }, lattice.add_todo)
  eq(H.last_notify().message, "sentinel")
  eq(buffer_text(), "# Title\n```\ncode\n```\nText\n- TODO Visible")
end)

-- Waiting On items -----------------------------------------------------------

test("adds to the end of a Waiting On section, past blanks and subitems", function()
  reset(nil)
  note_buffer("## Waiting On\n- One\n  - Sub\n\n## Notes\nText")
  with_inputs({ "Raju", "Estimate" }, lattice.add_waiting)
  eq(buffer_text(), "## Waiting On\n- One\n  - Sub\n- [ ] @Raju Estimate\n\n## Notes\nText")
end)

test("adds under a heading with an empty section", function()
  reset(nil)
  note_buffer("## Waiting On\n\n## Notes")
  with_inputs({ "@Raju", "Estimate" }, lattice.add_waiting)
  eq(buffer_text(), "## Waiting On\n- [ ] @Raju Estimate\n\n## Notes")
end)

test("asks before creating a missing Waiting On section at the end of the note", function()
  reset(nil)
  note_buffer("# Title\nText")
  local asked = with_inputs({ "", "Task" }, lattice.add_waiting, "Yes")
  eq(asked, { 'This note has no "Waiting On" heading. Add one at the end?' })
  eq(buffer_text(), "# Title\nText\n\n## Waiting On\n- [ ] Task")
end)

test("declining or dismissing the heading prompt leaves the buffer untouched", function()
  reset(nil)
  note_buffer("# Title\nText")
  vim.bo.modified = false
  with_inputs({ "", "Task" }, lattice.add_waiting, "No")
  with_inputs({ "Raju", "Task" }, lattice.add_waiting, nil)
  eq(buffer_text(), "# Title\nText")
  eq(vim.bo.modified, false)
end)

test("does not reuse a section-like heading inside a code fence", function()
  reset(nil)
  note_buffer("```\n## Waiting On\n```")
  with_inputs({ "", "Task" }, lattice.add_waiting, "Yes")
  eq(buffer_text(), "```\n## Waiting On\n```\n\n## Waiting On\n- [ ] Task")
end)

test("fills an empty note with a Waiting On section after confirmation", function()
  reset(nil)
  note_buffer("")
  with_inputs({ "", "Task" }, lattice.add_waiting, "Yes")
  eq(buffer_text(), "## Waiting On\n- [ ] Task")
end)

test("warns when a Waiting On item lands inside an unclosed code fence", function()
  reset(nil)
  note_buffer("## Waiting On\n- One\n```\ncode never closed")
  with_inputs({ "", "Hidden" }, lattice.add_waiting)
  eq(buffer_text(), "## Waiting On\n- One\n```\ncode never closed\n- [ ] Hidden")
  assert(H.last_notify().message:find("line 5 was added", 1, true), H.last_notify().message)

  note_buffer("# Title\n```")
  with_inputs({ "", "Also hidden" }, lattice.add_waiting, "Yes")
  eq(buffer_text(), "# Title\n```\n\n## Waiting On\n- [ ] Also hidden")
  assert(H.last_notify().message:find("line 5 was added", 1, true), H.last_notify().message)
end)

test("the assignee is optional", function()
  reset(nil)
  note_buffer("## Waiting On\n- Old")
  with_inputs({ "", "Follow up with vendor" }, lattice.add_waiting)
  eq(buffer_text(), "## Waiting On\n- Old\n- [ ] Follow up with vendor")
end)

local REPEATED = table.concat({
  "# Notes", -- 1
  "## Waiting On", -- 2
  "- A", -- 3
  "## Middle", -- 4
  "text", -- 5
  "### Waiting On", -- 6
  "- B", -- 7
  "", -- 8
  "## End", -- 9
}, "\n")

local function add_at(cursor)
  note_buffer(REPEATED)
  at(cursor)
  with_inputs({ "", "New" }, lattice.add_waiting)
  return buffer_text()
end

test("with repeated sections, uses the one containing the cursor", function()
  reset(nil)
  eq(add_at(8), (REPEATED:gsub("%- B", "- B\n- [ ] New")))
  eq(add_at(3), (REPEATED:gsub("%- A", "- A\n- [ ] New")))
end)

test("outside any section, uses the nearest section above, else the first below", function()
  reset(nil)
  eq(add_at(5), (REPEATED:gsub("%- A", "- A\n- [ ] New")))
  eq(add_at(9), (REPEATED:gsub("%- B", "- B\n- [ ] New")))
  eq(add_at(1), (REPEATED:gsub("%- A", "- A\n- [ ] New")))
end)

test("pick_section is deterministic", function()
  local sections = { { line = 2, stop = 3 }, { line = 6, stop = 8 } }
  eq(H.insert.pick_section(sections, 7), sections[2])
  eq(H.insert.pick_section(sections, 4), sections[1])
  eq(H.insert.pick_section(sections, 1), sections[1])
  eq(H.insert.pick_section(sections, 20), sections[2])
end)

test("uses the Waiting On heading from .lattice.json", function()
  local root = notes()
  write(root, ".lattice.json", '{"headings": {"waiting": "Blocked"}}')
  reset(root)
  note_buffer("## Blocked\n- One")
  with_inputs({ "", "Two" }, lattice.add_waiting)
  eq(buffer_text(), "## Blocked\n- One\n- [ ] Two")
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
  local path = write(root, "a.md", "## TODO\n- One\n")
  reset(root)
  vim.cmd.edit(vim.fn.fnameescape(path))
  with_inputs({ "Two" }, lattice.add_todo)
  eq(buffer_text(), "## TODO\n- TODO Two\n- One")
  eq(vim.bo.modified, true)
  eq(read(path), "## TODO\n- One\n")
  vim.cmd("bwipeout!")
end)

test("never inserts into the dashboard or a non-Markdown buffer", function()
  local root = notes()
  write(root, "a.md", "## TODO\n- Task\n")
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
