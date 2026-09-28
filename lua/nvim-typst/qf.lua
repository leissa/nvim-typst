--- Typst diagnostics into the quickfix list.
---
--- The compiler runs with `--diagnostic-format short`, so every diagnostic is
--- a single line:
---
---   chapters/intro.typ:12:5: error: unknown variable: foo
---   warning: unknown font family: nosuchfont
---
--- Paths are relative to the directory typst runs in, which is the project
--- root. A diagnostic inside a package names it by its spec, as in
--- `@preview/cetz:0.3.1/src/draw.typ`, and is resolved into the package
--- directory. A diagnostic without a location is attributed to the main file.
---
--- The list shows messages at or above `qf.level` (`'warning'` by default);
--- `:TypstQfLevel` cycles the level without recompiling.
local config = require('nvim-typst.config')
local util = require('nvim-typst.util')

local M = {}

--- Ordering of the severities, lowest (most severe) first.
local RANK = { E = 1, W = 2 }

--- `qf.level` values, mapped onto the same scale.
local LEVEL_RANK = { error = 1, warning = 2 }

--- Cycled through by `M.cycle_level`.
local LEVEL_ORDER = { 'error', 'warning' }

local TYPE = { error = 'E', warning = 'W' }

--- Session override for `qf.level`, set by `M.set_level`.
---@type string|nil
local level_override = nil

---@param message string
---@return boolean
local function ignored(message)
  for _, pattern in ipairs(config.get('qf', 'ignore_filters') or {}) do
    if message:match(pattern) then
      return true
    end
  end
  return false
end

--- The severity currently shown, honouring a `M.set_level` override.
---@return string
function M.level()
  local level = level_override or config.get('qf', 'level') or 'warning'
  if not LEVEL_RANK[level] then
    util.warn(("unknown qf.level %q, falling back to 'warning'"):format(tostring(level)))
    return 'warning'
  end
  return level
end

--- Show messages at or above `level` (`'error'` or `'warning'`).
---@param level string
function M.set_level(level)
  if not LEVEL_RANK[level] then
    util.error(('unknown qf.level %q, expected one of: %s'):format(tostring(level), table.concat(LEVEL_ORDER, ', ')))
    return
  end
  level_override = level
end

--- Step to the next severity, wrapping around.
---@return string the new level
function M.cycle_level()
  local current = M.level()
  for i, level in ipairs(LEVEL_ORDER) do
    if level == current then
      level_override = LEVEL_ORDER[i % #LEVEL_ORDER + 1]
      break
    end
  end
  return M.level()
end

---@return string[]
function M.levels()
  return vim.deepcopy(LEVEL_ORDER)
end

--- Where typst keeps the packages of `namespace`: `@local` ones in the data
--- directory, downloaded ones in the cache. The same environment variables
--- as typst's own are honoured.
---@param namespace string
---@return string
local function package_dir(namespace)
  if namespace == 'local' then
    local base = vim.env.TYPST_PACKAGE_PATH
    if not base then
      local data = vim.fn.has('mac') == 1 and vim.fs.normalize('~/Library/Application Support')
        or vim.env.XDG_DATA_HOME
        or vim.fs.normalize('~/.local/share')
      base = util.join(data, 'typst', 'packages')
    end
    return util.join(base, namespace)
  end
  local base = vim.env.TYPST_PACKAGE_CACHE_PATH
  if not base then
    local cache = vim.fn.has('mac') == 1 and vim.fs.normalize('~/Library/Caches')
      or vim.env.XDG_CACHE_HOME
      or vim.fs.normalize('~/.cache')
    base = util.join(cache, 'typst', 'packages')
  end
  return util.join(base, namespace)
end

--- The file a diagnostic path names.
---@param path string
---@param root string
---@return string
function M.resolve_path(path, root)
  local namespace, name, version, rest = path:match('^@([^/]+)/([^:/]+):([^/]+)/(.+)$')
  if namespace then
    return util.join(package_dir(namespace), name, version, rest)
  end
  if path:match('^[/~]') then
    return util.normalize(path)
  end
  return util.normalize(util.join(root, path))
end

--- Typst counts columns in characters, the quickfix list in bytes.
---@param cache table<string, string[]> file -> lines, filled on demand
---@param file string
---@param lnum integer
---@param col integer
---@return integer
local function byte_col(cache, file, lnum, col)
  if not cache[file] then
    cache[file] = util.readlines(file)
  end
  local line = cache[file][lnum]
  if not line then
    return col
  end
  local index = vim.fn.byteidx(line, col - 1)
  return index >= 0 and index + 1 or col
end

--- Parse typst's short diagnostics into quickfix items.
---@param lines string[]
---@param root string directory relative paths resolve against
---@param main string file used when a diagnostic has no location
---@return table[] items
function M.parse(lines, root, main)
  local items = {}
  local cache = {}
  for _, line in ipairs(lines) do
    local file, lnum, col, severity, message = line:match('^(%S.-):(%d+):(%d+): (%a+): (.*)$')
    local item
    if file and TYPE[severity] then
      local filename = M.resolve_path(file, root)
      item = {
        filename = filename,
        lnum = tonumber(lnum),
        col = byte_col(cache, filename, tonumber(lnum), tonumber(col)),
        type = TYPE[severity],
        text = message,
      }
    else
      severity, message = line:match('^(%a+): (.*)$')
      if severity and TYPE[severity] then
        item = { filename = main, lnum = 0, type = TYPE[severity], text = message }
      end
    end
    if item and not ignored(item.text) then
      item.text = vim.trim(item.text)
      items[#items + 1] = item
    end
  end
  return items
end

--- Collect all diagnostics of `project`'s last run.
---@param project table
---@return table[]
function M.collect(project)
  local items = M.parse(project.last_output or {}, project.root, project.main)
  -- A compiled selection points its diagnostics back at the buffer.
  if project.qf_translate then
    items = vim.tbl_map(project.qf_translate, items)
  end
  return items
end

--- Split `items` into those the current level shows and those it hides,
--- errors first so that the interesting entries are at the top of the list.
---@param items table[]
---@return table[] shown, integer hidden
local function apply_level(items)
  local max_rank = LEVEL_RANK[M.level()]
  local shown = {}
  local hidden = 0
  for _, item in ipairs(items) do
    if (RANK[item.type] or RANK.W) <= max_rank then
      shown[#shown + 1] = item
    else
      hidden = hidden + 1
    end
  end
  -- `table.sort` is not stable, so carry the original order explicitly.
  for index, item in ipairs(shown) do
    item._index = index
  end
  table.sort(shown, function(a, b)
    local ra, rb = RANK[a.type] or RANK.W, RANK[b.type] or RANK.W
    if ra ~= rb then
      return ra < rb
    end
    return a._index < b._index
  end)
  for _, item in ipairs(shown) do
    item._index = nil
  end
  return shown, hidden
end

--- Fill the quickfix list from `project`'s last run and open it if configured.
---@param project table
---@param opts table|nil `{ force_open = boolean, silent = boolean }`
---@return integer errors, integer warnings
function M.update(project, opts)
  opts = opts or {}
  if not config.get('qf', 'enabled') then
    return 0, 0
  end

  local all = M.collect(project)
  local items, hidden = apply_level(all)

  local errors, warnings = 0, 0
  for _, item in ipairs(all) do
    if item.type == 'E' then
      errors = errors + 1
    else
      warnings = warnings + 1
    end
  end

  local title = ('nvim-typst: %s [%s]'):format(vim.fn.fnamemodify(project.main, ':t'), M.level())
  if hidden > 0 then
    title = title .. (' (%d hidden)'):format(hidden)
  end
  vim.fn.setqflist({}, ' ', { title = title, items = items })

  project.qf_items = items
  project.qf_errors, project.qf_warnings = errors, warnings
  project.qf_hidden = hidden

  local should_open = opts.force_open
    or (config.get('qf', 'auto_open') and (errors > 0 or (warnings > 0 and config.get('qf', 'open_on_warning'))))

  if should_open then
    M.open({ silent = opts.silent, hidden = hidden })
  elseif config.get('qf', 'auto_close') and #items == 0 then
    M.close()
  end

  return errors, warnings
end

---@param opts table|nil `{ silent = boolean, hidden = integer }`
function M.open(opts)
  opts = opts or {}
  local items = vim.fn.getqflist()
  if #items == 0 then
    local hidden = opts.hidden or 0
    if hidden > 0 then
      util.info(('No entries at level %q (%d hidden, :TypstQfLevel to show more)'):format(M.level(), hidden))
    else
      util.info('No errors or warnings')
    end
    return
  end

  local winid = vim.api.nvim_get_current_win()
  vim.cmd('botright copen ' .. (config.get('qf', 'height') or 8))
  if config.get('qf', 'autojump') then
    vim.cmd('cfirst')
  elseif opts.silent ~= false then
    vim.api.nvim_set_current_win(winid)
  end
end

function M.close()
  vim.cmd('cclose')
end

return M
