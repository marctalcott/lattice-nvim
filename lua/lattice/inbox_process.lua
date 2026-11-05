-- Pure helpers for reviewing captures (LATTICE_INBOX_SPEC A1.3, A1.8, A1.9):
-- suggested titles, filenames, folder suggestions and the filed note's text.
-- Deterministic: the same capture and configuration give the same result.
local M = {}

local FILLERS = {
  "i was thinking about",
  "i was thinking",
  "maybe we should",
  "note to self",
  "remember to",
  "i need to",
  "i think",
  "so",
}
local MAX_WORDS = 8
local MAX_TITLE_CHARS = 60
local MAX_FILENAME_BYTES = 80

--- The capture's text after its front matter, as lines.
function M.body_lines(text, body_line)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return vim.list_slice(lines, body_line or 1, #lines)
end

--- Seconds since the epoch for an ISO 8601 timestamp with an offset or Z
--- (2026-11-05T07:45:00-05:00), or nil.
function M.epoch(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s, zone = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d):?(%d?%d?)(.*)$")
  if not y then
    return nil
  end
  y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s) or 0
  -- Days from 1970-01-01 (Howard Hinnant's days_from_civil).
  local yy = mo <= 2 and y - 1 or y
  local era = math.floor(yy / 400)
  local yoe = yy - era * 400
  local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  local offset = 0
  local sign, oh, om = zone:match("^%.?%d*([+-])(%d%d):?(%d%d)$")
  if sign then
    offset = (tonumber(oh) * 60 + tonumber(om)) * 60 * (sign == "-" and -1 or 1)
  elseif not zone:match("^%.?%d*Z?$") then
    return nil
  end
  return days * 86400 + h * 3600 + mi * 60 + s - offset
end

local function capitalize(text)
  local first = vim.fn.strcharpart(text, 0, 1)
  return vim.fn.toupper(first) .. text:sub(#first + 1)
end

--- A suggested title (A1.8), or `Capture YYYY-MM-DD HHMM` from `created`
--- when the text gives none.
function M.title(lines, created)
  local line
  for _, l in ipairs(lines) do
    if vim.trim(l) ~= "" then
      line = vim.trim(l:gsub("\r$", ""))
      break
    end
  end
  line = line or ""
  -- Markdown markers: headings, bullets, quotes, checkboxes.
  local before
  repeat
    before = line
    line = line:gsub("^#+%s*", ""):gsub("^[-*+]%s+", ""):gsub("^>%s*", ""):gsub("^%[[ xX%-]%]%s*", "")
  until line == before
  -- The first sentence.
  local cut = line:find("[.?!]%s") or line:find("[.?!]$")
  if cut then
    line = line:sub(1, cut - 1)
  end
  -- One leading filler phrase.
  local lower = line:lower()
  for _, filler in ipairs(FILLERS) do
    if lower:sub(1, #filler) == filler and not lower:sub(#filler + 1, #filler + 1):match("[%w']") then
      line = line:sub(#filler + 1)
      break
    end
  end
  line = vim.trim(line:gsub("^[%s,;:%-]+", ""))
  -- At most MAX_WORDS words and MAX_TITLE_CHARS characters.
  local words = vim.split(line, "%s+", { trimempty = true })
  words = vim.list_slice(words, 1, MAX_WORDS)
  while #words > 1 and vim.fn.strchars(table.concat(words, " ")) > MAX_TITLE_CHARS do
    words[#words] = nil
  end
  line = table.concat(words, " ")
  if vim.fn.strchars(line) > MAX_TITLE_CHARS then
    line = vim.fn.strcharpart(line, 0, MAX_TITLE_CHARS)
  end
  line = vim.trim(line:gsub("[%s,;:%-]+$", ""))
  if line == "" then
    local date, hh, mm = (created or ""):match("^(%d%d%d%d%-%d%d%-%d%d)[T ](%d%d):(%d%d)")
    return date and ("Capture %s %s%s"):format(date, hh, mm) or "Capture"
  end
  return capitalize(line)
end

-- Cuts a string to at most `limit` bytes without splitting a UTF-8 character.
local function cut_bytes(text, limit)
  if #text <= limit then
    return text
  end
  local cut = limit
  while cut > 0 and text:byte(cut + 1) and text:byte(cut + 1) >= 0x80 and text:byte(cut + 1) < 0xC0 do
    cut = cut - 1
  end
  return text:sub(1, cut)
end

--- A filesystem-safe file name for a title (A1.8), without the extension.
function M.file_stem(title)
  local stem = title:gsub('[/\\:*?"<>|%c]', " "):gsub("%s+", " ")
  stem = vim.trim(stem):gsub("^%.+", "")
  stem = vim.trim(cut_bytes(vim.trim(stem), MAX_FILENAME_BYTES))
  return stem ~= "" and stem or "Capture"
end

--- The first free path `<folder>/<stem>.md`, `<stem> 2.md`, … A path is
--- taken if a file exists there or a buffer already has that name.
function M.free_path(folder, stem, taken)
  taken = taken
    or function(path)
      if vim.uv.fs_lstat(path) then
        return true
      end
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == path then
          return true
        end
      end
      return false
    end
  local n = 1
  while true do
    local name = n == 1 and stem or ("%s %d"):format(stem, n)
    local path = ("%s/%s.md"):format(folder, name)
    if not taken(path) then
      return path
    end
    n = n + 1
  end
end

-- A matcher for a list of globs, or nil when the list is empty.
local function matcher(globs)
  local patterns = {}
  for _, glob in ipairs(globs or {}) do
    local ok, pattern = pcall(vim.glob.to_lpeg, glob)
    if ok then
      patterns[#patterns + 1] = pattern
    end
  end
  return function(path)
    for _, pattern in ipairs(patterns) do
      if pattern:match(path) then
        return true
      end
    end
    return false
  end
end

--- Existing folders under the notes root that a capture can be filed into:
--- depth 1 and 2, not hidden, not symbolic links, not excluded from
--- scanning, and not the local inbox folder.
--- @param cfg table  .lattice.json config (scan.exclude, inbox.path)
function M.folders(root, cfg)
  local excluded = matcher(cfg.scan and cfg.scan.exclude)
  local inbox = cfg.inbox and cfg.inbox.path
  local out = {}
  local function skip(rel)
    -- A folder is excluded when a note inside it would be.
    return excluded(rel .. "/x.md") or (inbox and (rel == inbox or vim.startswith(rel, inbox .. "/")))
  end
  local function visit(rel, depth)
    local handle = vim.uv.fs_scandir(rel == "" and root or (root .. "/" .. rel))
    if not handle then
      return
    end
    while true do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local child = rel == "" and name or (rel .. "/" .. name)
      if kind == "directory" and name:sub(1, 1) ~= "." and not skip(child) then
        out[#out + 1] = child
        if depth < 2 then
          visit(child, depth + 1)
        end
      end
    end
  end
  visit("", 1)
  table.sort(out)
  return out
end

-- Keywords for a folder: its name, its name with - and _ as spaces and any
-- leading number ("1-Projects", "02 Etna") removed, plus configured aliases.
local function folder_keywords(rel, aliases)
  local name = rel:match("[^/]+$")
  local words = { name:lower() }
  local plain = name:gsub("^%d+[%s._-]*", ""):gsub("[-_]", " "):lower()
  plain = vim.trim(plain)
  if plain ~= "" and plain ~= words[1] then
    words[#words + 1] = plain
  end
  for _, alias in ipairs(aliases[rel] or {}) do
    words[#words + 1] = alias:lower()
  end
  return words
end

-- Whole-word, case-insensitive occurrences of `word` in `text` (lowercase).
local function count_word(text, word)
  local count, start = 0, 1
  while true do
    local s, e = text:find(word, start, true)
    if not s then
      return count
    end
    local before, after = text:sub(s - 1, s - 1), text:sub(e + 1, e + 1)
    if not before:match("[%w_]") and not after:match("[%w_]") then
      count = count + 1
    end
    start = e + 1
  end
end

--- The suggested folder (A1.9): the candidate whose keywords occur most
--- often as whole words in the text; ties go to the deeper folder, then
--- alphabetical order. With no match, `default`.
--- @return string folder, integer score
function M.suggest(lines, folders, aliases, default)
  local text = table.concat(lines, "\n"):lower()
  local best, best_score = nil, 0
  for _, rel in ipairs(folders) do
    local score = 0
    local seen = {}
    for _, word in ipairs(folder_keywords(rel, aliases or {})) do
      if word ~= "" and not seen[word] then
        seen[word] = true
        score = score + count_word(text, word)
      end
    end
    if score > 0 then
      local better = score > best_score
      if score == best_score and best then
        local depth, best_depth = select(2, rel:gsub("/", "")), select(2, best:gsub("/", ""))
        better = depth > best_depth or (depth == best_depth and rel < best)
      end
      if better then
        best, best_score = rel, score
      end
    end
  end
  return best or default, best_score
end

--- The filed note's lines (A1.3): a heading (`# <title>`, or
--- `# <keyword> <title>` for a task), the capture's properties, a blank
--- line and the text unchanged.
function M.note_lines(capture, body, title, keyword)
  local lines = { keyword and ("# %s %s"):format(keyword, title) or ("# " .. title), ":PROPERTIES:" }
  lines[#lines + 1] = ":CAPTURE_ID: " .. capture.id
  if capture.created then
    lines[#lines + 1] = ":CAPTURED: " .. capture.created
  end
  if capture.source then
    lines[#lines + 1] = ":CAPTURE_SOURCE: " .. capture.source
  end
  lines[#lines + 1] = ":CAPTURE_REPO: " .. capture.repo
  lines[#lines + 1] = ":END:"
  lines[#lines + 1] = ""
  vim.list_extend(lines, body)
  return lines
end

--- The :CAPTURE_ID: value in a note's text, or nil.
function M.capture_id_in(text)
  return text:match("\n:CAPTURE_ID:[ \t]*([^%s]+)[ \t]*\r?\n") or text:match("^:CAPTURE_ID:[ \t]*([^%s]+)")
end

return M
