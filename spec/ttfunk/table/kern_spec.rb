# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'ttfunk/subset'

RSpec.describe TTFunk::Table::Kern do
  subject(:kerning) { font.kerning }

  let(:font) { TTFunk::File.open(StringIO.new(font_bytes)) }
  let(:font_bytes) do
    base = File.binread(test_font('DejaVuSans'))
    patch_kern_table(base, kern_bytes)
  end

  let(:gids) do
    %w[A V W X a o e x].to_h { |char| [char, cmap_for_base_font(char.ord)] }
  end

  # The base font is parsed to resolve glyph ids before it is patched.
  let(:base_font) { TTFunk::File.open(test_font('DejaVuSans')) }

  def cmap_for_base_font(code)
    base_font.cmap.unicode.first[code]
  end

  # Build an Apple/Microsoft format 1 class table. Class values are given as
  # word positions within the matrix row/column; they are converted to the
  # byte offsets required by the format.
  def class_table(first_glyph, class_values, multiplier: 1)
    byte_values = class_values.map { |value| value * multiplier * 2 }
    [1, first_glyph, byte_values.length, *byte_values].pack('n*')
  end

  # Build a version 0 format 2 (class-based) kerning subtable.
  #
  # @param coverage [Integer] coverage/format field
  # @param left_table [String] left-hand class table
  # @param right_table [String] right-hand class table
  # @param values [Array<Array<Integer>>] matrix of signed values, rows are
  #   indexed by right-hand classes, columns by left-hand classes
  def format2_subtable(coverage, left_table, right_table, values)
    row_width = values.first.length * 2
    data = [2, row_width].pack('n2')
    left_offset = 10
    right_offset = left_offset + left_table.bytesize
    array_offset = right_offset + right_table.bytesize
    data << [left_offset, right_offset, array_offset].pack('n3')
    data << left_table << right_table
    data << values.flatten.map { |value| value & 0xFFFF }.pack('n*')
    [0, 6 + data.bytesize, coverage].pack('n3') + data
  end

  # Replace the kern table in an sfnt font binary, appending the new bytes at
  # the end of the file and pointing the directory record at them.
  def patch_kern_table(original, kern)
    num_tables = original.unpack1('x4n')
    num_tables.times do |index|
      record_offset = 12 + (index * 16)
      next unless original[record_offset, 4] == 'kern'

      table_offset = original.bytesize
      patched = original.dup
      patched[record_offset + 4, 4] = [0].pack('N')
      patched[record_offset + 8, 4] = [table_offset].pack('N')
      patched[record_offset + 12, 4] = [kern.bytesize].pack('N')
      return patched + kern
    end

    raise 'kern directory record not found'
  end

  context 'format 2 subtable' do
    let(:a) { gids['a'] }
    let(:o) { gids['o'] }

    let(:left_table) do
      class_table(
        gids['A'],
        (gids['A']..gids['X']).map do |gid|
          case gid
          when gids['A'] then 1
          when gids['V'], gids['W'] then 2
          when gids['X'] then 3
          else 0
          end
        end,
      )
    end

    let(:right_table) do
      class_table(
        a,
        (a..gids['x']).map do |gid|
          case gid
          when a then 1
          when o then 2
          when gids['e'] then 3
          else 0
          end
        end,
        multiplier: 4,
      )
    end

    # Columns: default, A, V/W, X (left classes 0, 1, 2, 3).
    # Rows: default, a, o, e (right classes 0, 1, 2, 3).
    let(:values) do
      [
        [0, 0, 0, 0],
        [0, -80, 40, 25],
        [0, -30, -10, 15],
        [0, 5, 0, 0],
      ]
    end

    let(:subtable) do
      format2_subtable(0x0201, left_table, right_table, values)
    end

    let(:kern_bytes) { [0, 1].pack('n2') + subtable }

    it 'is parsed as a format 2 subtable' do
      expect(kerning.tables.length).to eq(1)
      expect(kerning.tables.first).to \
        be_a(described_class::Format2)
    end

    it 'shares values across glyphs of the same class' do
      expect(kerning.kerning_for(gids['V'], a)).to eq(40)
      expect(kerning.kerning_for(gids['W'], a)).to eq(40)
      expect(kerning.kerning_for(gids['V'], o)).to eq(-10)
      expect(kerning.kerning_for(gids['W'], o)).to eq(-10)
    end

    it 'maps unlisted glyphs to the default class' do
      expect(kerning.kerning_for(gids['X'], a)).to eq(25)
      expect(kerning.kerning_for(gids['X'], gids['x'])).to eq(0)
      expect(kerning.kerning_for(gids['A'], gids['x'])).to eq(0)
    end

    it 'exposes pairs compatible with format 0 queries' do
      pairs = kerning.pairs(horizontal: true)
      expect(pairs[[gids['A'], a]]).to eq(-80)
      expect(pairs[[gids['V'], o]]).to eq(-10)
      expect(pairs[[gids['W'], o]]).to eq(-10)
      expect(pairs[[gids['X'], a]]).to eq(25)
      expect(pairs).not_to have_key([gids['A'], gids['x']])
    end
  end

  context 'multiple subtables with shared classes and overrides' do
    let(:a) { gids['a'] }
    let(:o) { gids['o'] }
    let(:e) { gids['e'] }

    # Base subtable: A vs {V, W} share the left class; a vs o share the
    # right class.
    let(:base_left) do
      class_table(
        gids['A'],
        (gids['A']..gids['X']).map do |gid|
          case gid
          when gids['A'] then 1
          when gids['V'], gids['W'] then 2
          when gids['X'] then 3
          else 0
          end
        end,
      )
    end

    let(:base_right) do
      class_table(
        a,
        (a..gids['x']).map do |gid|
          case gid
          when a then 1
          when o then 2
          when gids['e'] then 3
          else 0
          end
        end,
        multiplier: 4,
      )
    end

    let(:base_values) do
      [
        [0, 0, 0, 0],
        [0, -80, 40, 25],
        [0, -30, -10, 15],
        [0, 5, 0, 0],
      ]
    end

    # Override subtable: A, V and W share one left class, a one right class.
    let(:override_left) do
      class_table(
        gids['A'],
        (gids['A']..gids['W']).map do |gid|
          [gids['A'], gids['V'], gids['W']].include?(gid) ? 1 : 0
        end,
      )
    end

    let(:override_right) { class_table(a, [1], multiplier: 3) }

    let(:override_values) do
      [
        [0, 0, 0],
        [0, -120, -120],
      ]
    end

    # Vertical subtable for Aa; horizontal queries must ignore it.
    let(:vertical_left) { class_table(gids['A'], [1]) }
    let(:vertical_right) { class_table(a, [1], multiplier: 2) }
    let(:vertical_values) { [[0, 0], [0, -17]] }

    let(:kern_bytes) do
      [0, 3].pack('n2') +
        format2_subtable(0x0201, base_left, base_right, base_values) +
        format2_subtable(
          0x0209, override_left, override_right, override_values
        ) +
        format2_subtable(
          0x0280, vertical_left, vertical_right, vertical_values
        )
    end

    let(:expected_horizontal) do
      {
        [gids['A'], a] => -120,
        [gids['V'], a] => -120,
        [gids['W'], a] => -120,
        [gids['A'], o] => -30,
        [gids['V'], o] => -10,
        [gids['W'], o] => -10,
        [gids['X'], a] => 25,
        [gids['X'], o] => 15,
        [gids['A'], e] => 5,
        [gids['X'], gids['x']] => 0,
      }
    end

    it 'honors overrides and direction flags' do
      expected_horizontal.each do |(left, right), value|
        expect(kerning.kerning_for(left, right)).to eq(value)
      end

      # vertical subtable is ignored for horizontal queries but available
      # when vertical kerning is requested
      expect(kerning.kerning_for(gids['A'], a, horizontal: false)).to eq(-137)
      expect(kerning.tables[2]).to be_vertical
      expect(kerning.tables[1]).to be_override
    end

    it 'keeps the same kerning after subsetting' do
      query_chars = %w[A V W X a o e x]
      before = {}
      query_chars.product(query_chars) do |left_char, right_char|
        pair = [gids[left_char], gids[right_char]]
        before[pair] = kerning.kerning_for(*pair)
      end

      subset = TTFunk::Subset::Unicode.new(font)
      %w[A V W a o].each { |char| subset.use(char.ord) }

      new_font = TTFunk::File.open(StringIO.new(subset.encode(kerning: true)))
      new_cmap = new_font.cmap.unicode.first
      new_kern = new_font.kerning
      surviving = %w[A V W a o]
      surviving.product(surviving) do |left_char, right_char|
        left = new_cmap[left_char.ord]
        right = new_cmap[right_char.ord]
        expect(new_kern.kerning_for(left, right)).to eq(
          before[[gids[left_char], gids[right_char]]],
        )
      end

      # the override and vertical subtables survive
      expect(new_kern.tables.length).to eq(3)
      expect(new_kern.tables.map(&:class)).to \
        all(eq(described_class::Format2))
      expect(new_kern.tables[1]).to be_override
      expect(new_kern.tables[2]).to be_vertical
    end

    it 'drops classes used only by removed glyphs when subsetting' do
      subset = TTFunk::Subset::Unicode.new(font)
      %w[A V W a o].each { |char| subset.use(char.ord) }

      new_font = TTFunk::File.open(StringIO.new(subset.encode(kerning: true)))
      base = new_font.kerning.tables.first

      # Surviving left classes are default, A and V/W: 3 columns. Surviving
      # right classes are default, a and o: 3 rows. Classes used only by
      # removed glyphs (X on the left, e on the right) must not survive.
      expect(base.row_width).to eq(6)
      expect(base.left_class_offsets.uniq).to contain_exactly(0, 1, 2)
      expect(base.right_class_offsets.uniq).to contain_exactly(0, 1, 2)
      expect(base.values.length).to eq(9)

      # Removed-glyph-only values must not remain encoded in the matrix
      expect(base.values).not_to include(25, 15, 5)
    end
  end

  context 'version 1 header with accumulating subtables' do
    let(:a) { gids['a'] }

    # Format 2 subtable giving Aa = -80.
    let(:class_left) do
      class_table(gids['A'], [1])
    end

    let(:class_right) { class_table(a, [1], multiplier: 2) }
    let(:class_values) { [[0, 0], [0, -80]] }

    # Format 0 subtable adding -7 for Aa (so -87 combined).
    let(:format0_subtable) do
      body = [1, 6, 0, 0, gids['A'], a, -7 & 0xFFFF].pack('n*')
      [8 + body.bytesize].pack('N') + [0x8000, 0].pack('nn') + body
    end

    let(:format2_subtable_bytes) do
      s = format2_subtable(0x0001, class_left, class_right, class_values)
      # convert the version 0 6-byte header into a version 1 8-byte header
      _version, v0_length, _coverage = s[0, 6].unpack('n3')
      [v0_length + 2, 0x8002, 0].pack('Nnn') + s[6..]
    end

    let(:kern_bytes) do
      # version 1 outer header: 0x00010000 followed by a uint32 count
      [0x00010000, 2].pack('NN') + format2_subtable_bytes + format0_subtable
    end

    it 'parses version 1 headers and accumulates values' do
      expect(kerning.tables.map do |t|
        t.class.name.split('::').last
      end).to eq(%w[Format2 Format0])
      # format 2 gives -80, format 0 adds -7: values accumulate to -87.
      expect(kerning.kerning_for(gids['A'], a)).to eq(-87)
    end

    it 're-encodes with a version 1 header after subsetting' do
      subset = TTFunk::Subset::Unicode.new(font)
      subset.use('A'.ord)
      subset.use('a'.ord)

      encoded = TTFunk::Table::Kern.encode(kerning, subset.old_to_new_glyph)
      outer_version, num_tables = encoded.unpack('N2')
      expect(outer_version).to eq(0x00010000)
      expect(num_tables).to eq(2)

      new_font = TTFunk::File.open(StringIO.new(subset.encode(kerning: true)))
      new_cmap = new_font.cmap.unicode.first
      expect(
        new_font.kerning.kerning_for(new_cmap['A'.ord], new_cmap['a'.ord]),
      ).to eq(-87)
    end
  end

  context 'unsupported formats' do
    let(:kern_bytes) do
      # format 3 version 0 subtable (never defined)
      [0, 1].pack('n2') + [0, 20, 0x0300].pack('n3') + ('\0' * 14).b
    end

    it 'raises instead of treating the font as having zero kerning' do
      expect { kerning }.to raise_error(
        described_class::UnsupportedFormatError,
        /unsupported kern subtable format: 3/,
      )
    end
  end
end
