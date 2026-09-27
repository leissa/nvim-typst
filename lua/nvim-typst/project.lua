--- Project (main file) detection and the per-project state registry.
---
--- Every Typst buffer belongs to exactly one project, identified by the
--- absolute path of its main file. All long lived state -- the running
--- compiler job, the viewer handle, the collected output -- hangs off that
--- project, so several buffers of the same document share one compilation.
---
--- Two directories matter: `root` is Typst's project root (`--root`), which
--- bounds file access and is what absolute paths such as `/figures/a.svg`
--- resolve against; `dir` is the directory of the main file.
local config = require('nvim-typst.config')
local util = require('nvim-typst.util')

local M = {}

--- main path -> project
---@type table<string, table>
M.projects = {}

--- bufnr -> main path
---@type table<integer, string>
local buf_main = {}

--- `// !TYPST main = thesis.typ`, the counterpart of LaTeX's `% !TEX root`.
--- It is `main` rather than `root` because "root" already means something
--- else in Typst.
local MAIN_PATTERNS = {
  '^%s*//%s*!%s*[Tt][Yy][Pp][Ss][Tt]%s+main%s*=%s*(.-)%s*$',
}

--- How far up the directory tree the main file is searched for.
local MAX_LEVELS = 5

--- How many `#include` hops separate a file from its main file at most.
local MAX_DEPTH = 8

---@param lines string[]
---@param patterns string[]
---@return string|nil
local function match_directive(lines, patterns)
  for _, line in ipairs(lines) do
    for _, pat in ipairs(patterns) do
      local value = line:match(pat)
      if value and value ~= '' then
        return value
      end
    end
  end
  return nil
end

--- Directive lines are only honoured near the top or bottom of a file.
---@param bufnr integer
---@return string[]
local function directive_lines(bufnr)
  local total = vim.api.nvim_buf_line_count(bufnr)
  local head = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(5, total), false)
  local tail = vim.api.nvim_buf_get_lines(bufnr, math.max(0, total - 5), -1, false)
  return vim.list_extend(head, tail)
end

--- The nearest directory at or above `dir` holding one of `root_markers`.
---@param dir string
---@return string|nil
local function marked_root(dir)
  local markers = config.get('root_markers') or {}
  if #markers == 0 then
    return nil
  end
  local found = vim.fs.find(markers, { path = dir, upward = true, limit = 1 })[1]
  return found and util.normalize(vim.fs.dirname(found)) or nil
end

--- The project root for a main file in `dir`: the nearest directory holding
--- one of `root_markers`, or `dir` itself.
---@param dir string
---@return string
function M.find_root(dir)
  return marked_root(dir) or util.normalize(dir)
end

--- Resolve a path as Typst would from inside `file`: relative to the file,
--- or to the project root when it starts with `/`. Package imports
--- (`@preview/...`) resolve to nothing.
---@param path string
---@param file string
---@param root string
---@return string|nil
function M.resolve(path, file, root)
  if path:match('^@') then
    return nil
  end
  if path:match('^/') then
    return util.normalize(util.join(root, path))
  end
  return util.normalize(util.join(vim.fs.dirname(file), path))
end

--- The files `#include`d or `#import`ed by `lines`, which belong to `file`.
---@param lines string[]
---@param file string
---@param root string
---@return string[]
function M.dependencies(lines, file, root)
  local out = {}
  for _, line in ipairs(lines) do
    -- Walk the line string by string, so that a quote inside one string --
    -- or the `//` of a URL -- is never taken for the start of another.
    local pos = 1
    while true do
      local open = line:find('["/]', pos)
      if not open then
        break
      end
      if line:sub(open, open + 1) == '//' then
        break -- a line comment
      end
      if line:sub(open, open) == '"' then
        local close = open + 1
        while close <= #line and line:sub(close, close) ~= '"' do
          close = close + (line:sub(close, close) == '\\' and 2 or 1)
        end
        local keyword = line:sub(pos, open - 1):match('(%a+)%s*$')
        if keyword == 'include' or keyword == 'import' then
          local resolved = M.resolve(line:sub(open + 1, close - 1), file, root)
          if resolved then
            out[#out + 1] = resolved
          end
        end
        pos = close + 1
      else
        pos = open + 1
      end
    end
  end
  return out
end

--- Does `candidate` pull `target` in via `#include` or `#import`?
---@param candidate string
---@param target string
---@param root string|nil the project root, found from `candidate` if nil
---@return boolean
local function includes(candidate, target, root)
  root = root or M.find_root(vim.fs.dirname(candidate))
  return vim.tbl_contains(M.dependencies(util.readlines(candidate), candidate, root), target)
end

--- Look for a file including `target` in its directory and the ones above,
--- without leaving `limit` when there is one.
---@param target string
---@param limit string|nil
---@return string|nil
local function find_includer(target, limit)
  local current = vim.fs.dirname(target)
  for _ = 1, MAX_LEVELS do
    local candidates = vim.fn.glob(util.join(current, '*.typ'), false, true)
    table.sort(candidates)
    for _, candidate in ipairs(candidates) do
      candidate = util.normalize(candidate)
      if candidate ~= target and includes(candidate, target, limit) then
        return candidate
      end
    end

    local parent = vim.fs.dirname(current)
    if current == limit or not parent or parent == current then
      break
    end
    current = parent
  end
  return nil
end

--- Follow the chain of includers up to the file nothing includes: a chapter
--- included by a part included by the thesis resolves to the thesis. The
--- search does not leave the directory marked as the project root, if any.
---@param file string
---@return string|nil
local function search_upwards(file)
  local limit = marked_root(vim.fs.dirname(file))
  local seen = { [file] = true }
  local current = file
  for _ = 1, MAX_DEPTH do
    local includer = find_includer(current, limit)
    if not includer or seen[includer] then
      break
    end
    seen[includer] = true
    current = includer
  end
  return current ~= file and current or nil
end

--- The main file of a known project that pulls in `file`. The project of the
--- alternate buffer wins, as that is usually where `file` was opened from.
---@param file string
---@return string|nil
local function open_project_including(file)
  local mains = {}
  for main, project in pairs(M.projects) do
    if main ~= file and includes(main, file, project.root) then
      mains[#mains + 1] = main
    end
  end
  if #mains == 0 then
    return nil
  end
  local alt = buf_main[vim.fn.bufnr('#')]
  if alt and vim.tbl_contains(mains, alt) then
    return alt
  end
  table.sort(mains)
  return mains[1]
end

--- Resolve the main file for `bufnr`.
---@param bufnr integer
---@return string
function M.detect_main(bufnr)
  local file = util.normalize(vim.api.nvim_buf_get_name(bufnr))

  -- 1. Buffer variable set by the user or by `:TypstToggleMain`.
  local ok, override = pcall(vim.api.nvim_buf_get_var, bufnr, 'typst_main')
  if ok and type(override) == 'string' and override ~= '' then
    return util.normalize(override)
  end

  -- 2. Explicit configuration.
  local configured = config.get('main_file')
  if type(configured) == 'function' then
    configured = configured(bufnr)
  end
  if type(configured) == 'string' and configured ~= '' then
    return util.normalize(configured)
  end

  -- 3. A `// !TYPST main = ...` directive.
  local main = match_directive(directive_lines(bufnr), MAIN_PATTERNS)
  if main then
    if not main:match('^[/~]') then
      main = util.join(vim.fs.dirname(file), main)
    end
    if not main:match('%.%a+$') then
      main = main .. '.typ'
    end
    return util.normalize(main)
  end

  if file == '' then
    return file
  end

  -- 4. An already open project that includes this file, e.g. the document a
  -- chapter was opened from.
  local open = open_project_including(file)
  if open then
    return open
  end

  -- 5. A file in this or a parent directory that includes this one. Typst
  -- has no marker like `\begin{document}` -- every file compiles on its
  -- own -- so a file that nothing includes is its own main file.
  return search_upwards(file) or file
end

---@param main string
---@return table
local function new_project(main)
  local backend = config.compiler_options()
  local dir = vim.fs.dirname(main)
  local project = {
    main = main,
    dir = dir,
    root = M.find_root(dir),
    name = vim.fn.fnamemodify(main, ':t:r'),
    compiler = nil, -- set by nvim-typst.compiler
    viewer = nil, -- set by nvim-typst.viewer
    output = {}, -- captured compiler output
  }

  local file_info = {
    root = project.root,
    dir = dir,
    target = main,
    target_basename = vim.fn.fnamemodify(main, ':t'),
    target_name = project.name,
  }
  project.file_info = file_info

  local env_out = vim.env.NVIM_TYPST_OUTPUT_DIRECTORY
  local out_dir = env_out or util.resolve(backend.out_dir, file_info) or ''
  project.out_dir_set = out_dir ~= ''
  if out_dir == '' then
    project.out_dir = dir
  elseif out_dir:match('^[/~]') then
    project.out_dir = util.normalize(out_dir)
  else
    project.out_dir = util.normalize(util.join(dir, out_dir))
  end

  return project
end

--- Get (creating if needed) the project for `bufnr`.
---@param bufnr integer|nil
---@return table
function M.get(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr

  local main = buf_main[bufnr]
  if not main or not M.projects[main] then
    main = M.detect_main(bufnr)
    buf_main[bufnr] = main
    if not M.projects[main] then
      M.projects[main] = new_project(main)
    end
  end
  return M.projects[main]
end

--- Drop cached detection for `bufnr` and redetect on next access.
---@param bufnr integer|nil
function M.invalidate(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  buf_main[bufnr] = nil
end

--- Forget a project entirely (used by `:TypstReloadState`).
---@param project table
function M.forget(project)
  for bufnr, main in pairs(buf_main) do
    if main == project.main then
      buf_main[bufnr] = nil
    end
  end
  M.projects[project.main] = nil
end

--- All buffers currently associated with `project`.
---@param project table
---@return integer[]
function M.buffers(project)
  local out = {}
  for bufnr, main in pairs(buf_main) do
    if main == project.main and vim.api.nvim_buf_is_valid(bufnr) then
      out[#out + 1] = bufnr
    end
  end
  return out
end

--- The compiled PDF for `project`.
---@param project table
---@param ext string|nil defaults to 'pdf'
---@return string
function M.output_file(project, ext)
  return util.join(project.out_dir, project.name .. '.' .. (ext or 'pdf'))
end

--- Where scratch data is cached.
---@param project table
---@return string
function M.cache_dir(project)
  local hash = vim.fn.sha256(project.main):sub(1, 16)
  local dir = util.join(config.get('cache_root'), project.name .. '-' .. hash)
  util.mkdir(dir)
  return dir
end

return M
