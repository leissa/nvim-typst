--- Table of contents built from the tree-sitter parse tree.
---
--- The whole project is walked from the main file, following
--- `#include "..."`, so the TOC covers a multi-file document even when only
--- one of its files is open.
local config = require('nvim-typst.config')
local project_mod = require('nvim-typst.project')
local util = require('nvim-typst.util')

local M = {}

--- How many `#include` hops are followed at most.
local MAX_DEPTH = 8

--- Buffer holding the TOC, and the entries it currently shows.
local toc_buf = nil
local entries = {}

--- Current contents of `path`, preferring a loaded buffer over the file.
---@param path string
---@return string
local function contents(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr >= 0 and vim.api.nvim_buf_is_loaded(bufnr) then
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  end
  return table.concat(util.readlines(path), '\n')
end

--- The text of a heading, with the markup of `*strong*` and `_emph_`
--- dropped: `= A *bold* move <label>` is "A bold move".
---@param heading TSNode
---@param source string
---@return string
local function title(heading, source)
  local parts = {}
  local last_end = nil
  local function visit(node)
    for child in node:iter_children() do
      local t = child:type()
      if t == 'strong' or t == 'emph' then
        visit(child)
      elseif child:named() and t ~= 'label' then
        local srow, scol = child:start()
        if last_end and (srow > last_end[1] or scol > last_end[2]) then
          parts[#parts + 1] = ' '
        end
        parts[#parts + 1] = vim.treesitter.get_node_text(child, source)
        last_end = { child:end_() }
      end
    end
  end
  visit(heading)
  return vim.trim((table.concat(parts):gsub('%s+', ' ')))
end

--- The path of an `include` node, without the quotes.
---@param node TSNode
---@param source string
---@return string|nil
local function include_path(node, source)
  local function find(n)
    for child in n:iter_children() do
      if child:type() == 'string' then
        return child
      end
      local found = child:named() and find(child)
      if found then
        return found
      end
    end
  end
  local str = find(node)
  if not str then
    return nil
  end
  return (vim.treesitter.get_node_text(str, source):gsub('^"', ''):gsub('"$', ''))
end

---@param file string
---@param root string
---@param out table[]
---@param seen table<string, boolean>
---@param depth integer
local function walk_file(file, root, out, seen, depth)
  if seen[file] or depth > MAX_DEPTH then
    return
  end
  seen[file] = true

  local source = contents(file)
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, 'typst')
  if not ok or not parser then
    return
  end
  local tree = parser:parse()[1]
  if not tree then
    return
  end

  local opts = config.get('toc')
  -- Entries other than headings sit one level below the current heading.
  local level = 0

  ---@param node TSNode
  ---@param kind string
  ---@param text string
  local function add(node, kind, text, entry_level)
    out[#out + 1] = {
      file = file,
      lnum = node:start() + 1,
      level = entry_level or level + 1,
      kind = kind,
      title = text,
    }
  end

  ---@param node TSNode
  local function visit(node)
    local kind = node:type()

    if kind == 'heading' then
      local marker = node:child(0)
      level = marker and #vim.treesitter.get_node_text(marker, source) or 1
      add(node, 'heading', title(node, source), level)
    elseif kind == 'include' then
      local raw = include_path(node, source)
      if raw then
        if opts.show_includes then
          add(node, 'include', 'include: ' .. raw)
        end
        local target = project_mod.resolve(raw, file, root)
        if target and util.is_file(target) then
          local saved = level
          walk_file(target, root, out, seen, depth + 1)
          level = saved
        end
      end
      return
    elseif kind == 'label' and opts.show_labels then
      add(node, 'label', 'label: ' .. vim.treesitter.get_node_text(node, source):sub(2, -2))
    elseif kind == 'comment' and opts.show_todos then
      -- The first line of the comment, without its `//` or `/*`.
      local text = vim.treesitter.get_node_text(node, source):match('^[^\n]*')
      text = text:gsub('^//+%s*', ''):gsub('^/%*+%s*', ''):gsub('%s*%*+/$', '')
      for _, word in ipairs({ 'TODO', 'FIXME', 'XXX' }) do
        if vim.startswith(text, word) then
          add(node, 'todo', vim.trim(text))
          break
        end
      end
    end

    for child in node:iter_children() do
      if child:named() then
        visit(child)
      end
    end
  end

  visit(tree:root())
end

--- Build the TOC entries for `project`.
---@param project table
---@return table[]
function M.build(project)
  local out = {}
  walk_file(project.main, project.root, out, {}, 0)
  return out
end

---@param entry table
---@return string
local function render(entry)
  return string.rep('  ', entry.level - 1) .. entry.title
end

--- Jump to the entry under the cursor in the TOC window.
local function jump()
  local index = vim.api.nvim_win_get_cursor(0)[1]
  local entry = entries[index]
  if not entry then
    return
  end

  local close = config.get('toc', 'close_after_jump')
  local toc_win = vim.api.nvim_get_current_win()

  -- Find a window that is not the TOC to jump in.
  local target_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= toc_win then
      target_win = win
      break
    end
  end
  if not target_win then
    vim.cmd('vsplit')
    target_win = vim.api.nvim_get_current_win()
  end

  vim.api.nvim_set_current_win(target_win)
  if util.normalize(vim.api.nvim_buf_get_name(0)) ~= entry.file then
    vim.cmd('edit ' .. vim.fn.fnameescape(entry.file))
  end
  vim.api.nvim_win_set_cursor(0, { math.min(entry.lnum, vim.api.nvim_buf_line_count(0)), 0 })
  vim.cmd('normal! zv')
  vim.cmd('normal! zz')

  if close and vim.api.nvim_win_is_valid(toc_win) then
    vim.api.nvim_win_close(toc_win, true)
  end
end

--- The entry the cursor of the current window is in: the last one at or
--- above it in the same file.
---@return integer|nil index
local function current_entry()
  local file = util.normalize(vim.api.nvim_buf_get_name(0))
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local found = nil
  for index, entry in ipairs(entries) do
    if entry.file == file and entry.lnum <= lnum then
      found = index
    end
  end
  return found
end

---@param project table
---@return integer bufnr
local function create_buffer(project)
  entries = M.build(project)

  local lines = {}
  for _, entry in ipairs(entries) do
    lines[#lines + 1] = render(entry)
  end
  if #lines == 0 then
    lines = { '(no headings found)' }
  end

  if not toc_buf or not vim.api.nvim_buf_is_valid(toc_buf) then
    toc_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(toc_buf, 'nvim-typst://toc')
  end

  vim.bo[toc_buf].modifiable = true
  vim.api.nvim_buf_set_lines(toc_buf, 0, -1, false, lines)
  vim.bo[toc_buf].modifiable = false
  vim.bo[toc_buf].buftype = 'nofile'
  vim.bo[toc_buf].bufhidden = 'hide'
  vim.bo[toc_buf].swapfile = false
  vim.bo[toc_buf].filetype = 'nvimtypsttoc'

  vim.keymap.set('n', '<CR>', jump, { buffer = toc_buf, nowait = true })
  vim.keymap.set('n', '<2-LeftMouse>', jump, { buffer = toc_buf, nowait = true })
  vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = toc_buf, nowait = true })
  vim.keymap.set('n', 'r', function()
    M.open(project)
  end, { buffer = toc_buf, nowait = true })

  return toc_buf
end

---@return integer|nil
function M.window()
  if toc_buf and vim.api.nvim_buf_is_valid(toc_buf) then
    local win = vim.fn.bufwinid(toc_buf)
    return win ~= -1 and win or nil
  end
  return nil
end

--- Open the TOC of `project`, with the cursor on the heading the cursor is
--- under in the current window.
---@param project table
function M.open(project)
  local from_toc = M.window() == vim.api.nvim_get_current_win()
  local bufnr = create_buffer(project)
  local here = not from_toc and current_entry() or nil
  local opts = config.get('toc')

  local win = M.window()
  if not win then
    if opts.split == 'tab' then
      vim.cmd('tabnew')
    elseif opts.split == 'split' then
      vim.cmd('botright split')
    else
      vim.cmd('topleft vsplit')
    end

    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, bufnr)
    if opts.split == 'split' then
      vim.api.nvim_win_set_height(win, opts.height)
    elseif opts.split == 'vsplit' then
      vim.api.nvim_win_set_width(win, opts.width)
    end
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    vim.wo[win].winfixwidth = opts.split == 'vsplit'
    vim.wo[win].winfixheight = opts.split == 'split'
  end

  vim.api.nvim_set_current_win(win)
  if here then
    vim.api.nvim_win_set_cursor(win, { here, 0 })
  end
end

---@param project table
function M.toggle(project)
  local win = M.window()
  if win then
    vim.api.nvim_win_close(win, true)
  else
    M.open(project)
  end
end

return M
