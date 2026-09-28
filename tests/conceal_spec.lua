local H = require('tests.helpers')
local conceal = require('nvim-typst.conceal')
local config = require('nvim-typst.config')
local symbols = require('nvim-typst.conceal.symbols')

--- Each line of `lines` as it shows with 'conceallevel' at 2: concealed
--- ranges replaced by their character, styled ones marked `*like this*`.
---@param lines string|string[]
---@param opts table|nil `conceal` configuration
---@return string|string[]
local function shown(lines, opts)
  config.setup({ conceal = opts or {} })
  local single = type(lines) == 'string'
  lines = single and { lines } or lines
  local bufnr = H.buf(lines)
  local rows = conceal.items(bufnr, 0, #lines)
  local out = {}
  for row, line in ipairs(lines) do
    local items = rows[row - 1] or {}
    table.sort(items, function(a, b)
      return a.col < b.col
    end)
    local text, pos = {}, 0
    for _, item in ipairs(items) do
      text[#text + 1] = line:sub(pos + 1, item.col)
      local body = line:sub(item.col + 1, item.end_col)
      if item.hl then
        text[#text + 1] = '*' .. body .. '*'
      else
        text[#text + 1] = item.text
      end
      pos = item.end_col
    end
    text[#text + 1] = line:sub(pos + 1)
    out[row] = table.concat(text)
  end
  return single and out[1] or out
end

describe('conceal', function()
  before_each(H.need_parser)
  after_each(function()
    config.setup({})
    H.cleanup()
  end)

  describe('the symbol table', function()
    it("is Typst's sym module", function()
      T.eq('α', symbols.greek['alpha'])
      T.eq('ϕ', symbols.greek['phi.alt'])
      T.eq('ℝ', symbols.math['RR'])
      T.eq('⟶', symbols.math['arrow.r.long'])
      T.eq('≠', symbols.math['eq.not'])
    end)

    it('holds single visible characters only', function()
      for _, tbl in ipairs({ symbols.greek, symbols.math }) do
        for name, char in pairs(tbl) do
          T.eq(1, vim.fn.strchars(char), name)
          T.falsy(char:match('^%s$'), name)
        end
      end
    end)
  end)

  describe('in math', function()
    it('shows Greek letters and symbols', function()
      T.eq('$α ∈ ℝ, ∑ ∞$', shown('$alpha in RR, sum infinity$'))
    end)

    it('shows symbols with modifiers as a whole', function()
      T.eq('$ϕ ⟶ ⊆ …$', shown('$phi.alt arrow.r.long subset.eq dots.h$'))
    end)

    it('shows `sym.` names and `#sym.` code', function()
      T.eq('$α →$', shown('$sym.alpha #sym.arrow.r$'))
    end)

    it('leaves unknown modifiers alone', function()
      T.eq('$arrow.nope$', shown('$arrow.nope$'))
    end)

    it('shows shorthands', function()
      T.eq('$a → b ≤ c ≠ d ⇔ e …$', shown('$a -> b <= c != d <=> e ...$'))
    end)

    it('leaves the same names alone in text, strings, code and comments', function()
      T.eq('alpha in RR // $alpha$', shown('alpha in RR // $alpha$'))
      T.eq('$"alpha" #f(alpha)$', shown('$"alpha" #f(alpha)$'))
    end)

    it('does not conceal a function name', function()
      T.eq('$in(x)$', shown('$in(x)$'))
    end)

    it('shows super- and subscripts', function()
      T.eq('$x² y₁ z¹²$', shown('$x^2 y_1 z^12$'))
      T.eq('$x⁻¹ yᵢ⁺$', shown('$x^(-1) y_i^+$'))
    end)

    it('drops the parentheses of a script group', function()
      T.eq('$xⁿ⁺¹$', shown('$x^(n+1)$'))
    end)

    it('leaves scripts without a Unicode form alone', function()
      T.eq('$x^q x^(i j)$', shown('$x^q x^(i j)$'))
      -- `x^beta`: the script is a name, shown as such.
      T.eq('$x^β$', shown('$x^beta$'))
    end)

    it('shows font functions of a single letter', function()
      T.eq('$ℝ 𝒜 𝔤 𝐱 𝟙$', shown('$bb(R) cal(A) frak(g) bold(x) bb(1)$'))
      T.eq('$bb(xy) sqrt(x)$', shown('$bb(xy) sqrt(x)$'))
    end)

    it('shows spacing', function()
      T.eq('$a   b$', shown('$a quad b$'))
    end)
  end)

  describe('in markup', function()
    it('shows `#sym.` symbols', function()
      T.eq('A → B', shown('A #sym.arrow.r B'))
    end)

    it('shows dashes and ellipses', function()
      T.eq('a – b — c …', shown('a -- b --- c ...'))
    end)

    it('hides style markers and highlights the text', function()
      T.eq('a *bold* and *emph*', shown('a *bold* and _emph_'))
      T.eq('*x* and *y*', shown('#strong[x] and #emph[y]'))
    end)

    it('highlights a multi-line style line by line', function()
      T.eq({ '*a*', '*b*' }, shown({ '*a', 'b*' }))
    end)

    it('shows escapes', function()
      T.eq('a # b 😀', shown('a \\# b \\u{1F600}'))
    end)

    it('shows bullets', function()
      T.eq({ '• one', '+ two' }, shown({ '- one', '+ two' }))
    end)

    it('leaves raw text alone', function()
      T.eq('`$alpha$ --`', shown('`$alpha$ --`'))
    end)
  end)

  it('switches categories off one by one', function()
    T.eq('$alpha ∈$', shown('$alpha in$', { greek = false }))
    T.eq('$α in$', shown('$alpha in$', { math_symbols = false }))
    T.eq('$x^2$', shown('$x^2$', { math_super_sub = false }))
    T.eq('a -- b', shown('a -- b', { text_symbols = false }))
    T.eq('*b*', shown('*b*', { styles = false }))
  end)

  it('takes custom names', function()
    T.eq(
      '$x ∈ ℕ ⟶$, see ☞',
      shown('$x in NN arrow.r.long$, see #hand', {
        custom = { NN = 'ℕ', ['arrow.r.long'] = '⟶', hand = '☞' },
      })
    )
  end)

  it('draws through the decoration provider', function()
    local bufnr = H.buf({ '$alpha$' })
    conceal.attach(bufnr)
    T.ok(conceal.is_attached(bufnr))
    vim.wo.conceallevel = 2
    -- A redraw runs the provider; it must neither fail nor leave marks
    -- behind, since they are ephemeral.
    vim.cmd('redraw')
    T.eq({}, vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, {}))
    vim.wo.conceallevel = 0
  end)

  it('attaches to Typst buffers when enabled', function()
    local bufnr = H.buf({ '$alpha$' })
    require('nvim-typst').attach(bufnr)
    T.ok(conceal.is_attached(bufnr))
  end)
end)
