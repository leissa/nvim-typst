--- `<localleader>a`: act on what is under the cursor.
---
--- A reference jumps to its label, or to the bibliography entry of a
--- citation; `#include`/`#import` open the file or the package; a
--- `#bibliography(...)` opens the bibliography. Everything else goes to the
--- LSP.
local cite = require('nvim-typst.cite')
local lsp = require('nvim-typst.lsp')
local project_mod = require('nvim-typst.project')
local qf = require('nvim-typst.qf')
local ts = require('nvim-typst.ts')
local util = require('nvim-typst.util')

local M = {}

--- The characters of a Typst label.
local LABEL = '[%w_%-:%.\128-\255]'

---@param node TSNode
---@param bufnr integer
---@return string
local function text(node, bufnr)
  return vim.treesitter.get_node_text(node, bufnr)
end

--- The contents of a `string` node, without the quotes.
---@param node TSNode
---@param bufnr integer
---@return string
local function unquote(node, bufnr)
  return (text(node, bufnr):gsub('^"(.*)"$', '%1'))
end

--- The name of the function `node` is an argument of: `cite` for the
--- `<key>` in `#cite(<key>)`.
---@param node TSNode
---@param bufnr integer
---@return string|nil
local function callee(node, bufnr)
  local group = node:parent()
  if not group or group:type() ~= 'group' then
    return nil
  end
  local call = group:parent()
  local ident = call and call:type() == 'call' and call:named_child(0)
  return ident and ident:type() == 'ident' and text(ident, bufnr) or nil
end

--- Put the cursor on `lnum`/`col` of `file`, leaving a jumplist entry.
---@param file string
---@param lnum integer 1-indexed
---@param col integer|nil 0-indexed
local function jump(file, lnum, col)
  vim.cmd("normal! m'")
  if util.normalize(vim.api.nvim_buf_get_name(0)) ~= file then
    vim.cmd('edit ' .. vim.fn.fnameescape(file))
  end
  vim.api.nvim_win_set_cursor(0, { lnum, col or 0 })
  vim.cmd('normal! zz')
end

--- Where `<name>` is attached in `lines`: the label nodes of the parse tree
--- that are not the argument of a call -- `#ref(<name>)` refers, it does
--- not define. Without the parser, a scan that skips `(<name>`.
---@param lines string[]
---@param name string
---@return integer|nil lnum, integer|nil col
function M.find_label(lines, name)
  local wanted = '<' .. name .. '>'
  local source = table.concat(lines, '\n')
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, 'typst')
  if ok and parser then
    local found
    local function walk(node)
      if found then
        return
      end
      if node:type() == 'label' then
        local parent = node:parent()
        if (not parent or parent:type() ~= 'group') and vim.treesitter.get_node_text(node, source) == wanted then
          local row, col = node:range()
          found = { row + 1, col }
        end
        return
      end
      for child in node:iter_children() do
        if child:named() then
          walk(child)
        end
      end
    end
    walk(parser:parse()[1]:root())
    if found then
      return found[1], found[2]
    end
    return nil
  end

  for lnum, line in ipairs(lines) do
    local pos = 1
    while true do
      local s, e = line:find(wanted, pos, true)
      if not s then
        break
      end
      if not line:sub(1, s - 1):match('[(,]%s*$') and not line:sub(1, s - 1):find('//', 1, true) then
        return lnum, s - 1
      end
      pos = e + 1
    end
  end
  return nil
end

--- Jump to the label `name` in any file of the document.
---@param project table
---@param name string
---@return boolean
function M.goto_label(project, name)
  for _, file in ipairs(cite.files(project)) do
    local lnum, col = M.find_label((cite.file_lines(file)), name)
    if lnum then
      jump(file, lnum, col)
      return true
    end
  end
  return false
end

--- Jump to the entry `key` in one of the bibliographies: a BibTeX entry or
--- a top-level key of a Hayagriva file.
---@param project table
---@param key string
---@return boolean
function M.goto_bib_entry(project, key)
  for _, bib in ipairs(cite.bibliographies(project)) do
    local lines = cite.file_lines(bib)
    if bib:match('%.ya?ml$') then
      for lnum, line in ipairs(lines) do
        if line:match('^' .. vim.pesc(key) .. '%s*:') or line:match('^"' .. vim.pesc(key) .. '"%s*:') then
          jump(bib, lnum)
          return true
        end
      end
    else
      for _, entry in ipairs(cite.bib_entries(lines)) do
        if entry.key == key then
          jump(bib, entry.lnum)
          return true
        end
      end
    end
  end
  return false
end

--- Jump to what `key` names: the citation first when `citation` is set, the
--- label first otherwise. A Typst reference is either.
---@param project table
---@param key string
---@param citation boolean
local function goto_key(project, key, citation)
  local first, second = M.goto_label, M.goto_bib_entry
  if citation then
    first, second = second, first
  end
  if not first(project, key) and not second(project, key) then
    util.warn(('no label or bibliography entry %s'):format(key))
  end
end

--- The source directory of the package `spec` (`@preview/cetz:0.3.1`).
---@param spec string
---@param root string
---@return string|nil
function M.package_dir(spec, root)
  if not spec:match('^@[^/]+/[^:/]+:[^/]+$') then
    return nil
  end
  return vim.fs.dirname(qf.resolve_path(spec .. '/typst.toml', root))
end

--- Open the entry point of a package, as its `typst.toml` names it, or its
--- directory.
---@param spec string
---@param root string
local function open_package(spec, root)
  local dir = M.package_dir(spec, root)
  if not dir or not util.is_dir(dir) then
    util.warn(('%s is not downloaded yet; compile the document once'):format(spec))
    return
  end
  for _, line in ipairs(util.readlines(util.join(dir, 'typst.toml'))) do
    local entry = line:match('^%s*entrypoint%s*=%s*"([^"]+)"')
    if entry and util.is_file(util.join(dir, entry)) then
      vim.cmd('edit ' .. vim.fn.fnameescape(util.join(dir, entry)))
      return
    end
  end
  vim.cmd('edit ' .. vim.fn.fnameescape(dir))
end

--- Open the file `path` names, as Typst resolves it from `file`.
---@param project table
---@param path string
---@param file string
local function open_path(project, path, file)
  if path:match('^@') then
    open_package(path, project.root)
    return
  end
  local target = project_mod.resolve(path, file, project.root)
  if target and util.is_file(target) then
    vim.cmd('edit ' .. vim.fn.fnameescape(target))
    return
  end
  util.warn('cannot open ' .. path)
end

--- The node under the cursor.
---@param bufnr integer
---@return TSNode|nil
local function node_at_cursor(bufnr)
  local node = ts.node_at_cursor(bufnr)
  -- On the `#` of `#import ...`, the node is the `code` around the import.
  if node and node:type() == 'code' and node:named_child(0) then
    node = node:named_child(0)
  end
  return node
end

--- The first `string` child of `node`.
---@param node TSNode
---@return TSNode|nil
local function string_child(node)
  for child in node:iter_children() do
    if child:type() == 'string' then
      return child
    end
  end
  return nil
end

--- The web page documenting the package `spec`: its Typst Universe page for
--- `@preview/...`, nil for other namespaces, which are not published.
---@param spec string
---@return string|nil
function M.package_url(spec)
  local name, version = spec:match('^@preview/([^:/]+):?([^:/]*)$')
  if not name then
    return nil
  end
  return 'https://typst.app/universe/package/' .. name .. (version ~= '' and ('/' .. version) or '')
end

--- `K`: the documentation of the package imported under the cursor -- its
--- Universe page, or the README of a local package -- and the LSP hover
--- everywhere else.
---@param project table
function M.doc_package(project)
  local bufnr = vim.api.nvim_get_current_buf()
  local import = ts.ancestor(node_at_cursor(bufnr), { import = true, include = true })
  local path = import and string_child(import)
  local spec = path and unquote(path, bufnr)
  if spec and spec:match('^@') then
    local url = M.package_url(spec)
    if url then
      vim.ui.open(url)
      util.info('opening ' .. url)
      return
    end
    local dir = M.package_dir(spec, project.root)
    for _, readme in ipairs(dir and { 'README.md', 'README.typ', 'README' } or {}) do
      local file = util.join(dir, readme)
      if util.is_file(file) then
        vim.cmd('edit ' .. vim.fn.fnameescape(file))
        return
      end
    end
    util.warn('no documentation for ' .. spec)
    return
  end

  if lsp.client(bufnr) then
    vim.lsp.buf.hover()
    return
  end
  util.warn('no package under the cursor, and no LSP to ask')
end

--- Act on whatever is under the cursor.
---@param project table
function M.menu(project)
  local bufnr = vim.api.nvim_get_current_buf()
  local file = util.normalize(vim.api.nvim_buf_get_name(bufnr))
  local node = node_at_cursor(bufnr)

  -- `@key`, `@key[supplement]`: a label or a citation.
  local ref = ts.ancestor(node, { ref = true })
  if ref then
    local key = text(ref, bufnr):match('^@(' .. LABEL .. '+)')
    if key then
      goto_key(project, (key:gsub('[.:]+$', '')), false)
      return
    end
  end

  -- `<key>` as an argument: `#cite(<key>)` cites, `#ref(<key>)` refers. A
  -- label anywhere else is attached, so its references are what is asked.
  local label = ts.ancestor(node, { label = true })
  if label then
    local fn = callee(label, bufnr)
    if fn then
      goto_key(project, text(label, bufnr):sub(2, -2), fn == 'cite')
      return
    end
    if lsp.client(bufnr) then
      vim.lsp.buf.references()
      return
    end
  end

  local include = ts.ancestor(node, { include = true, import = true })
  if include then
    local path = string_child(include)
    if path then
      open_path(project, unquote(path, bufnr), file)
      return
    end
  end

  -- `#cite(label("DBLP:..."))` and `#bibliography("refs.bib")`.
  local str = ts.ancestor(node, { string = true })
  if str then
    local fn = callee(str, bufnr)
    if fn == 'label' then
      local call = str:parent():parent()
      goto_key(project, unquote(str, bufnr), callee(call, bufnr) == 'cite')
      return
    end
    local group = str:parent()
    if group and group:type() == 'group' and not fn then
      fn = callee(group, bufnr) -- `#bibliography(("a.bib", "b.bib"))`
    end
    if fn == 'bibliography' then
      open_path(project, unquote(str, bufnr), file)
      return
    end
  end

  if lsp.client(bufnr) then
    vim.lsp.buf.definition()
    return
  end
  util.info('nothing to do here')
end

return M
