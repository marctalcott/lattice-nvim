local H = require("helpers")
local config, dashboard, lattice, parser, scanner = H.config, H.dashboard, H.lattice, H.parser, H.scanner
local test, eq, parse, texts, write, read = H.test, H.eq, H.parse, H.texts, H.write, H.read
local notes, reset, dashboard_text, press_enter_on = H.notes, H.reset, H.dashboard_text, H.press_enter_on

-- Config ---------------------------------------------------------------------

test("a missing config uses defaults with a notice", function()
  local cfg, notice, err = config.load(notes())
  eq(cfg, config.defaults())
  assert(notice:find(".lattice.json", 1, true))
  eq(err, nil)
end)

test("malformed configs give an error and scan nothing", function()
  local bad = {
    "{ nope",
    "",
    '{"version": 2}',
    '{"scan": "x"}',
    '{"scan": {"include": "**/*.md"}}',
    '{"scan": {"exclude": [1]}}',
    '{"scan": {"include": ["../**/*.md"]}}',
    '{"scan": {"include": ["/etc/**"]}}',
    '{"headings": {"todo": ""}}',
    '{"headings": {"todo": "Same", "waiting": "Same"}}',
  }
  for _, content in ipairs(bad) do
    local root = notes()
    write(root, ".lattice.json", content)
    write(root, "a.md", "## To Do\n- Task")
    local result = scanner.collect(root)
    assert(result.error, "expected an error for: " .. content)
    eq(result.tasks, {})
  end
end)

test("rejects an inbox outside the notes root", function()
  for _, path in ipairs({ "../Inbox", "/tmp/Inbox", "~/Inbox", "a/../../b", "", 1 }) do
    local root = notes()
    write(root, ".lattice.json", vim.json.encode({ inbox = { path = path } }))
    assert(scanner.collect(root).error, "expected an error for: " .. tostring(path))
  end
end)

test("an unset or missing root is an error, never a fallback", function()
  assert(scanner.collect(nil).error)
  assert(scanner.collect("/no/such/lattice/root").error)
end)

test("partial config keeps other defaults; an empty exclude removes Archives", function()
  local root = notes()
  write(root, ".lattice.json", '{"scan": {"exclude": []}}')
  write(root, "Archives/old.md", "## To Do\n- Old")
  local result = scanner.collect(root)
  eq(result.tasks[1].text, "Old")
end)

test("setup can disable or override keymaps", function()
  local saved = vim.deepcopy(config.options)
  lattice.setup({ root = "~/x", keymaps = { refresh = false, open = "<leader>zz" } })
  eq(vim.fn.maparg("<leader>zz", "n") ~= "" or vim.fn.mapcheck("<leader>zz", "n") ~= "", true)
  eq(config.options.keymaps.refresh, false)
  eq(config.options.keymaps.add_todo, "<leader>lt")
  eq(config.setup({ keymaps = false }).keymaps, false)
  config.options = saved
end)

test("setup keeps an existing mapping and reports it", function()
  local saved = vim.deepcopy(config.options)
  vim.keymap.set("n", "<leader>lt", "<cmd>echo 'mine'<cr>", { desc = "my own mapping" })
  lattice.setup({ root = "~/x" })
  eq(vim.fn.maparg("<leader>lt", "n", false, true).desc, "my own mapping")
  assert(H.last_notify().message:find("kept your existing mapping for <leader>lt (add_todo)", 1, true))
  eq(H.health.keymap_conflicts, { { lhs = "<leader>lt", action = "add_todo" } })
  -- Lattice's own mappings are not conflicts when setup runs again.
  eq(vim.fn.maparg("<leader>ll", "n", false, true).desc, "Lattice: open dashboard")
  lattice.setup({ root = "~/x", keymaps = { add_todo = false } })
  eq(H.health.keymap_conflicts, {})
  vim.keymap.del("n", "<leader>lt")
  config.options = saved
end)

-- Scanning -------------------------------------------------------------------

test("scans PARA folders and honors exclusions", function()
  local root = notes()
  write(root, ".lattice.json", '{"scan": {"include": ["**/*.md"], "exclude": ["Archives/**", "**/drafts/**", "Areas/skip.md"]}}')
  local task = "## To Do\n- Task"
  for _, rel in ipairs({ "Projects/a/n.md", "Areas/n.md", "Resources/n.md", "top.md" }) do
    write(root, rel, task)
  end
  for _, rel in ipairs({ "Archives/old/n.md", "Projects/drafts/n.md", "Areas/skip.md", "Projects/a/n.txt" }) do
    write(root, rel, task)
  end
  local files = scanner.list_files(root, config.load(root).scan)
  eq(files, { "Areas/n.md", "Projects/a/n.md", "Resources/n.md", "top.md" })
end)

test("* stays within one path segment", function()
  local root = notes()
  write(root, "Projects/a.md", "")
  write(root, "Projects/deep/b.md", "")
  local files = scanner.list_files(root, { include = { "Projects/*.md" }, exclude = {} })
  eq(files, { "Projects/a.md" })
end)

test("excluded directories are not entered", function()
  local root = notes()
  write(root, "Archives/secret/n.md", "")
  vim.fn.setfperm(root .. "/Archives/secret", "---------")
  local _, errors = scanner.list_files(root, config.defaults().scan)
  vim.fn.setfperm(root .. "/Archives/secret", "rwxr-xr-x")
  eq(errors, {})
end)

test("symlinks are never followed", function()
  local root, outside = notes(), notes()
  write(outside, "out.md", "## To Do\n- Outside")
  write(root, "in.md", "## To Do\n- Inside")
  assert(vim.uv.fs_symlink(outside, root .. "/linked"))
  assert(vim.uv.fs_symlink(outside .. "/out.md", root .. "/linked.md"))
  eq(scanner.list_files(root, config.defaults().scan), { "in.md" })
end)

test("symlink cycles terminate", function()
  local root = notes()
  write(root, "Areas/a.md", "## To Do\n- Task")
  assert(vim.uv.fs_symlink(root, root .. "/Areas/loop"))
  assert(vim.uv.fs_symlink(root .. "/Areas", root .. "/Areas/self"))
  eq(scanner.list_files(root, config.defaults().scan), { "Areas/a.md" })
end)

test("git metadata is skipped even when the exclude list omits it", function()
  local root = notes()
  write(root, ".git/notes.md", "## To Do\n- Git internals")
  write(root, "Projects/sub/.git/x.md", "## To Do\n- Nested git")
  write(root, "a.md", "## To Do\n- Real")
  eq(config.defaults().scan.exclude, { "Archives/**", ".git/**" })
  eq(scanner.list_files(root, config.defaults().scan), { "a.md" })
  eq(scanner.list_files(root, { include = { "**/*.md" }, exclude = {} }), { "a.md" })
end)

test("empty notes and prose-only notes yield no tasks", function()
  local root = notes()
  write(root, "empty.md", "")
  write(root, "prose.md", "# Meeting\n\nWe will send the plan.\nTODO: nothing here\n")
  local result = scanner.collect(root)
  eq(result.tasks, {})
  eq(result.files, 2)
end)

test("2 open To Do, 2 open Waiting On, and 1 completed count as 2 and 2", function()
  local root = notes()
  write(root, "Projects/a.md", "## To Do\n- One\n- [x] Finished\n## Waiting On\n- @Raju Estimate\n")
  write(root, "Areas/b.md", "## To Do\n- [ ] Two\n## Waiting On\n- [ ] Vendor reply\n")
  local result = scanner.collect(root)
  eq(#result.tasks, 5)
  eq(#dashboard.sorted(result.tasks, "todo"), 2)
  eq(#dashboard.sorted(result.tasks, "waiting"), 2)
end)

test("unreadable files are reported and do not stop the scan", function()
  local root = notes()
  write(root, "good.md", "## To Do\n- Good")
  local bad = write(root, "bad.md", "## To Do\n- Bad")
  vim.fn.setfperm(bad, "---------")
  local result = scanner.collect(root)
  vim.fn.setfperm(bad, "rw-r--r--")
  eq(texts(result), { "Good" })
  eq(#result.unreadable, 1)
  eq(result.unreadable[1].path, "bad.md")
end)

test("scanning changes no file", function()
  local root = notes()
  local path = write(root, "a.md", "## To Do\n- Task\r\n- [x] Done\n")
  local before = read(path)
  local mtime = vim.uv.fs_stat(path).mtime
  scanner.collect(root)
  eq(read(path), before)
  eq(vim.uv.fs_stat(path).mtime, mtime)
  eq(vim.fn.readdir(root), { "a.md" })
  -- The dashboard scan is equally read-only.
  reset(root)
  lattice.open()
  lattice.refresh()
  eq(read(path), before)
  eq(vim.uv.fs_stat(path).mtime, mtime)
  eq(vim.fn.readdir(root), { "a.md" })
end)

-- Inbox ----------------------------------------------------------------------

test("a missing inbox produces no list and no error", function()
  local root = notes()
  write(root, "a.md", "")
  eq(scanner.collect(root).inbox, nil)
end)

test("lists captures oldest first with titles from the first line", function()
  local root = notes()
  local new = write(root, "Inbox/new.md", "\n\n# Heard in hallway\nBody")
  local old = write(root, "Inbox/sub/old.md", "Plain first line\n")
  write(root, "Inbox/empty-capture.md", "")
  write(root, "Inbox/skip.txt", "ignored")
  vim.uv.fs_utime(new, 2000000000, 2000000000)
  vim.uv.fs_utime(old, 1000000000, 1000000000)
  vim.uv.fs_utime(root .. "/Inbox/empty-capture.md", 1500000000, 1500000000)
  local inbox = scanner.collect(root).inbox
  eq(vim.tbl_map(function(c)
    return c.title
  end, inbox), { "Plain first line", "empty-capture", "Heard in hallway" })
  eq(inbox[1].rel, "Inbox/sub/old.md")
end)

test("the inbox ignores scan.exclude, while excluding it hides its tasks", function()
  local root = notes()
  write(root, ".lattice.json", '{"scan": {"exclude": ["Inbox/**"]}}')
  write(root, "Inbox/cap.md", "## To Do\n- Captured")
  local result = scanner.collect(root)
  eq(result.tasks, {})
  eq(#result.inbox, 1)
end)

test("inbox tasks are scanned unless excluded", function()
  local root = notes()
  write(root, "Inbox/cap.md", "## To Do\n- Captured")
  local result = scanner.collect(root)
  eq(texts(result), { "Captured" })
  eq(#result.inbox, 1)
end)

test("honors a configured inbox path", function()
  local root = notes()
  write(root, ".lattice.json", '{"inbox": {"path": "Areas/Capture/"}}')
  write(root, "Areas/Capture/cap.md", "Capture")
  write(root, "Inbox/other.md", "Other")
  local inbox = scanner.collect(root).inbox
  eq(#inbox, 1)
  eq(inbox[1].rel, "Areas/Capture/cap.md")
end)

test("a symlinked inbox is not followed", function()
  local root, outside = notes(), notes()
  write(outside, "out.md", "Outside")
  assert(vim.uv.fs_symlink(outside, root .. "/Inbox"))
  eq(scanner.collect(root).inbox, nil)
end)

test("unreadable captures are reported and the rest still list", function()
  local root = notes()
  write(root, "Inbox/good.md", "Good")
  local bad = write(root, "Inbox/bad.md", "Bad")
  vim.fn.setfperm(bad, "---------")
  local result = scanner.collect(root)
  vim.fn.setfperm(bad, "rw-r--r--")
  eq(#result.inbox, 1)
  local paths = vim.tbl_map(function(item)
    return item.path
  end, result.unreadable)
  assert(vim.tbl_contains(paths, "Inbox/bad.md"))
end)

test("listing the inbox changes no file", function()
  local root = notes()
  local path = write(root, "Inbox/cap.md", "Capture\n")
  local mtime = vim.uv.fs_stat(path).mtime
  scanner.collect(root)
  eq(read(path), "Capture\n")
  eq(vim.uv.fs_stat(path).mtime, mtime)
end)

test("Enter opens a capture and a filed capture leaves after refresh", function()
  local root = notes()
  local path = write(root, "Inbox/cap.md", "Call the vendor\nMore")
  reset(root)
  lattice.open()
  assert(dashboard_text():find("INBOX%s+%(1%)"))
  press_enter_on("Call the vendor")
  eq(vim.api.nvim_buf_get_name(0), path)
  eq(vim.api.nvim_win_get_cursor(0)[1], 1)
  vim.cmd("bwipeout!") -- close the capture before moving it, as a user filing it would

  vim.fn.mkdir(root .. "/Projects", "p")
  assert(os.rename(path, root .. "/Projects/cap.md"))
  lattice.open()
  lattice.refresh()
  assert(dashboard_text():find("INBOX%s+%(0%)"))
end)
