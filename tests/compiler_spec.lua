local H = require('tests.helpers')
local compiler = require('nvim-typst.compiler')
local config = require('nvim-typst.config')
local project_mod = require('nvim-typst.project')

--- Collect the `User NvimTypst*` events fired while a test runs.
---@return string[]
local function record_events()
  local events = {}
  vim.api.nvim_create_autocmd('User', {
    pattern = 'NvimTypst*',
    callback = function(args)
      events[#events + 1] = args.match
    end,
  })
  return events
end

describe('compiler', function()
  local dir, project

  before_each(function()
    dir = H.tmpdir()
    config.setup({ compiler = { silent = true } })
  end)

  after_each(function()
    pcall(vim.api.nvim_clear_autocmds, { event = 'User', pattern = 'NvimTypst*' })
    H.cleanup()
  end)

  --- A project for `main.typ` in the test directory.
  ---@param source string|string[]
  local function make(source)
    H.write(dir .. '/main.typ', source)
    project = H.project(dir .. '/main.typ')
    project_mod.projects[project.main] = project
    return project
  end

  it('refuses to run a missing executable', function()
    config.setup({ compiler = { typst = { executable = 'no-such-typst' } } })
    compiler.start(make('x'))
    T.falsy(compiler.is_running(project))
    T.ok(H.notified('is not executable'))
  end)

  it('reports an unknown method', function()
    config.setup({ compiler = { method = 'nope' } })
    compiler.start(make('x'))
    T.ok(H.notified("unknown compiler method 'nope'"))
  end)

  describe('with typst', function()
    before_each(H.need_typst)

    it('compiles once and succeeds', function()
      local events = record_events()
      compiler.compile_single_shot(make('= Hello'))
      H.wait(function()
        return project.last_status == 'success'
      end, 20000, 'the compilation')
      T.ok(vim.uv.fs_stat(dir .. '/main.pdf'))
      T.contains(events, 'NvimTypstCompileStarted')
      T.contains(events, 'NvimTypstCompileSuccess')
      H.wait(function()
        return vim.tbl_contains(events, 'NvimTypstCompileStopped')
      end)
      T.falsy(compiler.is_running(project))
    end)

    it('fills the quickfix list from a failing run', function()
      H.write(dir .. '/chapters/ch.typ', 'Text #undefinedthing')
      compiler.compile_single_shot(make('#include "chapters/ch.typ"'))
      H.wait(function()
        return project.last_status == 'failed'
      end, 20000, 'the compilation')
      local items = vim.fn.getqflist()
      T.eq(1, #items)
      T.eq(dir .. '/chapters/ch.typ', vim.fn.fnamemodify(vim.fn.bufname(items[1].bufnr), ':p'))
      T.eq(1, items[1].lnum)
      T.eq(6, items[1].col)
      T.matches('unknown variable', items[1].text)
    end)

    it('writes into out_dir', function()
      make('= Hello')
      project.out_dir = dir .. '/build'
      compiler.compile_single_shot(project)
      H.wait(function()
        return project.last_status == 'success'
      end, 20000, 'the compilation')
      T.ok(vim.uv.fs_stat(dir .. '/build/main.pdf'))
    end)

    it('watches, reports every cycle, and stops', function()
      local main = make('= Hello')
      compiler.start(main, { continuous = true })
      T.ok(compiler.is_running(project))
      H.wait(function()
        return project.last_status == 'success'
      end, 20000, 'the first cycle')

      H.write(dir .. '/main.typ', '= Hello #oops')
      H.wait(function()
        return project.last_status == 'failed'
      end, 20000, 'the failing cycle')
      T.matches('unknown variable: oops', vim.fn.getqflist()[1].text)

      H.write(dir .. '/main.typ', '= Hello again')
      H.wait(function()
        return project.last_status == 'success'
      end, 20000, 'the fixed cycle')
      T.eq({}, vim.fn.getqflist())

      compiler.compile(project) -- toggles off
      H.wait(function()
        return not compiler.is_running(project)
      end)
      T.eq('stopped', project.last_status)
    end)

    it('keeps the raw output', function()
      compiler.compile_single_shot(make('#oops'))
      H.wait(function()
        return project.last_status == 'failed'
      end, 20000, 'the compilation')
      T.contains(project.output, 'main.typ:1:1: error: unknown variable: oops')
    end)
  end)

  describe('clean', function()
    it('removes the PDF on a full clean only', function()
      make('x')
      H.write(dir .. '/main.pdf', '')
      compiler.clean(project, false)
      T.ok(vim.uv.fs_stat(dir .. '/main.pdf'))
      T.ok(H.notified('nothing to clean'))
      compiler.clean(project, true)
      T.falsy(vim.uv.fs_stat(dir .. '/main.pdf'))
    end)
  end)

  describe('status_line', function()
    it('says what state the project is in', function()
      make('x')
      T.matches(': not started$', compiler.status_line(project))
      project.last_status = 'failed'
      T.matches(': failed$', compiler.status_line(project))
    end)
  end)
end)
