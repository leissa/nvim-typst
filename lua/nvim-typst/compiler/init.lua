--- Compiler job management.
---
--- One job per project. In continuous mode the job outlives the command that
--- started it and keeps rebuilding; `compile` therefore toggles.
local config = require('nvim-typst.config')
local project_mod = require('nvim-typst.project')
local qf = require('nvim-typst.qf')
local util = require('nvim-typst.util')

local M = {}

M.backends = {
  typst = require('nvim-typst.compiler.typst'),
}

--- How long a finished watch cycle waits for its diagnostics, which typst
--- prints after the line that says the cycle is done, in milliseconds.
M.settle_ms = 100

---@return table|nil
function M.backend()
  local method = config.get('compiler', 'method')
  local backend = M.backends[method]
  if not backend then
    util.error(("unknown compiler method '%s'"):format(tostring(method)))
  end
  return backend
end

--- Fire a `User NvimTypst<name>` autocmd.
---
--- Only plain data is passed along; the project itself holds job handles,
--- which cannot cross the autocmd boundary. Look it up with
--- `require('nvim-typst.project').projects[data.main]`.
---@param name string
---@param project table
local function emit(name, project)
  vim.api.nvim_exec_autocmds('User', {
    pattern = 'NvimTypst' .. name,
    data = { main = project.main, root = project.root, status = project.last_status },
  })
end

---@param project table
---@return boolean
function M.is_running(project)
  return project.compiler ~= nil and project.compiler.handle ~= nil
end

--- Split incoming chunks into complete lines.
---@param state table
---@param chunk string|nil
---@param on_line fun(line: string)
local function feed(state, chunk, on_line)
  if not chunk or chunk == '' then
    return
  end
  state.partial = (state.partial or '') .. chunk
  while true do
    local nl = state.partial:find('\n')
    if not nl then
      break
    end
    local line = state.partial:sub(1, nl - 1):gsub('\r$', '')
    state.partial = state.partial:sub(nl + 1)
    on_line(line)
  end
end

--- Report the result of one compilation run.
---@param project table
---@param lines string[] the output of this run
---@param code integer|nil exit code, nil when running continuously
---@param saw_failure boolean|nil the backend reported an error in its output
local function finish_run(project, lines, code, saw_failure)
  project.last_output = lines
  local errors, warnings = qf.update(project, { silent = true })
  local silent = config.get('compiler', 'silent')

  local failed = (code ~= nil and code ~= 0) or errors > 0 or saw_failure == true
  project.last_status = failed and 'failed' or 'success'

  if failed then
    util.info_unless(silent, ('compilation failed (%d errors, %d warnings)'):format(errors, warnings))
    emit('CompileFailed', project)
  else
    local detail = warnings > 0 and (' (%d warnings)'):format(warnings) or ''
    util.info_unless(silent, 'compilation succeeded' .. detail)
    emit('CompileSuccess', project)
  end
end

---@param project table
---@param opts table|nil `{ continuous = boolean, target = string, on_success = function, on_exit = function }`
function M.start(project, opts)
  opts = opts or {}
  if not config.get('compiler', 'enabled') then
    util.warn('compiler is disabled')
    return
  end
  if M.is_running(project) then
    util.info('compilation already running')
    return
  end

  local backend = M.backend()
  if not backend then
    return
  end

  local options = config.compiler_options()
  local continuous = opts.continuous
  if continuous == nil then
    continuous = options.continuous
  end
  -- Continuous mode needs the backend to say when a cycle is over.
  if not backend.is_finished_line then
    continuous = false
  end

  local cmd = backend.build_cmd(project, vim.tbl_extend('force', opts, { continuous = continuous }))
  if not util.executable(cmd[1]) then
    util.error(("'%s' is not executable"):format(cmd[1]))
    return
  end

  project.output = {}
  project.last_status = 'running'
  local job = {
    cmd = cmd,
    continuous = continuous,
    started_at = os.time(),
    saw_failure = false,
    on_success = opts.on_success,
    -- The output of the current run: everything for a single shot, the
    -- current cycle in continuous mode.
    run = {},
    -- A finished cycle waiting for its diagnostics.
    settling = false,
    timer = nil,
  }
  project.compiler = job

  --- Close the cycle that is waiting for its diagnostics.
  local function settle()
    if job.timer then
      job.timer:stop()
      job.timer:close()
      job.timer = nil
    end
    if not job.settling then
      return
    end
    job.settling = false
    finish_run(project, job.run, nil, job.saw_failure)
    job.saw_failure = false
    job.run = {}
    if job.on_success and project.last_status == 'success' then
      local cb = job.on_success
      job.on_success = nil
      cb()
    end
  end

  local function arm()
    if job.timer then
      job.timer:stop()
    else
      job.timer = vim.uv.new_timer()
    end
    job.timer:start(M.settle_ms, 0, vim.schedule_wrap(settle))
  end

  local state = {}
  local hooks = options.hooks or {}

  local function on_line(line)
    project.output[#project.output + 1] = line
    if #project.output > 5000 then
      table.remove(project.output, 1)
    end

    for _, hook in ipairs(hooks) do
      pcall(hook, line)
    end

    if continuous and backend.is_start_line and backend.is_start_line(line) then
      settle()
      job.run = {}
    end
    job.run[#job.run + 1] = line

    if backend.is_failure_line and backend.is_failure_line(line) then
      job.saw_failure = true
    end
    if continuous and (job.settling or backend.is_finished_line(line)) then
      job.settling = true
      arm()
    end
  end

  local function on_output(_, chunk)
    vim.schedule(function()
      feed(state, chunk, on_line)
    end)
  end

  local handle = vim.system(cmd, {
    cwd = project.root,
    text = true,
    stdout = on_output,
    stderr = on_output,
  }, function(result)
    vim.schedule(function()
      if state.partial and state.partial ~= '' then
        on_line(state.partial)
        state.partial = ''
      end
      settle()
      local was_stopped = job.stopping
      project.compiler = nil
      if was_stopped then
        project.last_status = 'stopped'
        util.info_unless(config.get('compiler', 'silent'), 'compilation stopped')
      elseif continuous and #job.run == 0 then
        -- The watcher went away after a finished cycle; that cycle has
        -- already been reported.
        project.last_status = 'stopped'
      else
        finish_run(project, job.run, result.code, job.saw_failure)
        if job.on_success and project.last_status == 'success' then
          job.on_success()
        end
      end
      emit('CompileStopped', project)
      if opts.on_exit then
        opts.on_exit()
      end
    end)
  end)

  job.handle = handle
  emit('CompileStarted', project)

  local mode = continuous and 'continuous' or 'single shot'
  util.info_unless(
    config.get('compiler', 'silent'),
    ('compiling %s (%s)'):format(vim.fn.fnamemodify(project.main, ':t'), mode)
  )
end

---@param project table
function M.stop(project)
  if not M.is_running(project) then
    util.info('no compilation running')
    return
  end
  project.compiler.stopping = true
  project.compiler.handle:kill('sigterm')
end

function M.stop_all()
  local count = 0
  for _, project in pairs(project_mod.projects) do
    if M.is_running(project) then
      project.compiler.stopping = true
      project.compiler.handle:kill('sigterm')
      count = count + 1
    end
  end
  util.info(('stopped %d compilation(s)'):format(count))
end

--- Toggle in continuous mode, run once otherwise.
---@param project table
---@param opts table|nil
function M.compile(project, opts)
  opts = opts or {}
  if M.is_running(project) then
    M.stop(project)
  else
    M.start(project, opts)
  end
end

--- Compile once, regardless of the `continuous` setting.
---@param project table
---@param opts table|nil
function M.compile_single_shot(project, opts)
  opts = vim.tbl_extend('force', opts or {}, { continuous = false })
  if M.is_running(project) then
    util.warn('a compilation is already running; stop it first')
    return
  end
  M.start(project, opts)
end

--- Compile `lines` of a buffer as a document of its own, with the preamble
--- of the main file in front, and show the result: below the last of the
--- lines when snacks.nvim can show images in the terminal (`view.snacks`),
--- or else in the viewer.
---
--- The fragment is written to a hidden file next to the buffer's file, so
--- that its relative paths resolve as they do in the document, and removed
--- once it is compiled. The output goes to the project's cache directory.
--- Diagnostics are mapped back to the buffer (and to the main file for the
--- preamble).
---
--- Each `name` is a project of its own, `project.fragments[name]`, reused
--- between runs so that the viewer showing it stays open.
---
--- `opts`: `bufnr` and `first`, where `lines` come from; `preview`, a
--- preview of them alone, with the page cropped to them and the
--- `#show: template` of the preamble left out; `definitions`, more lines of
--- the buffer to put between the preamble and `lines`, as `{ first, lines }`.
---@param project table
---@param name string
---@param lines string[]
---@param opts table|nil
function M.compile_fragment(project, name, lines, opts)
  opts = opts or {}
  local bufnr = (opts.bufnr == nil or opts.bufnr == 0) and vim.api.nvim_get_current_buf() or opts.bufnr
  local first = opts.first or 1
  local backend = M.backend()
  if not backend then
    return
  end
  if not backend.preamble or not backend.fragment_page then
    util.error(("compiler '%s' cannot compile a fragment"):format(backend.name))
    return
  end
  project.fragments = project.fragments or {}
  local fragment = project.fragments[name]
  if fragment and M.is_running(fragment) then
    util.warn('the fragment is still being compiled')
    return
  end

  local source = util.normalize(vim.api.nvim_buf_get_name(bufnr))
  local dir = source ~= '' and vim.fs.dirname(source) or project.dir
  local main_buf = vim.fn.bufnr(project.main)
  local main_lines = main_buf > 0
      and vim.api.nvim_buf_is_loaded(main_buf)
      and vim.api.nvim_buf_get_lines(main_buf, 0, -1, false)
    or util.readlines(project.main)
  -- A fragment of the main file itself must not repeat its preamble.
  local preamble = source ~= project.main
      and backend.preamble(main_lines, project.main, project.root, dir, opts.preview)
    or {}
  if not preamble then
    util.error("the 'typst' tree-sitter parser is needed to find the preamble")
    return
  end

  -- The document, and for each of its lines where it comes from: a line of
  -- the main file (`main`) or of the buffer (`buf`).
  local document, origin = {}, {}
  local function add(text, from, lnum)
    document[#document + 1] = text
    origin[#origin + 1] = { from, lnum }
  end
  for i, line in ipairs(preamble) do
    add(line, 'main', i)
  end
  for _, definition in ipairs(opts.definitions or {}) do
    for i, line in ipairs(definition.lines) do
      add(line, 'buf', definition.first + i - 1)
    end
  end
  local snacks = require('nvim-typst.viewer.snacks')
  local inline = snacks.available()
  if inline or opts.preview then
    add(backend.fragment_page(opts.preview == true), 'buf', first)
  end
  for i, line in ipairs(lines) do
    add(line, 'buf', first + i - 1)
  end

  local target = util.join(dir, ('.%s.%s.typ'):format(project.name, name))
  util.writelines(target, document)

  fragment = fragment
    or {
      name = name,
      root = project.root,
      out_dir = project_mod.cache_dir(project),
      out_dir_set = true,
      output = {},
    }
  fragment.main, fragment.dir = target, dir
  fragment.format = inline and 'png' or nil
  fragment.ppi = inline and snacks.ppi() or nil
  --- Point the diagnostics of the hidden file at where the lines came from.
  fragment.qf_translate = function(item)
    if item.filename ~= target then
      return item
    end
    local from = origin[item.lnum] or origin[#origin]
    if not from then
      return item
    end
    if from[1] == 'main' then
      item.filename, item.lnum = project.main, from[2]
    elseif source ~= '' then
      item.filename, item.lnum = source, from[2]
    else
      item.filename, item.bufnr, item.lnum = nil, bufnr, from[2]
    end
    return item
  end
  project.fragments[name] = fragment

  -- Below the last of the lines.
  local anchor = inline and snacks.anchor(bufnr, first + #lines - 2) or nil
  M.start(fragment, {
    continuous = false,
    on_success = function()
      require('nvim-typst.viewer').show_fragment(fragment, anchor)
    end,
    on_exit = function()
      vim.fn.delete(target)
    end,
  })
  if not M.is_running(fragment) then
    vim.fn.delete(target)
  end
end

--- Compile `lines` of a buffer as a document of its own; see
--- `compile_fragment`.
---@param project table
---@param lines string[]
---@param opts table|nil `{ bufnr = integer, first = integer }` where `lines` come from
function M.compile_selected(project, lines, opts)
  M.compile_fragment(project, 'selected', lines, opts)
end

---@param project table
---@param full boolean
function M.clean(project, full)
  local backend = M.backend()
  if not backend then
    return
  end

  local files = backend.clean_files(project, full)
  if #files == 0 then
    util.info('nothing to clean')
    return
  end
  local failed = {}
  for _, file in ipairs(files) do
    if vim.fn.delete(file) ~= 0 then
      failed[#failed + 1] = vim.fn.fnamemodify(file, ':~:.')
    end
  end
  if #failed > 0 then
    util.error('could not remove ' .. table.concat(failed, ', '))
  else
    util.info(full and 'cleaned all output files' or 'cleaned auxiliary files')
  end
end

--- One-line status summary.
---@param project table
---@return string
function M.status_line(project)
  local name = vim.fn.fnamemodify(project.main, ':~:.')
  if M.is_running(project) then
    local mode = project.compiler.continuous and 'continuous' or 'single shot'
    return ('%s: running (%s)'):format(name, mode)
  end
  return ('%s: %s'):format(name, project.last_status or 'not started')
end

--- Show the captured compiler output in a scratch split.
---@param project table
function M.show_output(project)
  local output = project.output or {}
  if #output == 0 then
    util.info('no compiler output yet')
    return
  end
  util.scratch('nvim-typst://output', output, { filetype = 'log', height = 15 })
end

return M
