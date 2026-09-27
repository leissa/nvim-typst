local H = require('tests.helpers')
local config = require('nvim-typst.config')

describe('config', function()
  after_each(H.cleanup)

  it('starts from the defaults', function()
    T.eq('typst', config.get('compiler', 'method'))
    T.eq('general', config.get('view', 'method'))
    T.eq('warning', config.get('qf', 'level'))
    T.eq('tinymist', config.get('lsp', 'name'))
    T.eq('<localleader>', config.get('mappings', 'prefix'))
  end)

  it('returns the whole table when called without a path', function()
    T.eq(config.options, config.get())
  end)

  it('returns nil for an unknown path', function()
    T.eq(nil, config.get('compiler', 'nope'))
  end)

  it('deep merges nested tables', function()
    config.setup({ compiler = { typst = { out_dir = 'build' } } })
    T.eq('build', config.get('compiler', 'typst', 'out_dir'))
    -- Untouched siblings survive the merge.
    T.eq('typst', config.get('compiler', 'typst', 'executable'))
    T.eq(true, config.get('compiler', 'typst', 'continuous'))
  end)

  it('leaves the defaults table untouched', function()
    config.setup({ compiler = { typst = { out_dir = 'build' } } })
    T.eq('', config.defaults.compiler.typst.out_dir)
  end)

  it('resets on every setup call', function()
    config.setup({ qf = { level = 'error' } })
    config.setup({})
    T.eq('warning', config.get('qf', 'level'))
  end)

  it('takes lists verbatim instead of merging them index by index', function()
    config.setup({ root_markers = { 'typst.toml' }, compiler = { typst = { options = { '--jobs', '1' } } } })
    T.eq({ 'typst.toml' }, config.get('root_markers'))
    T.eq({ '--jobs', '1' }, config.get('compiler', 'typst', 'options'))
  end)

  it('hands out the options of the active backend', function()
    T.eq(config.get('compiler', 'typst'), config.compiler_options())
  end)
end)
