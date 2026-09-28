--- Default configuration and user override handling.
---
--- The layout follows nvim-tex, option for option, wherever Typst has the
--- same concept: `compiler.<method>`, `view.<method>`, `qf`, `lsp`,
--- `treesitter` and `mappings` mean the same thing in both plugins.
local M = {}

--- The command that opens a file in the desktop's default application.
---@return string
local function default_opener()
  if vim.fn.has('mac') == 1 then
    return 'open'
  end
  return 'xdg-open'
end

---@type table
M.defaults = {
  enabled = true,

  --- Filetypes the plugin attaches to.
  filetypes = { 'typst' },

  --- Explicit main file. A string, or a function(bufnr) -> string|nil.
  --- When nil the main file is detected (see `nvim-typst.project`).
  main_file = nil,

  --- Files or directories marking the project root -- Typst's `--root`, which
  --- absolute paths like `/figures/a.svg` resolve against. The directory of
  --- the main file is used when none is found above it.
  root_markers = { 'typst.toml', '.git' },

  cache_root = vim.fs.joinpath(vim.fn.stdpath('cache'), 'nvim-typst'),

  compiler = {
    enabled = true,
    --- The options of the active backend live in the table of the same name
    --- below. `typst` is the only backend for now.
    method = 'typst',
    --- Suppress "started"/"stopped"/"success" messages.
    silent = false,
    --- Compile automatically when the buffer is written (single shot only;
    --- continuous mode does its own watching).
    build_on_save = false,

    typst = {
      executable = 'typst',
      --- `true` runs `typst watch`, rebuilding on every change until stopped.
      continuous = true,
      --- Extra flags for `typst compile` / `typst watch`, e.g.
      --- `{ '--font-path', 'fonts' }`. `--root` and `--diagnostic-format`
      --- are passed by nvim-typst itself.
      options = {},
      --- Relative to the main file's directory. Empty: next to the main file.
      out_dir = '',
      --- Functions called with every line of compiler output.
      hooks = {},
    },
  },

  view = {
    enabled = true,
    --- `general` opens the PDF with a command of your choice. Typst has no
    --- SyncTeX, so there is no forward search; viewers that watch the file
    --- (zathura, sioyek, okular, Skim) reload on their own after every
    --- compilation.
    --- `tinymist` opens tinymist's live preview in the browser instead: it
    --- follows every keystroke, `<localleader>v` scrolls it to the cursor
    --- and a click in it jumps to the source. It needs the LSP.
    method = 'general',

    --- `@pdf` is substituted.
    general = {
      executable = default_opener(),
      args = { '@pdf' },
    },

    --- `@url` is substituted. `executable = false` opens nothing and only
    --- reports the URL.
    tinymist = {
      executable = default_opener(),
      args = { '@url' },
      --- Extra flags for `tinymist preview`, e.g. `{ '--invert-colors=auto' }`
      --- or `{ '--preview-mode=slide' }`.
      options = {},
      --- Scroll the preview along whenever the cursor moves.
      follow_cursor = false,
      --- Milliseconds the cursor has to rest before the preview follows.
      follow_delay = 100,
    },
  },

  qf = {
    enabled = true,
    --- Open the quickfix window when the compilation produced entries.
    auto_open = true,
    --- Also open it when there are only warnings (no errors).
    open_on_warning = true,
    --- Lowest severity shown in the quickfix list: 'error' or 'warning'.
    --- `:TypstQfLevel` cycles the level without recompiling.
    level = 'warning',
    --- Jump to the first entry when opening.
    autojump = false,
    --- Keep the quickfix window open after a successful run.
    auto_close = true,
    --- Lua patterns; matching messages are dropped.
    ignore_filters = {},
    --- Height of the quickfix window.
    height = 8,
  },

  lsp = {
    enabled = true,
    --- Set `enabled = false` if you configure tinymist yourself (lspconfig,
    --- `vim.lsp.enable`, ...). The plugin also backs off when a tinymist
    --- client is already attached.
    name = 'tinymist',
    cmd = { 'tinymist' },
    --- Tell tinymist which file is the main file, so that the diagnostics,
    --- completion and references of an included file are those of the
    --- whole document.
    pin_main = true,
    --- tinymist's settings. `rootPath` is filled in from the project.
    settings = {
      --- nvim-typst drives the compiler itself, so tinymist exports nothing.
      exportPdf = 'never',
      formatterMode = 'typstyle',
    },
    --- Extra keys merged into the `vim.lsp.start` config (capabilities,
    --- on_attach, handlers, ...).
    config = {},
  },

  treesitter = {
    enabled = true,
    --- Warn once when the `typst` parser is missing.
    warn_missing_parser = true,
    --- Enable `:h treesitter-highlight` for Typst buffers.
    highlight = true,
  },

  --- Folding through `vim.treesitter.foldexpr()`, with a `folds` query
  --- nvim-typst installs. Needs the `typst` parser.
  fold = {
    enabled = false,
    --- Headings with everything up to the next heading of the same or a
    --- higher level, nested.
    sections = true,
    --- Multi-line `{ ... }`, `( ... )` and `[ ... ]` in code.
    code = true,
    --- Multi-line math, `$ ... $`.
    math = true,
    --- Fenced raw blocks, ```` ```lang ... ``` ````.
    raw = true,
    --- `/* ... */` and runs of `//` line comments.
    comments = true,
  },

  --- Only visible with 'conceallevel' at 1 or more.
  conceal = {
    enabled = true,
    --- `alpha`, `phi.alt`, `Omega` in math.
    greek = true,
    --- The rest of Typst's `sym` in math -- `arrow.r`, `RR`, `in`, `sum` --
    --- and the math shorthands `->`, `<=`, `!=`, `...`.
    math_symbols = true,
    --- `bb(R)`, `cal(A)`, `frak(g)`, `bold(x)`, `sans(x)`, `mono(x)`.
    math_fonts = true,
    --- `x^2`, `x_1`, `x^(n+1)`.
    math_super_sub = true,
    --- `thin`, `med`, `thick`, `quad`, `wide` in math.
    spacing = true,
    --- `#sym.arrow.r` outside math.
    sym = true,
    --- `--`, `---`, `...` outside math.
    text_symbols = true,
    --- `*bold*`, `_emph_`, `#strong[..]`, `#emph[..]`, `#underline[..]`:
    --- the markers are hidden, the text is highlighted.
    styles = true,
    --- `\#` as `#`, `\u{1F600}` as the character.
    escapes = true,
    --- The `-` of a list item as `•`.
    item = true,
    --- Your own: `{ NN = 'ℕ', ['arrow.r.long'] = '⟶' }`. Keys are math
    --- names, or the `name` of `#name` outside math.
    custom = {},
  },

  --- `:TypstCite`: search online, add the entry to the bibliography, cite it.
  cite = {
    --- DBLP, searched through its SPARQL endpoint.
    dblp = {
      enabled = true,
      endpoint = 'https://sparql.dblp.org/sparql',
      max_results = 30,
    },
    --- Key of a new entry: 'short' for `leissa2015graph`, 'source' for the
    --- source's own (`DBLP:conf/cgo/LeissaKH15`, cited as
    --- `#cite(label("..."))`), or a function(entry) returning one.
    key = 'short',
    --- Offer the key for editing before the entry is added.
    edit_key = true,
    --- Downloads go through curl, as a string or list.
    curl = 'curl',
    --- Seconds per request.
    timeout = 20,
  },

  --- Typst-aware indentation through `indentexpr`. Needs the `typst` parser.
  indent = {
    enabled = true,
  },

  toc = {
    --- Window layout: 'vsplit', 'split' or 'tab'.
    split = 'vsplit',
    width = 40,
    height = 15,
    --- Close the TOC after jumping to an entry.
    close_after_jump = true,
    --- Entry types to include.
    show_labels = false,
    show_includes = true,
    show_todos = true,
  },

  --- The `ds*` / `cs*` / `ts*` edits.
  edit = {
    --- How `ts$` lays out the displayed math it makes of inline math:
    --- `'lines'` puts each `$` on a line of its own, `'display'` writes
    --- `$ x $` in place.
    display_math = 'lines',
    --- The answers `csd` accepts, and the pair each one puts in place.
    delim_list = {
      ['('] = { '(', ')' },
      ['['] = { '[', ']' },
      ['{'] = { '{', '}' },
      ['|'] = { '|', '|' },
      ['||'] = { '‖', '‖' },
      ['<'] = { '⟨', '⟩' },
    },
  },

  mappings = {
    enabled = true,
    --- `<localleader>l` compiles, `<localleader>v` views, as in nvim-tex.
    prefix = '<localleader>',
    --- `]]`, `[[`, `]n`, ... in normal, visual and operator-pending mode.
    motions = true,
    --- `a$`, `i$`, `ac`, `ic`, ... in visual and operator-pending mode.
    text_objects = true,
    --- `ds$`, `cs$`, `ts$`, `<F7>`, ...
    surround = true,
    --- `]]` in insert mode closes the innermost open delimiter or math, as
    --- in nvim-tex. Off by default: in Typst, `]]` is ordinary text
    --- (`#strong[#emph[x]]`) and would no longer insert itself.
    insert_close = false,
  },
}

---@type table
M.options = vim.deepcopy(M.defaults)

--- Lists users realistically replace. `vim.tbl_deep_extend` merges
--- list-like tables key by key, which would keep stale trailing entries, so
--- for these the user value is taken verbatim.
local LISTS = {
  { 'filetypes' },
  { 'root_markers' },
  { 'compiler', 'typst', 'options' },
  { 'view', 'general', 'args' },
  { 'view', 'tinymist', 'args' },
  { 'view', 'tinymist', 'options' },
  { 'qf', 'ignore_filters' },
  { 'lsp', 'cmd' },
}

---@param opts table|nil
function M.setup(opts)
  local user = opts or {}
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), user)
  for _, path in ipairs(LISTS) do
    local value = vim.tbl_get(user, unpack(path))
    if value then
      local parent = vim.tbl_get(M.options, unpack(path, 1, #path - 1)) or M.options
      parent[path[#path]] = value
    end
  end
  return M.options
end

--- The options table of the active compiler backend,
--- `compiler[compiler.method]`.
---@return table
function M.compiler_options()
  local compiler = M.options.compiler or {}
  return compiler[compiler.method] or {}
end

--- Convenience accessor: `config.get('compiler', 'typst', 'executable')`.
function M.get(...)
  if select('#', ...) == 0 then
    return M.options
  end
  return vim.tbl_get(M.options, ...)
end

return M
