-- Fixtures for inbox tests: local bare Git repositories stand in for GitHub.
local H = require("helpers")
local write, notes = H.write, H.notes
local config = H.config
local sync = require("lattice.inbox_sync")

local IH = {}
function IH.run(cmd, cwd)
  local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, table.concat(cmd, " ") .. ": " .. (result.stderr or ""))
  return result
end

local IDENTITY = { "git", "-c", "user.name=Lattice Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false" }

-- A bare "GitHub" repository and a working clone used to add captures.
function IH.remote()
  local base = notes()
  IH.run({ "git", "init", "-q", "--bare", "-b", "main", base .. "/remote.git" })
  IH.run({ "git", "init", "-q", "-b", "main", base .. "/work" })
  IH.run({ "git", "remote", "add", "origin", base .. "/remote.git" }, base .. "/work")
  local r = { url = base .. "/remote.git", work = base .. "/work" }
  function r.push(files, remove)
    for rel, content in pairs(files or {}) do
      write(r.work, rel, content)
    end
    for _, rel in ipairs(remove or {}) do
      IH.run({ "git", "rm", "-q", rel }, r.work)
    end
    IH.run({ "git", "add", "-A" }, r.work)
    IH.run(vim.list_extend(vim.deepcopy(IDENTITY), { "commit", "-q", "--allow-empty", "-m", "captures" }), r.work)
    IH.run({ "git", "push", "-q", "origin", "main" }, r.work)
  end
  return r
end

function IH.capture(id, text)
  return ('---\nid: "%s"\ncreated: "2026-11-05T07:45:00-05:00"\nsource: "drafts"\ndestination: "personal"\n---\n%s\n'):format(id, text or "Etna lava dome idea")
end

-- Points Lattice at a notes root and an inbox.json listing `repos`.
function IH.setup_inbox(root, repos, inbox)
  local dir = notes()
  write(dir, "inbox.json", vim.json.encode({ inbox = inbox or vim.empty_dict(), repositories = repos }))
  config.options.root = root
  config.options.inbox_sync = { config = dir .. "/inbox.json" }
  sync.cache_root = notes() .. "/cache"
  sync.state = { running = false, repos = {}, order = {} }
end

function IH.fetch(mode)
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

function IH.files(name)
  return vim.tbl_map(function(c)
    return c.file
  end, sync.captures()[name] or {})
end

return IH
