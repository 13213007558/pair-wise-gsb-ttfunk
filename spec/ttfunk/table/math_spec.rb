# frozen_string_literal: true

require 'spec_helper'
require 'stringio'

RSpec.describe TTFunk::Table::OpenTypeMath do
  class MathFontBuilder
    def self.build
      constants = constants_table
      glyph_info = glyph_info_table
      variants = variants_table

      glyph_info_offset = 10 + constants.length
      variants_offset = glyph_info_offset + glyph_info.length
      header = [1, 0, 10, glyph_info_offset, variants_offset].pack('nnnnn')
      math = header + constants + glyph_info + variants
      sfnt(math)
    end

    def self.malformed
      sfnt([1, 0, 999, 0, 0].pack('nnnnn'))
    end

    class << self
      private

      def sfnt(math)
        offset = 28
        checksum = checksum_for(math)
        directory = [
          0x00010000, 1,
          0, 0, 0,
          'MATH', checksum, offset, math.length,
        ].flatten.pack('Nn4A4N3')
        padded = math.b.ljust((math.length / 4.0).ceil * 4, "\0")
        StringIO.new(directory + padded)
      end

      def checksum_for(data)
        padded = data.b.ljust((data.length / 4.0).ceil * 4, "\0")
        padded.unpack('N*').sum % 0x100000000
      end

      def coverage_format1(glyphs)
        [1, glyphs.length, *glyphs].pack('n*')
      end

      def coverage_format2(start_glyph, end_glyph)
        [2, 1, start_glyph, end_glyph, 0].pack('n*')
      end

      def device_format1
        [9, 10, 1, 0b0111_0000_0000_0000, 0].pack('n*')
      end

      def device_format2
        [9, 10, 2, 0b0001_1111_0000_0000].pack('n*')
      end

      def measured_list(glyphs, records, device)
        coverage = coverage_format1(glyphs)
        records_with_offsets = records.map { |value, has_device| [value, has_device ? nil : 0] }
        coverage_offset = 4 + (records.length * 4)
        device_offset = coverage_offset + coverage.length
        records_with_offsets.each do |record|
          record[1] = device_offset if record[1].nil?
        end
        records_blob = records_with_offsets.flat_map(&:itself).pack('n*')
        table = [coverage_offset, records.length].pack('n*') + records_blob
        table + coverage + device
      end

      def constants_table
        device_offset = 8 + (51 * 4) + 2
        words = [80, 60, 1000, 1000]
        constants = Array.new(51) { |index| index == 1 ? [100, device_offset] : [0, 0] }
        words.pack('n*') + constants.flat_map(&:itself).pack('n*') + [55].pack('n') + device_format1
      end

      def glyph_info_table
        italics_device = device_format2
        italics = measured_list([10, 11], [[5, true], [6, false]], italics_device)
        accents = measured_list([20, 21], [[7, true], [8, false]], italics_device)

        italics_offset = 8
        accents_offset = italics_offset + italics.length
        [
          italics_offset,
          accents_offset,
          0,
          0,
        ].pack('n*') + italics + accents
      end

      def part(glyph_id, start_connector, end_connector, full_advance, extender = 0)
        [glyph_id, start_connector, end_connector, full_advance, extender].pack('n*')
      end

      def assembly(italic_correction, parts)
        part_count = parts.is_a?(Array) ? parts.length : parts.length / 10
        part_blob = parts.is_a?(Array) ? parts.join : parts
        [italic_correction, 0, part_count].pack('nnn') + part_blob
      end

      def construction(assembly_blob, variants)
        assembly_offset = 4 + (variants.length * 4)
        variant_blob = variants.flat_map(&:itself).pack('n*')
        [assembly_offset, variants.length].pack('n*') + variant_blob + assembly_blob
      end

      def variants_table
        vertical_parts = [
          part(60, 0, 30, 50),
          part(61, 30, 30, 50, 1),
          part(62, 30, 0, 50),
        ].join
        vertical_assembly = assembly(0, vertical_parts)
        vertical_construction = construction(vertical_assembly, [[50, 120]])

        horizontal_parts = [
          part(30, 0, 12, 40),
          part(31, 20, 25, 40, 1),
          part(32, 25, 25, 40, 1),
          part(33, 30, 0, 40),
        ].join
        horizontal_assembly = assembly(9, horizontal_parts)
        horizontal_construction = construction(horizontal_assembly, [[24, 130]])

        no_extender_parts = [
          part(40, 0, 30, 40),
          part(41, 30, 0, 40),
        ].join
        no_extender_assembly = assembly(0, no_extender_parts)
        no_extender_construction = construction(no_extender_assembly, [])

        zero_growth_parts = [
          part(70, 0, 40, 40),
          part(71, 40, 40, 40, 1),
          part(72, 40, 0, 40),
        ]
        zero_growth_assembly = assembly(0, zero_growth_parts)
        zero_growth_construction = construction(zero_growth_assembly, [])

        header_size = 18
        vertical_coverage = coverage_format1([100])
        horizontal_coverage = coverage_format2(200, 202)
        vertical_coverage_offset = header_size
        horizontal_coverage_offset = vertical_coverage_offset + vertical_coverage.length
        vertical_construction_offset = horizontal_coverage_offset + horizontal_coverage.length
        first_horizontal_offset = vertical_construction_offset + vertical_construction.length
        second_horizontal_offset = first_horizontal_offset + horizontal_construction.length
        third_horizontal_offset = second_horizontal_offset + zero_growth_construction.length

        header = [
          10,
          vertical_coverage_offset,
          horizontal_coverage_offset,
          1,
          3,
          vertical_construction_offset,
          first_horizontal_offset,
          second_horizontal_offset,
          third_horizontal_offset,
        ].pack('n*')

        header +
          vertical_coverage +
          horizontal_coverage +
          vertical_construction +
          horizontal_construction +
          zero_growth_construction +
          no_extender_construction
      end
    end
  end

  let(:font) { TTFunk::File.open(MathFontBuilder.build) }
  let(:math) { font.math }

  it 'parses constants and applies device adjustments at the requested ppem' do
    expect(math.constants.length).to eq(56)
    expect(math.constant(:script_percent_scale_down)).to eq(80)
    expect(math.constant(:scriptPercentScaleDown)).to eq(80)
    expect(math.constant(:radical_degree_bottom_raise_percent)).to eq(55)
    expect(math.constant(:axis_height)).to eq(100)
    expect(math.constant(:axis_height, 9)).to eq(101)
    expect(math.constant(:axis_height, 10)).to eq(99)
    expect(math.constant(:axis_height, 11)).to eq(100)
  end

  it 'parses italic correction and top accent attachment' do
    expect(math.italic_correction(10, 9)).to eq(6)
    expect(math.italic_correction(10, 10)).to eq(4)
    expect(math.italic_correction(11)).to eq(6)
    expect(math.italic_correction(99)).to be_nil

    expect(math.top_accent_attachment(20, 9)).to eq(8)
    expect(math.top_accent_attachment(20, 10)).to eq(6)
    expect(math.top_accent_attachment(21)).to eq(8)
  end

  it 'selects an exact variant threshold before falling back to assembly' do
    assembly = math.select_vertical_variant(100, 130)
    expect(assembly.assembly?).to eq(true)
    expect(assembly.glyph_ids).to eq([60, 61, 62])
    expect(assembly.size).to eq(130)
    expect(assembly.positions.map(&:position)).to eq([0, 40, 80])
    expect(assembly.positions.map(&:overlap_after)).to eq([10, 10, 0])

    variant = math.select_vertical_variant(100, 119)
    expect(variant.variant?).to eq(true)
    expect(variant.glyph_ids).to eq([50])
    expect(variant.size).to eq(120)

    exact = math.select_vertical_variant(100, 120)
    expect(exact.glyph_ids).to eq([50])
    expect(exact.size).to eq(120)
  end

  it 'repeats extenders and allocates every overlap within connector ranges' do
    selection = math.select_horizontal_variant(200, 190)

    expect(selection.assembly?).to eq(true)
    expect(selection.glyph_ids).to eq([30, 31, 32, 32, 32, 33])
    expect(selection.size).to eq(190)
    expect(selection.positions.map(&:position)).to eq([0, 30, 60, 90, 120, 150])
    expect(selection.positions.map(&:overlap_after)).to eq([10, 10, 10, 10, 10, 0])

    parts = selection.assembly.parts
    overlaps = selection.positions.map(&:overlap_after)[0...-1]
    overlaps.each_with_index do |overlap, index|
      left = parts[index]
      right = parts[index + 1]
      expect(overlap).to be >= 10
      expect(overlap).to be <= [
        left.end_connector_length,
        right.start_connector_length,
        left.full_advance_length,
        right.full_advance_length,
      ].min
    end
  end

  it 'raises a clear error when an assembly without extenders cannot grow' do
    expect { math.select_horizontal_variant(202, 75) }.to raise_error(
      described_class::SelectionError,
      /cannot reach requested size/
    )
  end

  it 'repeats an extender whose initial minimum growth is zero' do
    selection = math.select_horizontal_variant(201, 120)

    expect(selection.glyph_ids).to eq([70, 71, 71, 72])
    expect(selection.size).to eq(120)
    expect(selection.positions.map(&:position)).to eq([0, 26, 53, 80])
    expect(selection.positions.map(&:overlap_after)).to eq([14, 13, 13, 0])
  end

  it 'raises a parse error for an offset outside the table' do
    malformed_font = TTFunk::File.open(MathFontBuilder.malformed)
    expect { malformed_font.math.constant(:axis_height) }.to raise_error(
      described_class::ParseError,
      /out of bounds/
    )
  end
end
