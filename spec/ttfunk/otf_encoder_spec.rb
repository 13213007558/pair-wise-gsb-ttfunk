# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/otf_encoder'
require 'ttfunk/subset'

RSpec.describe TTFunk::OTFEncoder do
  let(:original_font_path) { test_font('NotoSansCJKsc-Thin', :otf) }
  let(:original) { TTFunk::File.open(original_font_path) }

  let(:subset) do
    TTFunk::Subset::Unicode.new(original).tap do |subset|
      # ASCII lowercase
      (97..122).each { |char| subset.use(char) }
    end
  end

  let(:encoder_options) { {} }
  let(:encoder) { described_class.new(original, subset, encoder_options) }

  describe '#encode' do
    subject { encoder.encode }

    let(:new_font) { TTFunk::File.open(StringIO.new(subject)) }

    it 'includes the CFF, VORG, and DSIG tables' do
      expect(new_font.directory.tables).to include('CFF ')
      expect(new_font.directory.tables).to include('VORG')
      expect(new_font.directory.tables).to include('DSIG')
    end

    it 'lists tables in optimal order' do
      tables = described_class::OPTIMAL_TABLE_ORDER &
        new_font.directory.tables.keys

      tables.each_cons(2) do |first_table, second_table|
        first_offset = new_font.directory.tables[first_table][:offset]
        second_offset = new_font.directory.tables[second_table][:offset]
        expect(first_offset).to be < second_offset
      end
    end

    context 'with CFF to TrueType conversion' do
      let(:encoder_options) do
        { cff_to_truetype: true, cff_to_truetype_tolerance: 1 }
      end

      it 'writes and rereads an unhinted TrueType outline font' do
        expect(new_font.directory.scaler_type).to eq(0x00010000)
        expect(new_font.directory.tables)
          .to include('glyf', 'loca', 'maxp', 'head', 'hmtx', 'hhea')
        expect(new_font.directory.tables).not_to include('CFF ', 'VORG', 'fpgm', 'prep', 'cvt ')

        expect(new_font.maximum_profile.version).to eq(0x00010000)
        expect(new_font.maximum_profile.num_glyphs)
          .to eq(new_font.glyph_locations.offsets.length - 1)
        expect(new_font.maximum_profile.max_size_of_instructions).to eq(0)
        expect(new_font.header.index_to_loc_format)
          .to eq(new_font.glyph_locations.offsets.any?(&:odd?) ? 1 : 0)

        glyph_id = new_font.cmap.unicode.first[97]
        glyph = new_font.glyph_outlines.for(glyph_id)
        metric = new_font.horizontal_metrics.for(glyph_id)

        expect(glyph).not_to be_nil
        expect(glyph.number_of_contours).to be_positive
        expect(glyph.instruction_length).to eq(0)
        expect(glyph.points.length).to be <= new_font.maximum_profile.max_points
        expect(glyph.number_of_contours).to be <= new_font.maximum_profile.max_contours
        expect(metric.left_side_bearing).to eq(glyph.x_min)
        expect(new_font.header.x_min).to be <= glyph.x_min
        expect(new_font.header.x_max).to be >= glyph.x_max
        expect(new_font.header.y_min).to be <= glyph.y_min
        expect(new_font.header.y_max).to be >= glyph.y_max
        on_curve_values = glyph.points.map { |point| point[:on_curve] }
        expect(on_curve_values).to all(satisfy { |value| [true, false].include?(value) })
      end

      it 'keeps empty glyphs empty in glyf and preserves their metrics' do
        space_id = new_font.cmap.unicode.first[32]
        old_space_id = original.cmap.unicode.first[32]
        original_metric = original.horizontal_metrics.for(old_space_id)

        expect(new_font.glyph_locations.size_of(space_id)).to eq(0)
        expect(new_font.glyph_outlines.for(space_id)).to be_nil
        expect(new_font.horizontal_metrics.for(space_id).advance_width)
          .to eq(original_metric.advance_width)
      end

      it 'rebuilds checksums for the generated tables' do
        new_font.directory.tables.each_value do |descriptor|
          offset = descriptor[:offset]
          length = descriptor[:length]
          raw = subject
          table_data = raw[offset, length].dup
          table_data[8, 4] = "\0\0\0\0" if descriptor[:tag] == 'head'
          table_data << "\0" * ((4 - (length % 4)) % 4)
          checksum = table_data.unpack('N*').sum & 0xFFFF_FFFF

          expect(checksum).to eq(descriptor[:checksum])
        end

        head_offset = new_font.directory.tables['head'][:offset]
        expect(subject[head_offset + 8, 4].unpack1('N')).not_to eq(0)
        expect(subject[head_offset + 12, 4].unpack1('N')).to eq(0x5F0F3CF5)
      end

      context 'when the tolerance cannot contain integer quantization' do
        let(:encoder_options) do
          { cff_to_truetype: true, cff_to_truetype_tolerance: 0.1 }
        end

        it 'raises instead of silently widening the bound' do
          expect { subject }.to raise_error(TTFunk::Error, /quantization exceeds tolerance/) 
        end
      end

      context 'when no tolerance is supplied' do
        let(:encoder_options) { { cff_to_truetype: true } }

        it 'asks the caller for a positive numeric tolerance' do
          expect { subject }.to raise_error(TTFunk::Error, /positive numeric tolerance/)
        end
      end

      context 'when the tolerance is non-numeric' do
        let(:encoder_options) { { cff_to_truetype: true, cff_to_truetype_tolerance: true } }

        it 'asks the caller for a numeric bound' do
          expect { subject }.to raise_error(TTFunk::Error, /positive numeric tolerance/)
        end
      end
    end
  end
end
