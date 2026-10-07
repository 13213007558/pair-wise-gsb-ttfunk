# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TTFunk::CffToTtf do
  let(:original) { TTFunk::File.open(test_font('Exo-Regular', :otf)) }
  let(:max_error) { 1.0 }
  let(:result) { described_class.convert(original, max_error: max_error) }

  it 'raises for fonts without CFF outlines' do
    ttf = TTFunk::File.open(test_font('DejaVuSans', :ttf))

    expect { described_class.convert(ttf, max_error: max_error) }
      .to raise_error(ArgumentError)
  end

  context 'with a convertible font' do
    let(:new_font) { TTFunk::File.open(StringIO.new(result.font)) }

    it 'converts all glyphs within the error budget' do
      expect(result).to be_complete
      expect(result.incomplete_glyphs).to be_empty
      expect(result.font).not_to be_nil
    end

    it 'produces a font with a TrueType scaler type' do
      expect(new_font.directory.scaler_type).to eq(0x0001_0000)
    end

    it 'produces glyf and loca tables' do
      expect(new_font.directory.tables).to include('glyf', 'loca')
    end

    it 'does not carry over CFF or hinting tables' do
      expect(new_font.directory.tables.keys)
        .not_to include('CFF ', 'cvt ', 'fpgm', 'prep')
    end

    it 'declares a TrueType maxp table without instruction resources' do
      maxp = new_font.maximum_profile

      expect(maxp.version).to eq(0x0001_0000)
      expect(maxp.max_size_of_instructions).to eq(0)
      expect(maxp.max_function_defs).to eq(0)
      expect(maxp.max_instruction_defs).to eq(0)
      expect(maxp.max_stack_elements).to eq(0)
    end

    it 'preserves the glyph count' do
      expect(new_font.maximum_profile.num_glyphs)
        .to eq(original.maximum_profile.num_glyphs)
    end

    it 'preserves horizontal metrics' do
      expect(new_font.horizontal_metrics.widths)
        .to eq(original.horizontal_metrics.widths)
      expect(new_font.horizontal_header.number_of_metrics)
        .to eq(original.horizontal_header.number_of_metrics)
    end

    it 'preserves the character mapping' do
      original_cmap = original.cmap.unicode.first
      new_cmap = new_font.cmap.unicode.first

      (0x20..0x7e).each do |codepoint|
        expect(new_cmap[codepoint]).to eq(original_cmap[codepoint])
      end
    end

    it 'writes consistent loca offsets' do
      offsets = new_font.glyph_locations.offsets
      glyf_length = new_font.directory_info('glyf')[:length]

      expect(offsets.length).to eq(new_font.maximum_profile.num_glyphs + 1)
      expect(offsets.last).to eq(glyf_length)
      expect(offsets.each_cons(2).all? { |a, b| a <= b }).to be(true)
      expect(offsets.all? { |offset| offset <= glyf_length }).to be(true)

      if new_font.header.index_to_loc_format.zero?
        expect(offsets.all?(&:even?)).to be(true)
      end
    end

    it 'keeps empty glyphs empty' do
      space_id = original.cmap.unicode.first[0x20]

      expect(new_font.glyph_locations.size_of(space_id)).to eq(0)
      expect(new_font.glyph_outlines.for(space_id)).to be_nil
    end

    it 'writes simple glyphs with the expected number of contours' do
      converter = TTFunk::CffToTtf::PathConverter.new(max_error: max_error)
      charstrings = original.cff.top_index[0].charstrings_index

      [35, 36, 67].each do |glyph_id|
        expected = converter.convert(charstrings[glyph_id].path)
        glyph = new_font.glyph_outlines.for(glyph_id)

        expect(glyph).not_to be_compound
        expect(glyph.number_of_contours).to eq(expected.contours.length)
      end
    end

    it 'writes the expected points' do
      converter = TTFunk::CffToTtf::PathConverter.new(max_error: max_error)
      charstrings = original.cff.top_index[0].charstrings_index

      [35, 36, 67].each do |glyph_id|
        expected = converter.convert(charstrings[glyph_id].path)
        glyph = new_font.glyph_outlines.for(glyph_id)

        expect(decode_simple_glyph_points(glyph.raw)).to eq(expected.contours)
      end
    end

    it 'keeps outlines within the maximum error' do
      converter = TTFunk::CffToTtf::PathConverter.new(max_error: max_error)
      charstrings = original.cff.top_index[0].charstrings_index

      [35, 36, 67].each do |glyph_id|
        path = charstrings[glyph_id].path
        converted = converter.convert(path)

        deviation = outline_deviation(
          sample_cff_path(path),
          sample_quadratic_contours(converted.contours),
        )

        expect(deviation).to be <= max_error
      end
    end

    it 'declares a head bbox that covers all glyphs' do
      head = new_font.header

      new_font.maximum_profile.num_glyphs.times do |glyph_id|
        glyph = new_font.glyph_outlines.for(glyph_id)
        next unless glyph

        expect(glyph.x_min).to be >= head.x_min
        expect(glyph.y_min).to be >= head.y_min
        expect(glyph.x_max).to be <= head.x_max
        expect(glyph.y_max).to be <= head.y_max
      end
    end

    it 'computes maxp maxima that cover all glyphs' do
      maxp = new_font.maximum_profile

      new_font.maximum_profile.num_glyphs.times do |glyph_id|
        glyph = new_font.glyph_outlines.for(glyph_id)
        next unless glyph

        expect(glyph.number_of_contours).to be <= maxp.max_contours
        expect(glyph.end_point_of_last_contour).to be <= maxp.max_points
      end
    end

    it 'adjusts the whole-font checksum' do
      font = result.font
      font += "\0" * ((4 - (font.length % 4)) % 4)

      expect(font.unpack('N*').sum & 0xFFFF_FFFF).to eq(0xB1B0_AFBA)
    end
  end

  context 'when the error budget cannot be met' do
    let(:max_error) { 0.5 }

    it 'reports an incomplete conversion without a font' do
      expect(result).not_to be_complete
      expect(result.incomplete_glyphs).not_to be_empty
      expect(result.font).to be_nil
    end
  end

  context 'when the subdivision limit cannot be met' do
    it 'reports an incomplete conversion without a font' do
      result = described_class.convert(original, max_error: 1.0, max_depth: 0)

      expect(result).not_to be_complete
      expect(result.font).to be_nil
    end
  end
end
