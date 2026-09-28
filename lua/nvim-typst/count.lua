--- Word and letter counts (nvim-tex's `:TexCountWords`).
---
--- There is no texcount for Typst, so the words are read off the parse tree:
--- the markup text of the document -- body, headings, list items, terms and
--- the `[...]` content handed to functions like `#strong` or a figure's
--- caption -- with `#include`s followed from the main file. Math, code, raw
--- text, comments, labels, references and URLs are not counted, nor is the
--- content of `#let`, `#set` and `#show`, which is only typeset where it is
--- used. Formulas are counted separately.
---
--- Unlike texcount this reads the buffers, so unsaved changes are counted.
--- tinymist reports a word count of its own (in its compile status), which
--- needs the LSP; this one only needs the parser.
local project_mod = require('nvim-typst.project')
local util = require('nvim-typst.util')

local M = {}

--- Subtrees that never contribute words.
local SKIP = {
  comment = true,
  raw_span = true,
  raw_blck = true,
  label = true,
  ref = true,
  url = true,
  -- Definitions and rules: their content shows up where it is used.
  let = true,
  set = true,
  show = true,
  import = true,
  include = true,
  string = true,
}

--- Leaves whose text is part of a word.
local WORD_LEAF = { text = true, quote = true }

--- Leaves that separate words.
local SEPARATOR = { shorthand = true, linebreak = true, parbreak = true }

--- How many words and letters `text` holds. A word is a run of non-blank
--- characters with at least one letter or digit in it; CJK characters count
--- as a word each, as texcount has it.
---@param text string
---@return integer words, integer letters
function M.words(text)
  local words, letters = 0, 0
  for token in text:gmatch('%S+') do
    if not token:find('[\128-\255]') then
      local n = select(2, token:gsub('%w', ''))
      letters = letters + n
      if n > 0 then
        words = words + 1
      end
    else
      local has_letter = false
      for _, char in ipairs(vim.fn.split(token, '\\zs')) do
        local class = #char == 1 and (char:match('%w') and 2 or 1) or vim.fn.charclass(char)
        if class == 2 then
          letters = letters + 1
          has_letter = true
        elseif class >= 0x100 then
          -- CJK and the like: a word per character.
          letters = letters + 1
          words = words + 1
        end
      end
      if has_letter then
        words = words + 1
      end
    end
  end
  return words, letters
end

--- Count the text of a Typst source.
---@param source string
---@param opts table|nil `{ first = integer, last = integer }`: only the lines
---  first..last (1-indexed) are counted
---@return table stats `{ words, letters, heading_words, inline, display, includes = string[] }`
function M.count_source(source, opts)
  opts = opts or {}
  local stats = { words = 0, letters = 0, heading_words = 0, inline = 0, display = 0, includes = {} }

  local ok, parser = pcall(vim.treesitter.get_string_parser, source, 'typst')
  if not ok or not parser then
    error("the 'typst' tree-sitter parser is not available")
  end
  local root = parser:parse()[1]:root()

  -- Byte range to count, from the line range.
  local lo, hi = 0, #source
  if opts.first then
    local offset, row = 0, 1
    for line in (source .. '\n'):gmatch('([^\n]*)\n') do
      if row == opts.first then
        lo = offset
      end
      if row == opts.last then
        hi = offset + #line
        break
      end
      offset = offset + #line + 1
      row = row + 1
    end
  end

  --- The text of the paragraph being gathered, per target.
  local chunks = { body = {}, heading = {} }
  local prev_end = nil

  local function flush()
    for kind, parts in pairs(chunks) do
      if #parts > 0 then
        local words, letters = M.words(table.concat(parts))
        stats.words = stats.words + words
        stats.letters = stats.letters + letters
        if kind == 'heading' then
          stats.heading_words = stats.heading_words + words
        end
        chunks[kind] = {}
      end
    end
    prev_end = nil
  end

  ---@param s integer start byte
  ---@param e integer end byte
  ---@param heading boolean
  local function emit(s, e, heading)
    s, e = math.max(s, lo), math.min(e, hi)
    if s >= e then
      return
    end
    local parts = chunks[heading and 'heading' or 'body']
    -- Whatever lies between two pieces of text -- a newline, a list marker,
    -- the `*` of strong text -- separates words when it has blanks in it.
    if prev_end and (prev_end > s or source:sub(prev_end + 1, s):find('%s')) then
      parts[#parts + 1] = ' '
    end
    parts[#parts + 1] = source:sub(s + 1, e)
    prev_end = e
  end

  local function in_range(node)
    local _, _, s = node:start()
    local _, _, e = node:end_()
    return e > lo and s < hi
  end

  ---@param node TSNode
  ---@param code boolean inside code, where only `[...]` content counts
  ---@param heading boolean
  local function walk(node, code, heading)
    local kind = node:type()
    if kind == 'include' and node:named_child(0) and in_range(node) then
      local path = vim.treesitter.get_node_text(node:named_child(0), source):match('^"(.*)"$')
      if path then
        stats.includes[#stats.includes + 1] = path
      end
    end
    if SKIP[kind] or not in_range(node) then
      flush()
      return
    end
    if kind == 'math' then
      flush()
      local _, _, s = node:start()
      if s >= lo then
        local text = vim.treesitter.get_node_text(node, source)
        if text:match('^%$%s') and text:match('%s%$$') then
          stats.display = stats.display + 1
        else
          stats.inline = stats.inline + 1
        end
      end
      return
    end
    if kind == 'content' then
      code = false
    elseif kind == 'code' then
      code = true
    elseif kind == 'heading' then
      flush()
      heading = true
    end

    if WORD_LEAF[kind] then
      if not code then
        local _, _, s = node:start()
        local _, _, e = node:end_()
        emit(s, e, heading)
      end
      return
    end
    if SEPARATOR[kind] or node:named_child_count() == 0 then
      flush()
      return
    end
    for child in node:iter_children() do
      if child:named() then
        walk(child, code, heading)
      end
    end
    if kind == 'heading' or kind == 'code' or kind == 'item' or kind == 'term' then
      flush()
    end
  end

  walk(root, false, false)
  flush()
  return stats
end

--- The source of `file`: the buffer when it is loaded, the file otherwise.
---@param file string
---@return string|nil
local function source_of(file)
  local bufnr = vim.fn.bufnr(file)
  if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  end
  if not util.is_file(file) then
    return nil
  end
  return table.concat(util.readlines(file), '\n')
end

--- Count `file` and, depth first, the files it includes.
---@param file string
---@param root string
---@param source string|nil
---@param opts table|nil passed to `count_source` for this file only
---@param out table[] `{ file, stats }` per file, in document order
---@param seen table<string, boolean>
local function count_file(file, root, source, opts, out, seen)
  if seen[file] then
    return
  end
  seen[file] = true
  source = source or source_of(file)
  if not source then
    out[#out + 1] = { file = file, missing = true }
    return
  end
  local stats = M.count_source(source, opts)
  out[#out + 1] = { file = file, stats = stats }
  for _, path in ipairs(stats.includes) do
    local target = project_mod.resolve(path, file, root)
    if target then
      count_file(target, root, nil, nil, out, seen)
    end
  end
end

--- Count the whole document of `project`, or a line range of a buffer.
---@param project table
---@param opts table|nil `{ bufnr = integer, first = integer, last = integer }`
---@return table[] per file `{ file, stats }` or `{ file, missing = true }`
function M.collect(project, opts)
  opts = opts or {}
  local out = {}
  if opts.first then
    local bufnr = (opts.bufnr == nil or opts.bufnr == 0) and vim.api.nvim_get_current_buf() or opts.bufnr
    local file = util.normalize(vim.api.nvim_buf_get_name(bufnr))
    local source = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    count_file(file, project.root, source, { first = opts.first, last = opts.last }, out, {})
  else
    count_file(project.main, project.root, nil, nil, out, {})
  end
  return out
end

--- Add up per-file results.
---@param files table[]
---@return table
function M.total(files)
  local sum = { words = 0, letters = 0, heading_words = 0, inline = 0, display = 0 }
  for _, entry in ipairs(files) do
    for key in pairs(sum) do
      sum[key] = sum[key] + (entry.stats and entry.stats[key] or 0)
    end
  end
  return sum
end

--- The per-file report `:TypstCountWords!` shows.
---@param files table[]
---@param root string
---@return string[]
function M.report(files, root)
  local function row(name, s)
    return ('%-32s %8d %8d %8d %8d %8d'):format(name, s.words, s.heading_words, s.letters, s.inline, s.display)
  end
  local lines = { ('%-32s %8s %8s %8s %8s %8s'):format('file', 'words', 'headings', 'letters', 'inline', 'display') }
  for _, entry in ipairs(files) do
    local name = vim.fs.normalize(entry.file):gsub('^' .. vim.pesc(root) .. '/', '')
    if entry.missing then
      lines[#lines + 1] = ('%-32s %8s'):format(name, '(missing)')
    else
      lines[#lines + 1] = row(name, entry.stats)
    end
  end
  if #files > 1 then
    lines[#lines + 1] = row('total', M.total(files))
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Words include those in headings; inline and display count formulas.'
  return lines
end

--- `:TypstCountWords` / `:TypstCountLetters`.
---@param project table
---@param opts table|nil `{ letters = boolean, detailed = boolean, first = integer, last = integer }`
function M.count(project, opts)
  opts = opts or {}
  local ok, files = pcall(M.collect, project, opts)
  if not ok then
    util.error(tostring(files):gsub('^.-:%d+: ', ''))
    return
  end

  if opts.detailed then
    local lines = M.report(files, project.root)
    util.scratch('nvim-typst://count', lines, { height = math.min(#lines, 20) })
    return
  end

  local sum = M.total(files)
  local what = opts.first and 'selection' or vim.fn.fnamemodify(project.main, ':t')
  local unit = opts.letters and 'letters' or 'words'
  local missing = {}
  for _, entry in ipairs(files) do
    if entry.missing then
      missing[#missing + 1] = vim.fn.fnamemodify(entry.file, ':~:.')
    end
  end
  local note = #missing > 0 and (' (not found: %s)'):format(table.concat(missing, ', ')) or ''
  util.info(('%s: %d %s%s'):format(what, opts.letters and sum.letters or sum.words, unit, note))
end

return M
