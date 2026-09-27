local H = require('tests.helpers')
local config = require('nvim-typst.config')
local typst = require('nvim-typst.compiler.typst')
local util = require('nvim-typst.util')

describe('compiler.typst', function()
  local project

  before_each(function()
    project = H.project(H.tmpdir() .. '/thesis.typ')
  end)

  after_each(H.cleanup)

  describe('build_cmd', function()
    it('compiles once, with the root and short diagnostics', function()
      T.eq({
        'typst',
        'compile',
        '--root',
        project.root,
        '--diagnostic-format',
        'short',
        project.main,
        project.root .. '/thesis.pdf',
      }, typst.build_cmd(project))
    end)

    it('watches in continuous mode', function()
      T.eq('watch', typst.build_cmd(project, { continuous = true })[2])
    end)

    it('passes the extra options before the files', function()
      config.setup({ compiler = { typst = { options = { '--font-path', 'fonts' } } } })
      local cmd = typst.build_cmd(project)
      T.eq({ '--font-path', 'fonts', project.main, project.root .. '/thesis.pdf' }, vim.list_slice(cmd, 7))
    end)

    it('takes the executable as a list', function()
      config.setup({ compiler = { typst = { executable = { 'nix', 'run', 'nixpkgs#typst', '--' } } } })
      T.eq({ 'nix', 'run', 'nixpkgs#typst', '--', 'compile' }, vim.list_slice(typst.build_cmd(project), 1, 5))
    end)

    it('creates the output directory', function()
      project.out_dir = project.root .. '/build'
      local cmd = typst.build_cmd(project)
      T.eq(project.root .. '/build/thesis.pdf', cmd[#cmd])
      T.ok(util.is_dir(project.root .. '/build'))
    end)
  end)

  describe('clean_files', function()
    it('lists the PDF for a full clean only', function()
      H.write(project.root .. '/thesis.pdf', '')
      T.eq({}, typst.clean_files(project, false))
      T.eq({ project.root .. '/thesis.pdf' }, typst.clean_files(project, true))
    end)
  end)

  describe('watch output', function()
    it('recognises the start and the end of a cycle', function()
      T.ok(typst.is_start_line('[23:46:56] compiling ...'))
      T.falsy(typst.is_start_line('[23:46:56] compiled successfully in 5.3 ms'))
      T.ok(typst.is_finished_line('[23:46:56] compiled successfully in 5.3 ms'))
      T.ok(typst.is_finished_line('[23:46:56] compiled with warnings in 5.3 ms'))
      T.ok(typst.is_finished_line('[23:46:58] compiled with errors'))
      T.falsy(typst.is_finished_line('watching main.typ'))
    end)

    it('recognises failures', function()
      T.ok(typst.is_failure_line('[23:46:58] compiled with errors'))
      T.ok(typst.is_failure_line('sub/ch.typ:1:9: error: unknown variable: oops'))
      T.ok(typst.is_failure_line('error: failed to write PDF file'))
      T.falsy(typst.is_failure_line('sub/ch.typ:2:16: warning: unknown font family: x'))
      T.falsy(typst.is_failure_line('[23:46:56] compiled with warnings in 5.3 ms'))
    end)
  end)
end)
