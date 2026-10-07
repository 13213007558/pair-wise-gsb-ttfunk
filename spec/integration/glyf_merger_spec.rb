# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'ttfunk/subset'

describe TTFunk::GlyfMerger do
  def glyf_subset(path, *code_points)
    font = TTFunk::File.open(path)
    subset = TTFunk::Subset.for(font, :unicode)
    code_points.each { |code_point| subset.use(code_point) }
    TTFunk::File.new(subset.encode)
  end

  def with_units_per_em(font, units_per_em)
    data = font.contents.string.dup
    info = font.directory_info('head')
    data[info[:offset] + 18, 2] = [units_per_em].pack('n')
    TTFunk::File.new(data)
  end

  describe '#merge' do
    it 'merges a scaled composite glyph and remaps its components' do
      primary = glyf_subset('spec/fonts/DejaVuSans.ttf', 'a'.ord, ' '.ord)
      fallback = with_units_per_em(
        glyf_subset('spec/fonts/DejaVuSans.ttf', 0x100, ' '.ord),
        1000,
      )

      result = described_class.merge(primary, 0x100 => fallback)

      expect(result).to be_success
      merged = TTFunk::File.new(result.font)
      expect(merged.header.units_per_em).to eq(2048)
      expect(merged.directory.tables).not_to include('GDEF', 'GPOS', 'GSUB')

      glyph_id = merged.cmap.unicode.first[0x100]
      expect(glyph_id).to eq(primary.maximum_profile.num_glyphs)

      glyph = merged.glyph_outlines.for(glyph_id)
      expect(glyph).to be_compound
      expect(glyph.glyph_ids).to all(be < merged.maximum_profile.num_glyphs)
      expect(glyph.glyph_ids).to all(be >= primary.maximum_profile.num_glyphs)

      source_glyph = fallback.glyph_outlines.for(fallback.cmap.unicode.first[0x100])
      expect(glyph.glyph_ids).not_to eq(source_glyph.glyph_ids)

      source_metric = fallback.horizontal_metrics.for(
        fallback.cmap.unicode.first[0x100],
      )
      expected_width = (Rational(source_metric.advance_width, 1000) * 2048)
        .round(half: :up)
      expect(merged.horizontal_metrics.for(glyph_id).advance_width)
        .to eq(expected_width)

      glyph.glyph_ids.each do |component_gid|
        component = merged.glyph_outlines.for(component_gid)
        expect(component.number_of_contours).to be_positive
        expect(component.end_point_of_last_contour).to be_positive
      end
    end

    it 'returns restrictions instead of a font when layout tables cannot be migrated' do
      primary = TTFunk::File.open('spec/fonts/DejaVuSans.ttf')
      fallback = glyf_subset('spec/fonts/DejaVuSans.ttf', 0x100)

      result = described_class.merge(primary, 0x100 => fallback)

      expect(result).not_to be_success
      expect(result.font).to be_nil
      tags = result.restrictions.map(&:tag)
      expect(tags).to include('GDEF', 'GPOS', 'GSUB')
    end

    it 'rejects CFF-based fallback fonts' do
      primary = glyf_subset('spec/fonts/DejaVuSans.ttf', 'a'.ord)
      fallback = TTFunk::File.open('spec/fonts/Exo-Regular.otf')

      result = described_class.merge(primary, 'a'.ord => fallback)

      expect(result).not_to be_success
      expect(result.restrictions.map(&:tag)).to include('CFF ')
    end

    it 'reports a missing selected glyph without emitting a font' do
      primary = glyf_subset('spec/fonts/DejaVuSans.ttf', 'a'.ord)
      fallback = glyf_subset('spec/fonts/Mplus1p.ttf', 'a'.ord)

      result = described_class.merge(primary, 0x100 => fallback)

      expect(result).not_to be_success
      expect(result.font).to be_nil
      expect(result.restrictions.map(&:code)).to include(:missing_glyph)
    end

    it 'does not guess between conflicting explicit source selections' do
      primary = glyf_subset('spec/fonts/DejaVuSans.ttf', 'a'.ord)
      first_fallback = glyf_subset('spec/fonts/Mplus1p.ttf', 'a'.ord)
      second_fallback = glyf_subset('spec/fonts/DejaVuSans.ttf', 'a'.ord)

      expect do
        described_class.new(primary, [
          ['a'.ord, first_fallback],
          ['a'.ord, second_fallback],
        ])
      end.to raise_error(ArgumentError, /ambiguous source selection/i)
    end
  end

  describe '#merge!' do
    it 'raises the restriction list for an unsupported merge' do
      primary = TTFunk::File.open('spec/fonts/DejaVuSans.ttf')
      fallback = glyf_subset('spec/fonts/DejaVuSans.ttf', 0x100)

      expect do
        described_class.merge!(primary, 0x100 => fallback)
      end.to raise_error(TTFunk::GlyfMergeError) do |error|
        expect(error.restrictions.map(&:tag)).to include('GSUB')
      end
    end
  end
end
