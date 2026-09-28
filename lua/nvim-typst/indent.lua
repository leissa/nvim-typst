--- Typst-aware indentation (`indentexpr`).
---
--- The contents of a multi-line `( ... )`, `[ ... ]`, `{ ... }` and
--- `$ ... $` are indented by one level, and a line starting with the closing
--- delimiter lines up with the line that opened it. In a list, a nested item
--- and the lines continuing an item sit one level into the item; raw blocks,
--- block comments and multi-line strings are left alone.
---
--- Which characters are delimiters is read off the parse tree, so a bracket
--- in markup text, a string or a comment is never mistaken for one. As in
--- nvim-tex, the tree is not trusted for structure while it is incomplete:
--- right after `o` on `#figure(`, there is no `)` yet and the parser only
--- has an ERROR node. What survives in that ERROR node is the tokens. The
--- indent of a line is therefore worked out from the previous line: its
--- indent, plus the delimiters that line leaves open. Only a line that
--- starts with a closing delimiter, or that belongs to a list item, is
--- aligned to its opening line directly, when the tree has it.
---
--- List items are different from delimiters in that the indentation is what
--- makes the structure: a line indented under `- item` continues the item,
--- one that is not ends it. Their rules therefore take the tree as it is,
--- and so leave the meaning of a document unchanged.
local ts = require('nvim-typst.ts')

local M = {}

local OPEN = { ['('] = true, ['['] = true, ['{'] = true }
local CLOSE = { [')'] = true, [']'] = true, ['}'] = true }

--- `- item`, `+ item` and `/ Term: description`.
local ITEM = { item = true, term = true }

--- Nodes whose inner lines are not Typst and keep their indentation.
local VERBATIM = { raw_blck = true, string = true }

--- Run `fn` with `bufnr` as the current buffer. `indentexpr` already runs in
--- it, so the switch is only paid for when called from elsewhere.
---@param bufnr integer
---@param fn function
---@return any
local function in_buf(bufnr, fn)
  if bufnr == vim.api.nvim_get_current_buf() then
    return fn()
  end
  return vim.api.nvim_buf_call(bufnr, fn)
end

--- Is `node` delimited by brackets or dollars? The `content` of a section
--- is its body and has none.
---@param node TSNode
---@return boolean
local function delimited(node)
  local t = node:type()
  if t == 'group' or t == 'block' or t == 'math' then
    return true
  end
  if t == 'content' then
    local first = node:child(0)
    return first ~= nil and first:type() == '['
  end
  return false
end

--- What a token does to the indentation: `'open'`, `'close'` or nil, and
--- the node that spans from the opening to the closing delimiter, which is
--- where a closing line aligns to.
---@param node TSNode|nil a leaf
---@return string|nil kind, TSNode|nil anchor
local function classify(node)
  if not node then
    return nil, nil
  end
  local t = node:type()
  local parent = node:parent()
  if OPEN[t] then
    return 'open', parent
  elseif CLOSE[t] then
    return 'close', parent
  elseif t == '$' and parent then
    if parent:type() == 'math' and parent:child(0) ~= node then
      return 'close', parent
    end
    return 'open', parent
  end
  return nil, nil
end

--- The leaves of the parse tree that start on `row`, in document order.
---@param root TSNode
---@param row integer 0-indexed
---@param width integer length of the line
---@return TSNode[]
local function tokens(root, row, width)
  local out = {}
  local function walk(node)
    local sr, _, er, ec = node:range()
    if sr > row or er < row or (er == row and ec == 0 and sr < row) then
      return
    end
    if node:child_count() == 0 then
      if sr == row and not node:missing() then
        out[#out + 1] = node
      end
      return
    end
    for child in node:iter_children() do
      walk(child)
    end
  end
  walk(root:descendant_for_range(row, 0, row, width) or root)
  return out
end

--- How many levels the tokens of one line leave open, up to (not including)
--- the byte offset `stop`. Closing delimiters at the start of the line are
--- skipped: they were already taken into account for the line's own indent.
---@param list TSNode[]
---@param stop integer|nil
---@return integer
local function open_levels(list, stop)
  local levels = 0
  local leading = true
  for _, token in ipairs(list) do
    if stop and select(3, token:start()) >= stop then
      break
    end
    local kind = classify(token)
    if kind == 'open' then
      levels = levels + 1
    elseif kind == 'close' and not leading then
      levels = levels - 1
    end
    leading = leading and kind == 'close'
  end
  return levels
end

--- The closest list item above `node` (exclusive), not looking past a
--- delimited node: the lines of a `#figure(...)` in an item follow the
--- parentheses, not the item.
---@param node TSNode
---@return TSNode|nil
local function enclosing_item(node)
  local current = node:parent()
  while current do
    if ITEM[current:type()] then
      return current
    elseif delimited(current) then
      return nil
    end
    current = current:parent()
  end
  return nil
end

---@param bufnr integer
---@param row integer 0-indexed
---@return string
local function line_at(bufnr, row)
  return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
end

---@param bufnr integer
---@param row integer 0-indexed
---@return integer
local function indent_of(bufnr, row)
  return in_buf(bufnr, function()
    return vim.fn.indent(row + 1)
  end)
end

--- Does `node` cover `row`?
---@param node TSNode
---@param row integer
---@return boolean
local function covers(node, row)
  local srow, _, erow, ecol = node:range()
  return srow <= row and (row < erow or (row == erow and ecol > 0))
end

--- The indent for line `lnum` of `bufnr`, or -1 to keep the current one.
---@param lnum integer 1-indexed
---@param bufnr integer|nil
---@return integer
function M.get(lnum, bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local root = ts.root(bufnr)
  if not root then
    return -1
  end

  local sw = in_buf(bufnr, vim.fn.shiftwidth)
  local row = lnum - 1
  local line = line_at(bufnr, row)
  local first = line:find('%S')
  local col = first and first - 1 or 0

  local node = root:descendant_for_range(row, col, row, col)

  -- Inside a raw block, a string or a block comment, the text is not ours
  -- to move. The closing fence of a raw block lines up with the opening one.
  local verbatim = ts.ancestor(node, function(n)
    return VERBATIM[n:type()] == true or (n:type() == 'comment' and n:start() < n:end_())
  end)
  if verbatim then
    local srow, _, erow = verbatim:range()
    if row > srow and row < erow then
      return -1
    elseif row > srow and row == erow then
      return verbatim:type() == 'raw_blck' and line:match('^%s*```') and indent_of(bufnr, srow) or -1
    end
  end

  local lead
  if first then
    local own = tokens(root, row, #line)
    if own[1] and select(2, own[1]:start()) == col then
      lead = own[1]
    end
  end
  local lead_kind, anchor = classify(lead)

  -- A closing delimiter lines up with the line that opened it, plus what
  -- that line had already opened before: the `]` of `#box(width: 1cm)[`
  -- belongs inside the parentheses only if they are still open.
  if lead_kind == 'close' and anchor and anchor:type() ~= 'ERROR' then
    local arow, _, abyte = anchor:start()
    if arow < row then
      local before = open_levels(tokens(root, arow, #line_at(bufnr, arow)), abyte)
      return indent_of(bufnr, arow) + math.max(0, before) * sw
    end
  end

  if first and node then
    -- The line of a nested item, or one that continues an item.
    local lead_parent = lead and lead:parent()
    local lead_item = lead_parent and ITEM[lead_parent:type()] and lead_parent:child(0) == lead and lead_parent or nil
    local item = enclosing_item(lead_item or node)
    if item and item:start() < row then
      return indent_of(bufnr, item:start()) + sw
    end
    -- An item after another lines up with it.
    local prev = lead_item and lead_item:prev_named_sibling()
    if prev and ITEM[prev:type()] then
      return indent_of(bufnr, prev:start())
    end
  end

  local prow = in_buf(bufnr, function()
    return vim.fn.prevnonblank(lnum - 1)
  end) - 1
  if prow < 0 then
    return 0
  end

  local prev_tokens = tokens(root, prow, #line_at(bufnr, prow))
  local levels = open_levels(prev_tokens)
  if lead_kind == 'close' then
    levels = levels - 1
  end

  -- A line after a list item that does not continue it: the indent is that
  -- of the item, not of its last continuation line. An empty line right
  -- below the item (`o`) stays with the innermost item, to start the next
  -- one; any other line, or one after a blank line, leaves the whole list.
  local base = indent_of(bufnr, prow)
  local ptoken = prev_tokens[1]
  if ptoken then
    local current = ptoken
    while current do
      if ITEM[current:type()] then
        if covers(current, row) then
          break
        end
        base = indent_of(bufnr, current:start())
        if not first and prow == row - 1 then
          break
        end
      elseif delimited(current) and covers(current, row) then
        break
      end
      current = current:parent()
    end
  end

  return math.max(0, base + levels * sw)
end

--- Entry point for `indentexpr`.
---@return integer
function M.indentexpr()
  return M.get(vim.v.lnum, vim.api.nvim_get_current_buf())
end

--- Keys that reindent the current line: the usual new-line triggers and a
--- closing delimiter at the start of the line.
M.INDENTKEYS = '!^F,o,O,0),0],0},0$'

--- Install `indentexpr` for `bufnr`, replacing `indent/typst.vim`'s.
---@param bufnr integer
function M.attach(bufnr)
  vim.bo[bufnr].indentexpr = "v:lua.require'nvim-typst.indent'.indentexpr()"
  vim.bo[bufnr].indentkeys = M.INDENTKEYS
  vim.bo[bufnr].autoindent = true
  vim.bo[bufnr].smartindent = false
  vim.bo[bufnr].cindent = false
end

return M
