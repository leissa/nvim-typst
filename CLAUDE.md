# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
make test                  # whole suite, headless Neovim against tests/minimal_init.lua
make test SPEC=qf          # one spec file (basename of tests/<name>_spec.lua)
make test SPEC='qf project'
make fmt                   # stylua lua plugin tests
make fmt-check             # what CI enforces
make doc                   # regenerate doc/tags (after editing doc/nvim-typst.txt)
make parser                # build the pinned `typst` tree-sitter parser into .deps/parser
python3 scripts/gen_symbols.py  # regenerate lua/nvim-typst/conceal/symbols.lua from the installed `typst`
```

Specs needing the tree-sitter parser or the `typst` binary skip when they are missing. Set
`NVIM_TYPST_REQUIRE_PARSER=1` / `NVIM_TYPST_REQUIRE_TYPST=1` to turn those skips into failures (CI does);
`NVIM_TYPST_PARSER=/path/typst.so` points at a specific parser. CI runs on Neovim v0.10.4, stable and nightly, so
code must work on 0.10. The parser revision `TS_TYPST_REV` is pinned in both `Makefile` and
`.github/workflows/ci.yml` — keep them in sync.

## Design rules

- **Neovim only, pure Lua.** No Vimscript, no Vim compatibility.
- **Structure from tree-sitter, language intelligence from the LSP (tinymist).** The plugin ships no Typst parser or
  syntax heuristics of its own. What it does own: main-file/project detection, driving `typst watch`/`typst compile`,
  the quickfix list, and opening the PDF.
- **Sibling of [nvim-tex](https://github.com/leissa/nvim-tex).** Mappings, commands, option names and `User` events
  mirror nvim-tex with `Tex` → `Typst` (e.g. `:TypstCompile`, `User NvimTypstAttach`). nvim-tex actions without a
  Typst counterpart are left unmapped rather than invented. Keep this parity when adding features.
- **No runtime or test dependencies.** `tests/runner.lua` is the entire test framework (`describe`/`it`/
  `before_each`/`after_each` globals, assertions on `T`: `eq`, `ok`, `matches`, `contains`, `raises`, `skip`, …);
  `tests/helpers.lua` (`H`) provides tmpdirs, buffers, `H.project`, `H.wait`, `H.need_parser`/`H.need_typst`.
- `setup()` is optional: `plugin/nvim-typst.lua` calls `require('nvim-typst').init()` with defaults; `setup` merges
  options and re-attaches already-open buffers.

## Architecture

- **Projects are the unit of state** (`project.lua`). Each buffer maps to one project keyed by the absolute path of its
  main file; `M.projects[main]` holds the compiler job, viewer handle, and last output, so all buffers of a document
  share one compilation. Main file detection order: `b:typst_main`, `main_file` option, `// !TYPST main = …` directive
  (top/bottom 5 lines), an open document that `#include`s/`#import`s the buffer, then searching upward for includers.
  `root` (Typst's `--root`, from `root_markers` like `typst.toml`/`.git`) is distinct from `dir` (main file's dir).
  Compilation always targets the main file, never the current buffer.
- **Compiler** (`compiler/init.lua`) manages one job per project and is backend-agnostic; `compiler/typst.lua` is the
  backend (`build_cmd`, `clean_files`, and line predicates `is_start_line`/`is_finished_line`/`is_failure_line`).
  Typst writes no log, so diagnostics are parsed from stdout (`--diagnostic-format short`). In watch mode a cycle ends
  on the `compiled …` line but diagnostics follow it, hence the `settle_ms` delay before `qf.update`.
  `compile` toggles in continuous mode. Events are fired as `User NvimTypst<Name>` with plain data only
  (`main`, `root`, `status`) — job handles can't cross the autocmd boundary.
- **qf.lua** parses `file:line:col: severity: msg` into quickfix items, converting Typst's character columns to byte
  columns and attributing location-less errors to the main file.
- **lsp.lua** starts tinymist (unless a client with that name is already attached) and pins the main file so included
  chapters are checked in context; sets `exportPdf = 'never'` since the plugin compiles.
- **viewer/** mirrors compiler/: `init.lua` dispatches to a backend (`general.lua`, a generic external opener).
  `viewer/tinymist.lua` is the live preview: it runs inside the tinymist LSP (`tinymist.doStartPreview`/
  `scrollPreview`/`doKillPreview` via `workspace/executeCommand`); inverse search arrives as `window/showDocument`,
  which Neovim handles itself. Backends with their own `view`/`close`/`forward_search` bypass the PDF path.
- **Tree-sitter features**, all on top of `ts.lua` (`node_at_cursor`, `ancestor`, `collect`, node-type sets):
  `motions.lua` and `textobj.lua` export a `M.map` table (lhs → fn) that `keymaps.lua` loops over; `surround.lua`
  (`ds`/`cs`/`ts`, `<F6>`, `<F7>`, insert `]]`); `toc.lua` (follows `#include`s, parses unloaded files with
  `get_string_parser`); `fold.lua` (installs its own `folds` query with option-reading predicates); `indent.lua`;
  `conceal/` (decoration provider; `symbols.lua` is generated by `scripts/gen_symbols.py` — never edit it by hand);
  `count.lua` (word count); `imaps.lua` (insert-mode math mappings, nvim-tex's `imaps`; asks about the insertion
  point, not the character under the cursor, and reparses with a `$` added when unclosed math left an error).
  In math the parser gives brackets of calls/groups the node type `(`/`)` whatever the bracket — compare text.
- **cite/** (DBLP via SPARQL + curl, appends to the first `.bib` a `#bibliography` names, inserts `@key`) and
  **context.lua** (`<localleader>a`: jump to label/bib entry, open include/import/package).
  `compiler.compile_selected` writes a hidden `.<name>.selected.typ` next to the buffer (so relative paths resolve),
  prefixed with the main file's preamble, and maps diagnostics back via `project.qf_translate`; it is
  `compile_fragment(project, name, …)`, which also backs `preview.lua` (`<localleader>p`: math/code under the
  cursor on a cropped page, `#show: template` left out). Fragments live in `project.fragments[name]`; with
  snacks.nvim (`viewer/snacks.lua`) typst renders them as PNG (`fragment.format`), shown below their last line.
- **init.lua** wires everything on `FileType`: buffer options, tree-sitter highlighting (only if a `highlights` query
  exists, otherwise regex syntax is kept), conceal/indent/fold, LSP, keymaps, build-on-save, and kills running watches
  on `VimLeavePre`.
- Defaults live in `config.lua` (`config.get('compiler', 'typst')` style access); user docs in
  `doc/nvim-typst.txt` — update both when changing options.

## Style

stylua: 2-space indent, 120 columns, single quotes. Modules use `local M = {}` with `---` LuaLS annotations.
