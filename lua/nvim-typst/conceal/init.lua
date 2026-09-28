--- Conceal, the tree-sitter way: `alpha` in math shows as α, `arrow.r` as →,
--- `->` as →, `x^2` as x², `bb(R)` as ℝ, `#sym.arrow.r` as →, `---` as —,
--- and `*bold*` as bold text without the stars.
---
--- The replacements are ephemeral extmarks set by a decoration provider for
--- the lines being drawn, so nothing is stored in the buffer and they work
--- the same under tree-sitter highlighting and under `syntax/typst.vim`.
--- They only show with 'conceallevel' at 1 or more, like any conceal; with
--- it at 0 the provider does no work at all.
---
--- What a piece of text is -- a math identifier, an attachment, a shorthand
--- -- is read off the parse tree, so `alpha` in running text, in a string or
--- in a comment is left as it is.
local config = require('nvim-typst.config')
local symbols = require('nvim-typst.conceal.symbols')
local ts = require('nvim-typst.ts')

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace('nvim-typst-conceal')

--- Buffers conceal is enabled for.
---@type table<integer, boolean>
local attached = {}

--- winid -> `{ bufnr, tick, top, bot, rows }`, the items of the range last
--- drawn in that window. Per window, so that two views of one buffer do not
--- keep evicting each other.
---@type table<integer, table>
local cache = {}

local EMPTY = {}

local QUERY = [[
(ident) @ident
(field) @field
(shorthand) @shorthand
(attach) @attach
(call) @call
(code) @code
(strong) @strong
(emph) @emph
(escape) @escape
(item) @item
]]

--- Math shorthands, as Typst renders them. A few (`|=>`, `<~`, `||`) are
--- not recognised by the parser and so never reach this table.
local MATH_SHORTHANDS = {
  ['->'] = '→',
  ['-->'] = '⟶',
  ['->>'] = '↠',
  ['<-'] = '←',
  ['<--'] = '⟵',
  ['<<-'] = '↞',
  ['<->'] = '↔',
  ['<-->'] = '⟷',
  ['=>'] = '⇒',
  ['==>'] = '⟹',
  ['<='] = '≤',
  ['<=='] = '⟸',
  ['<=>'] = '⇔',
  ['<==>'] = '⟺',
  ['|->'] = '↦',
  ['|=>'] = '⤇',
  ['>->'] = '↣',
  ['<-<'] = '↢',
  ['~>'] = '⇝',
  ['~~>'] = '⟿',
  ['<~'] = '⇜',
  ['<~~'] = '⬳',
  ['!='] = '≠',
  ['>='] = '≥',
  ['<<'] = '≪',
  ['>>'] = '≫',
  ['<<<'] = '⋘',
  ['>>>'] = '⋙',
  [':='] = '≔',
  ['::='] = '⩴',
  ['=:'] = '≕',
  ['...'] = '…',
  ['[|'] = '⟦',
  ['|]'] = '⟧',
  ['||'] = '‖',
}

--- Markup shorthands. `~` (no-break space) and `-?` (soft hyphen) are left
--- visible: concealed, they would look like the plain characters they are
--- there to differ from.
local TEXT_SHORTHANDS = {
  ['--'] = '–',
  ['---'] = '—',
  ['...'] = '…',
}

--- Math spacing, in `$a quad b$`.
local SPACING = {
  thin = ' ',
  med = ' ',
  thick = ' ',
  quad = ' ',
  wide = ' ',
}

--- `#strong[...]` and friends.
local STYLES = {
  strong = 'NvimTypstBold',
  emph = 'NvimTypstItalic',
  underline = 'NvimTypstUnderline',
}

local query
---@return vim.treesitter.Query
local function get_query()
  query = query or vim.treesitter.query.parse('typst', QUERY)
  return query
end

--- One replacement: `text` stands in for the range, or `hl` colours it.
---@class NvimTypstConceal
---@field col integer
---@field end_col integer
---@field text string|nil
---@field hl string|nil

---@param items table<integer, NvimTypstConceal[]>
---@param row integer
---@param col integer
---@param end_col integer
---@param text string|nil
---@param hl string|nil
local function add(items, row, col, end_col, text, hl)
  items[row] = items[row] or {}
  table.insert(items[row], { col = col, end_col = end_col, text = text, hl = hl })
end

--- Is `node` math, as opposed to markup or code? The nearest enclosing
--- `math` or `code` decides: `alpha` in `$#f(alpha)$` is a variable.
---@param node TSNode
---@return boolean
local function in_math(node)
  local parent = node:parent()
  while parent do
    local t = parent:type()
    if t == 'math' then
      return true
    elseif t == 'code' then
      return false
    end
    parent = parent:parent()
  end
  return false
end

---@param node TSNode
---@return boolean
local function single_line(node)
  local row, _, erow = node:range()
  return row == erow
end

--- The replacement for the math name `name` (`alpha`, `arrow.r`,
--- `sym.arrow.r`), if any.
---@param opts table
---@param name string
---@return string|nil
local function math_name(opts, name)
  if opts.custom and opts.custom[name] then
    return opts.custom[name]
  end
  name = name:gsub('^sym%.', '')
  return (opts.greek and symbols.greek[name]) or (opts.math_symbols and symbols.math[name]) or nil
end

--- `alpha`, `RR`, `quad`, and `phi.alt`, `arrow.r.long` as a whole.
---@param opts table
---@param items table
---@param node TSNode
---@param bufnr integer
local function name(opts, items, node, bufnr)
  local parent = node:parent()
  -- The parts of `phi.alt` are handled with the whole, the `bb` of `bb(R)`
  -- is a function.
  if parent and (parent:type() == 'field' or (parent:type() == 'call' and parent:named_child(0) == node)) then
    return
  end
  if not single_line(node) or not in_math(node) then
    return
  end
  local text = vim.treesitter.get_node_text(node, bufnr)
  local char = math_name(opts, text)
  if not char and opts.spacing then
    char = SPACING[text]
  end
  if char then
    local row, col, _, ecol = node:range()
    add(items, row, col, ecol, char)
  end
end

---@param opts table
---@param items table
---@param node TSNode
---@param bufnr integer
local function shorthand(opts, items, node, bufnr)
  local text = vim.treesitter.get_node_text(node, bufnr)
  local char
  if in_math(node) then
    char = opts.math_symbols and MATH_SHORTHANDS[text]
  else
    char = opts.text_symbols and TEXT_SHORTHANDS[text]
  end
  if char then
    local row, col, _, ecol = node:range()
    add(items, row, col, ecol, char)
  end
end

--- What a script may be made of. `x^ab` is not x to the power of a and b
--- but of the variable `ab`, an `ident`.
local SCRIPT_ATOMS = { number = true, letter = true, symbol = true }

--- `x^2`, `x_1`, `x^(n+1)`: every script whose characters all have a
--- super- or subscript form.
---@param opts table
---@param items table
---@param node TSNode
---@param bufnr integer
local function attach(opts, items, node, bufnr)
  if not opts.math_super_sub or not in_math(node) then
    return
  end
  for i = 0, node:child_count() - 2 do
    local op = node:child(i)
    local map = op:type() == '^' and symbols.superscript or op:type() == '_' and symbols.subscript or nil
    local script = node:child(i + 1)
    if map and script and single_line(script) then
      local row, col = op:start()
      local srow, scol, _, ecol = script:range()
      local text = vim.treesitter.get_node_text(script, bufnr)
      local chars, first = text, scol
      local simple = SCRIPT_ATOMS[script:type()]
      if script:type() == 'group' then
        chars, first = text:match('^%((.*)%)$'), scol + 1
        local formula = script:named_child(0)
        simple = formula ~= nil and formula:type() == 'formula'
        for k = 0, simple and formula:named_child_count() - 1 or -1 do
          simple = simple and SCRIPT_ATOMS[formula:named_child(k):type()] or false
        end
      end
      local ok = simple and srow == row and chars and chars ~= ''
      for k = 1, ok and #chars or 0 do
        ok = ok and map[chars:sub(k, k)] ~= nil
      end
      if ok then
        -- The operator (and the opening paren) goes with the first
        -- character, the closing paren with the last.
        for k = 1, #chars do
          local from = k == 1 and col or first + k - 1
          local to = k == #chars and ecol or first + k
          add(items, row, from, to, map[chars:sub(k, k)])
        end
      end
    end
  end
end

--- `bb(R)` as ℝ, `cal(A)` as 𝒜.
---@param opts table
---@param items table
---@param node TSNode
---@param bufnr integer
local function math_call(opts, items, node, bufnr)
  if not opts.math_fonts or not single_line(node) or not in_math(node) then
    return
  end
  local fn, letter = vim.treesitter.get_node_text(node, bufnr):match('^(%a+)%((%w)%)$')
  local font = fn and symbols.fonts[fn]
  if font and font[letter] then
    local row, col, _, ecol = node:range()
    add(items, row, col, ecol, font[letter])
  end
end

--- The markers of a styled range are hidden and what is between them is
--- highlighted, one line at a time: an extmark is set for the line being
--- drawn, and a multi-line one starting above the window would be missed.
---@param items table
---@param bufnr integer
---@param open integer[] `{ row, col, end_col }` of the opening marker
---@param close integer[] `{ row, col, end_col }` of the closing marker
---@param hl string
local function styled(items, bufnr, open, close, hl)
  add(items, open[1], open[2], open[3], '')
  add(items, close[1], close[2], close[3], '')
  for r = open[1], close[1] do
    local line = api.nvim_buf_get_lines(bufnr, r, r + 1, false)[1] or ''
    local from = r == open[1] and open[3] or 0
    local to = r == close[1] and close[2] or #line
    if to > from then
      add(items, r, from, to, nil, hl)
    end
  end
end

--- `*bold*` and `_emph_`.
---@param opts table
---@param items table
---@param node TSNode
---@param bufnr integer
---@param hl string
local function markup_style(opts, items, node, bufnr, hl)
  if not opts.styles then
    return
  end
  local first, last = node:child(0), node:child(node:child_count() - 1)
  if not first or first == last or first:named() or last:named() or first:type() ~= last:type() then
    return
  end
  local r1, c1, _, e1 = first:range()
  local r2, c2, _, e2 = last:range()
  styled(items, bufnr, { r1, c1, e1 }, { r2, c2, e2 }, hl)
end

--- `#sym.arrow.r` as →, `#strong[text]` as bold text, and the markup
--- counterpart of a `custom` entry, `#name`.
---@param opts table
---@param items table
---@param node TSNode
---@param bufnr integer
local function code(opts, items, node, bufnr)
  local expr = node:named_child(0)
  if not expr then
    return
  end
  local row, col, erow, ecol = node:range()
  local kind = expr:type()

  if (kind == 'field' or kind == 'ident') and erow == row then
    local text = vim.treesitter.get_node_text(expr, bufnr)
    local char = opts.custom and opts.custom[text]
    if not char and opts.sym and kind == 'field' and text:match('^sym%.') then
      char = symbols.greek[text:sub(5)] or symbols.math[text:sub(5)]
    end
    if char then
      add(items, row, col, ecol, char)
    end
    return
  end

  if kind ~= 'call' or not opts.styles then
    return
  end
  local fn, body = expr:named_child(0), expr:named_child(1)
  local hl = fn and fn:type() == 'ident' and STYLES[vim.treesitter.get_node_text(fn, bufnr)]
  if not hl or not body or body:type() ~= 'content' or expr:named_child_count() ~= 2 then
    return
  end
  local brow, bcol, berow, becol = body:range()
  if brow ~= row then
    return
  end
  styled(items, bufnr, { row, col, bcol + 1 }, { berow, becol - 1, becol }, hl)
end

--- `\#` as #, `\u{1F600}` as the character it names.
---@param opts table
---@param items table
---@param node TSNode
---@param bufnr integer
local function escape(opts, items, node, bufnr)
  if not opts.escapes or not single_line(node) then
    return
  end
  local text = vim.treesitter.get_node_text(node, bufnr)
  local hex = text:match('^\\u{(%x+)}$')
  local char
  if hex then
    local nr = tonumber(hex, 16)
    char = nr and nr > 0x20 and nr <= 0x10FFFF and vim.fn.nr2char(nr) or nil
  elseif #text == 2 then
    char = text:sub(2)
  end
  if char then
    local row, col, _, ecol = node:range()
    add(items, row, col, ecol, char)
  end
end

--- The `-` of a bullet list item as •.
---@param opts table
---@param items table
---@param node TSNode
---@param bufnr integer
local function item(opts, items, node, bufnr)
  local marker = node:child(0)
  if opts.item and marker and not marker:named() and vim.treesitter.get_node_text(marker, bufnr) == '-' then
    local row, col, _, ecol = marker:range()
    add(items, row, col, ecol, '•')
  end
end

--- The replacements for rows `top` to `bot` (0-indexed, end exclusive).
---@param bufnr integer
---@param top integer
---@param bot integer
---@return table<integer, NvimTypstConceal[]> rows
function M.items(bufnr, top, bot)
  local items = {}
  local root = ts.root(bufnr)
  if not root then
    return items
  end
  local opts = config.get('conceal') or {}
  local q = get_query()
  for id, node in q:iter_captures(root, bufnr, top, bot) do
    local capture = q.captures[id]
    if capture == 'ident' or capture == 'field' then
      name(opts, items, node, bufnr)
    elseif capture == 'shorthand' then
      shorthand(opts, items, node, bufnr)
    elseif capture == 'attach' then
      attach(opts, items, node, bufnr)
    elseif capture == 'call' then
      math_call(opts, items, node, bufnr)
    elseif capture == 'code' then
      code(opts, items, node, bufnr)
    elseif capture == 'strong' then
      markup_style(opts, items, node, bufnr, 'NvimTypstBold')
    elseif capture == 'emph' then
      markup_style(opts, items, node, bufnr, 'NvimTypstItalic')
    elseif capture == 'escape' then
      escape(opts, items, node, bufnr)
    elseif capture == 'item' then
      item(opts, items, node, bufnr)
    end
  end
  return items
end

local function define_highlights()
  api.nvim_set_hl(0, 'NvimTypstBold', { default = true, link = '@markup.strong' })
  api.nvim_set_hl(0, 'NvimTypstItalic', { default = true, link = '@markup.italic' })
  api.nvim_set_hl(0, 'NvimTypstUnderline', { default = true, link = '@markup.underline' })
end

local provider_set = false

local function set_provider()
  if provider_set then
    return
  end
  provider_set = true
  define_highlights()
  local group = api.nvim_create_augroup('nvim-typst-conceal', { clear = true })
  api.nvim_create_autocmd('ColorScheme', { group = group, callback = define_highlights })
  api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
      cache[tonumber(args.match)] = nil
    end,
  })

  api.nvim_set_decoration_provider(ns, {
    on_win = function(_, win, bufnr, top, bot)
      if not attached[bufnr] or vim.wo[win].conceallevel == 0 then
        return false
      end
      local tick = api.nvim_buf_get_changedtick(bufnr)
      local cached = cache[win]
      if not (cached and cached.bufnr == bufnr and cached.tick == tick and cached.top <= top and cached.bot > bot) then
        local ok, rows = pcall(M.items, bufnr, top, bot + 1)
        cache[win] = { bufnr = bufnr, tick = tick, top = top, bot = bot + 1, rows = ok and rows or EMPTY }
      end
    end,
    on_line = function(_, win, bufnr, row)
      local cached = cache[win]
      for _, entry in ipairs(cached and cached.rows[row] or EMPTY) do
        pcall(api.nvim_buf_set_extmark, bufnr, ns, row, entry.col, {
          end_row = row,
          end_col = entry.end_col,
          conceal = entry.text,
          hl_group = entry.hl,
          ephemeral = true,
          priority = 110,
        })
      end
    end,
  })
end

--- Conceal in `bufnr`.
---@param bufnr integer
function M.attach(bufnr)
  set_provider()
  if attached[bufnr] then
    return
  end
  attached[bufnr] = true
  api.nvim_create_autocmd({ 'BufWipeout', 'BufUnload' }, {
    buffer = bufnr,
    once = true,
    callback = function()
      attached[bufnr] = nil
    end,
  })
end

--- Is conceal enabled for `bufnr`?
---@param bufnr integer
---@return boolean
function M.is_attached(bufnr)
  return attached[bufnr] == true
end

return M
