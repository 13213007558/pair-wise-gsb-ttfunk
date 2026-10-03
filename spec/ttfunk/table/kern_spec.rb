# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'ttfunk/subset'

describe TTFunk::Table::Kern do
  include KernFontHelpers

  let(:font) { TTFunk::File.open(test_font('DejaVuSans')) }

  # A font with three kern subtables: a class-based one, a horizontal
  # override one and a vertical one. Both sides of the class table share
  # classes; the X row and Q column are used only by glyphs that subsetting
  # removes.
  let(:crafted_font) do
    g = ->(char) { font.cmap.unicode.first[char.ord] }

    # left classes (byte offsets): default row, A/V, T, X (removed)
    left_classes = {
      g.call('A') => 8, g.call('V') => 8, g.call('T') => 16, g.call('X') => 24
    }
    # right classes (column indices): default, comma, period, Q (removed)
    right_classes = {
      g.call(',') => 1, g.call('.') => 2, g.call('Q') => 3
    }
    matrix = [
      [0, 5, 11, -9],        # default left
      [-40, -55, -60, -130], # A/V
      [-70, -25, -30, -200], # T
      [-50, -9, -15, -250],  # X (dead after subsetting)
    ]

    subtables = [
      format2_subtable(matrix, left_classes, right_classes),
      format0_subtable({ [g.call('A'), g.call('A')] => -102 },
                       coverage: 0x0008),
      format0_subtable({ [g.call('T'), g.call('V')] => -777 },
                       coverage: 0x0001),
    ]
    blob = rebuild_font_with_kern(
      test_font('DejaVuSans'), kern_table(subtables)
    )
    TTFunk::File.new(blob)
  end

  def gid(char, source = font)
    source.cmap.unicode.first[char.ord]
  end

  def subset_of(source, characters, **options)
    subset = TTFunk::Subset.for(source, :unicode)
    characters.each { |char| subset.use(char.ord) }
    TTFunk::File.new(subset.encode(options))
  end

  describe 'parsing' do
    it 'keeps every subtable and its flags' do
      kern = crafted_font.kerning

      expect(kern.tables.length).to eq(3)
      expect(kern.tables.map(&:class)).to eq(
        [
          described_class::Format2,
          described_class::Format0,
          described_class::Format0,
        ]
      )

      format2 = kern.tables.first
      expect(format2).to be_horizontal
      expect(format2).to_not be_override
      expect(kern.tables[1]).to be_override
      expect(kern.tables[2]).to be_vertical
    end

    it 'resolves class-based pairs with the default class' do
      format2 = crafted_font.kerning.tables.first

      expect(format2.kerning_for(gid('A'), gid('.'))).to eq(-60)
      expect(format2.kerning_for(gid('V'), gid(','))).to eq(-55)
      expect(format2.kerning_for(gid('T'), gid('.'))).to eq(-30)
      expect(format2.kerning_for(gid('X'), gid('Q'))).to eq(-250)

      # Unlisted glyphs fall back to the default class.
      expect(format2.kerning_for(gid('e'), gid(','))).to eq(5)
      expect(format2.kerning_for(gid('e'), gid('.'))).to eq(11)
      expect(format2.kerning_for(gid('A'), gid('e'))).to eq(-40)
      expect(format2.kerning_for(gid('e'), gid('e'))).to eq(0)
    end

    it 'exposes expanded pairs compatible with format 0' do
      pairs = crafted_font.kerning.tables.first.pairs

      expect(pairs[[gid('A'), gid('.')]]).to eq(-60)
      expect(pairs[[gid('T'), gid(',')]]).to eq(-25)
      # glyph 0 represents the default class
      expect(pairs[[0, gid(',')]]).to eq(5)
      expect(pairs[[gid('A'), 0]]).to eq(-40)
    end

    it 'accumulates values and applies override subtables in order' do
      kern = crafted_font.kerning

      # straight from the class table
      expect(kern.kerning_for(gid('A'), gid('.'))).to eq(-60)
      # an override subtable replaces instead of adding
      expect(kern.kerning_for(gid('A'), gid('A'))).to eq(-102)
      # an override subtable leaves pairs it does not list untouched
      expect(kern.kerning_for(gid('T'), gid('A'))).to eq(-70)
      # vertical subtables do not participate in horizontal kerning
      expect(kern.kerning_for(gid('T'), gid('V'))).to eq(-70)
    end

    it 'parses Apple class table format 1' do
      g = ->(char) { font.cmap.unicode.first[char.ord] }
      left_classes = {
        g.call('A') => 8, g.call('V') => 8, g.call('T') => 16, g.call('X') => 24
      }
      right_classes = {
        g.call(',') => 1, g.call('.') => 2, g.call('Q') => 3
      }
      matrix = [
        [0, 5, 11, -9],
        [-40, -55, -60, -130],
        [-70, -25, -30, -200],
        [-50, -9, -15, -250],
      ]
      subtable = format2_subtable(
        matrix, left_classes, right_classes, left_format: 1
      )
      kern = TTFunk::Table::Kern.new(
        TestFile.new(StringIO.new(kern_table([subtable])))
      )

      expect(kern.tables.first).to be_a(described_class::Format2)
      expect(kern.kerning_for(g.call('A'), g.call('.'))).to eq(-60)
      expect(kern.kerning_for(g.call('T'), g.call(','))).to eq(-25)
      expect(kern.kerning_for(g.call('X'), g.call('Q'))).to eq(-250)
    end

    it 'raises on unsupported subtable formats instead of zero kerning' do
      subtable = [0, 14, 0x0900, 0, 0, 0, 0].pack('n*')
      data = kern_table([subtable])

      expect do
        TTFunk::Table::Kern.new(TestFile.new(StringIO.new(data)))
      end.to raise_error(
        described_class::UnsupportedFormatError, /format 9/
      )
    end

    it 'raises on unsupported class table formats' do
      # The left class table begins right after the 12-byte headers and
      # claims class-table format 3.
      body = [2, 12, 0].pack('n*') + [3].pack('n')
      subtable = [0, body.length + 6, 0x0200].pack('n*') + body
      data = kern_table([subtable])

      expect do
        TTFunk::Table::Kern.new(TestFile.new(StringIO.new(data)))
      end.to raise_error(
        described_class::UnsupportedFormatError, /class table format 3/
      )
    end
  end

  describe 'subsetting' do
    let(:subset_font) do
      subset_of(crafted_font, %w[A V T e , .], kerning: true)
    end

    let(:queried_chars) { %w[A V T e , .] }

    it 'keeps kerning identical for every queried pair' do
      before = queried_chars.product(queried_chars).map do |left, right|
        crafted_font.kerning.kerning_for(gid(left), gid(right))
      end

      after = queried_chars.product(queried_chars).map do |left, right|
        subset_font.kerning.kerning_for(
          gid(left, subset_font), gid(right, subset_font)
        )
      end

      expect(after).to eq(before)
    end

    it 'preserves subtable order, coverage and direction' do
      tables = subset_font.kerning.tables

      expect(tables.length).to eq(3)
      expect(tables[0]).to be_a(described_class::Format2)
      expect(tables[0]).to be_horizontal
      expect(tables[1]).to be_a(described_class::Format0)
      expect(tables[1]).to be_override
      expect(tables[2]).to be_vertical
    end

    it 'reorganizes the matrix and drops classes of removed glyphs' do
      format2 = subset_font.kerning.tables.first

      # The X row and Q column are gone: 3 rows (default, A/V, T) x
      # 3 columns (default, comma, period).
      expect(format2.row_width).to eq(6)
      expect(format2.values.length).to eq(9)

      # X and Q resolve to .notdef and carry no non-default class.
      expect(gid('X', subset_font)).to eq(0)
      expect(gid('Q', subset_font)).to eq(0)
      expect(format2.left_classes.values).to_not include(18, 24)
      expect(format2.right_classes.values).to_not include(3)

      expect(format2.left_classes[gid('A', subset_font)]).to eq(6)
      expect(format2.left_classes[gid('T', subset_font)]).to eq(12)
      expect(format2.right_classes[gid(',', subset_font)]).to eq(1)
      expect(format2.right_classes[gid('.', subset_font)]).to eq(2)

      # Every class points inside the value matrix.
      max_index =
        (format2.left_classes.values.max.to_i / 2) +
        format2.right_classes.values.max.to_i
      expect(max_index).to be < format2.values.length
    end

    it 'round-trips a second subset' do
      twice = subset_of(subset_font, %w[A e ,], kerning: true)

      expect(
        twice.kerning.kerning_for(gid('A', twice), gid(',', twice))
      ).to eq(-55)
    end

    it 'still subsets format 0 fonts end to end' do
      new_font = subset_of(font, 'AVTe,.XQ'.chars, kerning: true)

      expect(new_font.kerning.tables.first)
        .to be_a(described_class::Format0)
      expected = font.kerning.kerning_for(gid('A'), gid('V'))
      expect(
        new_font.kerning.kerning_for(gid('A', new_font), gid('V', new_font))
      ).to eq(expected)
    end
  end
end

