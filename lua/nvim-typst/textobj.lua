--- Typst text objects, implemented on the tree-sitter parse tree.
---
---   a$/i$  math (`i` without the `$` and the spaces inside them)
---   aP/iP  section (`i` without the heading)
---   ac/ic  function call (`i` is the argument list or content block under
---          the cursor, the last one when the cursor is on the name)
---   ad/id  delimiters: `(...)`, `[...]`, `{...}` in code and math
---   am/im  list, enumeration or term item (`i` without the marker)
local ts = require('nvim-typst.ts')

local M = {}

local ESC = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)

--- Select `(sr, sc)` .. `(er, ec)` (1-indexed rows, 0-indexed inclusive cols).
---@param sr integer
---@param sc integer
---@param er integer
---@param ec integer
---@param linewise boolean|nil
local function select_range(sr, sc, er, ec, linewise)
  local mode = vim.fn.mode()
  if mode == 'v' or mode == 'V' or mode == '\22' then
    vim.cmd('normal! ' .. ESC)
  end

  local last = vim.api.nvim_buf_line_count(0)
  sr, er = math.min(sr, last), math.min(er, last)

  vim.api.nvim_win_set_cursor(0, { sr, math.max(0, sc) })
  vim.cmd('normal! ' .. (linewise and 'V' or 'v'))
  vim.api.nvim_win_set_cursor(0, { er, math.max(0, ec) })
end

---@param row integer 1-indexed
---@return string
local function line_at(row)
  return vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ''
end

--- The inclusive range of `node`, as 1-indexed rows / 0-indexed cols.
---@param node TSNode
---@return integer, integer, integer, integer
local function range(node)
  local sr, sc, er, ec = node:range()
  if ec == 0 and er > sr then
    er = er - 1
    ec = #line_at(er + 1)
  end
  return sr + 1, sc, er + 1, math.max(0, ec - 1)
end

--- Select `node` as a whole.
---@param node TSNode
local function select_node(node)
  local sr, sc, er, ec = range(node)
  select_range(sr, sc, er, ec)
end

--- Select what lies between the delimiters `open` and `close`.
---
--- With the delimiters on lines of their own the lines in between are
--- selected linewise, which is what makes `di$` on a displayed equation leave
--- the `$` lines behind. `trim` drops the whitespace just inside the
--- delimiters, as in `$ x $`.
---@param open TSNode
---@param close TSNode
---@param trim boolean|nil
local function select_between(open, close, trim)
  local _, _, oer, oec = open:range()
  local csr, csc = close:range()
  local sr, sc = oer + 1, oec
  local er, ec = csr + 1, csc - 1

  if csr > oer + 1 and oec >= #line_at(sr) and line_at(er):sub(1, csc):match('^%s*$') then
    select_range(sr + 1, 0, er - 1, math.max(0, #line_at(er - 1) - 1), true)
    return
  end

  if ec < 0 then
    er = er - 1
    ec = #line_at(er) - 1
  end
  if trim then
    -- A column past the end of the line stands for the line break.
    local function blank(row, c)
      local line = line_at(row)
      return c >= #line or line:sub(c + 1, c + 1):match('%s') ~= nil
    end
    while (sr < er or (sr == er and sc <= ec)) and blank(sr, sc) do
      if sc >= #line_at(sr) then
        sr, sc = sr + 1, 0
      else
        sc = sc + 1
      end
    end
    while (sr < er or (sr == er and sc <= ec)) and blank(er, ec) do
      if ec <= 0 then
        er = er - 1
        ec = #line_at(er)
      else
        ec = ec - 1
      end
    end
  end

  if sr > er or (sr == er and sc > ec) then
    return -- nothing between the delimiters
  end
  select_range(sr, sc, er, ec)
end

--- The delimiters of `node` when it is bracketed: code and math groups
--- `(...)`, content blocks `[...]`, code blocks `{...}`, and the parentheses
--- of a call in math, which the parser keeps as direct children of the call
--- (a call in code has them in a `group` child instead).
---@param node TSNode
---@return TSNode|nil open, TSNode|nil close
local function delimiters(node)
  local t = node:type()
  if t ~= 'group' and t ~= 'content' and t ~= 'block' and t ~= 'call' then
    return nil
  end

  local open, close
  for child in node:iter_children() do
    if not child:named() then
      local ct = child:type()
      if not open and (ct == '(' or ct == '[' or ct == '{') then
        open = child
      elseif ct == ')' or ct == ']' or ct == '}' then
        close = child
      end
    end
  end
  if not open or not close then
    return nil
  end
  return open, close
end

---@param inner boolean
function M.math(inner)
  local node = ts.ancestor(ts.node_at_cursor(0), ts.MATH)
  if not node then
    return
  end
  if not inner then
    select_node(node)
    return
  end
  local open, close = node:child(0), node:child(node:child_count() - 1)
  if open and close and open:id() ~= close:id() then
    select_between(open, close, true)
  end
end

---@param inner boolean
function M.section(inner)
  local node = ts.ancestor(ts.node_at_cursor(0), ts.SECTION)
  if not node then
    return
  end

  local sr, _, er, _ = range(node)
  if not inner then
    select_range(sr, 0, er, math.max(0, #line_at(er) - 1), true)
    return
  end

  local heading = node:named_child(0)
  local heading_end = heading and (select(3, heading:range()) + 1) or sr
  if er > heading_end then
    select_range(heading_end + 1, 0, er, math.max(0, #line_at(er) - 1), true)
  end
end

--- The call under the cursor: the innermost one, extended over trailing
--- content blocks (`#table(..)[a][b]` is one call nested three deep).
---@return TSNode|nil
local function call_at_cursor()
  local node = ts.node_at_cursor(0)
  if node and node:type() == 'code' then
    node = node:named_child(0)
  end
  node = ts.ancestor(node, { call = true })
  if not node then
    return nil
  end
  local sr, sc = node:range()
  local parent = node:parent()
  while parent and parent:type() == 'call' do
    local psr, psc = parent:range()
    if psr ~= sr or psc ~= sc then
      break
    end
    node, parent = parent, parent:parent()
  end
  return node
end

---@param inner boolean
function M.call(inner)
  local node = call_at_cursor()
  if not node then
    return
  end

  if not inner then
    -- `#emph[x]` in markup: take the `#` along, so `dac` leaves nothing behind.
    local parent = node:parent()
    if parent and parent:type() == 'code' and parent:named_child_count() == 1 then
      node = parent
    end
    select_node(node)
    return
  end

  -- The argument lists and content blocks of the whole chain, in order.
  local args = {}
  local function gather(call)
    local open, close = delimiters(call)
    if open then
      args[#args + 1] = { open, close }
      return
    end
    for child in call:iter_children() do
      if child:type() == 'call' then
        gather(child)
      elseif child:type() == 'group' or child:type() == 'content' then
        local o, c = delimiters(child)
        if o then
          args[#args + 1] = { o, c }
        end
      end
    end
  end
  gather(node)
  if #args == 0 then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local chosen = args[#args]
  for _, pair in ipairs(args) do
    local sr, sc = pair[1]:range()
    local _, _, er, ec = pair[2]:range()
    if (row > sr or (row == sr and col >= sc)) and (row < er or (row == er and col < ec)) then
      chosen = pair
      break
    end
  end
  select_between(chosen[1], chosen[2])
end

--- Fallback for brackets the parser does not group: in markup, `(...)` and
--- `[...]` are plain text.
---@param inner boolean
local function delimiter_fallback(inner)
  local saved = vim.api.nvim_win_get_cursor(0)
  for _, pair in ipairs({ { '(', ')' }, { '\\[', '\\]' }, { '{', '}' } }) do
    local open = vim.fn.searchpairpos(pair[1], '', pair[2], 'bcnW')
    local close = vim.fn.searchpairpos(pair[1], '', pair[2], 'cnW')
    if open[1] > 0 and close[1] > 0 then
      vim.api.nvim_win_set_cursor(0, saved)
      if not inner then
        select_range(open[1], open[2] - 1, close[1], close[2] - 1)
        return
      end
      local sr, sc, er, ec = open[1], open[2], close[1], close[2] - 2
      if ec < 0 then
        er, ec = er - 1, #line_at(er - 1) - 1
      end
      if not (sr > er or (sr == er and sc > ec)) then
        select_range(sr, sc, er, ec)
      end
      return
    end
  end
  vim.api.nvim_win_set_cursor(0, saved)
end

---@param inner boolean
function M.delimiter(inner)
  local node = ts.node_at_cursor(0)
  local open, close
  while node do
    open, close = delimiters(node)
    if open then
      break
    end
    node = node:parent()
  end
  if not node or not open or not close then
    delimiter_fallback(inner)
    return
  end

  if inner then
    select_between(open, close)
  else
    local sr, sc = open:range()
    local _, _, er, ec = close:range()
    select_range(sr + 1, sc, er + 1, ec - 1)
  end
end

---@param inner boolean
function M.item(inner)
  local node = ts.ancestor(ts.node_at_cursor(0), { item = true, term = true })
  if not node then
    return
  end

  local sr, sc, er, ec = range(node)
  if not inner then
    -- A whole-line item goes linewise, so `dam` takes the line with it.
    if line_at(sr):sub(1, sc):match('^%s*$') and line_at(er):sub(ec + 2):match('^%s*$') then
      select_range(sr, 0, er, math.max(0, #line_at(er) - 1), true)
    else
      select_range(sr, sc, er, ec)
    end
    return
  end

  -- Everything after the `-`, `+`, `1.` or `/` marker.
  local first = node:named_child(0)
  if first then
    local fsr, fsc = first:range()
    select_range(fsr + 1, fsc, er, ec)
  end
end

---@param fn fun(inner: boolean)
---@param inner boolean
---@return function
local function object(fn, inner)
  return function()
    fn(inner)
  end
end

--- Mapping table: lhs -> function. Used by `nvim-typst.keymaps`.
M.map = {
  ['a$'] = object(M.math, false),
  ['i$'] = object(M.math, true),
  ['aP'] = object(M.section, false),
  ['iP'] = object(M.section, true),
  ['ac'] = object(M.call, false),
  ['ic'] = object(M.call, true),
  ['ad'] = object(M.delimiter, false),
  ['id'] = object(M.delimiter, true),
  ['am'] = object(M.item, false),
  ['im'] = object(M.item, true),
}

return M
