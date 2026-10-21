local H = require('tests.helpers')
local cetz = require('nvim-typst.cetz')
local compiler = require('nvim-typst.compiler')
local config = require('nvim-typst.config')
local preview = require('nvim-typst.preview')
local viewer = require('nvim-typst.viewer')

describe('cetz', function()
  local dir

  before_each(function()
    dir = H.tmpdir()
    config.setup({
      lsp = { enabled = false },
      compiler = { silent = true },
      cache_root = dir .. '/cache',
      view = { snacks = { enabled = false }, general = { executable = 'true', args = {} } },
    })
  end)

  after_each(function()
    H.cleanup()
  end)

  describe('canvas', function()
    before_each(H.need_parser)

    --- The text of the canvas at `needle`.
    local function at(lines, needle)
      local bufnr = H.buf(lines)
      H.cursor_at(needle)
      local node = cetz.canvas(require('nvim-typst.ts').node_at_cursor(bufnr), bufnr)
      return node and vim.treesitter.get_node_text(node, bufnr)
    end

    it('takes a call of cetz.canvas or canvas', function()
      T.eq(
        'cetz.canvas({\n  line((0, 0), (1, 1))\n})',
        at({ '#cetz.canvas({', '  line((0, 0), (1, 1))', '})' }, 'line')
      )
      T.eq('canvas(length: 1cm, { circle((0, 0)) })', at({ '#canvas(length: 1cm, { circle((0, 0)) })' }, 'circle'))
      T.eq('c.canvas({})', at({ '#c.canvas({})' }, '{'))
    end)

    it('takes the outermost canvas', function()
      T.eq('canvas({ content((0, 0), canvas({ x })) })', at({ '#canvas({ content((0, 0), canvas({ x })) })' }, 'x'))
    end)

    it('takes a canvas in a figure or a #let', function()
      T.eq('cetz.canvas({ circle() })', at({ '#figure(cetz.canvas({ circle() }), caption: [C])' }, 'circle'))
      T.eq('cetz.canvas({ circle() })', at({ '#let pic = cetz.canvas({ circle() })' }, 'circle'))
    end)

    it('has nothing in a function body, or outside a canvas', function()
      T.eq(nil, at({ '#let pic(n) = cetz.canvas({ circle(n) })' }, 'circle'))
      T.eq(nil, at({ '#let pic = n => cetz.canvas({ circle(n) })' }, 'circle'))
      T.eq(nil, at({ '#figure(cetz.canvas({}), caption: [C])' }, 'C'))
      T.eq(nil, at({ '#plot({ line() })' }, 'line'))
    end)

    it('lets a function inside a canvas be', function()
      T.eq('canvas({ let f(x) = line(x); f(1) })', at({ '#canvas({ let f(x) = line(x); f(1) })' }, 'line'))
    end)

    it('follows cetz.functions', function()
      config.setup({ cetz = { functions = { 'diagram' } } })
      T.eq('diagram(node((0, 0)))', at({ '#figure(diagram(node((0, 0))))' }, 'node'))
      T.eq(nil, at({ '#canvas({ x })' }, 'x'))
    end)

    it('wins the fragment preview over the math inside it', function()
      local bufnr = H.buf({ '#figure(cetz.canvas({', '  content((0, 0), [$alpha$])', '}), caption: [$C$])' })
      H.cursor_at('alpha')
      T.eq('call', preview.fragment_at_cursor(bufnr):type())
      H.cursor_at('C$')
      T.eq('$C$', vim.treesitter.get_node_text(preview.fragment_at_cursor(bufnr), bufnr))
    end)
  end)

  describe('with typst', function()
    local view

    before_each(function()
      H.need_parser()
      H.need_typst()
      view = viewer.view
    end)

    after_each(function()
      viewer.view = view
    end)

    it('compiles the canvas of a figure without the figure', function()
      viewer.view = function() end
      -- A stand-in for the package: a canvas is a box around its body.
      H.write(dir .. '/cetz.typ', { '#let canvas(body) = box(stroke: 1pt, body)' })
      local main = H.write(dir .. '/main.typ', {
        '#import "cetz.typ"',
        'Text.',
        '#figure(cetz.canvas[',
        '  #context counter(figure).get().first()',
        '], caption: [C])',
      })
      local project = H.project(main)
      H.buf(vim.fn.readfile(main), { name = main })
      H.cursor_at('context')
      cetz.preview(project)
      local fragment = project.fragments.preview
      H.wait(function()
        return not compiler.is_running(fragment) and fragment.last_status ~= 'running'
      end, 20000, 'the compilation')
      T.eq('success', fragment.last_status)
      local pdf = fragment.out_dir .. '/preview.pdf'
      T.ok(vim.uv.fs_stat(pdf))
      if vim.fn.executable('pdftotext') == 1 then
        local text = vim.fn.system({ 'pdftotext', pdf, '-' })
        -- No figure around the canvas: no caption, and none counted.
        T.eq(nil, text:find('Figure'))
        T.matches('^%s*0%s*$', text)
      end
    end)

    it('warns outside a canvas', function()
      local main = H.write(dir .. '/main.typ', { '$ x $' })
      local project = H.project(main)
      H.buf(vim.fn.readfile(main), { name = main })
      H.cursor_at('x')
      cetz.preview(project)
      T.eq(nil, project.fragments)
    end)
  end)
end)
