--- typst backend: `typst watch` in continuous mode, `typst compile` otherwise.
---
--- Typst writes nothing but the PDF -- no log, no auxiliary files -- so the
--- diagnostics are read from the compiler output, which `--diagnostic-format
--- short` turns into one `file:line:col: severity: message` line each.
---
--- A watch cycle is framed by two lines: `[12:00:00] compiling ...` when it
--- starts and `[12:00:00] compiled successfully in 3 ms` (or `with warnings`,
--- `with errors`) when it is done. The diagnostics come after the second one.
local config = require('nvim-typst.config')
local project_mod = require('nvim-typst.project')
local util = require('nvim-typst.util')

local M = {
  name = 'typst',
  install_hint = 'Install typst: https://github.com/typst/typst#installation',
}

---@param project table
---@param opts table|nil `{ continuous = boolean, target = string }`
---@return string[] cmd
function M.build_cmd(project, opts)
  opts = opts or {}
  local typst = config.get('compiler', 'typst')
  local target = opts.target or project.main

  local cmd = util.as_cmd(typst.executable)
  cmd[#cmd + 1] = opts.continuous and 'watch' or 'compile'
  vim.list_extend(cmd, { '--root', project.root, '--diagnostic-format', 'short' })
  vim.list_extend(cmd, typst.options or {})

  -- Typst refuses to write into a directory that is missing.
  util.mkdir(project.out_dir)
  vim.list_extend(cmd, { target, project_mod.output_file(project) })
  return cmd
end

--- Typst leaves nothing behind but the PDF.
---@param project table
---@param full boolean also remove the PDF
---@return string[]
function M.clean_files(project, full)
  local pdf = project_mod.output_file(project)
  if full and util.is_file(pdf) then
    return { pdf }
  end
  return {}
end

--- Does a new watch cycle start on this line?
---@param line string
---@return boolean
function M.is_start_line(line)
  return line:match('^%[[%d:]+%] compiling') ~= nil
end

--- Is a watch cycle done? Its diagnostics are still to come.
---@param line string
---@return boolean
function M.is_finished_line(line)
  return line:match('^%[[%d:]+%] compiled') ~= nil
end

--- Did typst report a failure on this line?
---@param line string
---@return boolean
function M.is_failure_line(line)
  return line:match('^%[[%d:]+%] compiled with errors') ~= nil
    or line:match('^error: ') ~= nil
    or line:match('^%S.-:%d+:%d+: error: ') ~= nil
end

return M
