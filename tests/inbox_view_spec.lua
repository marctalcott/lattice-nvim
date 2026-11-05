-- Inbox review: titles, filenames, folder suggestions, the view and filing
-- (LATTICE_INBOX_SPEC §8–§11, A1.2, A1.3, A1.8–A1.10).
local H = require("helpers")
local IH = require("inbox_helpers")
local test, eq, write, read, notes = H.test, H.eq, H.write, H.read, H.notes
local config = H.config
local process = require("lattice.inbox_process")
local view = require("lattice.inbox_view")
local sync = require("lattice.inbox_sync")

-- Titles (A1.8) -----------------------------------------------------------------

test("title: first sentence, filler dropped, at most 8 words, capitalized", function()
  local cases = {
    {
      "I was thinking about a better way to organize\nthe project notes when I get back to my computer.",
      "A better way to organize",
    },
    { "I was thinking about a better way to organize the project notes. Maybe later.", "A better way to organize the project notes" },
    { "\n\n  - [ ] call Kilauea team about the gas readings? and more", "Call Kilauea team about the gas readings" },
    { "# Etna: lava dome observations", "Etna: lava dome observations" },
    { "Maybe we should separate meeting notes from decisions!", "Separate meeting notes from decisions" },
    { "So, the Stromboli trip", "The Stromboli trip" },
    { "Sorting the Stromboli photos", "Sorting the Stromboli photos" }, -- "So" is not a prefix of a word
    { "note to self: renew permit", "Renew permit" },
    { "one two three four five six seven eight nine ten", "One two three four five six seven eight" },
    { "Supercalifragilisticexpialidocious-lava-observation-network-and-more-words-here", "Supercalifragilisticexpialidocious-lava-observation-network" }, -- cut at 60, trailing - dropped
    { "éruption à Piton de la Fournaise", "Éruption à Piton de la Fournaise" },
    { "iPhone note about Etna", "IPhone note about Etna" },
  }
  for _, case in ipairs(cases) do
    eq(process.title(vim.split(case[1], "\n"), nil), case[2])
  end
end)

test("title: 60-character limit cuts at a word boundary", function()
  local title = process.title({ "Aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd eeeeeeeeee ffffffffff gggg" })
  eq(title, "Aaaaaaaaaa bbbbbbbbbb cccccccccc dddddddddd eeeeeeeeee")
  assert(vim.fn.strchars(title) <= 60)
end)

test("title: falls back to the capture time", function()
  eq(process.title({ "", "   " }, "2026-11-05T07:45:00-05:00"), "Capture 2026-11-05 0745")
  eq(process.title({ "I think." }, "2026-11-05T07:45:00-05:00"), "Capture 2026-11-05 0745")
  eq(process.title({}, nil), "Capture")
end)

test("epoch: ISO timestamps with offsets compare correctly", function()
  eq(process.epoch("1970-01-01T00:00:00Z"), 0)
  eq(process.epoch("2026-11-05T07:45:00-05:00"), process.epoch("2026-11-05T12:45:00Z"))
  eq(process.epoch("2026-11-05T07:45:00+01:00") < process.epoch("2026-11-05T07:45:00-05:00"), true)
  eq(process.epoch("2024-02-29T00:00:00Z") - process.epoch("2024-02-28T00:00:00Z"), 86400)
  eq(process.epoch("not a date"), nil)
  eq(process.epoch("2026-11-05T07:45:00 nonsense"), nil)
end)

-- File names -----------------------------------------------------------------

test("file names are safe, cut at 80 bytes, and never reuse a taken path", function()
  eq(process.file_stem("Etna: lava/dome? *notes*"), "Etna lava dome notes")
  eq(process.file_stem("..hidden"), "hidden")
  eq(process.file_stem("a\tb\nc"), "a b c")
  eq(process.file_stem("///"), "Capture")
  local long = process.file_stem(string.rep("é", 50))
  assert(#long <= 80 and vim.fn.strchars(long) == 40, long)
  local taken = { ["/n/Ideas.md"] = true, ["/n/Ideas 2.md"] = true }
  eq(process.free_path("/n", "Ideas", function(p)
    return taken[p]
  end), "/n/Ideas 3.md")
  local root = notes()
  write(root, "Ideas.md", "x")
  eq(process.free_path(root, "Ideas"), root .. "/Ideas 2.md")
end)

-- Folder suggestions (A1.9) ----------------------------------------------------------

local function para_root()
  local root = notes()
  for _, dir in ipairs({
    "Projects/Etna",
    "Projects/Kilauea",
    "Projects/Etna/Deep/Deeper",
    "Areas/Photography",
    "Areas/1-Field_Work",
    "Resources",
    "Archives/Old",
    "Inbox/Sub",
    ".hidden",
  }) do
    vim.fn.mkdir(root .. "/" .. dir, "p")
  end
  vim.uv.fs_symlink("/tmp", root .. "/Linked")
  return root
end

test("folders: depth 1 and 2, skipping hidden, excluded, inbox and symlinked folders", function()
  local root = para_root()
  eq(process.folders(root, config.defaults()), {
    "Areas",
    "Areas/1-Field_Work",
    "Areas/Photography",
    "Projects",
    "Projects/Etna",
    "Projects/Kilauea",
    "Resources",
  })
end)

test("suggest: most whole-word matches wins; ties prefer deeper, then alphabetical; else default", function()
  local folders = process.folders(para_root(), config.defaults())
  local function suggest(text, aliases)
    return (process.suggest(vim.split(text, "\n"), folders, aliases or {}, "Resources"))
  end
  eq(suggest("Etna readings look odd. Ask about Etna and Kilauea."), "Projects/Etna")
  eq(suggest("Kilauea and Etna"), "Projects/Etna") -- tie at depth 2: alphabetical
  eq(suggest("ETNA lava"), "Projects/Etna") -- case-insensitive
  eq(suggest("Etnaville is unrelated"), "Resources") -- whole words only
  eq(suggest("plan the field work for spring"), "Areas/1-Field_Work") -- numbering and _ ignored
  eq(suggest("new projects list"), "Projects")
  eq(suggest("projects about Etna"), "Projects/Etna") -- tie: deeper wins
  eq(suggest("nothing relevant"), "Resources")
  eq(suggest("the lava dome grew", { ["Projects/Kilauea"] = { "Lava Dome" } }), "Projects/Kilauea")
  -- Deterministic: the same input gives the same answer.
  eq(suggest("Kilauea and Etna"), suggest("Kilauea and Etna"))
end)

-- Note text (A1.3) -------------------------------------------------------------------

local CAPTURE = { id = "3f1c9a52", created = "2026-11-05T07:45:00-05:00", source = "drafts", repo = "Personal" }

test("note lines: heading, capture properties, blank line, text unchanged", function()
  local body = { "Etna idea.", "", "  - keep indent  ", "tab\there" }
  eq(process.note_lines(CAPTURE, body, "Etna idea", nil), {
    "# Etna idea",
    ":PROPERTIES:",
    ":CAPTURE_ID: 3f1c9a52",
    ":CAPTURED: 2026-11-05T07:45:00-05:00",
    ":CAPTURE_SOURCE: drafts",
    ":CAPTURE_REPO: Personal",
    ":END:",
    "",
    "Etna idea.",
    "",
    "  - keep indent  ",
    "tab\there",
  })
  eq(process.note_lines(CAPTURE, {}, "Call the Etna team", "TODO")[1], "# TODO Call the Etna team")
  eq(process.has_capture_id(table.concat(process.note_lines(CAPTURE, body, "x"), "\n") .. "\n", "3f1c9a52"), true)
  eq(process.has_capture_id("# x\nno drawer\n", "3f1c9a52"), false)
  local note = table.concat(process.note_lines(CAPTURE, body, "x"), "\n") .. "\n"
  eq(process.has_capture_id(note, "3f1c9a52", CAPTURE.repo), true)
  eq(process.has_capture_id(note, "3f1c9a52", "Work"), false)
  local drawer = ":PROPERTIES:\n:CAPTURE_ID: 3f1c9a52\n:END:\n"
  eq(process.has_capture_id("# a\r\n:PROPERTIES:\r\n:capture_id:  3f1c9a52 \r\n:END:\r\n", "3f1c9a52"), true)
  eq(process.has_capture_id("# x\n:PROPERTIES:\n:CAPTURE_ID: 3f1c9a52-more\n:END:\n", "3f1c9a52"), false)
  -- Only a heading's property drawer counts: not body text, a quote or code.
  eq(process.has_capture_id("# x\n\nSome text.\n" .. drawer, "3f1c9a52"), false)
  eq(process.has_capture_id(":CAPTURE_ID: 3f1c9a52\n", "3f1c9a52"), false)
  eq(process.has_capture_id("# x\n\n```\n# y\n" .. drawer .. "```\n", "3f1c9a52"), false)
  eq(process.has_capture_id("# x\n\n> :CAPTURE_ID: 3f1c9a52\n", "3f1c9a52"), false)
end)

test("a filed task note is read by Lattice as a TODO heading with its properties", function()
  local lines = process.note_lines(CAPTURE, { "Ask about the gas readings." }, "Call the Etna team", "TODO")
  local parsed = H.parse(table.concat(lines, "\n"))
  eq(#parsed.tasks, 1)
  eq(parsed.tasks[1].state, "TODO")
  eq(parsed.tasks[1].title, "Call the Etna team")
  eq(parsed.tasks[1].properties.CAPTURE_ID, "3f1c9a52")
  eq(#H.parse(table.concat(process.note_lines(CAPTURE, { "x" }, "Plain note"), "\n")).tasks, 0)
end)

-- The view and filing -------------------------------------------------------------------

local function inbox_with(captures, opts)
  opts = opts or {}
  local root = opts.root or para_root()
  local r = IH.remote()
  r.push(captures)
  if opts.protect then
    r.protect(true)
  end
  IH.setup_inbox(root, opts.repos or { { name = "Personal", url = r.url, notes_root = root } }, opts.inbox)
  IH.fetch("manual")
  H.reset(root)
  view.state.pending, view.state.collapsed = {}, {}
  view.open()
  return root, r
end

local function cursor_to(text)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line:find(text, 1, true) then
      vim.api.nvim_win_set_cursor(0, { i, 0 })
      return
    end
  end
  error("no inbox line contains " .. text .. ":\n" .. H.dashboard_text())
end

-- Answers vim.ui.input / vim.ui.select prompts; records what select offered.
local function answer(title, folder)
  local offered = {}
  local input, select = vim.ui.input, vim.ui.select
  vim.ui.input = function(opts, cb)
    offered.default = opts.default
    cb(title == true and opts.default or title)
  end
  vim.ui.select = function(items, opts, cb)
    offered.items = vim.tbl_map(opts.format_item, items)
    cb(folder == true and items[1] or folder)
  end
  return offered, function()
    vim.ui.input, vim.ui.select = input, select
  end
end

local function cap(id, created, text)
  return ('---\nid: "%s"\ncreated: "%s"\nsource: "drafts"\ndestination: "personal"\n---\n%s\n'):format(id, created, text)
end

test("view: grouped by repository, newest first, with counts and dates", function()
  local root = para_root()
  local a, b = IH.remote(), IH.remote()
  a.push({
    ["2026-11-04-182000-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-04T18:20:00-05:00", "Photography notes"),
    ["2026-11-05-074500-bbbbbbbb.md"] = cap("bbbbbbbb", "2026-11-05T07:45:00-05:00", "Project organization idea"),
    ["2026-11-05-080000-cccccccc.md"] = cap("cccccccc", "2026-11-05T12:00:00+01:00", "Earlier in absolute time"),
  })
  b.push({ ["2026-11-05-081500-dddddddd.md"] = cap("dddddddd", "2026-11-05T08:15:00-05:00", "Deployment improvement") })
  IH.setup_inbox(root, {
    { name = "Personal", url = a.url, notes_root = root },
    { name = "Work", url = b.url, notes_root = root },
  })
  IH.fetch("manual")
  H.reset(root)
  view.state.collapsed = {}
  view.open()
  eq(vim.api.nvim_buf_get_lines(0, 0, 9, false), {
    "LATTICE INBOX",
    "",
    "▾ Personal (3)",
    "  2026-11-05 07:45  Project organization idea",
    "  2026-11-05 12:00  Earlier in absolute time", -- 11:00 UTC, before 12:45 UTC
    "  2026-11-04 18:20  Photography notes",
    "",
    "▾ Work (1)",
    "  2026-11-05 08:15  Deployment improvement",
  })
  -- The cursor starts on the first capture.
  eq(vim.api.nvim_win_get_cursor(0)[1], 4)
  -- Enter on a group header folds it.
  cursor_to("Personal")
  view.activate()
  eq(vim.api.nvim_buf_get_lines(0, 2, 4, false), { "▸ Personal (3)", "" })
  view.activate()
  eq(vim.api.nvim_buf_get_lines(0, 3, 4, false), { "  2026-11-05 07:45  Project organization idea" })
  view.close()
end)

test("view: oldest_first, repository errors and malformed captures are shown", function()
  local root = para_root()
  local a = IH.remote()
  a.push({
    ["2026-11-04-182000-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-04T18:20:00-05:00", "First"),
    ["2026-11-05-074500-bbbbbbbb.md"] = cap("bbbbbbbb", "2026-11-05T07:45:00-05:00", "Second"),
    ["noid.md"] = "no front matter\n",
  })
  IH.setup_inbox(root, {
    { name = "Personal", url = a.url, notes_root = root },
    { name = "Broken", url = root .. "/missing.git", notes_root = root },
  }, { sort_order = "oldest_first" })
  IH.fetch("manual")
  H.reset(root)
  view.open()
  local text = H.dashboard_text()
  assert(text:find("  2026-11-04 18:20  First\n  2026-11-05 07:45  Second", 1, true), text)
  assert(text:find("  ⚠ noid.md: no id in its front matter", 1, true), text)
  assert(text:find("▾ Broken (0)\n  ! repository not found", 1, true), text)
  view.close()
end)

test("view: says why it is empty", function()
  local root = notes()
  config.options.root = root
  config.options.inbox_sync = { config = root .. "/none.json" }
  sync.state = sync.new_state()
  H.reset(root)
  view.open()
  assert(H.dashboard_text():find("Inbox is off: no configuration at", 1, true), H.dashboard_text())
  view.close()
end)

test("preview: read-only, with suggested title, date, repository, folder and the text", function()
  inbox_with({ ["2026-11-05-074500-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-05T07:45:00-05:00", "I think the Kilauea gas readings need a second look.\nCall Leilani.") })
  cursor_to("Kilauea")
  view.activate()
  local win = view.state.preview_win
  local buf = vim.api.nvim_win_get_buf(win)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
    "Title:    The Kilauea gas readings need a second look",
    "Captured: 2026-11-05T07:45:00-05:00",
    "From:     Personal",
    "Folder:   Projects/Kilauea",
    "",
    "I think the Kilauea gas readings need a second look.",
    "Call Leilani.",
    "",
    "f  File    t  Task    o  Open    D  Dismiss",
  })
  eq({ vim.bo[buf].modifiable, vim.bo[buf].readonly }, { false, true })
  -- Focus stays in the inbox.
  eq(vim.api.nvim_get_current_buf(), view.state.buf)
  view.close()
  eq(vim.api.nvim_win_is_valid(win), false)
end)

test("preview: a missing default folder is explained", function()
  local root = notes()
  vim.fn.mkdir(root .. "/Projects", "p")
  inbox_with({ ["2026-11-05-074500-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-05T07:45:00-05:00", "Nothing matches") }, { root = root })
  cursor_to("Nothing")
  view.activate()
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(view.state.preview_win), 0, -1, false)
  eq(lines[4], "Folder:   none (default folder Resources does not exist or is excluded)")
  view.close()
end)

test("file: asks for title then folder, opens an unsaved note; saving files the capture", function()
  local root, r = inbox_with({ ["2026-11-05-074500-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-05T07:45:00-05:00", "Etna lava dome notes.\nMore detail.") })
  cursor_to("Etna")
  local offered, restore = answer("Etna dome", true)
  view.process("file")
  restore()
  eq(offered.default, "Etna lava dome notes")
  eq(offered.items[1], "Projects/Etna  (suggested)")
  local path = root .. "/Projects/Etna/Etna dome.md"
  local buf = vim.api.nvim_get_current_buf()
  eq(vim.api.nvim_buf_get_name(buf), path)
  eq(vim.bo[buf].modified, true)
  -- Nothing is written until the user saves.
  eq(vim.uv.fs_stat(path), nil)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
    "# Etna dome",
    ":PROPERTIES:",
    ":CAPTURE_ID: aaaaaaaa",
    ":CAPTURED: 2026-11-05T07:45:00-05:00",
    ":CAPTURE_SOURCE: drafts",
    ":CAPTURE_REPO: Personal",
    ":END:",
    "",
    "Etna lava dome notes.",
    "More detail.",
  })
  -- Filing again while the note is unsaved returns to the same buffer.
  view.open()
  cursor_to("Etna")
  view.process("file")
  eq(vim.api.nvim_get_current_buf(), buf)
  -- The user saves.
  vim.cmd("silent write")
  eq(H.last_notify().message, "Lattice Inbox: filed as Projects/Etna/Etna dome.md")
  assert(read(path):find(":CAPTURE_ID: aaaaaaaa\n", 1, true))
  view.open()
  local text = H.dashboard_text()
  assert(text:find("▾ Personal (0)", 1, true), text)
  assert(text:find("Etna lava dome notes  · filed, removing…", 1, true), text)
  -- Removal from GitHub follows the save.
  IH.wait_removals()
  eq(r.files(), {})
  eq(r.last_message(), "Lattice: remove processed capture 2026-11-05-074500-aaaaaaaa.md")
  text = H.dashboard_text()
  assert(text:find("▾ Personal (0)\n  No captures", 1, true), text)
  eq(H.last_notify().message, "Lattice Inbox: filed as Projects/Etna/Etna dome.md")
  -- Saving the note again is an ordinary save.
  vim.notify("sentinel")
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent write")
  end)
  eq(H.last_notify().message, "sentinel")
  view.close()
end)

test("task: the note's heading starts with the default workflow's first state", function()
  local root = inbox_with({ ["2026-11-05-074500-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-05T07:45:00-05:00", "Call the Etna team") })
  write(root, ".lattice.json", '{"todo": "BACKLOG TODO | DONE"}')
  cursor_to("Etna")
  local _, restore = answer(true, "Projects/Etna")
  view.process("task")
  restore()
  eq(vim.api.nvim_buf_get_lines(0, 0, 1, false), { "# BACKLOG Call the Etna team" })
  vim.cmd("silent write")
  local result = H.scanner.collect(root)
  local found
  for _, task in ipairs(result.tasks) do
    if task.title == "Call the Etna team" then
      found = task
    end
  end
  assert(found and found.state == "BACKLOG", vim.inspect(found))
end)

test("file: an existing name gets a number; cancelling either prompt creates nothing", function()
  local root = inbox_with({ ["2026-11-05-074500-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-05T07:45:00-05:00", "Etna notes") })
  write(root, "Projects/Etna/Etna notes.md", "existing\n")
  local before = vim.api.nvim_list_bufs()
  for _, case in ipairs({ { nil, true }, { "  ", true }, { true, nil } }) do
    cursor_to("Etna")
    local _, restore = answer(case[1], case[2])
    view.process("file")
    restore()
    eq(vim.api.nvim_list_bufs(), before)
  end
  cursor_to("Etna")
  local _, restore = answer(true, "Projects/Etna")
  view.process("file")
  restore()
  eq(vim.api.nvim_buf_get_name(0), root .. "/Projects/Etna/Etna notes 2.md")
  eq(read(root .. "/Projects/Etna/Etna notes.md"), "existing\n")
end)

test("file: saving without the capture ID keeps the capture; a file appearing first blocks the write", function()
  local root = inbox_with({ ["2026-11-05-074500-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-05T07:45:00-05:00", "Etna notes") })
  cursor_to("Etna")
  local _, restore = answer(true, "Resources")
  view.process("file")
  restore()
  local path = vim.api.nvim_buf_get_name(0)
  eq(path, root .. "/Resources/Etna notes.md")
  -- Another program creates the file before the user saves: Neovim refuses.
  write(root, "Resources/Etna notes.md", "theirs\n")
  local ok, err = pcall(vim.cmd, "silent write")
  eq(ok, false)
  assert(tostring(err):find("E13", 1, true), err)
  eq(read(path), "theirs\n")
  -- The user removes the property and saves elsewhere under the same name.
  vim.fn.delete(path)
  vim.api.nvim_buf_set_lines(0, 2, 3, false, {})
  vim.cmd("silent write")
  assert(H.last_notify().message:find("saved without :CAPTURE_ID: aaaaaaaa", 1, true), H.last_notify().message)
  view.open()
  assert(H.dashboard_text():find("▾ Personal (1)", 1, true))
  view.close()
end)

test("file: malformed captures cannot be filed; o opens the capture read-only", function()
  inbox_with({
    ["noid.md"] = "just text\n",
    ["2026-11-05-074500-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-05T07:45:00-05:00", "Etna notes"),
  })
  cursor_to("noid.md")
  local offered, restore = answer(true, true)
  view.process("file")
  restore()
  eq(offered.default, nil)
  assert(H.last_notify().message:find("noid.md cannot be filed", 1, true))
  cursor_to("Etna")
  view.open_capture()
  eq({ vim.bo.readonly, vim.bo.modifiable }, { true, false })
  assert(vim.endswith(vim.api.nvim_buf_get_name(0), "/2026-11-05-074500-aaaaaaaa.md"), vim.api.nvim_buf_get_name(0))
end)

test("file: a folder outside the notes root is refused", function()
  local root = inbox_with({ ["2026-11-05-074500-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-05T07:45:00-05:00", "Etna notes") })
  cursor_to("Etna")
  local before = vim.api.nvim_list_bufs()
  for _, folder in ipairs({ "../outside", "Linked", "Missing" }) do
    local _, restore = answer(true, folder)
    view.process("file")
    restore()
    eq(vim.api.nvim_list_bufs(), before)
    eq(H.last_notify().level, vim.log.levels.ERROR)
  end
  eq(vim.uv.fs_stat(vim.fs.dirname(root) .. "/outside"), nil)
end)

-- Dismissal (§12.4) and recovery in the view (A1.12) ---------------------------------

local function confirming(answer_yes)
  local asked = {}
  local confirm = view.confirm
  view.confirm = function(message)
    asked[#asked + 1] = message
    return answer_yes
  end
  return asked, function()
    view.confirm = confirm
  end
end

test("dismiss: asks first; cancelling keeps the capture, confirming deletes it remotely", function()
  local _, r = inbox_with({
    ["2026-11-05-074500-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-05T07:45:00-05:00", "Etna notes"),
    ["noid.md"] = "just text\n",
  })
  cursor_to("Etna")
  local asked, restore = confirming(false)
  view.dismiss()
  restore()
  eq(asked, { 'Dismiss "Etna notes" from Personal? It is deleted from GitHub and not filed.' })
  eq(#r.files(), 2)
  asked, restore = confirming(true)
  view.dismiss()
  assert(H.dashboard_text():find("Etna notes  · dismissing…", 1, true), H.dashboard_text())
  -- Pressing D again while it runs says so.
  view.dismiss()
  eq(H.last_notify().message, "Lattice Inbox: this capture is being dismissed")
  eq(#asked, 1)
  IH.wait_removals()
  eq(r.files(), { "noid.md" })
  eq(H.last_notify().message, "Lattice Inbox: dismissed 2026-11-05-074500-aaaaaaaa.md")
  -- A malformed capture can be dismissed too.
  cursor_to("noid.md")
  view.dismiss()
  IH.wait_removals()
  restore()
  eq(asked[2], 'Dismiss "noid.md" from Personal? It is deleted from GitHub and not filed.')
  eq(r.files(), {})
  assert(H.dashboard_text():find("▾ Personal (0)\n  No captures", 1, true), H.dashboard_text())
  view.close()
end)

test("dismiss: a failed deletion leaves the capture available", function()
  local _, r = inbox_with({ ["2026-11-05-074500-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-05T07:45:00-05:00", "Etna notes") })
  r.protect(true)
  cursor_to("Etna")
  local _, restore = confirming(true)
  view.dismiss()
  IH.wait_removals()
  restore()
  eq(sync.state.removals, {})
  eq(H.last_notify().level, vim.log.levels.WARN)
  assert(H.last_notify().message:find("could not dismiss 2026-11-05-074500-aaaaaaaa.md from Personal", 1, true))
  assert(H.dashboard_text():find("▾ Personal (1)\n  2026-11-05 07:45  Etna notes\n", 1, true), H.dashboard_text())
  eq(#r.files(), 1)
  view.close()
end)

test("dismiss: refused while the capture's note is open unsaved", function()
  local _, r = inbox_with({ ["2026-11-05-074500-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-05T07:45:00-05:00", "Etna notes") })
  cursor_to("Etna")
  local _, restore = answer(true, "Resources")
  view.process("file")
  restore()
  local note = vim.api.nvim_get_current_buf()
  view.open()
  cursor_to("Etna")
  local asked, restore_confirm = confirming(true)
  view.dismiss()
  restore_confirm()
  eq(asked, {})
  assert(H.last_notify().message:find("open and unsaved", 1, true))
  eq(#r.files(), 1)
  view.close()
  vim.api.nvim_buf_delete(note, { force = true })
end)

test("recovery: a capture already filed in a note shows as filed and cannot be filed again", function()
  local root = para_root()
  write(root, "Resources/Etna notes.md", "# Etna notes\n:PROPERTIES:\n:CAPTURE_ID: aaaaaaaa\n:CAPTURE_REPO: Personal\n:END:\n")
  -- The remote refuses pushes, so the removal started by the fetch fails.
  local _, r = inbox_with(
    { ["2026-11-05-074500-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-05T07:45:00-05:00", "Etna notes") },
    { root = root, protect = true }
  )
  IH.wait_removals()
  view.paint()
  assert(H.dashboard_text():find("▾ Personal (0)\n  2026-11-05 07:45  Etna notes  · filed, removal pending", 1, true), H.dashboard_text())
  cursor_to("Etna")
  local offered, restore = answer(true, true)
  view.process("file")
  restore()
  eq(offered.default, nil)
  eq(H.last_notify().message, "Lattice Inbox: already filed as Resources/Etna notes.md; R retries its removal")
  -- Allowed again: R removes it.
  r.protect(false)
  view.refresh()
  assert(vim.wait(20000, function()
    return not sync.state.running and next(sync.state.removals) == nil
  end, 20))
  eq(r.files(), {})
  view.close()
end)

test("file: the saved note must name the capture's repository; a parse failure is reported", function()
  local root, r = inbox_with({ ["2026-11-05-074500-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-05T07:45:00-05:00", "Etna notes") })
  cursor_to("Etna")
  local _, restore = answer(true, "Resources")
  view.process("file")
  restore()
  local buf = vim.api.nvim_get_current_buf()
  -- Another repository's drawer: not this capture.
  vim.api.nvim_buf_set_lines(buf, 5, 6, false, { ":CAPTURE_REPO: Work" })
  vim.cmd("silent write")
  assert(H.last_notify().message:find("saved without :CAPTURE_ID: aaaaaaaa and :CAPTURE_REPO: Personal", 1, true), H.last_notify().message)
  eq(sync.state.removals, {})
  -- The note can't be parsed back.
  vim.api.nvim_buf_set_lines(buf, 5, 6, false, { ":CAPTURE_REPO: Personal" })
  local tasks = require("lattice.tasks")
  local parse = tasks.parse
  tasks.parse = function()
    return nil, "no Markdown parser"
  end
  vim.cmd("silent write")
  tasks.parse = parse
  eq(H.last_notify().message, "Lattice Inbox: Resources/Etna notes.md could not be read back (no Markdown parser), so the capture stays in the inbox")
  eq(sync.state.removals, {})
  -- Fixed: the next save files it.
  vim.cmd("silent write")
  eq(H.last_notify().message, "Lattice Inbox: filed as Resources/Etna notes.md")
  IH.wait_removals()
  eq(r.files(), {})
end)

test("file: saving after the capture was recovered from another note warns and does not file it again", function()
  local root = inbox_with({ ["2026-11-05-074500-aaaaaaaa.md"] = cap("aaaaaaaa", "2026-11-05T07:45:00-05:00", "Etna notes") })
  cursor_to("Etna")
  local _, restore = answer(true, "Resources")
  view.process("file")
  restore()
  local buf = vim.api.nvim_get_current_buf()
  -- Meanwhile a fetch found an older note for this capture.
  sync.state.removals["Personal\0aaaaaaaa"] = {
    repo = "Personal",
    id = "aaaaaaaa",
    file = "2026-11-05-074500-aaaaaaaa.md",
    kind = "filed",
    note = root .. "/Projects/Etna/Older.md",
    status = "pending",
  }
  vim.cmd("silent write")
  eq(
    H.last_notify().message,
    "Lattice Inbox: the capture was already filed as Projects/Etna/Older.md; Resources/Etna notes.md is a separate copy and the capture was not filed again"
  )
  eq(view.state.pending["Personal\0aaaaaaaa"], nil)
  -- Later saves are ordinary saves.
  vim.notify("sentinel")
  vim.api.nvim_buf_call(buf, function()
    vim.cmd("silent write")
  end)
  eq(H.last_notify().message, "sentinel")
  sync.state.removals = {}
end)
