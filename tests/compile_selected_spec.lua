local H = require('tests.helpers')
local compiler = require('nvim-typst.compiler')
local config = require('nvim-typst.config')
local qf = require('nvim-typst.qf')
local typst = require('nvim-typst.compiler.typst')

describe('compile selected', function()
  local dir

  before_each(function()
    dir = H.tmpdir()
    config.setup({
      compiler = { silent = true },
      cache_root = dir .. '/cache',
      view = { general = { executable = 'true', args = {} } },
    })
  end)

  after_each(function()
    H.reset()
    H.cleanup()
  end)

  describe('preamble', function()
    before_each(H.need_parser)

    it('takes the leading rules and definitions', function()
      local lines = {
        '#import "tpl.typ": conf',
        '// comment',
        '#set text(size: 11pt)',
        '#show: conf.with(title: "T")',
        '#let x = 1',
        '',
        '= Intro',
        'text',
      }
      T.eq(typst.preamble(lines, dir .. '/main.typ', dir, dir), vim.list_slice(lines, 1, 6))
    end)

    it('stops at the first content', function()
      local lines = { '#set text(size: 11pt)', 'Hello', '#set par(justify: true)' }
      T.eq(typst.preamble(lines, dir .. '/main.typ', dir, dir), { '#set text(size: 11pt)' })
    end)

    it('rewrites relative imports for another directory', function()
      local lines = { '#import "lib/tpl.typ": conf', '#import "@preview/cetz:0.3.1"', '#import "/abs.typ"' }
      T.eq(typst.preamble(lines, dir .. '/main.typ', dir, dir .. '/chapters'), {
        '#import "/lib/tpl.typ": conf',
        '#import "@preview/cetz:0.3.1"',
        '#import "/abs.typ"',
      })
    end)
  end)

  describe('with typst', function()
    before_each(function()
      H.need_parser()
      H.need_typst()
    end)

    it('compiles the lines with the preamble of the main file', function()
      H.write(dir .. '/lib/tpl.typ', '#let conf(doc) = doc')
      local main = H.write(dir .. '/main.typ', { '#import "lib/tpl.typ": conf', '#show: conf', '#include "ch/a.typ"' })
      local chapter = H.write(dir .. '/ch/a.typ', { '= Chapter', '#image("fig.svg")', 'Only this.' })
      H.write(dir .. '/ch/fig.svg', '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>')
      local project = H.project(main)
      H.buf(H.lines(vim.fn.bufadd(chapter)), { name = chapter })

      compiler.compile_selected(project, { '#image("fig.svg")', 'Only this.' }, { first = 2 })
      local fragment = project.fragments.selected
      T.ok(fragment)
      H.wait(function()
        return not compiler.is_running(fragment) and fragment.last_status ~= 'running'
      end, 20000, 'the compilation')
      T.eq(fragment.last_status, 'success')
      T.ok(vim.uv.fs_stat(dir .. '/cache/' .. vim.fs.basename(vim.fn.glob(dir .. '/cache/*')) .. '/selected.pdf'))
      -- The hidden source is gone again.
      T.eq(vim.fn.glob(dir .. '/ch/.*.typ', true, true), {})
    end)

    it('points errors back at the buffer', function()
      local main = H.write(dir .. '/main.typ', { '#set text(size: 11pt)', '#include "a.typ"' })
      local chapter = H.write(dir .. '/a.typ', { 'fine', 'fine', '#nope' })
      local project = H.project(main)
      H.buf({ 'fine', 'fine', '#nope' }, { name = chapter })

      compiler.compile_selected(project, { 'fine', '#nope' }, { first = 2 })
      local fragment = project.fragments.selected
      H.wait(function()
        return not compiler.is_running(fragment) and fragment.last_status ~= 'running'
      end, 20000, 'the compilation')
      T.eq(fragment.last_status, 'failed')
      local items = qf.collect(fragment)
      T.eq(#items > 0, true)
      T.eq(items[1].filename, chapter)
      T.eq(items[1].lnum, 3)
    end)
  end)
end)
