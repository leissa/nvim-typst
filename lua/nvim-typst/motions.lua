--- Tree-sitter driven motions.
---
---   ]] [[  start of the next / previous heading
---   ][ []  end of the next / previous section
---   ]n [n  start of math, ]N [N end of math
---   ]m [m  start of a `#call(...)[...]` in markup, ]M [M its end
---   ]/ [/  start of a comment, ]* [* its end
---   %      between the `$` of math, the `*` / `_` of strong and emphasis,
---          falling back to the built-in `%` for brackets
---
--- All motions are exclusive and work in normal, visual and operator-pending
--- mode. They accept a count.
local ts = require('nvim-typst.ts')

local M = {}

---@param row integer 1-indexed
---@return string
local function line_at(row)
  return vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ''
end

---@param node TSNode
---@return integer, integer 1-indexed row, 0-indexed col
local function node_start(node)
  local sr, sc = node:range()
  return sr + 1, sc
end

--- The last character of `node`.
---@param node TSNode
---@return integer, integer 1-indexed row, 0-indexed col
local function node_end(node)
  local _, _, er, ec = node:range()
  if ec == 0 and er > 0 then
    er = er - 1
    ec = #line_at(er + 1)
  end
  return er + 1, math.max(0, ec - 1)
end

--- The last non-blank character of `node`. Sections run up to the next
--- heading, blank lines included; `][` should stop at the text.
---@param node TSNode
---@return integer, integer
local function trimmed_end(node)
  local sr = node:range()
  local row, col = node_end(node)
  while row > sr + 1 and line_at(row):match('^%s*$') do
    row = row - 1
    col = #line_at(row)
  end
  local text = line_at(row):sub(1, col + 1)
  return row, math.max(0, #(text:gsub('%s+$', '')) - 1)
end

--- Is `node` a `#...` in markup that calls a function: `#emph[x]`,
--- `#figure(...)[...]`? `#let`, `#set` and plain expressions are not.
---@param node TSNode
---@return boolean
local function is_markup_call(node)
  if node:type() ~= 'code' then
    return false
  end
  local child = node:named_child(0)
  return child ~= nil and child:type() == 'call'
end

local KINDS = {
  section = ts.SECTION,
  math = ts.MATH,
  call = is_markup_call,
  comment = ts.COMMENT,
}

--- Collect the jump targets for `kind`.
---@param kind string
---@param which 'start'|'finish'
---@return table[] list of `{ row, col }`, sorted
local function targets(kind, which)
  local out = {}
  for _, node in ipairs(ts.collect(vim.api.nvim_get_current_buf(), KINDS[kind])) do
    local row, col
    if which == 'start' then
      row, col = node_start(node)
    elseif kind == 'section' then
      row, col = trimmed_end(node)
    else
      row, col = node_end(node)
    end
    out[#out + 1] = { row, col }
  end

  table.sort(out, function(a, b)
    if a[1] ~= b[1] then
      return a[1] < b[1]
    end
    return a[2] < b[2]
  end)
  return out
end

---@param a table
---@param row integer
---@param col integer
---@return boolean
local function after(a, row, col)
  return a[1] > row or (a[1] == row and a[2] > col)
end

---@param kind 'section'|'math'|'call'|'comment'
---@param which 'start'|'finish'
---@param direction 'next'|'prev'
function M.jump(kind, which, direction)
  local count = vim.v.count1
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]
  local list = targets(kind, which)

  local found
  local seen = 0
  if direction == 'next' then
    for _, pos in ipairs(list) do
      if after(pos, row, col) then
        seen = seen + 1
        if seen == count then
          found = pos
          break
        end
      end
    end
  else
    for i = #list, 1, -1 do
      local pos = list[i]
      if not after(pos, row, col) and not (pos[1] == row and pos[2] == col) then
        seen = seen + 1
        if seen == count then
          found = pos
          break
        end
      end
    end
  end

  if found then
    vim.api.nvim_win_set_cursor(0, { found[1], found[2] })
  end
end

--- Nodes whose first and last child are a matching pair of delimiters.
local PAIRED = { math = true, strong = true, emph = true }

--- Move to `(row, col)`. In operator-pending mode the target is selected
--- instead, so that `d%` includes the character under it, as the built-in
--- `%` does.
---@param row integer
---@param col integer
local function go(row, col)
  if vim.fn.mode(1):sub(1, 2) == 'no' then
    vim.cmd('normal! v')
  end
  vim.api.nvim_win_set_cursor(0, { row, col })
end

--- `%`: jump between the `$` of math, or the `*` / `_` of strong and
--- emphasis. Anywhere else it is the built-in `%`.
function M.match_pair()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1], cursor[2]

  local node = ts.ancestor(ts.node_at_cursor(0), PAIRED)
  if node and node:child_count() >= 2 then
    local open, close = node:child(0), node:child(node:child_count() - 1)
    if not open:named() and not close:named() then
      local osr, osc = node_start(open)
      local csr, csc = node_start(close)
      if row == osr and col == osc then
        go(csr, csc)
        return
      elseif row == csr and col == csc then
        go(osr, osc)
        return
      end
    end
  end

  vim.cmd('normal! %')
  local target = vim.api.nvim_win_get_cursor(0)
  if target[1] ~= row or target[2] ~= col then
    vim.api.nvim_win_set_cursor(0, cursor)
    go(target[1], target[2])
  end
end

---@param kind string
---@param which 'start'|'finish'
---@param direction 'next'|'prev'
---@return function
local function jumper(kind, which, direction)
  return function()
    M.jump(kind, which, direction)
  end
end

--- Mapping table: lhs -> function. Used by `nvim-typst.keymaps`.
M.map = {
  [']]'] = jumper('section', 'start', 'next'),
  ['[['] = jumper('section', 'start', 'prev'),
  [']['] = jumper('section', 'finish', 'next'),
  ['[]'] = jumper('section', 'finish', 'prev'),
  [']n'] = jumper('math', 'start', 'next'),
  ['[n'] = jumper('math', 'start', 'prev'),
  [']N'] = jumper('math', 'finish', 'next'),
  ['[N'] = jumper('math', 'finish', 'prev'),
  [']m'] = jumper('call', 'start', 'next'),
  ['[m'] = jumper('call', 'start', 'prev'),
  [']M'] = jumper('call', 'finish', 'next'),
  ['[M'] = jumper('call', 'finish', 'prev'),
  [']/'] = jumper('comment', 'start', 'next'),
  ['[/'] = jumper('comment', 'start', 'prev'),
  [']*'] = jumper('comment', 'finish', 'next'),
  ['[*'] = jumper('comment', 'finish', 'prev'),
  ['%'] = M.match_pair,
}

return M
