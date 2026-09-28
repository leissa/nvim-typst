local H = require('tests.helpers')
local textobj = require('nvim-typst.textobj')

--- The selection the object `lhs` makes, with the cursor first placed on the
--- first occurrence of `needle`.
---@param lines string|string[]
---@param needle string
---@param lhs string
---@return table|nil
local function selection(lines, needle, lhs)
  H.buf(lines)
  H.cursor_at(needle)
  return H.selection(textobj.map[lhs])
end

--- The text the object `lhs` selects, or nil when it selects nothing.
---@param lines string|string[]
---@param needle string
---@param lhs string
---@return string|nil
local function selected(lines, needle, lhs)
  local sel = selection(lines, needle, lhs)
  return sel and H.selected_text(sel) or nil
end

describe('textobj', function()
  before_each(H.need_parser)
  after_each(H.cleanup)

  describe('math', function()
    it('a$ takes the dollars with it', function()
      T.eq('$x^2 + alpha$', selected('see $x^2 + alpha$ here', 'alpha', 'a$'))
    end)

    it('i$ leaves them behind', function()
      T.eq('x^2 + alpha', selected('see $x^2 + alpha$ here', 'alpha', 'i$'))
    end)

    it('i$ drops the spaces of display math', function()
      T.eq('sum_i x', selected('$ sum_i x $', 'sum', 'i$'))
    end)

    it('i$ selects the body linewise when the $ have lines of their own', function()
      local sel = selection({ 'a', '$', '  x = y', '  z', '$', 'b' }, 'x', 'i$')
      T.eq('V', sel.mode)
      T.eq('  x = y\n  z', H.selected_text(sel))
    end)

    it('works when the cursor is on a $', function()
      T.eq('x', selected('a $x$ b', '$', 'i$'))
    end)

    it('selects nothing outside math', function()
      T.eq(nil, selected('plain text', 'text', 'a$'))
    end)

    it('deletes through the mapping', function()
      H.buf({ 'a $x + y$ b' })
      H.cursor_at('y')
      vim.api.nvim_feedkeys('di$', 'x', false)
      T.eq('a $$ b', H.lines()[1])
    end)
  end)

  describe('section', function()
    local DOC = { '= One', 'intro', '== Sub', 'body', '', '= Two', 'more' }

    it('aP takes the heading and the subsections', function()
      T.eq('= One\nintro\n== Sub\nbody\n', selected(DOC, 'intro', 'aP'))
    end)

    it('iP leaves the heading behind', function()
      T.eq('intro\n== Sub\nbody\n', selected(DOC, 'intro', 'iP'))
    end)

    it('picks the innermost section', function()
      T.eq('== Sub\nbody\n', selected(DOC, 'body', 'aP'))
    end)

    it('covers the last section up to the end of the buffer', function()
      T.eq('= Two\nmore', selected(DOC, 'more', 'aP'))
    end)
  end)

  describe('call', function()
    local LINE = 'see #strong[hello #emph[world]] and #foo(1, 2) now'

    it('ac takes the # along', function()
      T.eq('#emph[world]', selected(LINE, 'world', 'ac'))
      T.eq('#foo(1, 2)', selected(LINE, 'foo', 'ac'))
    end)

    it('ic selects the content or the arguments', function()
      T.eq('world', selected(LINE, 'world', 'ic'))
      T.eq('hello #emph[world]', selected(LINE, 'hello', 'ic'))
      T.eq('1, 2', selected(LINE, '2', 'ic'))
    end)

    it('works with the cursor on the #', function()
      T.eq('#strong[hello #emph[world]]', selected(LINE, '#strong', 'ac'))
    end)

    it('treats trailing content blocks as part of the call', function()
      local line = '#figure(image("a.png"), caption: [Cap])[body]'
      T.eq(line, selected(line, 'figure', 'ac'))
      -- On the name, `ic` takes the last block; inside one, that block.
      T.eq('body', selected(line, 'figure', 'ic'))
      T.eq('image("a.png"), caption: [Cap]', selected(line, 'caption', 'ic'))
    end)

    it('selects an inner call in the arguments', function()
      T.eq('image("a.png")', selected('#figure(image("a.png"))', 'image', 'ac'))
    end)

    it('handles calls in math', function()
      T.eq('frac(a, b)', selected('$ frac(a, b) $', 'frac', 'ac'))
      T.eq('a, b', selected('$ frac(a, b) $', 'frac', 'ic'))
    end)

    it('selects a multi-line body linewise', function()
      local sel = selection({ '#block[', '  one', '  two', ']' }, 'one', 'ic')
      T.eq('V', sel.mode)
      T.eq('  one\n  two', H.selected_text(sel))
    end)

    it('dac removes the call', function()
      H.buf({ LINE })
      H.cursor_at('world')
      vim.api.nvim_feedkeys('dac', 'x', false)
      T.eq('see #strong[hello ] and #foo(1, 2) now', H.lines()[1])
    end)
  end)

  describe('delimiter', function()
    it('selects code groups, blocks and content', function()
      T.eq('(1, 2)', selected('#f((1, 2))', '2', 'ad'))
      T.eq('{ x + 1 }', selected('#let f(x) = { x + 1 }', '1', 'ad'))
      T.eq('[Cap]', selected('#f(caption: [Cap])', 'Cap', 'ad'))
    end)

    it('id leaves the delimiters behind', function()
      T.eq('1, 2', selected('#f((1, 2))', '2', 'id'))
      T.eq(' x + 1 ', selected('#let f(x) = { x + 1 }', '1', 'id'))
    end)

    it('handles groups in math, whatever the bracket', function()
      T.eq('(x + y)', selected('$ (x + y) [z] $', 'y', 'ad'))
      T.eq('z', selected('$ (x + y) [z] $', 'z', 'id'))
    end)

    it('handles the parentheses of a call in math', function()
      T.eq('(a, b)', selected('$ frac(a, b) $', 'a,', 'ad'))
      T.eq('a + b', selected('$ lr((a + b)) $', 'a', 'id'))
    end)

    it('falls back to a search for brackets in markup', function()
      T.eq('(some text)', selected('see (some text) here', 'some', 'ad'))
      T.eq('some text', selected('see (some text) here', 'some', 'id'))
    end)

    it('selects nothing for an empty pair', function()
      T.eq(nil, selected('#f()', 'f', 'id'))
    end)
  end)

  describe('item', function()
    local LIST = { '- one', '- two', '  continued', '+ enum', '1. numbered', '/ Term: desc' }

    it('am takes the whole item, linewise', function()
      local sel = selection(LIST, 'two', 'am')
      T.eq('V', sel.mode)
      T.eq('- two\n  continued', H.selected_text(sel))
    end)

    it('im leaves the marker behind', function()
      T.eq('two\n  continued', selected(LIST, 'continued', 'im'))
      T.eq('enum', selected(LIST, 'enum', 'im'))
      T.eq('numbered', selected(LIST, 'numbered', 'im'))
      T.eq('Term: desc', selected(LIST, 'desc', 'im'))
    end)

    it('picks the innermost of nested items', function()
      T.eq('inner', selected({ '- outer', '  - inner' }, 'inner', 'im'))
      T.eq('outer\n  - inner', selected({ '- outer', '  - inner' }, 'outer', 'im'))
    end)

    it('dam deletes the line', function()
      H.buf(LIST)
      H.cursor_at('one')
      vim.api.nvim_feedkeys('dam', 'x', false)
      T.eq('- two', H.lines()[1])
    end)
  end)
end)
