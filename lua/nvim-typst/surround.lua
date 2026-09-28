--- The `ds*` / `cs*` / `ts*` editing mappings plus <F7> and insert-mode `]]`.
---
--- nvim-tex's set, translated: Typst has no environments, starred commands,
--- `\\` line breaks or `\left`/`\right`, so those mappings are gone. What is
--- left works on math (`$…$`), function calls (`#emph[…]`, `frac(a, b)`),
--- delimiters and fractions. Deleting, changing and toggling all go through
--- the tree-sitter node under the cursor, so nesting and line breaks do not
--- throw them off.
local config = require('nvim-typst.config')
local ts = require('nvim-typst.ts')
local util = require('nvim-typst.util')

local M = {}

local ESC = vim.api.nvim_replace_termcodes('<Esc>', true, false, true)

--- Opening delimiter -> closing delimiter.
local CLOSER = { ['('] = ')', ['['] = ']', ['{'] = '}' }

---@param row integer 1-indexed
---@return string
local function line_at(row)
  return vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ''
end

--- Replace a tree-sitter range (0-indexed, end-exclusive) with `text`.
---@param sr integer
---@param sc integer
---@param er integer
---@param ec integer
---@param text string
local function replace(sr, sc, er, ec, text)
  vim.api.nvim_buf_set_text(0, sr, sc, er, ec, vim.split(text, '\n', { plain = true }))
end

---@param sr integer
---@param sc integer
---@param er integer
---@param ec integer
---@return string
local function text_between(sr, sc, er, ec)
  return table.concat(vim.api.nvim_buf_get_text(0, sr, sc, er, ec, {}), '\n')
end

---@param node TSNode
---@return string
local function text_of(node)
  return vim.treesitter.get_node_text(node, 0)
end

--- Ask for input, pre-filled with `default`.
---@param prompt string
---@param default string|nil
---@return string|nil
local function ask(prompt, default)
  local ok, answer = pcall(vim.fn.input, { prompt = prompt, default = default or '' })
  if not ok or answer == nil or vim.trim(answer) == '' then
    return nil
  end
  return vim.trim(answer)
end

--- The syntactic mode at a position: `'markup'`, `'math'` or `'code'`. The
--- nearest enclosing math, content block or embedded code decides.
---@param pos integer[]|nil `{ row (1-indexed), col (0-indexed) }`
---@return string
local function mode_at(pos)
  local node = ts.node_at_cursor(0, pos)
  while node do
    local type = node:type()
    if type == 'math' then
      return 'math'
    elseif type == 'content' or type == 'source_file' then
      return 'markup'
    elseif type == 'code' then
      return 'code'
    end
    node = node:parent()
  end
  return 'markup'
end

-- ---------------------------------------------------------------------------
-- Math
-- ---------------------------------------------------------------------------

--- The innermost math around the cursor, with its body range (the text
--- between the two `$`, spaces included).
---@return TSNode|nil node, integer[]|nil body
local function math_at_cursor()
  local node = ts.ancestor(ts.node_at_cursor(0), ts.MATH)
  if not node then
    return nil
  end
  local open, close = node:child(0), node:child(node:child_count() - 1)
  if not (open and close) or open:id() == close:id() or text_of(close) ~= '$' then
    return nil
  end
  local _, _, osr, osc = open:range()
  local cer, cec = close:range()
  return node, { osr, osc, cer, cec }
end

--- Typst's rule: math is displayed when both `$` are followed/preceded by
--- whitespace.
---@param body string
---@return boolean
local function is_display(body)
  return body:match('^%s') ~= nil and body:match('%s$') ~= nil
end

--- Remove one `$`, taking the whitespace that pads it on the same line along,
--- or its whole line when it stands alone.
---@param row integer 0-indexed
---@param col integer 0-indexed column of the `$`
---@param opening boolean
local function remove_dollar(row, col, opening)
  local line = line_at(row + 1)
  local before, after = line:sub(1, col), line:sub(col + 2)
  if before:match('^%s*$') and after:match('^%s*$') then
    vim.api.nvim_buf_set_lines(0, row, row + 1, false, {})
  elseif opening and not after:match('^%s*$') then
    replace(row, col, row, col + 1 + #after:match('^%s*'), '')
  elseif not opening and not before:match('^%s*$') then
    replace(row, col - #before:match('%s*$'), row, col + 1, '')
  elseif opening then
    replace(row, col - #before:match('%s*$'), row, col + 1, '')
  else
    replace(row, col, row, col + 1 + #after:match('^%s*'), '')
  end
end

function M.math_delete()
  local node, body = math_at_cursor()
  if not (node and body) then
    util.warn('not inside math')
    return
  end
  local sr, sc = node:range()
  -- The closing `$` first, so the opening one stays where it is.
  remove_dollar(body[3], body[4], false)
  remove_dollar(sr, sc, true)
end

--- Rewrite the math around the cursor in one of three layouts: `inline`
--- (`$x$`), `display` (`$ x $`) or `lines` (the `$` on lines of their own).
---@param node TSNode
---@param body integer[]
---@param style string
local function set_math_style(node, body, style)
  local sr, sc, er, ec = node:range()
  local text = vim.trim(text_between(body[1], body[2], body[3], body[4]))

  if style == 'lines' then
    local indent = line_at(sr + 1):match('^%s*')
    local lines = vim.split(text, '\n', { plain = true })
    for i, line in ipairs(lines) do
      -- Continuation lines keep their own indentation.
      lines[i] = i == 1 and (indent .. '  ' .. line) or line
    end
    replace(sr, sc, er, ec, '$\n' .. table.concat(lines, '\n') .. '\n' .. indent .. '$')
    return
  end

  -- Inline and single-line display math join a multi-line body.
  local parts = vim.tbl_map(vim.trim, vim.split(text, '\n', { plain = true }))
  text = table.concat(parts, ' ')
  if style == 'display' then
    replace(sr, sc, er, ec, '$ ' .. text .. ' $')
  else
    replace(sr, sc, er, ec, '$' .. text .. '$')
  end
end

--- The accepted answers to `cs$`, abbreviations included.
local MATH_STYLES = {
  i = 'inline',
  inline = 'inline',
  d = 'display',
  display = 'display',
  l = 'lines',
  lines = 'lines',
}

---@param style string|nil `inline`, `display` or `lines`; prompted for when nil
function M.math_change(style)
  local node, body = math_at_cursor()
  if not (node and body) then
    util.warn('not inside math')
    return
  end
  style = style or ask('Change math to (inline, display, lines): ')
  if not style then
    return
  end
  local target = MATH_STYLES[style]
  if not target then
    util.warn(("unknown math style '%s'"):format(style))
    return
  end
  set_math_style(node, body, target)
end

--- Inline math becomes displayed math, laid out as `edit.display_math` says,
--- and displayed math becomes inline.
function M.math_toggle()
  local node, body = math_at_cursor()
  if not (node and body) then
    util.warn('not inside math')
    return
  end
  if is_display(text_between(body[1], body[2], body[3], body[4])) then
    set_math_style(node, body, 'inline')
  else
    set_math_style(node, body, config.get('edit', 'display_math') or 'lines')
  end
end

-- ---------------------------------------------------------------------------
-- Function calls
-- ---------------------------------------------------------------------------

--- `*strong*` and `_emph_` are markup for `#strong[…]` and `#emph[…]`, so
--- they count as calls here.
local MARKUP_CALL = { strong = true, emph = true }

--- The call around the cursor. In `#text(red)[x]` the parser nests
--- `text(red)` inside the whole call; the whole call is what is returned.
---@return TSNode|nil
local function call_at_cursor()
  local node = ts.ancestor(ts.node_at_cursor(0), function(n)
    return n:type() == 'call' or MARKUP_CALL[n:type()] == true
  end)
  while node and node:type() == 'call' do
    local parent = node:parent()
    if parent and parent:type() == 'call' and parent:child(0):id() == node:id() then
      node = parent
    else
      break
    end
  end
  return node
end

--- The name of a call: an `ident` or a `field` such as `math.equation`.
---@param call TSNode
---@return TSNode
local function callee(call)
  local node = call:child(0)
  while node:type() == 'call' do
    node = node:child(0)
  end
  return node
end

--- The part of a call `dsc` keeps: the content of `[…]`, or the arguments.
---@param call TSNode
---@return integer[] range, boolean bracketed whether it was a `[…]` block
local function call_body(call)
  local function inner(node)
    local first, last = node:child(0), node:child(node:child_count() - 1)
    local _, _, sr, sc = first:range()
    local er, ec = last:range()
    return { sr, sc, er, ec }
  end

  if MARKUP_CALL[call:type()] then
    return inner(call), true
  end

  local last = call:child(call:child_count() - 1)
  if last:type() == 'content' then
    return inner(last), true
  end
  if last:type() == 'group' then
    -- `#f([x])`: a lone content argument is as good as a trailing one.
    local only = last:named_child_count() == 1 and last:named_child(0)
    if only and only:type() == 'content' then
      return inner(only), true
    end
    return inner(last), false
  end
  -- A call in math: `sqrt(x)`, whose parentheses are anonymous children.
  local open = call:child(1)
  local _, _, sr, sc = open:range()
  local er, ec = last:range()
  return { sr, sc, er, ec }, false
end

--- The node a call occupies in the text: `#emph[x]` includes the `#`.
---@param call TSNode
---@return TSNode node, boolean markup whether the call sits in markup
local function call_extent(call)
  local parent = call:parent()
  if parent and parent:type() == 'code' and parent:named_child_count() == 1 then
    return parent, true
  end
  if MARKUP_CALL[call:type()] then
    return call, true
  end
  return call, false
end

function M.cmd_delete()
  local call = call_at_cursor()
  if not call then
    util.warn('no surrounding function call')
    return
  end
  local body, bracketed = call_body(call)
  local extent, markup = call_extent(call)
  local text = text_between(body[1], body[2], body[3], body[4])
  -- Outside markup a content block is a value; unwrapping keeps it one.
  if bracketed and not markup then
    text = '[' .. text .. ']'
  end
  local sr, sc, er, ec = extent:range()
  replace(sr, sc, er, ec, text)
end

---@param new_name string|nil prompted for when nil
function M.cmd_change(new_name)
  local call = call_at_cursor()
  if not call then
    util.warn('no surrounding function call')
    return
  end

  local current = MARKUP_CALL[call:type()] and call:type() or text_of(callee(call))
  new_name = new_name or ask('Change function: ', current)
  if not new_name then
    return
  end
  new_name = new_name:gsub('^#', '')
  if new_name == current then
    return
  end

  if MARKUP_CALL[call:type()] then
    -- `*x*` has no name to rename, so it turns into the call it stands for.
    local body = call_body(call)
    local sr, sc, er, ec = call:range()
    local prefix = mode_at({ sr + 1, sc }) == 'markup' and '#' or ''
    replace(sr, sc, er, ec, prefix .. new_name .. '[' .. text_between(body[1], body[2], body[3], body[4]) .. ']')
    return
  end
  local sr, sc, er, ec = callee(call):range()
  replace(sr, sc, er, ec, new_name)
end

-- ---------------------------------------------------------------------------
-- Fractions
-- ---------------------------------------------------------------------------

---@param node TSNode
---@return boolean
local function is_frac_call(node)
  if node:type() ~= 'call' or node:child_count() < 3 then
    return false
  end
  local open = node:child(1)
  return not open:named() and text_of(node:child(0)) == 'frac'
end

---@param node TSNode
---@return boolean
local function is_fraction(node)
  return node:type() == 'fraction' or is_frac_call(node)
end

--- The text a fraction toggles to.
---@param node TSNode `fraction` or `frac(…)` call
---@return string|nil
local function toggled_fraction(node)
  if node:type() == 'fraction' then
    local parts = {}
    for _, part in ipairs({ node:named_child(0), node:named_child(node:named_child_count() - 1) }) do
      local text = text_of(part)
      -- `(a+b)/2` becomes `frac(a+b, 2)`: the parentheses only grouped.
      if part:type() == 'group' and text:match('^%(.*%)$') then
        text = text:sub(2, -2)
      end
      parts[#parts + 1] = vim.trim(text)
    end
    return ('frac(%s, %s)'):format(parts[1], parts[2])
  end

  local args = {}
  for child in node:iter_children() do
    if child:named() and child:type() == 'formula' then
      local text = text_of(child)
      -- A compound argument needs parentheses to stay one operand of `/`.
      if child:named_child_count() > 1 then
        text = '(' .. text .. ')'
      end
      args[#args + 1] = text
    end
  end
  if #args ~= 2 then
    return nil
  end
  return args[1] .. '/' .. args[2]
end

--- `a/b` <-> `frac(a, b)`.
---@param visual boolean|nil every fraction in the visual selection
function M.toggle_fraction(visual)
  local nodes = {}
  if visual then
    vim.cmd('normal! ' .. ESC)
    local srow, scol = vim.fn.line("'<") - 1, vim.fn.col("'<") - 1
    local erow, ecol = vim.fn.line("'>") - 1, vim.fn.col("'>")
    if vim.fn.visualmode() == 'V' then
      scol, ecol = 0, math.huge
    end
    local function inside(node)
      local sr, sc, er, ec = node:range()
      return (sr > srow or (sr == srow and sc >= scol)) and (er < erow or (er == erow and ec <= ecol))
    end
    local function walk(node)
      if is_fraction(node) and inside(node) then
        nodes[#nodes + 1] = node
        return
      end
      for child in node:iter_children() do
        if child:named() then
          walk(child)
        end
      end
    end
    local root = ts.root(0)
    if root then
      walk(root)
    end
  else
    nodes[1] = ts.ancestor(ts.node_at_cursor(0), is_fraction)
  end

  if #nodes == 0 then
    util.warn('no fraction found')
    return
  end

  -- Work out every replacement first, then apply them back to front so the
  -- earlier ranges stay valid.
  local edits = {}
  for _, node in ipairs(nodes) do
    local text = toggled_fraction(node)
    if text then
      local sr, sc, er, ec = node:range()
      edits[#edits + 1] = { sr, sc, er, ec, text }
    end
  end
  for i = #edits, 1, -1 do
    replace(unpack(edits[i]))
  end
end

-- ---------------------------------------------------------------------------
-- Delimiters
-- ---------------------------------------------------------------------------

--- A node whose first and last children are a matching pair of brackets
--- that can go without breaking the syntax: not the argument list or
--- content block of a call (`#f(x)`, `#emph[x]`), not `#(…)` / `#[…]`.
---@param node TSNode
---@return boolean
local function is_delimited(node)
  local count = node:child_count()
  if count < 2 then
    return false
  end
  local first, last = node:child(0), node:child(count - 1)
  if first:named() or last:named() then
    return false
  end
  local closer = CLOSER[text_of(first)]
  if not closer or text_of(last) ~= closer then
    return false
  end
  local parent = node:parent()
  return not (parent and (parent:type() == 'call' or parent:type() == 'code'))
end

--- The delimited node around the cursor, with its two bracket nodes.
---@return TSNode|nil node, TSNode|nil open, TSNode|nil close
local function find_delims()
  local node = ts.ancestor(ts.node_at_cursor(0), is_delimited)
  if not node then
    return nil
  end
  return node, node:child(0), node:child(node:child_count() - 1)
end

function M.delim_delete()
  local node, open, close = find_delims()
  if not (node and open and close) then
    util.warn('no surrounding delimiter')
    return
  end
  -- Closing side first, so the opening range stays valid.
  local sr, sc, er, ec = close:range()
  replace(sr, sc, er, ec, '')
  sr, sc, er, ec = open:range()
  replace(sr, sc, er, ec, '')
end

---@param answer string|nil a key of `edit.delim_list`; prompted for when nil
function M.delim_change(answer)
  local node, open, close = find_delims()
  if not (node and open and close) then
    util.warn('no surrounding delimiter')
    return
  end
  answer = answer or ask('Change delimiter to: ')
  if not answer then
    return
  end
  local pair = (config.get('edit', 'delim_list') or {})[answer]
  if not pair then
    util.warn(("unknown delimiter '%s'"):format(answer))
    return
  end
  local sr, sc, er, ec = close:range()
  replace(sr, sc, er, ec, pair[2])
  sr, sc, er, ec = open:range()
  replace(sr, sc, er, ec, pair[1])
end

--- Typst's counterpart of `\left…\right`: wrap the delimiters around the
--- cursor in `lr(…)`, or unwrap them again.
function M.delim_toggle_lr()
  local node = find_delims()
  if not node or not ts.ancestor(node, ts.MATH) then
    util.warn('no surrounding delimiter in math')
    return
  end

  -- `lr((x))` parses as a call whose only argument is the group.
  local formula = node:parent()
  local call = formula and formula:parent()
  if
    formula
    and call
    and formula:type() == 'formula'
    and formula:named_child_count() == 1
    and call:type() == 'call'
    and text_of(call:child(0)) == 'lr'
  then
    local sr, sc, er, ec = call:range()
    replace(sr, sc, er, ec, text_of(node))
    return
  end
  local sr, sc, er, ec = node:range()
  replace(sr, sc, er, ec, 'lr(' .. text_of(node) .. ')')
end

-- ---------------------------------------------------------------------------
-- Creating calls
-- ---------------------------------------------------------------------------

--- A word, for <F7>: letters, digits, underscores and anything non-ASCII.
local WORD = '[%w_\128-\255]+'

--- Wrap `text` in a call suited to the mode it sits in: `#name[text]` in
--- markup, `name(text)` in math and code.
---@param mode string
---@param name string
---@return string opening, string closing
local function call_wrapper(mode, name)
  if mode == 'markup' then
    return '#' .. name .. '[', ']'
  end
  return name .. '(', ')'
end

--- Normal/visual mode: wrap the word or the selection in a call.
---@param visual boolean|nil
---@param name string|nil prompted for when nil
function M.cmd_create(visual, name)
  local srow, scol, erow, ecol
  if visual then
    vim.cmd('normal! ' .. ESC)
    srow, scol = vim.fn.line("'<"), vim.fn.col("'<") - 1
    erow, ecol = vim.fn.line("'>"), vim.fn.col("'>")
    if vim.fn.visualmode() == 'V' then
      scol = #(line_at(srow):match('^%s*'))
      ecol = #line_at(erow)
    else
      -- `'>` is the first byte of the last character.
      local rest = line_at(erow):sub(ecol)
      ecol = ecol - 1 + #(rest:match('^[%z\1-\127\194-\244][\128-\191]*') or ' ')
    end
  else
    local row, col = unpack(vim.api.nvim_win_get_cursor(0))
    local line = line_at(row)
    local s, e = line:find(WORD)
    while s and not (col >= s - 1 and col < e) do
      s, e = line:find(WORD, e + 1)
    end
    if not s then
      util.warn('no word under the cursor')
      return
    end
    srow, scol, erow, ecol = row, s - 1, row, e
  end

  name = name or ask('Function: ')
  if not name then
    return
  end
  local opening, closing = call_wrapper(mode_at({ srow, scol }), (name:gsub('^#', '')))
  vim.api.nvim_buf_set_text(0, erow - 1, ecol, erow - 1, ecol, { closing })
  vim.api.nvim_buf_set_text(0, srow - 1, scol, srow - 1, scol, { opening })
end

--- Insert mode: turn the word before the cursor into a call, `#word[|]` in
--- markup and `word(|)` in math and code.
function M.cmd_create_insert()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local before = line_at(row):sub(1, col)
  local start = before:find('[%a_][%w_%-]*$')
  if not start then
    return
  end
  local word = before:sub(start)
  local opening, closing = call_wrapper(mode_at({ row, start - 1 }), word)
  vim.api.nvim_buf_set_text(0, row - 1, start - 1, row - 1, col, { opening .. closing })
  vim.api.nvim_win_set_cursor(0, { row, start - 1 + #opening })
end

-- ---------------------------------------------------------------------------
-- Closing delimiters
-- ---------------------------------------------------------------------------

--- The brackets and `$` still open at the end of `text`, innermost last.
---
--- The parse tree of a half-typed document is unreliable, so this scans the
--- text instead, tracking markup, math and code the way Typst does: in markup
--- only brackets that belong to embedded code (`#f(`, `#emph[`, `#{`) count,
--- so prose like "(see above" does not; strings, raw text, comments and
--- escapes are skipped.
---@param text string
---@return table[] `{ char, mode, display }` entries
function M.open_delims(text)
  local stack = {}
  local n = #text
  local i = 1
  -- Position right after embedded code, where a `(` or `[` continues it.
  local attach = nil

  local function mode()
    local top = stack[#stack]
    return top and top.mode or 'markup'
  end

  --- A bracket opens code, except `[`, which opens content, and plain
  --- brackets in math, which stay math.
  ---@param char string
  ---@param call boolean part of embedded code, `#f(` or `#emph[`
  local function push(char, call)
    local inner = char == '[' and 'markup' or 'code'
    if mode() == 'math' and not call then
      inner = 'math'
    end
    stack[#stack + 1] = { char = char, mode = inner, call = call }
  end

  while i <= n do
    local c = text:sub(i, i)
    local m = mode()
    local attached = attach == i
    attach = nil

    if text:sub(i, i + 1) == '//' and not (m == 'markup' and text:sub(i - 1, i - 1) == ':') then
      i = (text:find('\n', i, true) or n) + 1
    elseif text:sub(i, i + 1) == '/*' then
      local _, e = text:find('*/', i + 2, true)
      if not e then
        return stack
      end
      i = e + 1
    elseif c == '\\' and m ~= 'code' then
      i = i + 2
    elseif c == '"' and m ~= 'markup' then
      local j = i + 1
      while j <= n and text:sub(j, j) ~= '"' do
        j = j + (text:sub(j, j) == '\\' and 2 or 1)
      end
      i = j + 1
    elseif c == '`' then
      local ticks = text:match('^`+', i)
      if #ticks == 2 then
        i = i + 2
      else
        local _, e = text:find(ticks, i + #ticks, true)
        if not e then
          -- Inside raw text nothing is open.
          return {}
        end
        i = e + 1
      end
    elseif c == '$' then
      if m == 'math' then
        while #stack > 0 do
          local top = table.remove(stack)
          if top.char == '$' then
            break
          end
        end
      else
        stack[#stack + 1] = { char = '$', mode = 'math', display = text:sub(i + 1, i + 1):match('%s') ~= nil }
      end
      i = i + 1
    elseif c == '#' and m ~= 'code' then
      -- `#name`, `#a.b.c`: embedded code a bracket may follow.
      local j = i + 1
      local ident = text:match('^[%a_][%w_%-]*', j)
      while ident do
        j = j + #ident
        ident = text:sub(j, j) == '.' and text:match('^[%a_][%w_%-]*', j + 1) or nil
        if ident then
          j = j + 1
        end
      end
      attach = j
      i = j
    elseif CLOSER[c] then
      if m ~= 'markup' or attached then
        push(c, attached)
      end
      i = i + 1
    elseif c == ')' or c == ']' or c == '}' then
      local top = stack[#stack]
      if top and CLOSER[top.char] == c then
        table.remove(stack)
        -- `#text(red)[x]`, `#box[y](z)`: a call continues with brackets.
        if top.call then
          attach = i + 1
        end
      end
      i = i + 1
    else
      i = i + 1
    end
  end
  return stack
end

--- Insert mode `]]`: close the innermost open bracket or math.
function M.delim_close()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local lines = vim.api.nvim_buf_get_lines(0, 0, row, false)
  lines[#lines] = lines[#lines]:sub(1, col)
  local stack = M.open_delims(table.concat(lines, '\n'))

  local top = stack[#stack]
  if not top then
    return
  end
  local closer = CLOSER[top.char] or '$'
  if top.char == '$' and top.display and not lines[#lines]:match('%s$') then
    closer = ' $'
  end
  vim.api.nvim_buf_set_text(0, row - 1, col, row - 1, col, { closer })
  vim.api.nvim_win_set_cursor(0, { row, col + #closer })
end

return M
