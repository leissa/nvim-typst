--- Viewer control.
---
--- Typst has no SyncTeX, so for a PDF viewer all there is to do is open the
--- PDF. A viewer that is still running is not launched a second time: those
--- that watch the file reload it after every compilation on their own.
---
--- The `tinymist` backend is the exception: tinymist's live preview scrolls
--- to the cursor on request and jumps back to the source on a click, so it
--- takes the place of SyncTeX. Backends like it implement `view`, `close`,
--- `is_running` and `forward_search` themselves instead of `spawn_cmd`.
local config = require('nvim-typst.config')
local project_mod = require('nvim-typst.project')
local util = require('nvim-typst.util')

local M = {}

M.backends = {
  general = require('nvim-typst.viewer.general'),
  tinymist = require('nvim-typst.viewer.tinymist'),
}

---@param method string|nil defaults to `view.method`
---@return table|nil
function M.backend(method)
  method = method or config.get('view', 'method')
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
  local backend = viewer and M.backends[viewer.backend]
  if backend and backend.is_running then
    return backend.is_running(project)
  end
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

--- Open the PDF, or with the `tinymist` backend start the preview (and
--- scroll it to the cursor once it runs).
---
--- `opts.pdf` insists on the PDF: a live preview needs a source file, which
--- a compiled selection no longer has, so that is opened with `general` then.
---@param project table
---@param opts table|nil `{ pdf = boolean }`
function M.view(project, opts)
  if not config.get('view', 'enabled') then
    util.warn('viewer is disabled')
    return
  end

  local method = config.get('view', 'method')
  local preferred = M.backends[method]
  if opts and opts.pdf and preferred and preferred.view then
    method = 'general'
  end
  local backend = M.backend(method)
  if not backend then
    return
  end
  if backend.view then
    backend.view(project)
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

  local ok, handle = pcall(spawn, backend.spawn_cmd(project, { pdf = pdf }), project.root)
  if not ok then
    util.error('could not start the viewer: ' .. tostring(handle))
    return
  end
  project.viewer = { handle = handle, pid = handle.pid, backend = backend.name }
end

--- Show a compiled fragment (see `compiler.compile_fragment`): below
--- `anchor` in the buffer with `view.snacks`, or else in the viewer, which
--- reloads the PDF when it is open already.
---@param fragment table
---@param anchor NvimTypstAnchor|nil
function M.show_fragment(fragment, anchor)
  if fragment.format == 'png' and require('nvim-typst.viewer.snacks').show(fragment, anchor) then
    return
  end
  if not M.is_running(fragment) then
    M.view(fragment, { pdf = true })
  end
end

--- Scroll the viewer to the cursor. Only the `tinymist` preview can.
---@param project table
function M.forward_search(project)
  local backend = M.backend()
  if not backend then
    return
  end
  if not backend.forward_search then
    util.warn(("viewer '%s' has no forward search; use view.method = 'tinymist'"):format(backend.name))
    return
  end
  if not M.is_running(project) then
    M.view(project)
    return
  end
  backend.forward_search(project)
end

--- Close the viewer belonging to `project`.
---@param project table
function M.close(project)
  local backend = project.viewer and M.backends[project.viewer.backend]
  if backend and backend.close then
    backend.close(project)
    return
  end
  if M.is_running(project) then
    project.viewer.handle:kill('sigterm')
    project.viewer = nil
  end
end

return M
