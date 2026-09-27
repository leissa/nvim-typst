--- Generic viewer backend: runs a user supplied command.
---
--- The placeholder `@pdf` is substituted in `view.general.args`.
local config = require('nvim-typst.config')
local util = require('nvim-typst.util')

local M = { name = 'general' }

function M.available()
  return util.executable(util.as_cmd(config.get('view', 'general', 'executable'))[1])
end

---@param project table
---@param ctx table
---@return string[]
function M.spawn_cmd(_, ctx)
  local opts = config.get('view', 'general')
  local cmd = util.as_cmd(opts.executable)
  vim.list_extend(cmd, util.expand_args(opts.args or { '@pdf' }, { pdf = ctx.pdf }))
  return cmd
end

return M
