-- Inbox configuration and sync (LATTICE_INBOX_SPEC A1.4–A1.6, A1.11).
-- Git remotes are local bare repositories standing in for GitHub.
local H = require("helpers")
local test, eq, write, notes = H.test, H.eq, H.write, H.notes
local config = H.config
local inbox_config = require("lattice.inbox_config")
local sync = require("lattice.inbox_sync")

local function validate(tbl)
  return inbox_config.validate(tbl)
end

local function repo_entry(extra)
  return vim.tbl_extend("force", { name = "Personal", url = "git@github.com:me/inbox.git", notes_root = "~/Notes" }, extra or {})
end

-- Configuration ----------------------------------------------------------------

test("inbox config: defaults and a minimal repository", function()
  local cfg = assert(validate({ repositories = { repo_entry() } }))
  eq(cfg.inbox, inbox_config.defaults())
  eq(cfg.inbox.default_folder, "Resources")
  local repo = cfg.repositories[1]
  eq({ repo.branch, repo.directory, repo.enabled }, { "main", "", true })
  eq(assert(validate({})).repositories, {})
end)

test("inbox config: settings and repository fields are read", function()
  local cfg = assert(validate({
    inbox = { auto_fetch = false, sort_order = "oldest_first", notification_duration_ms = 1500, default_folder = "Areas/Misc/" },
    repositories = {
      repo_entry({ branch = "captures/main", directory = "captures/", enabled = false, aliases = { ["Projects/Etna"] = { " lava dome " } } }),
    },
  }))
  eq(cfg.inbox, { auto_fetch = false, sort_order = "oldest_first", notification_duration_ms = 1500, default_folder = "Areas/Misc" })
  local repo = cfg.repositories[1]
  eq({ repo.branch, repo.directory, repo.enabled }, { "captures/main", "captures", false })
  eq(repo.aliases, { ["Projects/Etna"] = { "lava dome" } })
end)

test("inbox config: invalid files give errors that name the problem", function()
  local cases = {
    { "[1]", "top level must be a JSON object" },
    { { extra = 1 }, 'unknown key "extra"' },
    { { inbox = { group_by = "repository" } }, 'inbox: unknown key "group_by"' },
    { { inbox = { auto_fetch = "yes" } }, "auto_fetch must be true or false" },
    { { inbox = { sort_order = "random" } }, "sort_order" },
    { { inbox = { notification_duration_ms = 0 } }, "positive whole number" },
    { { inbox = { default_folder = "../Elsewhere" } }, "default_folder" },
    { { inbox = { default_folder = "/abs" } }, "default_folder" },
    { { repositories = { repo_entry({ name = "" }) } }, "name is required" },
    { { repositories = { { name = "Personal", notes_root = "~/Notes" } } }, "url is required" },
    { { repositories = { repo_entry({ notes_root = 5 }) } }, "notes_root is required" },
    { { repositories = { repo_entry(), repo_entry() } }, 'two repositories are named "Personal"' },
    { { repositories = { repo_entry({ url = "https://me:ghp_secret@github.com/me/inbox" }) } }, "must not contain credentials" },
    { { repositories = { repo_entry({ url = "https://ghp_secret@github.com/me/inbox" }) } }, "must not contain credentials" },
    { { repositories = { repo_entry({ url = "--upload-pack=evil" }) } }, "Git remote URL" },
    { { repositories = { repo_entry({ branch = "-x" }) } }, "not a valid branch" },
    { { repositories = { repo_entry({ branch = "a..b" }) } }, "not a valid branch" },
    { { repositories = { repo_entry({ directory = "a/../b" }) } }, "directory" },
    { { repositories = { repo_entry({ directory = "/captures" }) } }, "directory" },
    { { repositories = { repo_entry({ enabled = "no" }) } }, "enabled must be true or false" },
    { { repositories = { repo_entry({ token = "x" }) } }, 'repository "Personal": unknown key "token"' },
    { { repositories = { repo_entry({ aliases = { ["../x"] = { "a" } } }) } }, "aliases folder" },
    { { repositories = { repo_entry({ aliases = { Etna = "lava" } }) } }, "list of keywords" },
    { { repositories = { repo_entry({ aliases = { Etna = { "" } } }) } }, "non-empty strings" },
  }
  for _, case in ipairs(cases) do
    local raw = type(case[1]) == "string" and vim.json.decode(case[1]) or case[1]
    local cfg, err = validate(raw)
    assert(cfg == nil and err, "expected an error for " .. vim.inspect(case[1]))
    assert(err:find(case[2], 1, true), ("error %q should mention %q"):format(err, case[2]))
  end
end)

test("inbox config: a missing file means off; invalid JSON is an error; credentials are redacted", function()
  local dir = notes()
  eq({ inbox_config.load(dir .. "/inbox.json") }, {})
  write(dir, "bad.json", "{ nope")
  local cfg, err = inbox_config.load(dir .. "/bad.json")
  assert(cfg == nil and err:find("Invalid JSON", 1, true))
  write(dir, "creds.json", vim.json.encode({ repositories = { repo_entry({ url = "https://me:ghp_secret@github.com/x" }) } }))
  cfg, err = inbox_config.load(dir .. "/creds.json")
  assert(cfg == nil and err:find("credentials", 1, true))
  assert(not err:find("ghp_secret", 1, true), err)
  eq(inbox_config.redact("fatal: https://me:tok@github.com/x failed"), "fatal: https://***@github.com/x failed")
end)

test("inbox config: repositories are active only for the current notes root", function()
  local personal, work = notes(), notes()
  local cfg = assert(validate({
    repositories = {
      repo_entry({ name = "Personal", notes_root = personal .. "/" }),
      repo_entry({ name = "Work", notes_root = work }),
      repo_entry({ name = "Old", notes_root = personal, enabled = false }),
      repo_entry({ name = "Gone", notes_root = personal .. "/missing" }),
    },
  }))
  inbox_config.classify(cfg, personal)
  local roles = vim.tbl_map(function(r)
    return r.role
  end, cfg.repositories)
  eq(roles, { "active", "other_root", "disabled", "other_root" })
  eq(cfg.repositories[4].root_missing, true)
  eq(cfg.repositories[2].root_missing, false)
end)

test("setup: inbox_sync.config sets the path; the inbox refresh key defaults to <leader>lR", function()
  local saved = vim.deepcopy(config.options)
  config.setup({ root = "/tmp", inbox_sync = { config = "/tmp/x/inbox.json" } })
  eq(sync.config_path(), "/tmp/x/inbox.json")
  eq(config.options.keymaps.inbox_refresh, "<leader>lR")
  config.setup({ root = "/tmp" })
  eq(sync.config_path(), inbox_config.default_path())
  config.options = saved
end)

-- Sync -------------------------------------------------------------------------

local IH = require("inbox_helpers")
local run, remote, capture, setup_inbox, fetch, files = IH.run, IH.remote, IH.capture, IH.setup_inbox, IH.fetch, IH.files

test("sync: first fetch clones, lists captures in the directory only, and counts all as new", function()
  local root, r = notes(), remote()
  r.push({
    ["captures/2026-11-05-074500-aaaaaaaa.md"] = capture("aaaaaaaa"),
    ["captures/2026-11-04-182000-bbbbbbbb.md"] = capture("bbbbbbbb"),
    ["README.md"] = "not a capture",
  })
  setup_inbox(root, { { name = "Personal", url = r.url, directory = "captures", notes_root = root } })
  assert(fetch("startup"))
  eq(files("Personal"), { "2026-11-04-182000-bbbbbbbb.md", "2026-11-05-074500-aaaaaaaa.md" })
  local entry = sync.state.repos.Personal
  eq({ entry.status, entry.new }, { "ok", 2 })
  local first = sync.captures().Personal[1]
  eq({ first.id, first.created, first.source, first.destination, first.body_line }, {
    "bbbbbbbb",
    "2026-11-05T07:45:00-05:00",
    "drafts",
    "personal",
    7,
  })
  eq(H.last_notify().message, "Lattice Inbox: 2 new captures")
  eq(H.last_notify().level, vim.log.levels.INFO)
  -- Sparse checkout: files outside the capture directory are not in the cache.
  eq(vim.uv.fs_stat(sync.cache_dir(entry.repo) .. "/README.md"), nil)
end)

test("sync: a later fetch counts only new captures and drops removed ones", function()
  local root, r = notes(), remote()
  r.push({ ["c/2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa"), ["c/2026-11-02-000000-bbbbbbbb.md"] = capture("bbbbbbbb") })
  setup_inbox(root, { { name = "Personal", url = r.url, directory = "c", notes_root = root } })
  fetch("startup")
  r.push({ ["c/2026-11-03-000000-cccccccc.md"] = capture("cccccccc") }, { "c/2026-11-01-000000-aaaaaaaa.md" })
  fetch("startup")
  eq(sync.state.repos.Personal.new, 1)
  eq(files("Personal"), { "2026-11-02-000000-bbbbbbbb.md", "2026-11-03-000000-cccccccc.md" })
  eq(H.last_notify().message, "Lattice Inbox: 1 new capture")
  -- Nothing changed: zero new, and the startup notification still appears.
  fetch("startup")
  eq(H.last_notify().message, "Lattice Inbox: 0 new captures")
end)

test("sync: a new session counts captures new since the cache was last updated", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  fetch("startup")
  local cache = sync.cache_root
  -- Simulate restarting Neovim: session state is gone, the cache remains.
  sync.state = sync.new_state()
  sync.cache_root = cache
  r.push({ ["2026-11-02-000000-bbbbbbbb.md"] = capture("bbbbbbbb") })
  fetch("startup")
  eq(sync.state.repos.Personal.new, 1)
end)

test("sync: manual refresh is silent on success", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  vim.notify("sentinel")
  assert(fetch("manual"))
  eq(H.last_notify().message, "sentinel")
  eq(#files("Personal"), 1)
end)

test("sync: one failing repository does not stop the others, and is reported", function()
  local root, good = notes(), remote()
  good.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, {
    { name = "Broken", url = root .. "/no-such-repo.git", notes_root = root },
    { name = "Personal", url = good.url, notes_root = root },
  })
  fetch("startup")
  eq(sync.state.repos.Personal.status, "ok")
  eq(sync.state.repos.Broken.status, "error")
  assert(sync.state.repos.Broken.error:find("repository not found", 1, true), sync.state.repos.Broken.error)
  eq(H.last_notify().message, "Lattice Inbox: 1 new capture (1 repository failed — :LatticeInboxStatus)")
  eq(H.last_notify().level, vim.log.levels.WARN)
  -- A manual refresh reports the failure.
  fetch("manual")
  assert(H.last_notify().message:find("Broken: repository not found", 1, true), H.last_notify().message)
  local status = table.concat(sync.status_lines(), "\n")
  assert(status:find("Broken  ERROR repository not found", 1, true), status)
  assert(status:find("Personal  ok; 1 capture, last fetched", 1, true), status)
end)

test("sync: a failed fetch keeps the captures already fetched", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  fetch("startup")
  vim.fn.delete(r.url, "rf")
  fetch("manual")
  eq(sync.state.repos.Personal.status, "error")
  eq(files("Personal"), { "2026-11-01-000000-aaaaaaaa.md" })
end)

test("sync: a missing branch is named in the error", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, branch = "inbox", notes_root = root } })
  fetch("startup")
  assert(sync.state.repos.Personal.error:find('branch "inbox" not found', 1, true), sync.state.repos.Personal.error)
end)

test("sync: a damaged cache (stale lock from an interrupted fetch) is rebuilt", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  fetch("startup")
  local dir = sync.cache_dir(sync.state.repos.Personal.repo)
  write(dir, ".git/index.lock", "")
  r.push({ ["2026-11-02-000000-bbbbbbbb.md"] = capture("bbbbbbbb") })
  fetch("manual")
  eq(sync.state.repos.Personal.status, "ok")
  eq(#files("Personal"), 2)
end)

test("sync: symlinks and unsafe names are skipped; captures without an id are flagged", function()
  local root, r = notes(), remote()
  r.push({
    ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa"),
    ["bad name.md"] = capture("cccccccc"),
    ["noid.md"] = "just text\n",
    ["notes.txt"] = "ignored",
  })
  vim.uv.fs_symlink("/etc/hosts", r.work .. "/link.md")
  r.push()
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  fetch("startup")
  eq(files("Personal"), { "2026-11-01-000000-aaaaaaaa.md", "noid.md" })
  eq(sync.captures().Personal[2].error, "no id in its front matter")
  eq(sync.state.repos.Personal.skipped, {
    { file = "bad name.md", reason = "unsafe file name" },
    { file = "link.md", reason = "symbolic link" },
  })
  local status = table.concat(sync.status_lines(), "\n")
  assert(status:find("skipped link.md: symbolic link", 1, true), status)
  assert(status:find("noid.md: no id in its front matter", 1, true), status)
end)

test("sync: only repositories for the current root are fetched", function()
  local root, other, r = notes(), notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, {
    { name = "Personal", url = r.url, notes_root = root },
    { name = "Work", url = r.url, notes_root = other },
    { name = "Off", url = r.url, notes_root = root, enabled = false },
  })
  fetch("startup")
  eq(vim.tbl_keys(sync.captures()), { "Personal" })
  eq(sync.state.repos.Work.status, nil)
  local status = table.concat(sync.status_lines(), "\n")
  assert(status:find("Work  other notes root", 1, true), status)
  assert(status:find("Off  disabled", 1, true), status)
end)

test("sync: no config means no fetch; auto_fetch=false skips only startup", function()
  local root = notes()
  config.options.root = root
  config.options.inbox_sync = { config = root .. "/missing.json" }
  sync.state = sync.new_state()
  vim.notify("sentinel")
  eq(fetch("startup"), false)
  eq(H.last_notify().message, "sentinel")
  eq(sync.status_lines()[1]:find("Lattice Inbox is off", 1, true), 1)
  fetch("manual")
  assert(H.last_notify().message:find("no configuration", 1, true))

  local r = remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } }, { auto_fetch = false })
  eq(fetch("startup"), false)
  assert(fetch("manual"))
  eq(#files("Personal"), 1)
end)

test("sync: an invalid config is reported and nothing is fetched", function()
  local root = notes()
  write(root, "inbox.json", '{"repositories": [{"name": "x"}]}')
  config.options.root = root
  config.options.inbox_sync = { config = root .. "/inbox.json" }
  sync.state = sync.new_state()
  eq(fetch("startup"), false)
  eq(H.last_notify().level, vim.log.levels.ERROR)
  assert(H.last_notify().message:find("url is required", 1, true))
  assert(sync.status_lines()[1]:find("url is required", 1, true))
end)

test("sync: git errors are explained without leaking credentials", function()
  local repo = { branch = "main" }
  local function explain(stderr, code)
    return sync.explain({ code = code or 128, stderr = stderr }, repo)
  end
  assert(explain("fatal: could not read Username for 'https://github.com': terminal prompts disabled"):find("^authentication failed"))
  assert(explain("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository."):find("^authentication failed"))
  assert(explain("Host key verification failed."):find("^SSH host key"))
  assert(explain("fatal: unable to access 'https://github.com/x/': Could not resolve host: github.com"):find("^network error"))
  assert(explain("", 124):find("^timed out after 30 s"))
  local leaked = explain("fatal: unable to access 'https://me:ghp_tok@github.com/x/': 403")
  assert(not leaked:find("ghp_tok", 1, true), leaked)
end)

test("health: the inbox section reports the config state", function()
  local root = notes()
  config.options.inbox_sync = { config = root .. "/missing.json" }
  eq(sync.health_items()[1].level, "info")
  write(root, "inbox.json", vim.json.encode({ repositories = { repo_entry() } }))
  config.options.inbox_sync = { config = root .. "/inbox.json" }
  local items = sync.health_items()
  eq(items[1].level, "ok")
  assert(items[1].message:find("1 repository", 1, true))
end)

test("startup: fetches once when a UI is attached, never headless", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  local list_uis, fetch_fn = vim.api.nvim_list_uis, sync.fetch
  local calls = {}
  sync.fetch = function(mode)
    calls[#calls + 1] = mode
  end
  -- Headless: on_startup waits for a UIEnter that never comes.
  sync.on_startup()
  vim.wait(50)
  eq(calls, {})
  -- A UI attaches.
  vim.api.nvim_list_uis = function()
    return { {} }
  end
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(200, function()
    return #calls > 0
  end)
  eq(calls, { "startup" })
  -- A second setup() does not fetch again.
  sync.on_startup()
  vim.wait(50)
  eq(calls, { "startup" })
  vim.api.nvim_list_uis, sync.fetch = list_uis, fetch_fn
end)

-- Removal (A1.6, §12) and recovery (A1.12) -------------------------------------------

local function listed(name, file)
  for _, c in ipairs(sync.captures()[name] or {}) do
    if c.file == file then
      return c
    end
  end
end

local function remove_and_wait(c, kind, note)
  sync.remove(c, kind, note)
  IH.wait_removals()
end

test("remove: git rm, commit and push under the user's identity; the cache follows", function()
  local root, r = notes(), remote()
  r.push({
    ["captures/2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa"),
    ["captures/2026-11-02-000000-bbbbbbbb.md"] = capture("bbbbbbbb"),
    ["README.md"] = "kept",
  })
  setup_inbox(root, { { name = "Personal", url = r.url, directory = "captures", notes_root = root } })
  fetch("manual")
  remove_and_wait(listed("Personal", "2026-11-01-000000-aaaaaaaa.md"), "filed", root .. "/Note.md")
  eq(r.files(), { "README.md", "captures/2026-11-02-000000-bbbbbbbb.md" })
  eq(r.last_message(), "Lattice: remove processed capture 2026-11-01-000000-aaaaaaaa.md")
  eq(vim.trim(run({ "git", "log", "-1", "--format=%an <%ae>", "main" }, r.url).stdout), "Lattice Test <test@example.com>")
  eq(files("Personal"), { "2026-11-02-000000-bbbbbbbb.md" })
  eq(sync.state.removals, {})
  -- A later fetch counts nothing new and does not bring it back.
  fetch("startup")
  eq(H.last_notify().message, "Lattice Inbox: 0 new captures")
  eq(files("Personal"), { "2026-11-02-000000-bbbbbbbb.md" })
end)

test("remove: a push rejected as non-fast-forward is retried after a fetch", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  fetch("manual")
  -- Drafts uploads another capture meanwhile.
  r.push({ ["2026-11-02-000000-bbbbbbbb.md"] = capture("bbbbbbbb") })
  remove_and_wait(listed("Personal", "2026-11-01-000000-aaaaaaaa.md"), "filed")
  eq(r.files(), { "2026-11-02-000000-bbbbbbbb.md" })
  eq(files("Personal"), { "2026-11-02-000000-bbbbbbbb.md" })
  eq(sync.state.removals, {})
  -- The capture the retry fetched is still announced by the next fetch.
  fetch("startup")
  eq(H.last_notify().message, "Lattice Inbox: 1 new capture")
  fetch("startup")
  eq(H.last_notify().message, "Lattice Inbox: 0 new captures")
end)

test("remove: a capture already deleted remotely counts as removed", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa"), ["2026-11-02-000000-bbbbbbbb.md"] = capture("bbbbbbbb") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  fetch("manual")
  r.push(nil, { "2026-11-01-000000-aaaaaaaa.md" })
  vim.notify("sentinel")
  remove_and_wait(listed("Personal", "2026-11-01-000000-aaaaaaaa.md"), "filed")
  eq(sync.state.removals, {})
  eq(H.last_notify().message, "sentinel")
  eq(r.files(), { "2026-11-02-000000-bbbbbbbb.md" })
end)

test("remove: a rejected push leaves the capture filed, removal pending; the next fetch retries", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  fetch("manual")
  r.protect(true)
  remove_and_wait(listed("Personal", "2026-11-01-000000-aaaaaaaa.md"), "filed", root .. "/Note.md")
  local record = sync.state.removals["Personal\0aaaaaaaa"]
  eq({ record.status, record.kind, record.note }, { "pending", "filed", root .. "/Note.md" })
  assert(record.error:find("protected branch", 1, true), record.error)
  eq(H.last_notify().level, vim.log.levels.WARN)
  assert(H.last_notify().message:find("is filed, but removing it from Personal failed", 1, true), H.last_notify().message)
  -- The capture is still on the remote and in the cache, and the local
  -- commit was undone.
  eq(r.files(), { "2026-11-01-000000-aaaaaaaa.md" })
  eq(files("Personal"), { "2026-11-01-000000-aaaaaaaa.md" })
  local status = table.concat(sync.status_lines(), "\n")
  assert(status:find("removal pending 2026-11-01-000000-aaaaaaaa.md: ", 1, true), status)
  -- Still refused: still pending after a fetch.
  fetch("manual")
  IH.wait_removals()
  eq(sync.state.removals["Personal\0aaaaaaaa"].status, "pending")
  -- Allowed again: the next fetch removes it.
  r.protect(false)
  fetch("manual")
  IH.wait_removals()
  eq(sync.state.removals, {})
  eq(r.files(), {})
end)

test("remove: a missing Git identity is explained", function()
  local message = sync.explain({ code = 128, stderr = "Author identity unknown\n\n*** Please tell me who you are.\n" }, { branch = "main" })
  assert(message:find("set user.name and user.email", 1, true), message)
end)

test("recovery: a capture whose ID is in a saved note is not offered again and is removed", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa"), ["2026-11-02-000000-bbbbbbbb.md"] = capture("bbbbbbbb") })
  -- A note filed in an earlier session whose removal never happened (a crash).
  write(root, "Projects/Etna/Dome.md", "# Dome\n:PROPERTIES:\n:CAPTURE_ID: aaaaaaaa\n:CAPTURE_REPO: Personal\n:END:\n\ntext\n")
  -- Same ID, another repository: not a match (it is a different capture).
  write(root, "Resources/Other.md", "# Other\n:PROPERTIES:\n:CAPTURE_ID: bbbbbbbb\n:CAPTURE_REPO: Work\n:END:\n")
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  H.reset(root)
  fetch("startup")
  -- Only the unfiled capture counts as new.
  eq(H.last_notify().message, "Lattice Inbox: 1 new capture")
  local record = sync.state.removals["Personal\0aaaaaaaa"]
  eq({ record.kind, record.note }, { "filed", root .. "/Projects/Etna/Dome.md" })
  IH.wait_removals()
  eq(r.files(), { "2026-11-02-000000-bbbbbbbb.md" })
  eq(sync.state.removals, {})
end)

test("recovery: an unsaved buffer or a note in an excluded folder does not count", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  write(root, "Ideas.md", "# Ideas\n")
  write(root, "Archives/Old.md", "# Old\n:PROPERTIES:\n:CAPTURE_ID: aaaaaaaa\n:CAPTURE_REPO: Personal\n:END:\n")
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  H.reset(root)
  vim.cmd.edit(vim.fn.fnameescape(root .. "/Ideas.md"))
  vim.api.nvim_buf_set_lines(0, 1, 1, false, { ":PROPERTIES:", ":CAPTURE_ID: aaaaaaaa", ":CAPTURE_REPO: Personal", ":END:" })
  fetch("manual")
  eq(sync.state.removals, {})
  eq(r.files(), { "2026-11-01-000000-aaaaaaaa.md" })
  -- Once the user saves that note, the next fetch finds it: the capture
  -- was not marked as looked up while only the buffer had the ID.
  vim.cmd("silent write")
  fetch("manual")
  IH.wait_removals()
  eq(r.files(), {})
  vim.cmd("bwipeout!")
end)

test("scan: headings record their :CAPTURE_ID: and :CAPTURE_REPO:", function()
  local parsed = H.parse(
    "# Plain\n:PROPERTIES:\n:CAPTURE_ID: abc\n:CAPTURE_REPO: Work\n:END:\n## TODO Task\n:PROPERTIES:\n:capture_id: def\n:END:\n# None\n"
  )
  eq(vim.tbl_map(function(h)
    return { h.capture_id or false, h.capture_repo or false }
  end, parsed.headings), { { "abc", "Work" }, { "def", false }, { false, false } })
end)

test("remove: git never acts on a repository above a damaged cache", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  fetch("manual")
  local c = listed("Personal", "2026-11-01-000000-aaaaaaaa.md")
  -- The cache lost its .git, and the folder above it is someone's repository
  -- (a home directory kept in Git) with an origin/main and unsaved work.
  local dir = sync.cache_dir(sync.state.repos.Personal.repo)
  vim.fn.delete(dir .. "/.git", "rf")
  local outer = vim.fs.dirname(sync.cache_root)
  run({ "git", "init", "-q", "-b", "main" }, outer)
  write(outer, "dotfile", "committed\n")
  run({ "git", "add", "dotfile" }, outer)
  run({ "git", "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "x" }, outer)
  run({ "git", "update-ref", "refs/remotes/origin/main", "HEAD" }, outer)
  write(outer, "dotfile", "unsaved work\n")
  remove_and_wait(c, "filed")
  eq(H.read(outer .. "/dotfile"), "unsaved work\n")
  eq(sync.state.removals["Personal\0aaaaaaaa"].status, "pending")
  -- Ordinary fetches don't escape the cache either: it is rebuilt.
  fetch("manual")
  IH.wait_removals()
  eq(H.read(outer .. "/dotfile"), "unsaved work\n")
  eq(r.files(), {})
end)

test("remove: works when the user's Git config signs commits", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  fetch("manual")
  local gitconfig = notes() .. "/gitconfig"
  write(vim.fs.dirname(gitconfig), "gitconfig", "[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = false\n")
  vim.env.GIT_CONFIG_GLOBAL = gitconfig
  local ok, err = pcall(remove_and_wait, listed("Personal", "2026-11-01-000000-aaaaaaaa.md"), "filed")
  vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
  assert(ok, err)
  eq(sync.state.removals, {})
  eq(r.files(), {})
end)

test("remove: a Lua error inside an operation releases the repository", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  local list = sync.list_captures
  local calls = 0
  -- On a first fetch, the only call runs in a git callback.
  sync.list_captures = function(...)
    calls = calls + 1
    if calls == 1 then
      error("boom")
    end
    return list(...)
  end
  local ok, err = pcall(fetch, "manual")
  sync.list_captures = list
  assert(ok, err)
  eq(sync.state.running, false)
  eq(sync.state.repos.Personal.status, "error")
  assert(sync.state.repos.Personal.error:find("internal error", 1, true), sync.state.repos.Personal.error)
  -- The repository is not stuck: the next fetch and a removal work.
  fetch("manual")
  eq(sync.state.repos.Personal.status, "ok")
  remove_and_wait(listed("Personal", "2026-11-01-000000-aaaaaaaa.md"), "filed")
  eq(r.files(), {})
end)

test("remove: a lasting failure warns once per session; inactive repositories' removals are dropped", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa"), ["2026-11-02-000000-bbbbbbbb.md"] = capture("bbbbbbbb") })
  for _, id in ipairs({ "aaaaaaaa", "bbbbbbbb" }) do
    write(root, id .. ".md", ("# Note\n:PROPERTIES:\n:CAPTURE_ID: %s\n:CAPTURE_REPO: Personal\n:END:\n"):format(id))
  end
  r.protect(true)
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  H.reset(root)
  local seen = {}
  local notify = vim.notify
  vim.notify = function(message, level)
    if level == vim.log.levels.WARN then
      seen[#seen + 1] = message
    end
    notify(message, level)
  end
  fetch("manual")
  IH.wait_removals()
  fetch("manual")
  IH.wait_removals()
  vim.notify = notify
  eq(#seen, 1)
  assert(seen[1]:find("removing filed captures from Personal failed", 1, true), seen[1])
  eq(#sync.removals_for("Personal"), 2)
  -- The repository is disabled: its pending removals are dropped.
  IH.setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root, enabled = false } })
  sync.state.removals = { ["Personal\0aaaaaaaa"] = { repo = "Personal", id = "aaaaaaaa", file = "x", kind = "filed", status = "pending" } }
  sync.fetch("manual")
  sync.retry_removals()
  eq(sync.state.removals, {})
end)

test("recovery: the notes are scanned only when a fetch lists a capture not looked up yet", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  H.reset(root)
  local scanner = H.scanner
  local collect, scans = scanner.collect, 0
  scanner.collect = function(...)
    scans = scans + 1
    return collect(...)
  end
  fetch("manual")
  fetch("manual")
  eq(scans, 1)
  r.push({ ["2026-11-02-000000-bbbbbbbb.md"] = capture("bbbbbbbb") })
  fetch("manual")
  fetch("manual")
  scanner.collect = collect
  eq(scans, 2)
end)

test("fetch: an error while finishing is reported without blaming a repository or skipping the rest", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  local scanner = H.scanner
  local collect = scanner.collect
  scanner.collect = function()
    error("scan exploded")
  end
  local errors = {}
  local notify = vim.notify
  vim.notify = function(message, level)
    if level == vim.log.levels.ERROR then
      errors[#errors + 1] = message
    end
    notify(message, level)
  end
  local ok, err = pcall(fetch, "startup")
  scanner.collect, vim.notify = collect, notify
  assert(ok, err)
  eq(sync.state.running, false)
  eq(sync.state.repos.Personal.status, "ok")
  eq(#errors, 1)
  assert(errors[1]:find("recovery failed", 1, true), errors[1])
  -- The summary still appeared.
  eq(H.last_notify().message, "Lattice Inbox: 1 new capture")
end)

test("remove: a damaged cache index is a failure, not an already-removed capture", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  fetch("manual")
  local c = listed("Personal", "2026-11-01-000000-aaaaaaaa.md")
  write(sync.cache_dir(sync.state.repos.Personal.repo), ".git/index", "garbage")
  remove_and_wait(c, "dismissed")
  eq(sync.state.removals, {})
  eq(H.last_notify().level, vim.log.levels.WARN)
  assert(H.last_notify().message:find("could not dismiss", 1, true), H.last_notify().message)
  eq(r.files(), { "2026-11-01-000000-aaaaaaaa.md" })
end)

-- Third review: cross-process lock and robustness --------------------------------------

local function other_process(seconds)
  local proc = vim.system({ "sleep", tostring(seconds) })
  return proc
end

test("lock: another live Neovim's lock makes a fetch wait, then give up; a dead one's is broken", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  local repo = inbox_config.load(sync.config_path()).repositories[1]
  repo.notes_root = root
  local lock = sync.cache_dir(vim.tbl_extend("force", repo, { branch = "main", directory = "" })) .. ".lock"
  -- Held by a live process.
  local live = other_process(30)
  vim.fn.mkdir(lock, "p")
  write(lock, "pid", tostring(live.pid))
  local wait, retry = sync.lock_wait_ms, sync.lock_retry_ms
  sync.lock_wait_ms, sync.lock_retry_ms = 300, 50
  fetch("manual")
  eq(sync.state.repos.Personal.status, "error")
  assert(sync.state.repos.Personal.error:find("another Neovim session", 1, true), sync.state.repos.Personal.error)
  eq(vim.uv.fs_stat(lock) ~= nil, true)
  live:kill(9)
  live:wait()
  -- Its process is gone: the lock is stale and is broken.
  fetch("manual")
  sync.lock_wait_ms, sync.lock_retry_ms = wait, retry
  eq(sync.state.repos.Personal.status, "ok")
  eq(files("Personal"), { "2026-11-01-000000-aaaaaaaa.md" })
  -- Released after the operation.
  eq(vim.uv.fs_stat(lock), nil)
end)

test("lock: after a Lua error, the next operation waits for the running git process", function()
  local root = notes()
  setup_inbox(root, {})
  local internal = sync._internal
  local dir = notes() .. "/cache-x"
  vim.fn.mkdir(dir, "p")
  local marker = dir .. "/git-finished"
  local repo = { name = "x", url = "/nowhere", branch = "main", directory = "" }
  local callback_ran, marker_seen = false, nil
  local restore_notify = vim.notify
  vim.notify = function() end
  internal.with_lock(dir, function(_, op)
    -- A git process that takes a moment and leaves a marker when it ends.
    internal.git(internal.bind(repo, op), { "-c", "alias.slow=!sleep 0.4 && touch git-finished", "slow" }, dir, function()
      callback_ran = true
    end)
    error("boom after starting git")
  end)
  internal.with_lock(dir, function(release)
    marker_seen = vim.uv.fs_stat(marker) ~= nil
    release()
  end)
  assert(vim.wait(5000, function()
    return marker_seen ~= nil
  end, 10))
  vim.notify = restore_notify
  -- The next operation started only after the process had finished, and
  -- the failed operation's callback was skipped.
  eq(marker_seen, true)
  eq(callback_ran, false)
  eq(vim.uv.fs_stat(dir .. ".lock"), nil)
end)

test("remove: a capture that returns after removal is looked up again", function()
  local root, r = notes(), remote()
  local text = capture("aaaaaaaa")
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = text })
  write(root, "Dome.md", "# Dome\n:PROPERTIES:\n:CAPTURE_ID: aaaaaaaa\n:CAPTURE_REPO: Personal\n:END:\n")
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  H.reset(root)
  fetch("manual")
  IH.wait_removals()
  eq(r.files(), {})
  -- Drafts uploads it again.
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = text })
  fetch("manual")
  IH.wait_removals()
  eq(r.files(), {})
end)

test("remove: if undoing a refused removal fails, the cache is discarded and the removal stays pending", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa"), ["2026-11-02-000000-bbbbbbbb.md"] = capture("bbbbbbbb") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  fetch("manual")
  local dir = sync.cache_dir(sync.state.repos.Personal.repo)
  -- The remote refuses the push and, while doing so, breaks the cache's
  -- remote-tracking ref so the undo (reset --hard) fails.
  write(r.url, "hooks/pre-receive", ("#!/bin/sh\nrm -f '%s/.git/refs/remotes/origin/main' '%s/.git/packed-refs'\necho protected >&2\nexit 1\n"):format(dir, dir))
  vim.uv.fs_chmod(r.url .. "/hooks/pre-receive", tonumber("755", 8))
  remove_and_wait(listed("Personal", "2026-11-01-000000-aaaaaaaa.md"), "filed", root .. "/Note.md")
  eq(vim.uv.fs_stat(dir), nil)
  eq(sync.state.removals["Personal\0aaaaaaaa"].status, "pending")
  -- The inbox still lists what the cache held.
  eq(files("Personal"), { "2026-11-01-000000-aaaaaaaa.md", "2026-11-02-000000-bbbbbbbb.md" })
  -- The next fetch clones afresh, announces nothing as new, and retries.
  r.protect(false)
  fetch("startup")
  eq(H.last_notify().message, "Lattice Inbox: 0 new captures")
  IH.wait_removals()
  eq(sync.state.removals, {})
  eq(r.files(), { "2026-11-02-000000-bbbbbbbb.md" })
end)

test("remove: an error in a view listener does not turn a removal into a failure", function()
  local root, r = notes(), remote()
  r.push({ ["2026-11-01-000000-aaaaaaaa.md"] = capture("aaaaaaaa") })
  setup_inbox(root, { { name = "Personal", url = r.url, notes_root = root } })
  fetch("manual")
  local messages = {}
  local notify = vim.notify
  vim.notify = function(message, level)
    messages[#messages + 1] = message
    notify(message, level)
  end
  table.insert(sync.listeners, function()
    error("view broke")
  end)
  local ok, err = pcall(remove_and_wait, listed("Personal", "2026-11-01-000000-aaaaaaaa.md"), "dismissed")
  table.remove(sync.listeners)
  vim.notify = notify
  assert(ok, err)
  eq(r.files(), {})
  local text = table.concat(messages, "\n")
  assert(text:find("dismissed 2026-11-01-000000-aaaaaaaa.md", 1, true), text)
  assert(not text:find("could not dismiss", 1, true), text)
  assert(text:find("could not update the view", 1, true), text)
end)

-- Fourth review ---------------------------------------------------------------------

test("lock: breaking a stale lock is itself locked; a lock not refreshed for 10 minutes is stale", function()
  local take = sync._internal.take_file_lock
  local dir = notes() .. "/cache-y"
  local lock, breaker = dir .. ".lock", dir .. ".lock.break"
  local function stale_lock(pid)
    vim.fn.mkdir(lock, "p")
    write(lock, "pid", tostring(pid))
  end
  local function take_within(tries)
    for _ = 1, tries do
      if take(dir) then
        return true
      end
    end
    return false
  end
  local dead = vim.system({ "true" })
  dead:wait()
  -- Another session is breaking it right now: leave it alone.
  stale_lock(dead.pid)
  vim.fn.mkdir(breaker, "p")
  eq(take_within(3), false)
  eq(vim.uv.fs_stat(lock) ~= nil, true)
  -- That session crashed mid-break: its old breaker is cleared, then the
  -- stale lock is broken and taken.
  local past = os.time() - 60
  vim.uv.fs_utime(breaker, past, past)
  eq(take_within(3), true)
  eq(vim.uv.fs_stat(breaker), nil)
  eq(H.read(lock .. "/pid"), tostring(vim.fn.getpid()))
  vim.fn.delete(lock, "rf")
  -- A live PID, but not refreshed for over 10 minutes (the PID was reused).
  local live = vim.system({ "sleep", "30" })
  stale_lock(live.pid)
  eq(take_within(3), false)
  past = os.time() - sync.lock_stale_s - 1
  vim.uv.fs_utime(lock, past, past)
  eq(take_within(3), true)
  live:kill(9)
  vim.fn.delete(lock, "rf")
end)

test("explain: a push still rejected as non-fast-forward is not called a refusal", function()
  local message = sync.explain({
    code = 1,
    stderr = " ! [rejected]        HEAD -> main (fetch first)\nerror: failed to push some refs to 'x'\n",
  }, { branch = "main" })
  assert(message:find("the branch kept changing during 3 attempts; the next fetch retries", 1, true), message)
  message = sync.explain({ code = 1, stderr = "remote: protected branch\n ! [remote rejected] HEAD -> main (pre-receive hook declined)\n" }, { branch = "main" })
  assert(message:find("the repository refused the push (protected branch)", 1, true), message)
end)
