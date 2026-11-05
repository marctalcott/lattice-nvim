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

local function run(cmd, cwd)
  local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, table.concat(cmd, " ") .. ": " .. (result.stderr or ""))
  return result
end

local IDENTITY = { "git", "-c", "user.name=Lattice Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false" }

-- A bare "GitHub" repository and a working clone used to add captures.
local function remote()
  local base = notes()
  run({ "git", "init", "-q", "--bare", "-b", "main", base .. "/remote.git" })
  run({ "git", "init", "-q", "-b", "main", base .. "/work" })
  run({ "git", "remote", "add", "origin", base .. "/remote.git" }, base .. "/work")
  local r = { url = base .. "/remote.git", work = base .. "/work" }
  function r.push(files, remove)
    for rel, content in pairs(files or {}) do
      write(r.work, rel, content)
    end
    for _, rel in ipairs(remove or {}) do
      run({ "git", "rm", "-q", rel }, r.work)
    end
    run({ "git", "add", "-A" }, r.work)
    run(vim.list_extend(vim.deepcopy(IDENTITY), { "commit", "-q", "--allow-empty", "-m", "captures" }), r.work)
    run({ "git", "push", "-q", "origin", "main" }, r.work)
  end
  return r
end

local function capture(id, text)
  return ('---\nid: "%s"\ncreated: "2026-11-05T07:45:00-05:00"\nsource: "drafts"\ndestination: "personal"\n---\n%s\n'):format(id, text or "Etna lava dome idea")
end

-- Points Lattice at a notes root and an inbox.json listing `repos`.
local function setup_inbox(root, repos, inbox)
  local dir = notes()
  write(dir, "inbox.json", vim.json.encode({ inbox = inbox or vim.empty_dict(), repositories = repos }))
  config.options.root = root
  config.options.inbox_sync = { config = dir .. "/inbox.json" }
  sync.cache_root = notes() .. "/cache"
  sync.state = { running = false, repos = {}, order = {} }
end

local function fetch(mode)
  local done = false
  local started = sync.fetch(mode, function()
    done = true
  end)
  if started then
    assert(vim.wait(20000, function()
      return done
    end, 20), "fetch did not finish")
  end
  return started
end

local function files(name)
  return vim.tbl_map(function(c)
    return c.file
  end, sync.captures()[name] or {})
end

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
  sync.state = { running = false, repos = {}, order = {} }
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
  sync.state = { running = false, repos = {}, order = {} }
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
  sync.state = { running = false, repos = {}, order = {} }
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
