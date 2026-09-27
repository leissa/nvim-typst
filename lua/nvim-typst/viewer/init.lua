--- PDF viewer control.
---
--- Typst has no SyncTeX, so all there is to do is open the PDF. A viewer
--- that is still running is not launched a second time: those that watch
--- the file reload it after every compilation on their own.
local config = require('nvim-typst.config')
local project_mod = require('nvim-typst.project')
local util = require('nvim-typst.util')

local M = {}

M.backends = {
  general = require('nvim-typst.viewer.general'),
}

---@return table|nil
function M.backend()
  local method = config.get('view', 'method')
  local backend = M.backends[method]
  if not backend then
    util.error(("unknown view method '%s'"):format(tostring(method)))
    return nil
  end
  if not backend.available() then
    util.error(("viewer '%s' is not executable"):format(backend.name))
    return nil
  end
  return backend
end

---@param project table
---@return boolean
function M.is_running(project)
  local viewer = project.viewer
  if not viewer or not viewer.handle then
    return false
  end
  return viewer.handle:is_closing() ~= true
end

---@param cmd string[]
---@param cwd string
local function spawn(cmd, cwd)
  return vim.system(cmd, { cwd = cwd, detach = true, text = true }, function(result)
    if result.code ~= 0 and result.stderr and result.stderr ~= '' then
      local message = vim.trim(result.stderr)
      vim.schedule(function()
        util.warn('viewer: ' .. message)
      end)
    end
  end)
end

--- Open the PDF.
---@param project table
function M.view(project)
  if not config.get('view', 'enabled') then
    util.warn('viewer is disabled')
    return
  end

  local pdf = project_mod.output_file(project, 'pdf')
  if not util.is_file(pdf) then
    util.warn('no PDF yet: ' .. vim.fn.fnamemodify(pdf, ':~:.'))
    return
  end
  if M.is_running(project) then
    util.info('the viewer is already open')
    return
  end

  local backend = M.backend()
  if not backend then
    return
  end
  local ok, handle = pcall(spawn, backend.spawn_cmd(project, { pdf = pdf }), project.root)
  if not ok then
    util.error('could not start the viewer: ' .. tostring(handle))
    return
  end
  project.viewer = { handle = handle, pid = handle.pid, backend = backend.name }
end

--- Close the viewer belonging to `project`.
---@param project table
function M.close(project)
  if M.is_running(project) then
    project.viewer.handle:kill('sigterm')
    project.viewer = nil
  end
end

return M
