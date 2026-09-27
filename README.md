# nvim-typst

[![CI](https://img.shields.io/github/actions/workflow/status/leissa/nvim-typst/ci.yml?branch=master&label=CI&logo=github&style=flat-square)](https://github.com/leissa/nvim-typst/actions/workflows/ci.yml)
[![Neovim](https://img.shields.io/badge/Neovim-0.10%2B-57A143?logo=neovim&logoColor=white&style=flat-square)](https://neovim.io)
[![Lua](https://img.shields.io/badge/made%20with-Lua-2C2D72?logo=lua&logoColor=white&style=flat-square)](https://www.lua.org)

A [Typst](https://typst.app) plugin for Neovim, the sibling of
[nvim-tex](https://github.com/leissa/nvim-tex): the same mappings, commands,
option names and events, with `Tex` replaced by `Typst`.

Two rules shape the design:

- **Neovim only.** No Vimscript, no Vim compatibility layer.
- **Structure from tree-sitter, language intelligence from the LSP.** The
  plugin ships no Typst parser and no syntax-group heuristics of its own.
  Structure comes from the `typst` parse tree; completion, diagnostics,
  references, rename and formatting come from
  [tinymist](https://github.com/Myriad-Dreamin/tinymist).

What is left is the part neither of those covers: finding the main file of a
multi-file document, driving `typst watch` and `typst compile`, the quickfix
list, and opening the PDF.

## Status

First milestone: compiler, LSP and tree-sitter integration. Continuous
(`typst watch`) and single shot compilation, a quickfix list filled after every
watch cycle, main file and project root detection, tinymist with the main file
pinned, and tree-sitter highlighting. A test suite runs in CI on Neovim 0.10,
stable and nightly.

Not there yet: motions, text objects, the `ds`/`cs`/`ts` edits, the table of
contents, folding, conceal and citations.

## Requirements

- Neovim 0.10+ (0.11+ recommended)
- [`typst`](https://github.com/typst/typst)
- The `typst` tree-sitter parser — `:TSInstall typst`

Optional: [`tinymist`](https://github.com/Myriad-Dreamin/tinymist), and a PDF
viewer that reloads a changed file (zathura, sioyek, okular, Skim).

`:checkhealth nvim-typst` reports what is missing.

## Installation

nvim-typst works without calling `setup`: the defaults apply as soon as the
plugin loads. Call `require('nvim-typst').setup({...})` only to change them.

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'leissa/nvim-typst',
  ft = { 'typst' },
  opts = {},
}
```

`vim.pack` (built into Neovim 0.12+):

```lua
vim.pack.add({ 'https://github.com/leissa/nvim-typst' })
```

Native packages (`:help packages`):

```sh
git clone https://github.com/leissa/nvim-typst \
  ~/.local/share/nvim/site/pack/plugins/start/nvim-typst
```

## Configuration

```lua
require('nvim-typst').setup({
  compiler = {
    typst = {
      continuous = true,   -- typst watch
      out_dir = 'build',
    },
  },
  view = { general = { executable = 'zathura' } },
})
```

`:TypstInfo!` prints the full effective configuration. The defaults live in
[`lua/nvim-typst/config.lua`](lua/nvim-typst/config.lua) and are documented in
`:help nvim-typst-configuration`.

## Mappings

The keys are nvim-tex's; those whose nvim-tex action has no Typst
counterpart yet are left unmapped.

| Key              | Action                                  |
| ---------------- | --------------------------------------- |
| `<localleader>l` | start / stop compilation (`typst watch`) |
| `<localleader>S` | compile once                            |
| `<localleader>k` | stop — `K` stops all                    |
| `<localleader>v` | view the PDF                            |
| `<localleader>e` | quickfix list — `E` cycles the level, `o` raw output |
| `<localleader>c` | clean — `C` also removes the PDF        |
| `<localleader>i` | project info — `I` full                 |
| `<localleader>g` | status — `G` for all projects           |
| `<localleader>s` | toggle the main file                    |
| `<localleader>x` | reload — `X` clears project state       |

Every mapping has a command behind it (`:TypstCompile`, `:TypstView`,
`:TypstErrors`, …).

## The main file

Compilation always runs on the project's main file, never on the buffer you
happen to be in. It is found from `b:typst_main`, the `main_file` option, a
`// !TYPST main = …` directive, an open document that `#include`s or
`#import`s the buffer, or by following the chain of files including it up
the directory tree. A file nothing includes is its own main file.
`<localleader>s` toggles between the detected main file and the current
buffer.

The project root — Typst's `--root`, against which `/figures/a.svg` resolves —
is the nearest directory holding a `typst.toml` or `.git` (`root_markers`),
or else the main file's directory. The compiler runs there, and tinymist is
rooted there too.

## LSP

nvim-typst starts tinymist unless a tinymist client is already attached, and
pins the main file in it, so that an included chapter is checked as part of the
whole document instead of reporting every label it uses as undefined. It sets
`exportPdf = 'never'`, since nvim-typst does the compiling. See
`:help nvim-typst-lsp`.

## Documentation

`:help nvim-typst`

## Tests

```sh
make test              # the whole suite
make test SPEC=qf      # one spec file
make fmt-check         # what CI enforces
make parser            # build the `typst` parser into .deps
```

The suite runs in a headless Neovim against `tests/minimal_init.lua` and
brings its own runner (`tests/runner.lua`), so there is nothing to install.
Specs that need the `typst` parser use the one `:TSInstall typst` left in
`stdpath('data')/site/parser`, or the one `make parser` builds into `.deps`,
and skip when there is neither; `NVIM_TYPST_PARSER` points at a specific
`typst.so`. Specs that run the compiler skip when `typst` is not installed.

CI runs the suite on Neovim 0.10, stable and nightly, with the parser built
from the revision of
[tree-sitter-typst](https://github.com/uben0/tree-sitter-typst) that
nvim-treesitter pins.

## Disclaimer

This plugin was mostly created with the help of AI.
