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
    --- `general` is the only method for now: it runs a command of your
    --- choice. Typst has no SyncTeX, so there is no forward search; viewers
    --- that watch the file (zathura, sioyek, okular, Skim) reload on their
    --- own after every compilation.
    method = 'general',

    --- `@pdf` is substituted.
    general = {
      executable = default_opener(),
      args = { '@pdf' },
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

  mappings = {
    enabled = true,
    --- `<localleader>l` compiles, `<localleader>v` views, as in nvim-tex.
    prefix = '<localleader>',
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
