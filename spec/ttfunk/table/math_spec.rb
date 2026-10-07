# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/table/math'

RSpec.describe TTFunk::Table::Math do
  subject(:math_table) { table_from_binary(table_bytes) }

  let(:table_bytes) { MathTableFixture.build }
  let(:font) { TTFunk::File.new(font_bytes) }
  let(:font_bytes) do
    header = [0x4f54544f, 1, 0, 0, 0, 0].pack('Nnnxxxx')
    record = ['MATH', 0, 28, table_bytes.bytesize].pack('a4NNN')
    header + record + table_bytes
  end

  it 'is available through TTFunk::File' do
    expect(font.math).to be_a(described_class)
    expect(font.math.constant(:superscript_shift_up)).to eq(10)
  end

  describe 'constants and device adjustments' do
    it 'reads percentage constants and value records' do
      expect(math_table.constant(:script_percent_scale_down)).to eq(90)
      expect(math_table.constant(:superscript_shift_up)).to eq(10)
      expect(
        math_table.constant(:radical_degree_bottom_raised_percent_rise)
      ).to eq(70)
    end

    it 'applies device adjustments only inside their ppem range' do
      expect(math_table.constant(:superscript_shift_up, 10)).to eq(12)
      expect(math_table.constant(:superscript_shift_up, 11)).to eq(9)
      expect(math_table.constant(:superscript_shift_up, 12)).to eq(10)
    end
  end

  describe '#italic_correction' do
    it 'uses coverage order and applies a device adjustment' do
      expect(math_table.italic_correction(11)).to eq(4)
      expect(math_table.italic_correction(10)).to eq(7)
      expect(math_table.italic_correction(10, 10)).to eq(9)
    end
  end

  describe '#top_accent_attachment' do
    it 'finds a glyph value through coverage' do
      expect(math_table.top_accent_attachment(10)).to eq(33)
      expect(math_table.top_accent_attachment(10, 10)).to eq(33)
    end
  end

  describe '#vertical_variant' do
    it 'chooses a ready-made variant at its exact critical size' do
      result = math_table.vertical_variant(10, 70)

      expect(result[:glyph]).to eq(11)
      expect(result[:glyphs]).to eq([11])
      expect(result[:size]).to eq(70)
      expect(result[:assembly]).to eq(false)
      expect(result[:parts].first[:position]).to eq(x: 0, y: 0)
    end

    it 'assembles fixed parts without repeating an extender' do
      result = math_table.vertical_variant(10, 85)

      expect(result[:glyphs]).to eq([50, 51])
      expect(result[:repeat_count]).to eq(0)
      expect(result[:overlaps]).to eq([15])
      expect(result[:assembly]).to eq(true)
      expect(result[:size]).to eq(85)
      expect(result[:parts].map { |part| part[:position] }).to eq([
        { x: 0, y: 0 }, { x: 0, y: 35 }
      ])
    end

    it 'raises a clear error when no assembly can reach the size' do
      expect { math_table.vertical_variant(10, 100) }.to raise_error(
        TTFunk::Error, /cannot reach target size 100/
      )
    end
  end

  describe '#horizontal_variant' do
    it 'chooses variants exactly on variant size boundaries' do
      expect(math_table.horizontal_variant(20, 80)[:glyph]).to eq(31)
      expect(math_table.horizontal_variant(20, 90)[:glyph]).to eq(32)
    end

    it 'keeps each overlap inside the connector range of its seam' do
      result = math_table.horizontal_variant(20, 100)

      expect(result[:glyphs]).to eq([40, 41, 42])
      expect(result[:overlaps]).to eq([30, 10])
      expect(result[:size]).to eq(100)
      expect(result[:parts].map { |part| part[:position] }).to eq([
        { x: 0, y: 0 },
        { x: 10, y: 0 },
        { x: 60, y: 0 }
      ])
    end

    it 'repeats the extender and allocates overlap against seam capacities' do
      result = math_table.horizontal_variant(20, 120)

      expect(result[:glyphs]).to eq([40, 41, 41, 42])
      expect(result[:repeat_count]).to eq(2)
      expect(result[:overlaps]).to eq([40, 30, 10])
      expect(result[:size]).to eq(120)
      expect(result[:parts].map { |part| part[:position] }).to eq([
        { x: 0, y: 0 },
        { x: 0, y: 0 },
        { x: 30, y: 0 },
        { x: 80, y: 0 }
      ])

      larger = math_table.horizontal_variant(20, 150)
      expect(larger[:glyphs]).to eq([40, 41, 41, 42])
      expect(larger[:repeat_count]).to eq(2)
      expect(larger[:overlaps]).to eq([20, 20, 10])
      expect(larger[:size]).to eq(150)

      boundary = math_table.horizontal_variant(20, 151)
      expect(boundary[:glyphs]).to eq([40, 41, 41, 41, 42])
      expect(boundary[:repeat_count]).to eq(3)
      expect(boundary[:overlaps]).to eq([40, 39, 20, 10])
      expect(boundary[:size]).to eq(151)
    end
  end

  describe 'offset validation' do
    it 'rejects an internal offset outside the table' do
      corrupted = table_bytes.dup
      corrupted[6, 2] = [0xffff].pack('n')

      expect { table_from_binary(corrupted) }.to raise_error(
        TTFunk::Error, /outside the table/
      )
    end

    it 'rejects a nested device offset outside the table' do
      corrupted = table_bytes.dup
      italics_base = 232
      corrupted[italics_base + 10, 2] = [0xffff].pack('n')

      expect { table_from_binary(corrupted) }.to raise_error(
        TTFunk::Error, /outside the table/
      )
    end
  end

  def table_from_binary(bytes)
    described_class.new(
      TestFile.new(StringIO.new(bytes))
    )
  end

  # Hand-built MATH table. Section offsets are assigned up front so records can
  # encode their table-relative offsets.
  class MathTableFixture
    SECTION_SIZES = {
      header: 10,
      constants: 214,
      glyph_info: 8,
      italics: 12,
      italics_coverage: 8,
      device: 8,
      top_accent: 8,
      top_accent_coverage: 6,
      variants: 14,
      vertical_coverage: 6,
      horizontal_coverage: 6,
      vertical_construction: 8,
      vertical_assembly: 26,
      horizontal_construction: 12,
      horizontal_assembly: 36,
    }.freeze

    def self.build
      new.build
    end

    def build
      assign_offsets
      pack_sections
      render
    end

    private

    attr_reader :offsets, :sections

    def assign_offsets
      @offsets = {}
      cursor = 0
      SECTION_SIZES.each do |name, size|
        @offsets[name] = cursor
        cursor += size
      end
    end

    def pack_sections
      @sections = {}
      pack_header
      pack_constants
      pack_glyph_info
      pack_italics
      pack_coverage(:italics_coverage, [11, 10])
      pack_device
      pack_top_accent
      pack_coverage(:top_accent_coverage, [10])
      pack_variants
      pack_coverage(:vertical_coverage, [10])
      pack_coverage(:horizontal_coverage, [20])
      pack_vertical_construction
      pack_vertical_assembly
      pack_horizontal_construction
      pack_horizontal_assembly
    end

    def pack_header
      @sections[:header] = [
        1, 0,
        relative(:constants), relative(:glyph_info), relative(:variants)
      ].pack('n*')
    end

    def pack_constants
      bytes = ''.b
      superscript_record =
        offsets[:constants] + 4 +
        ((TTFunk::Table::Math::Constants::NAMES.index(:superscript_shift_up) - 2) * 4)

      TTFunk::Table::Math::Constants::NAMES.each_with_index do |_name, index|
        case index
        when 0 then bytes << [90].pack('s>')
        when 1 then bytes << [80].pack('s>')
        when 10
          bytes << [10, offsets[:device] - superscript_record].pack('s>n')
        when 54 then bytes << [70].pack('s>')
        when (2..53) then bytes << [0, 0].pack('s>n')
        else bytes << [0].pack('s>')
        end
      end
      @sections[:constants] = bytes
    end

    def pack_glyph_info
      @sections[:glyph_info] = [
        relative_from(:glyph_info, :italics),
        relative_from(:glyph_info, :top_accent),
        0, 0,
      ].pack('n*')
    end

    def pack_italics
      value_base = offsets[:italics] + 4
      @sections[:italics] = [
        2,
        relative_from(:italics, :italics_coverage),
        4, 0,
        7,
        offsets[:device] - (value_base + 4),
      ].pack('n*')
    end

    def pack_top_accent
      @sections[:top_accent] = [
        1,
        relative_from(:top_accent, :top_accent_coverage),
        33, 0,
      ].pack('n*')
    end

    def pack_coverage(name, glyphs)
      @sections[name] = [1, glyphs.length, *glyphs].pack('n*')
    end

    def pack_device
      @sections[:device] = [10, 11, 2, 0x2f00].pack('n*')
    end

    def pack_variants
      @sections[:variants] = [
        10,
        relative_from(:variants, :vertical_coverage),
        relative_from(:variants, :horizontal_coverage),
        1, 1,
        relative_from(:variants, :vertical_construction),
        relative_from(:variants, :horizontal_construction),
      ].pack('n*')
    end

    def pack_vertical_construction
      @sections[:vertical_construction] = [
        1, 11, 70,
        relative_from(:vertical_construction, :vertical_assembly)
      ].pack('n*')
    end

    def pack_vertical_assembly
      @sections[:vertical_assembly] = [
        0, 0, 2,
        50, 0, 10, 15, 50,
        51, 0, 15, 10, 50,
      ].pack('s>n*')
    end

    def pack_horizontal_construction
      @sections[:horizontal_construction] = [
        2, 31, 80, 32, 90,
        relative_from(:horizontal_construction, :horizontal_assembly)
      ].pack('n*')
    end

    def pack_horizontal_assembly
      @sections[:horizontal_assembly] = [
        0, 0, 3,
        40, 0, 10, 20, 40,
        41, 1, 20, 10, 60,
        42, 0, 10, 10, 40,
      ].pack('s>n*')
    end

    def render
      result = ''.b
      SECTION_SIZES.each_key do |name|
        bytes = sections.fetch(name)
        result << bytes
        result << "\0".b * (SECTION_SIZES.fetch(name) - bytes.bytesize)
      end
      result
    end

    def relative(name)
      offsets.fetch(name) - offsets.fetch(:header)
    end

    def relative_from(from, name)
      offsets.fetch(name) - offsets.fetch(from)
    end
  end
end
