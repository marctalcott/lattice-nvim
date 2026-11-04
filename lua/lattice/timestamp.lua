-- Org timestamps (LATTICE_SYNTAX_SPEC §8–§10):
--   <2026-11-05 Thu>  <2026-11-05 Thu 09:30>  <2026-11-09 Mon +1w -3d>
--   [2026-11-09 Mon 14:30]   (inactive, used by CLOSED)
-- This module parses the syntax. Repeater arithmetic lives in milestone C.
local M = {}

local DAYS_IN_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function leap(year)
  return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

function M.days_in_month(year, month)
  return month == 2 and leap(year) and 29 or DAYS_IN_MONTH[month]
end

--- True for a real calendar date "YYYY-MM-DD".
function M.valid_date(value)
  local y, m, d = tostring(value):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return false
  end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  return m >= 1 and m <= 12 and d >= 1 and d <= M.days_in_month(y, m)
end

--- English weekday abbreviation for a valid date, independent of locale.
function M.weekday(year, month, day)
  -- Sakamoto's method.
  local offsets = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
  local y = month < 3 and year - 1 or year
  local index = (y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) + offsets[month] + day) % 7
  return WEEKDAYS[index + 1]
end

--- @class lattice.Timestamp
--- @field raw string
--- @field active boolean          <...> rather than [...]
--- @field date string             "YYYY-MM-DD", authoritative (§8.1)
--- @field year integer
--- @field month integer
--- @field day integer
--- @field weekday string|nil      as written
--- @field time string|nil         "HH:MM"
--- @field repeater { kind: "+"|"++"|".+", n: integer, unit: string }|nil
--- @field warning { n: integer, unit: string, first: boolean }|nil  -3d (first: --3d)

--- Parses one timestamp, brackets included.
--- @return lattice.Timestamp|nil
--- @return string|nil err
function M.parse(raw)
  local open, inner, close = raw:match("^([<%[])(.-)([>%]])$")
  if not open or (open == "<") ~= (close == ">") then
    return nil, ("%s is not a timestamp"):format(raw)
  end
  local date, rest = inner:match("^(%d%d%d%d%-%d%d%-%d%d)(.*)$")
  if not date then
    return nil, ("%s has no YYYY-MM-DD date"):format(raw)
  end
  if not M.valid_date(date) then
    return nil, ("%s is not a real date"):format(date)
  end
  local y, m, d = date:match("^(%d+)%-(%d+)%-(%d+)$")
  local ts = {
    raw = raw,
    active = open == "<",
    date = date,
    year = tonumber(y),
    month = tonumber(m),
    day = tonumber(d),
  }
  for token in rest:gmatch("%S+") do
    local kind, n, unit = token:match("^([%.%+]?%+)(%d+)([hdwmy])$")
    local warn_dash, warn_n, warn_unit = token:match("^(%-%-?)(%d+)([hdwmy])$")
    if token:match("^%a+$") and not ts.weekday and not ts.time then
      ts.weekday = token
    elseif token:match("^%d%d?:%d%d$") and not ts.time then
      local hour, minute = token:match("^(%d+):(%d+)$")
      if tonumber(hour) > 23 or tonumber(minute) > 59 then
        return nil, ("%s has an invalid time"):format(raw)
      end
      ts.time = ("%02d:%s"):format(tonumber(hour), minute)
    elseif kind and (kind == "+" or kind == "++" or kind == ".+") and not ts.repeater then
      ts.repeater = { kind = kind, n = tonumber(n), unit = unit }
    elseif warn_dash and not ts.warning then
      ts.warning = { n = tonumber(warn_n), unit = warn_unit, first = warn_dash == "--" }
    else
      return nil, ("%s: cannot read %q"):format(raw, token)
    end
  end
  return ts
end

--- The correct weekday when `ts` names a different English weekday, else
--- nil. Weekday names in other languages (Org writes the locale's) are not
--- checked.
function M.weekday_mismatch(ts)
  if not ts.weekday then
    return nil
  end
  local written = ts.weekday:sub(1, 3):lower()
  local english = false
  for _, name in ipairs(WEEKDAYS) do
    english = english or name:lower() == written
  end
  local actual = M.weekday(ts.year, ts.month, ts.day)
  if english and written ~= actual:lower() then
    return actual
  end
end

return M
