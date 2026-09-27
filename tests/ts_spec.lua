local H = require('tests.helpers')
local config = require('nvim-typst.config')
local ts = require('nvim-typst.ts')

local DOC = {
  '= Intro',
  'Some *bold* text with $x^2 + alpha$ inline.',
  '== Details',
  '$ sum_(i=0)^n i $',
  '// a comment',
  '#let f(x) = x + 1',
  '= Next',
  'text',
}

describe('ts', function()
  after_each(H.cleanup)

  describe('with the parser', function()
    before_each(H.need_parser)

    it('parses a buffer', function()
      local bufnr = H.buf(DOC)
      T.ok(ts.parser(bufnr))
      T.eq('source_file', ts.root(bufnr):type())
    end)

    it('finds the node under the cursor and its ancestors', function()
      local bufnr = H.buf(DOC)
      H.cursor_at('alpha')
      local node = ts.node_at_cursor(bufnr)
      T.ok(node)
      T.ok(ts.ancestor(node, ts.MATH))
      T.ok(ts.ancestor(node, ts.SECTION))
      T.falsy(ts.ancestor(node, ts.CODE))
    end)

    it('tells math from text', function()
      local bufnr = H.buf(DOC)
      H.cursor_at('alpha')
      T.ok(ts.in_math(bufnr))
      H.cursor_at('bold')
      T.falsy(ts.in_math(bufnr))
      H.cursor_at('sum_')
      T.ok(ts.in_math(bufnr))
    end)

    it('collects the sections, nested, with their levels', function()
      local bufnr = H.buf(DOC)
      local sections = ts.collect(bufnr, ts.SECTION)
      T.eq(3, #sections)
      T.eq(
        { 1, 2, 1 },
        vim.tbl_map(function(node)
          return ts.section_level(node, bufnr)
        end, sections)
      )
      -- `== Details` is a child of `= Intro`.
      T.ok(ts.ancestor(sections[2]:parent(), ts.SECTION) == sections[1])
    end)

    it('knows comments and code', function()
      local bufnr = H.buf(DOC)
      T.eq(1, #ts.collect(bufnr, ts.COMMENT))
      H.cursor_at('let')
      T.ok(ts.ancestor(ts.node_at_cursor(bufnr), ts.CODE))
    end)
  end)

  it('returns nothing when disabled', function()
    config.setup({ treesitter = { enabled = false } })
    local bufnr = H.buf(DOC)
    T.eq(nil, ts.parser(bufnr))
    T.eq(nil, ts.root(bufnr))
    T.eq({}, ts.collect(bufnr, ts.SECTION))
  end)
end)
