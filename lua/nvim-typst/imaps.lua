--- Insert mode math mappings, nvim-tex's (and vimtex's) `imaps`.
---
--- A short sequence behind a leader key -- a backtick by default -- expands
--- into a Typst symbol or function: `` `a `` gives `alpha`, `` `8 `` gives
--- `infinity`. The expansion only happens inside math; in running text the
--- typed keys are inserted unchanged, so the leader stays usable for raw text.
---
--- In math, `xalpha` is one identifier rather than `x` times `alpha`, so an
--- expansion that would run into a letter on either side is separated from it
--- by a space.
---
--- Whether the cursor sits in math is decided by `nvim-typst.ts`, from the
--- parse tree rather than from syntax groups.
local config = require('nvim-typst.config')
local ts = require('nvim-typst.ts')
local util = require('nvim-typst.util')

--- One insert mode mapping.
---@class nvim-typst.Imap
---@field lhs string typed after the leader, taken literally
---@field rhs? string|fun(lhs: string): string the text to insert
---@field style? string shorthand for an rhs built by `M.style`
---@field leader? string overrides `imaps.leader`
---@field wrapper? string|fun(lhs: string, expand: fun(): string): string

local M = {}

local ESC = '\27'

--- Buffers the mappings were created in, so `M.add` can reach them.
---@type table<integer, boolean>
local attached = {}

--- Maps registered at run time through `M.add`.
---@type nvim-typst.Imap[]
local extra = {}

--- Is the insertion point `row`/`col` (0-indexed) between the `$`s of math
--- in the tree of `root`?
---@param root TSNode
---@param row integer
---@param col integer
---@return boolean
local function math_around(root, row, col)
  local node = root:named_descendant_for_range(row, col, row, col)
  local math = ts.ancestor(node, ts.MATH)
  while math do
    local sr, sc, er, ec = math:range()
    -- Past the opening `$`, and before the closing one.
    local after_open = row > sr or (row == sr and col > sc)
    local before_close = row < er or (row == er and col < ec)
    if after_open and before_close then
      return true
    end
    math = ts.ancestor(math:parent(), ts.MATH)
  end
  return false
end

--- The top-level node of the tree of `root` around the insertion point
--- `row`/`col` (0-indexed), sections looked into; `root` itself when there
--- is none.
---@param root TSNode
---@param row integer
---@param col integer
---@return TSNode
local function block_at(root, row, col)
  -- A document that is one error has no blocks.
  if root:type() ~= 'source_file' then
    return root
  end
  local node = root
  while true do
    local inner
    for child in node:iter_children() do
      local sr, sc, er, ec = child:range()
      if (sr < row or (sr == row and sc <= col)) and (er > row or (er == row and ec >= col)) then
        inner = child
        break
      end
    end
    if not inner then
      return node
    end
    if not (ts.SECTION[inner:type()] or (inner:type() == 'content' and ts.SECTION[node:type()])) then
      return inner
    end
    node = inner
  end
end

--- Is the insert mode cursor in math?
---
--- Unlike `ts.in_math`, which asks about the character under the cursor,
--- this asks about the point between two characters the cursor is in insert
--- mode: at the end of `$x$` it is past the math. And math being typed has no
--- closing `$` yet, which leaves an error rather than math in the tree; so
--- when the block around the cursor has errors, the question is asked again
--- of its text with a `$` where the cursor is.
---@return boolean
function M.in_math()
  local root = ts.root(0)
  if not root then
    return false
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1
  if math_around(root, row, col) then
    return true
  end
  local block = block_at(root, row, col)
  if not block:has_error() then
    return false
  end

  -- Only the lines of that block are parsed again, so a long document costs
  -- no more than a short one.
  local first, _, last = block:range()
  local lines = vim.api.nvim_buf_get_lines(0, first, last + 1, false)
  local line = lines[row - first + 1]
  lines[row - first + 1] = line:sub(1, col) .. '$' .. line:sub(col + 1)
  local ok, parser = pcall(vim.treesitter.get_string_parser, table.concat(lines, '\n'), 'typst')
  if not ok or not parser then
    return false
  end
  -- With the `$` in front of it, the cursor has to be past the closing `$`
  -- being inserted, not at it.
  local closed = parser:parse()[1]:root()
  row = row - first
  local math = ts.ancestor(closed:named_descendant_for_range(row, col, row, col + 1), ts.MATH)
  if not math then
    return false
  end
  local _, _, er, ec = math:range()
  return er == row and ec == col + 1
end

--- Decide whether an entry expands at all.
---
--- A wrapper receives the typed sequence and a function producing the
--- expansion, and returns the text to insert. `entry.wrapper` names one of
--- these, or is a function of the same shape.
---@type table<string, fun(lhs: string, expand: fun(): string): string>
M.wrappers = {
  --- Expand in math, insert the typed keys everywhere else.
  math = function(lhs, expand)
    return M.in_math() and expand() or lhs
  end,
  --- Expand unconditionally.
  trivial = function(_, expand)
    return expand()
  end,
}

--- An rhs that reads one more keystroke and passes it to `fn`.
---
--- With the default list, `@bx` gives `bold(x)`.
---@param fn string
---@return fun(lhs: string): string
function M.style(fn)
  return function(lhs)
    local ok, char = pcall(vim.fn.getcharstr)
    if not ok then
      return lhs
    end
    if char == nil or char == '' or char == ESC then
      -- Aborted with <Esc>; leave the buffer alone.
      return ''
    end
    return fn .. '(' .. char .. ')'
  end
end

--- `text` with a space in front when it would otherwise run into the letter
--- `before` it, and one behind when it would run into the letter `after` it.
---@param text string
---@param before string the character in front of the cursor, or ''
---@param after string the character under the cursor, or ''
---@return string
function M.separate(text, before, after)
  if text:match('^%a') and before:match('^%a') then
    text = ' ' .. text
  end
  if text:match('%w$') and after:match('^%a') then
    text = text .. ' '
  end
  return text
end

--- The full typed sequence of an entry.
---@param entry nvim-typst.Imap
---@return string
function M.lhs(entry)
  return (entry.leader or config.get('imaps', 'leader') or '') .. entry.lhs
end

--- A short description of what an entry inserts, for `:TypstImaps`.
---@param entry nvim-typst.Imap
---@return string
function M.rhs_label(entry)
  if entry.style then
    return entry.style .. '(<char>)'
  end
  if type(entry.rhs) == 'function' then
    return '<function>'
  end
  return tostring(entry.rhs)
end

--- The entries that are actually mapped: the configured list without the
--- disabled ones, plus whatever `M.add` collected.
---@return nvim-typst.Imap[]
function M.entries()
  local opts = config.get('imaps')
  local disabled = {}
  for _, lhs in ipairs(opts.disabled or {}) do
    disabled[lhs] = true
  end

  local out = {}
  for _, list in ipairs({ opts.list or {}, extra }) do
    for _, entry in ipairs(list) do
      if entry.lhs and not disabled[entry.lhs] then
        out[#out + 1] = entry
      end
    end
  end
  return out
end

---@param entry nvim-typst.Imap
---@return fun(lhs: string, expand: fun(): string): string
local function wrapper_of(entry)
  local wrapper = entry.wrapper or 'math'
  if type(wrapper) == 'function' then
    return wrapper
  end
  local known = M.wrappers[wrapper]
  if not known then
    util.warn(("unknown imaps wrapper '%s'"):format(tostring(wrapper)))
    return M.wrappers.math
  end
  return known
end

--- Create the mapping for one entry in `bufnr`.
---@param bufnr integer
---@param entry nvim-typst.Imap
local function create(bufnr, entry)
  if not entry.lhs or not (entry.rhs or entry.style) then
    return
  end

  local lhs = M.lhs(entry)
  local wrapper = wrapper_of(entry)
  local rhs = entry.rhs or M.style(entry.style)
  local expand = function()
    local text = type(rhs) == 'function' and (rhs(lhs) or '') or rhs --[[@as string]]
    -- The leader is still pending, so the line is as it was before it.
    local col = vim.api.nvim_win_get_cursor(0)[2]
    local line = vim.api.nvim_get_current_line()
    return M.separate(text, line:sub(col, col), line:sub(col + 1, col + 1))
  end

  vim.keymap.set('i', (lhs:gsub('<', '<lt>')), function()
    return wrapper(lhs, expand)
  end, {
    buffer = bufnr,
    expr = true,
    -- The expansion is text, not keys: a `<` in it stays a `<`.
    replace_keycodes = false,
    nowait = true,
    silent = true,
    desc = ('nvim-typst: imap %s -> %s'):format(lhs, M.rhs_label(entry)),
  })
end

--- Create the insert mode mappings in `bufnr`.
---@param bufnr integer
function M.attach(bufnr)
  if not config.get('imaps', 'enabled') then
    return
  end
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  attached[bufnr] = true

  for _, entry in ipairs(M.entries()) do
    create(bufnr, entry)
  end
end

--- Register one more map, in every attached buffer and in those to come.
---
--- >lua
---     require('nvim-typst.imaps').add({ lhs = 'oo', rhs = 'compose' })
--- <
---@param entry nvim-typst.Imap
function M.add(entry)
  extra[#extra + 1] = entry
  for bufnr in pairs(attached) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      create(bufnr, entry)
    else
      attached[bufnr] = nil
    end
  end
end

--- Forget what `M.add` registered. For the tests.
function M.reset()
  extra = {}
end

--- Show every mapping in a scratch buffer.
function M.list()
  local entries = M.entries()
  if #entries == 0 then
    util.info('no insert mode mappings')
    return
  end

  local lines = {}
  for _, entry in ipairs(entries) do
    local wrapper = type(entry.wrapper) == 'string' and entry.wrapper or (entry.wrapper and 'custom' or 'math')
    lines[#lines + 1] = ('%-8s ->  %-24s %s'):format(M.lhs(entry), M.rhs_label(entry), wrapper)
  end
  util.scratch('nvim-typst://imaps', lines, { height = math.min(#lines + 1, 20) })
end

return M
