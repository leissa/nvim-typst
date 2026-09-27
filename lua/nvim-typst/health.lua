--- `:checkhealth nvim-typst`
local config = require('nvim-typst.config')
local util = require('nvim-typst.util')

local M = {}

---@param name string
---@param advice string|nil
---@param required boolean
local function check_executable(name, advice, required)
  if util.executable(name) then
    vim.health.ok(("'%s' found (%s)"):format(name, vim.fn.exepath(name)))
  elseif required then
    vim.health.error(("'%s' not found"):format(name), advice and { advice } or nil)
  else
    vim.health.warn(("'%s' not found"):format(name), advice and { advice } or nil)
  end
end

function M.check()
  vim.health.start('nvim-typst')

  if vim.fn.has('nvim-0.10') == 1 then
    vim.health.ok('Neovim ' .. tostring(vim.version()))
  else
    vim.health.error('Neovim 0.10 or newer is required')
  end

  vim.health.start('nvim-typst: tree-sitter')
  if pcall(vim.treesitter.get_string_parser, '', 'typst') then
    vim.health.ok("the 'typst' parser is installed")
    if require('nvim-typst').has_highlights() then
      vim.health.ok('a Typst highlight query is available; tree-sitter highlights')
    else
      vim.health.info('no Typst highlight query (nvim-treesitter provides one); syntax/typst.vim highlights')
    end
  else
    vim.health.error("the 'typst' parser is missing", {
      'Install it with :TSInstall typst, or with your parser manager of choice.',
    })
  end

  vim.health.start('nvim-typst: LSP')
  if config.get('lsp', 'enabled') then
    check_executable(config.get('lsp', 'cmd')[1], 'Install tinymist: https://github.com/Myriad-Dreamin/tinymist', false)
  else
    vim.health.info('LSP integration is disabled (lsp.enabled = false)')
  end

  vim.health.start('nvim-typst: compiler')
  local compiler_method = config.get('compiler', 'method')
  local backends = require('nvim-typst.compiler').backends
  local backend = backends[compiler_method]
  if not backend then
    local names = vim.tbl_keys(backends)
    table.sort(names)
    vim.health.error(
      ("unknown compiler method '%s'"):format(tostring(compiler_method)),
      { 'Use one of: ' .. table.concat(names, ', ') }
    )
  else
    local exe = util.as_cmd(config.compiler_options().executable)[1]
    check_executable(exe, backend.install_hint, true)
    if util.executable(exe) then
      local result = vim.system({ exe, '--version' }, { text = true }):wait()
      if result.code == 0 then
        vim.health.info(vim.trim(result.stdout or ''))
      end
    end
  end

  vim.health.start('nvim-typst: viewer')
  local method = config.get('view', 'method')
  local viewer = require('nvim-typst.viewer')
  local view_backend = viewer.backends[method]
  if view_backend and view_backend.available() then
    vim.health.ok(('viewer %s is available (%s)'):format(method, config.get('view', method, 'executable')))
  else
    vim.health.warn(('viewer %s is not available'):format(tostring(method)), {
      'Set view.general.executable to your PDF viewer, e.g. "zathura".',
    })
  end
end

return M
