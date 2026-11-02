-- Pure Markdown parsing: lines in, tasks and task sections out.
local M = {}

local DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

function M.valid_date(value)
  local y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return false
  end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if m < 1 or m > 12 then
    return false
  end
  local max = DAYS[m]
  if m == 2 and (y % 4 == 0 and y % 100 ~= 0 or y % 400 == 0) then
    max = 29
  end
  return d >= 1 and d <= max
end

-- Returns the indent in columns and the line without leading whitespace.
local function measure(line)
  local col = 0
  for i = 1, #line do
    local c = line:sub(i, i)
    if c == " " then
      col = col + 1
    elseif c == "\t" then
      col = col + 4 - col % 4
    else
      return col, line:sub(i)
    end
  end
  return col, ""
end

local function heading_text(indent, body)
  if indent > 3 then
    return nil
  end
  local hashes, rest = body:match("^(#+)(.*)$")
  if not hashes or #hashes > 6 or (rest ~= "" and not rest:match("^[ \t]")) then
    return nil
  end
  rest = vim.trim(rest)
  rest = rest:gsub("^#+$", "")
  rest = rest:gsub("[ \t]+#+$", "")
  return vim.trim(rest)
end

local function fence_open(body)
  local run = body:match("^(```+)") or body:match("^(~~~+)")
  if not run then
    return nil
  end
  local info = body:sub(#run + 1)
  if run:sub(1, 1) == "`" and info:find("`", 1, true) then
    return nil
  end
  return { char = run:sub(1, 1), length = #run }
end

local function fence_closes(fence, body)
  local run, rest = body:match("^(" .. fence.char:rep(3) .. "+)(.*)$")
  return run ~= nil and #run >= fence.length and vim.trim(rest) == ""
end

local function is_thematic_break(body)
  local compact = body:gsub("[ \t]", "")
  return compact:match("^%-%-%-+$") or compact:match("^%*%*%*+$") or compact:match("^___+$")
end

local function is_setext_underline(body)
  return body:match("^=+[ \t]*$") or body:match("^%-+[ \t]*$")
end

-- Returns marker, gap width, content, and whether the marker is a bullet.
local function list_item(body)
  local marker, gap, content = body:match("^([-*+])([ \t]+)(.*)$")
  if marker then
    return marker, #gap, content, true
  end
  marker, gap, content = body:match("^(%d+[.)])([ \t]+)(.*)$")
  if marker then
    return marker, #gap, content, false
  end
end

local function parse_item(content, kind)
  local text = vim.trim(content)
  local done = false

  local mark, rest = text:match("^%[([ xX])%][ \t]+(.*)$")
  if not mark then
    mark = text:match("^%[([ xX])%]$")
    rest = ""
  end
  if mark then
    done = mark ~= " "
    text = rest
  end
  if text == "" then
    return nil
  end

  local person
  if kind == "waiting" then
    local name, description = text:match("^@(%S+)[ \t]*(.*)$")
    if name then
      person, text = name, description
    end
  end

  local dates = {}
  local bad_dates = {}
  for _, tag in ipairs(kind == "waiting" and { "due", "promised" } or { "due" }) do
    for value in text:gmatch("%[" .. tag .. ":([^%]]*)%]") do
      if M.valid_date(value) then
        dates[tag] = dates[tag] or value
      else
        bad_dates[#bad_dates + 1] = { tag = tag, value = value }
      end
    end
    text = vim.trim((text:gsub("[ \t]*%[" .. tag .. ":[^%]]*%][ \t]*", " ")))
  end

  local task = { section = kind, text = text, person = person, due = dates.due, done = done }
  task.promised = dates.promised
  return task, bad_dates
end

--- @param lines string[]
--- @param headings { todo: string, waiting: string }
--- @return { tasks: table[], sections: table[], date_errors: table[] }
function M.parse(lines, headings)
  local result = { tasks = {}, sections = {}, date_errors = {} }
  local section -- the task section being read, if any
  local fence -- the open code fence, if any
  local list_col -- content column of the current top-level item
  local prev_paragraph, prev_blank = false, true

  -- Records where the section ends: `stop` is the line before the next
  -- heading, `last` the final non-blank line.
  local function close_section(last)
    if section then
      section.stop = last
      while last > section.line and vim.trim(lines[last]) == "" do
        last = last - 1
      end
      section.last = last
    end
    section = nil
  end

  for i, raw in ipairs(lines) do
    local line = raw:gsub("\r$", "")
    if i == 1 then
      line = line:gsub("^\239\187\191", "")
    end
    local indent, body = measure(line)
    local blank = body == ""
    local paragraph = false

    if fence then
      if fence_closes(fence, body) then
        fence = nil
      end
    elseif not blank then
      local opened = (indent <= 3 or (list_col and indent < list_col + 4)) and fence_open(body)
      local heading = heading_text(indent, body)

      if opened then
        fence = opened
      elseif heading then
        close_section(i - 1)
        list_col = nil
        local kind = (heading == headings.todo and "todo") or (heading == headings.waiting and "waiting")
        if kind then
          section = { kind = kind, line = i, last = i }
          result.sections[#result.sections + 1] = section
        end
      elseif prev_paragraph and indent <= 3 and is_setext_underline(body) then
        close_section(i - 2)
        list_col = nil
      elseif indent <= 3 and is_thematic_break(body) then
        list_col = nil
      else
        local marker, gap, content, bullet = list_item(body)
        if marker then
          local nested = list_col and indent >= list_col
          if not nested and (list_col or indent <= 3) then
            list_col = indent + #marker + (gap > 4 and 1 or gap)
            if bullet and section then
              local task, bad_dates = parse_item(content, section.kind)
              if task then
                task.line = i
                result.tasks[#result.tasks + 1] = task
                if not task.done then
                  for _, bad in ipairs(bad_dates) do
                    bad.line = i
                    result.date_errors[#result.date_errors + 1] = bad
                  end
                end
              end
            end
          end
        else
          if prev_blank and indent == 0 then
            list_col = nil
          end
          paragraph = indent <= 3 and not (list_col and indent >= list_col)
        end
      end
    end

    prev_paragraph = paragraph
    prev_blank = blank
  end

  close_section(#lines)
  return result
end

return M
