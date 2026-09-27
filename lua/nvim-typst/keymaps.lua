--- Buffer-local mappings.
---
--- The keys are nvim-tex's, which are VimTeX's without the extra `l` layer:
--- `<localleader>l` compiles, `<localleader>v` views, and so on. Keys whose
--- nvim-tex action has no Typst counterpart yet are left unmapped.
local compiler = require('nvim-typst.compiler')
local config = require('nvim-typst.config')
local info = require('nvim-typst.info')
local project_mod = require('nvim-typst.project')
local qf = require('nvim-typst.qf')
local viewer = require('nvim-typst.viewer')

local M = {}

---@return table
local function project()
  return project_mod.get(0)
end

---@param bufnr integer
---@return fun(modes: string|string[], lhs: string, rhs: function|string, desc: string, extra: table|nil)
local function mapper(bufnr)
  return function(modes, lhs, rhs, desc, extra)
    vim.keymap.set(
      modes,
      lhs,
      rhs,
      vim.tbl_extend('force', {
        buffer = bufnr,
        silent = true,
        desc = 'nvim-typst: ' .. desc,
      }, extra or {})
    )
  end
end

--- The `<localleader>` group, as in nvim-tex.
---@param map function
---@param prefix string
local function leader_maps(map, prefix)
  map('n', prefix .. 'i', function()
    info.info(project(), false)
  end, 'info')
  map('n', prefix .. 'I', function()
    info.info(project(), true)
  end, 'info (full)')
  map('n', prefix .. 'v', function()
    viewer.view(project())
  end, 'view the PDF')
  map('n', prefix .. 'l', function()
    compiler.compile(project())
  end, 'start or stop compilation')
  map('n', prefix .. 'S', function()
    compiler.compile_single_shot(project())
  end, 'compile once')
  map('n', prefix .. 'k', function()
    compiler.stop(project())
  end, 'stop compilation')
  map('n', prefix .. 'K', function()
    compiler.stop_all()
  end, 'stop all compilations')
  map('n', prefix .. 'e', function()
    qf.update(project(), { force_open = true })
  end, 'show errors')
  map('n', prefix .. 'E', function()
    qf.cycle_level()
    qf.update(project(), { force_open = true })
  end, 'cycle the quickfix severity level')
  map('n', prefix .. 'o', function()
    compiler.show_output(project())
  end, 'show compiler output')
  map('n', prefix .. 'g', function()
    info.status(project())
  end, 'compilation status')
  map('n', prefix .. 'G', function()
    info.status_all()
  end, 'compilation status (all)')
  map('n', prefix .. 'c', function()
    compiler.clean(project(), false)
  end, 'clean generated files')
  map('n', prefix .. 'C', function()
    compiler.clean(project(), true)
  end, 'clean all output')
  map('n', prefix .. 'x', function()
    info.reload()
  end, 'reload nvim-typst')
  map('n', prefix .. 'X', function()
    info.reload_state()
  end, 'reload project state')
  map('n', prefix .. 's', function()
    info.toggle_main(vim.api.nvim_get_current_buf())
  end, 'toggle main file')
end

---@param bufnr integer
function M.attach(bufnr)
  local opts = config.get('mappings')
  if not opts.enabled then
    return
  end
  leader_maps(mapper(bufnr), opts.prefix)
end

return M
