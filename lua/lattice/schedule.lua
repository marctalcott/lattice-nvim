-- Scheduling engine (LATTICE_SYNTAX_SPEC §8–§10): calendar arithmetic,
-- repeaters, deadline warnings and agenda status. Pure: dates are plain
-- tables, so no time zone or DST can shift a day, and nothing here edits a
-- note (the mutation layer, milestone D, applies the results).
--
-- Arithmetic follows Org's implementation, which shifts timestamps with
-- Emacs `encode-time`: adding months or years keeps the day number and lets
-- an impossible date overflow into the next month, so Jan 31 + 1m is
-- Mar 3 (Mar 2 in a leap year) and Feb 29 + 1y is Mar 1. See
-- ORG_MARKDOWN_PLAN.md D12.
local timestamp = require("lattice.timestamp")

local M = {}

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
-- days_from_civil), and back.
function M.day_number(year, month, day)
  local y = month <= 2 and year - 1 or year
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (month + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + day - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

function M.from_day_number(n)
  n = n + 719468
  local era = math.floor(n / 146097)
  local doe = n - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return m <= 2 and y + 1 or y, m, d
end

local function iso(year, month, day)
  return ("%04d-%02d-%02d"):format(year, month, day)
end

--- Day number of an ISO date "YYYY-MM-DD".
function M.days(date)
  local y, m, d = date:match("^(%d+)%-(%d+)%-(%d+)$")
  return M.day_number(tonumber(y), tonumber(m), tonumber(d))
end

--- The ISO date `n` days after `date`.
function M.add_days(date, n)
  return iso(M.from_day_number(M.days(date) + n))
end

-- Normalizes an overflowing month or day the way encode-time does.
local function normalize(year, month, day)
  year = year + math.floor((month - 1) / 12)
  month = (month - 1) % 12 + 1
  return M.from_day_number(M.day_number(year, month, 1) + day - 1)
end

--- Length of one repeater or warning unit in days, as Org's org-get-wdays
--- counts it (a month is 30.4 days).
M.UNIT_DAYS = { h = 1 / 24, d = 1, w = 7, m = 30.4, y = 365.25 }

-- A point in time as minutes since the epoch, for hour arithmetic.
local function minutes_of(ts)
  local hour, minute = 0, 0
  if ts.time then
    hour, minute = ts.time:match("^(%d+):(%d+)$")
  end
  return M.day_number(ts.year, ts.month, ts.day) * 1440 + tonumber(hour) * 60 + tonumber(minute)
end

-- A copy of `ts` moved to the given calendar date (and time, if given),
-- with its weekday rewritten in English and its raw text rebuilt.
local function moved(ts, year, month, day, time)
  local copy = vim.deepcopy(ts)
  copy.year, copy.month, copy.day = year, month, day
  copy.date = iso(year, month, day)
  copy.time = time or ts.time
  copy.weekday = timestamp.weekday(year, month, day)
  copy.raw = M.format(copy)
  copy.line = nil
  return copy
end

--- Renders a timestamp back to Org text, e.g. "<2026-11-09 Mon 09:30 +1w -3d>".
function M.format(ts)
  local parts = { ts.date, ts.weekday or timestamp.weekday(ts.year, ts.month, ts.day) }
  if ts.time then
    parts[#parts + 1] = ts.time
  end
  if ts.repeater then
    parts[#parts + 1] = ("%s%d%s"):format(ts.repeater.kind, ts.repeater.n, ts.repeater.unit)
  end
  if ts.warning then
    parts[#parts + 1] = ("%s%d%s"):format(ts.warning.first and "--" or "-", ts.warning.n, ts.warning.unit)
  end
  local open, close = "<", ">"
  if ts.active == false then
    open, close = "[", "]"
  end
  return open .. table.concat(parts, " ") .. close
end

--- `ts` shifted by `n` units ("h", "d", "w", "m", "y"), Org style.
function M.shift(ts, n, unit)
  if unit == "h" then
    local total = minutes_of(ts) + n * 60
    local day = math.floor(total / 1440)
    local rest = total - day * 1440
    local y, m, d = M.from_day_number(day)
    return moved(ts, y, m, d, ("%02d:%02d"):format(math.floor(rest / 60), rest % 60))
  elseif unit == "d" or unit == "w" then
    local y, m, d = M.from_day_number(M.day_number(ts.year, ts.month, ts.day) + n * (unit == "w" and 7 or 1))
    return moved(ts, y, m, d)
  elseif unit == "m" then
    return moved(ts, normalize(ts.year, ts.month + n, ts.day))
  elseif unit == "y" then
    return moved(ts, normalize(ts.year + n, ts.month, ts.day))
  end
  error("unknown unit " .. tostring(unit))
end

--- @class lattice.Now
--- @field date string  "YYYY-MM-DD"
--- @field time string|nil  "HH:MM"

--- The next occurrence of a repeating timestamp when its task is completed
--- at `now` (§10.1, §10.3):
---   +   one interval after the current occurrence, even if still past;
---   ++  whole intervals until the occurrence is in the future;
---   .+  one interval after the completion date (time for hourly repeats).
--- Returns nil for a timestamp without a repeater.
function M.next_occurrence(ts, now)
  local rep = ts.repeater
  if not rep then
    return nil
  end
  if rep.kind == "+" then
    return M.shift(ts, rep.n, rep.unit)
  end
  local now_ts = assert(timestamp.parse("<" .. now.date .. (now.time and (" " .. now.time) or "") .. ">"))
  if rep.kind == ".+" then
    local base
    if rep.unit == "h" then
      base = moved(ts, now_ts.year, now_ts.month, now_ts.day, now_ts.time or "00:00")
    else
      base = moved(ts, now_ts.year, now_ts.month, now_ts.day)
    end
    return M.shift(base, rep.n, rep.unit)
  end
  -- "++": the fewest whole intervals (at least one) that put the
  -- occurrence after now. A date without a time stands for its midnight,
  -- as in Org. Shifting from the original each time keeps month overflow
  -- from drifting; the estimate jumps close, then steps correct it.
  local now_minutes = minutes_of(now_ts)
  local function after_now(steps)
    return minutes_of(M.shift(ts, rep.n * steps, rep.unit)) > now_minutes
  end
  local interval = rep.n * M.UNIT_DAYS[rep.unit] * 1440
  local steps = math.max(1, math.floor((now_minutes - minutes_of(ts)) / interval))
  while steps > 1 and after_now(steps - 1) do
    steps = steps - 1
  end
  while not after_now(steps) do
    steps = steps + 1
  end
  return M.shift(ts, rep.n * steps, rep.unit)
end

--- Days of advance warning for a deadline: its own `-Nd`, else `default`.
function M.warning_days(ts, default)
  if ts.warning then
    return math.floor(ts.warning.n * M.UNIT_DAYS[ts.warning.unit])
  end
  return default
end

--- Agenda status of an open task's deadline on `today` (§9.3):
--- "overdue", "today", "upcoming" (inside the warning period), or nil.
--- Also returns the days until (negative: since) the deadline.
function M.deadline_status(date, today, warning)
  local diff = M.days(date) - M.days(today)
  if diff < 0 then
    return "overdue", diff
  elseif diff == 0 then
    return "today", diff
  elseif diff <= warning then
    return "upcoming", diff
  end
  return nil, diff
end

--- Agenda status of an open task's scheduled date on `today` (§8.2):
--- "today" when scheduled for today, "past" when scheduled earlier and still
--- open (Org keeps showing it, "Sched. Nx"), "future", or "delayed" while a
--- `-Nd` delay hides it. Also returns the days since the scheduled date.
function M.scheduled_status(ts, today)
  local since = M.days(today) - M.days(ts.date)
  if ts.warning then
    local delay = math.floor(ts.warning.n * M.UNIT_DAYS[ts.warning.unit])
    if since < delay then
      return since < 0 and "future" or "delayed", since
    end
  end
  if since == 0 then
    return "today", since
  elseif since > 0 then
    return "past", since
  end
  return "future", since
end

--- Reads a date answer: YYYY-MM-DD, today, tomorrow, or +N with d/w/m/y,
--- optionally followed by HH:MM. Returns { date, time } or nil.
function M.read_date(answer, today)
  local text, time = vim.trim(answer):match("^(.-)%s*(%d%d?:%d%d)$")
  if not text then
    text = vim.trim(answer)
  end
  local date
  if text == "today" or text == "" and time then
    date = today
  elseif text == "tomorrow" then
    date = M.add_days(today, 1)
  elseif text:match("^%+%d+[dwmy]$") then
    local n, unit = text:match("^%+(%d+)([dwmy])$")
    date = M.shift(assert(timestamp.parse("<" .. today .. ">")), tonumber(n), unit).date
  elseif timestamp.valid_date(text) then
    date = text
  end
  if not date then
    return nil
  end
  if time then
    local h, m = time:match("^(%d+):(%d+)$")
    if tonumber(h) > 23 or tonumber(m) > 59 then
      return nil
    end
    time = ("%02d:%s"):format(tonumber(h), m)
  end
  return { date = date, time = time }
end

--- What completing a repeating task at `now` changes (§10.3): the next
--- SCHEDULED and DEADLINE, each advanced by its own repeater (D12).
--- Returns nil when neither timestamp repeats. The task stays open.
function M.advance(task, now)
  local changes = {}
  for _, field in ipairs({ "scheduled", "deadline" }) do
    local ts = task[field]
    if ts and ts.repeater then
      changes[field] = M.next_occurrence(ts, now)
    end
  end
  if next(changes) == nil then
    return nil
  end
  return changes
end

return M
