local H = require('tests.helpers')
local count = require('nvim-typst.count')

describe('count', function()
  after_each(H.cleanup)

  describe('words', function()
    it('counts runs of non-blanks with a letter or digit in them', function()
      T.eq({ count.words('Hello, world -- 42 .') }, { 3, 12 })
    end)

    it('handles non-ASCII letters', function()
      T.eq({ count.words('Grüße aus Göttingen') }, { 3, 17 })
    end)

    it('counts every CJK character as a word', function()
      T.eq(count.words('中文 text'), 3)
    end)
  end)

  describe('count_source', function()
    before_each(H.need_parser)

    it('counts markup text but not code, math, raw or comments', function()
      local stats = count.count_source(table.concat({
        '#set page(width: 10cm)',
        '#let greet = [not counted]',
        '// a comment',
        '= A heading',
        'Some *bold* and _emph_ text, see @intro.',
        '- item one',
        '- item two',
        '$x^2$ and',
        '$ sum_i a_i $',
        '`raw code` here',
        '#strong[yes #emph[yes]] #figure(image("a.png"), caption: [Cap])',
      }, '\n'))
      -- A heading, Some bold and emph text see, item one item two, and, here,
      -- yes yes Cap.
      T.eq(stats.words, 2 + 6 + 4 + 1 + 1 + 3)
      T.eq(stats.heading_words, 2)
      T.eq(stats.inline, 1)
      T.eq(stats.display, 1)
    end)

    it('does not split words at markup', function()
      T.eq(count.count_source("don't foo*bar*baz").words, 2)
    end)

    it('separates words across lines', function()
      T.eq(count.count_source('one\ntwo').words, 2)
    end)

    it('collects includes', function()
      T.eq(count.count_source('#include "a.typ"\n// #include "b.typ"').includes, { 'a.typ' })
    end)

    it('restricts the count to a line range', function()
      local stats = count.count_source('one two\nthree four five\nsix', { first = 2, last = 2 })
      T.eq(stats.words, 3)
    end)
  end)

  describe('collect', function()
    before_each(H.need_parser)

    it('follows includes from the main file', function()
      local dir = H.tmpdir()
      H.write(dir .. '/main.typ', { '= Main', 'one two', '#include "ch/a.typ"' })
      H.write(dir .. '/ch/a.typ', { 'three', '#include "b.typ"', '#include "missing.typ"' })
      H.write(dir .. '/ch/b.typ', { 'four five' })
      local files = count.collect(H.project(dir .. '/main.typ'))
      T.eq(#files, 4)
      T.eq(count.total(files).words, 6)
      T.ok(files[4].missing)
      local report = count.report(files, dir)
      T.matches('^main%.typ', report[2])
      T.matches('^ch/a%.typ', report[3])
    end)

    it('counts an unsaved buffer as it stands', function()
      local dir = H.tmpdir()
      local main = H.write(dir .. '/main.typ', 'on disk')
      local bufnr = H.buf({ 'one two three' }, { name = main })
      T.eq(count.total(count.collect(H.project(main))).words, 3)
      T.eq(count.total(count.collect(H.project(main), { bufnr = bufnr, first = 1, last = 1 })).words, 3)
    end)

    it('reports the count', function()
      local dir = H.tmpdir()
      local main = H.write(dir .. '/main.typ', 'one two')
      count.count(H.project(main))
      T.ok(H.notified('main%.typ: 2 words'))
      count.count(H.project(main), { letters = true })
      T.ok(H.notified('main%.typ: 6 letters'))
    end)
  end)
end)
