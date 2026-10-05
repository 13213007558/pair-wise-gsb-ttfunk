# frozen_string_literal: true

require 'spec_helper'
require_relative '../../support/cbdt_font_builder'

RSpec.describe TTFunk::Table::Cblc do
  let(:builder) { CbdtFontBuilder.new(20) }
  let(:font_bytes) { builder.build }
  let(:font) { TTFunk::File.open(StringIO.new(font_bytes)) }
  let(:cblc) { font.color_bitmap_locations }

  def empty_subtable(index_format, image_format, glyph_id)
    metrics = CbdtFontBuilder.metrics
    CbdtFontBuilder::Subtable.new(
      index_format: index_format,
      image_format: image_format,
      entries: [
        CbdtFontBuilder::Entry.new(
          glyph_id: glyph_id,
          payload: "\x00".b,
          metrics: metrics,
        ),
      ],
    )
  end

  before do
    builder.add_strike(
      ppem: 16, bit_depth: 32,
      subtables: [empty_subtable(1, 17, 1)]
    )
    builder.add_strike(
      ppem: 32, bit_depth: 8,
      subtables: [empty_subtable(1, 17, 1)]
    )
    builder.add_strike(
      ppem: 48, bit_depth: 32,
      subtables: [empty_subtable(1, 17, 1)]
    )
  end

  describe '#strikes' do
    it 'parses strike descriptors and line metrics' do
      expect(cblc.strikes.length).to eq(3)

      strike = cblc.strikes.first
      expect(strike.ppem_x).to eq(16)
      expect(strike.ppem_y).to eq(16)
      expect(strike.bit_depth).to eq(32)
      expect(strike.horizontal_metrics.ascender).to eq(14)
      expect(strike.horizontal_metrics.descender).to eq(-4)
      expect(strike.vertical_metrics.ascender).to eq(14)
    end
  end

  describe '#strike_for' do
    it 'selects an exact ppem and bit depth match' do
      strike = cblc.strike_for(16, bit_depth: 32)
      expect(strike.index).to eq(0)
    end

    it 'ignores bit depth when not requested' do
      strike = cblc.strike_for(32)
      expect(strike.ppem_y).to eq(32)
      expect(strike.bit_depth).to eq(8)
    end

    it 'keeps the requested ppem even if bit depth differs' do
      strike = cblc.strike_for(32, bit_depth: 32)
      expect(strike.ppem_y).to eq(32)
      expect(strike.bit_depth).to eq(8)
    end

    it 'falls back to the nearest ppem, preferring the requested bit depth' do
      strike = cblc.strike_for(40, bit_depth: 32)
      expect(strike.ppem_y).to eq(48)
      expect(strike.bit_depth).to eq(32)
    end

    it 'resolves equidistant ppems towards the smaller strike' do
      strike = cblc.strike_for(24)
      expect(strike.ppem_y).to eq(16)
    end

    it 'prefers the requested bit depth at an equidistant ppem' do
      expect(cblc.strike_for(24, bit_depth: 8).index).to eq(1)
      expect(cblc.strike_for(24, bit_depth: 32).index).to eq(0)
    end

    it 'returns nil when the table declares no strikes' do
      empty = CbdtFontBuilder.new(20)
      file = TTFunk::File.open(StringIO.new(empty.build))
      expect(file.color_bitmap_locations.strike_for(16)).to be_nil
    end
  end

  describe 'index subtables' do
    def entry(glyph_id, payload_size)
      CbdtFontBuilder::Entry.new(
        glyph_id: glyph_id,
        payload: "\xaa".b * payload_size,
        metrics: CbdtFontBuilder.metrics,
      )
    end

    def font_with(subtable)
      builder = CbdtFontBuilder.new(20)
      builder.add_strike(
        ppem: 16, bit_depth: 32, subtables: [subtable]
      )
      TTFunk::File.open(StringIO.new(builder.build))
    end

    it 'parses consecutive 32-bit offsets (index format 1)' do
      file = font_with(
        CbdtFontBuilder::Subtable.new(
          index_format: 1,
          image_format: 6,
          entries: [entry(2, 9), entry(3, 5), entry(4, 7)],
        )
      )
      cblc = file.color_bitmap_locations
      strike = cblc.strikes.first

      location = cblc.location_for(strike, 2)
      expect(location.end_offset - location.start_offset).to eq(9)
      expect(cblc.location_for(strike, 3).start_offset)
        .to eq(location.end_offset)
      expect(cblc.location_for(strike, 4).end_offset - location.start_offset)
        .to eq(9 + 5 + 7)
      expect(cblc.location_for(strike, 5)).to be_nil
    end

    it 'parses sparse 16-bit offsets (index format 3)' do
      file = font_with(
        CbdtFontBuilder::Subtable.new(
          index_format: 3,
          image_format: 6,
          entries: [entry(2, 9), entry(7, 5)],
        )
      )
      strike = file.color_bitmap_locations.strikes.first
      cblc = file.color_bitmap_locations

      expect(cblc.location_for(strike, 2).image_format).to eq(6)
      expect(cblc.location_for(strike, 7).start_offset)
        .to eq(cblc.location_for(strike, 2).end_offset)
      expect(cblc.location_for(strike, 3)).to be_nil
    end

    it 'parses sparse glyph code/offset pairs (index format 4)' do
      file = font_with(
        CbdtFontBuilder::Subtable.new(
          index_format: 4,
          image_format: 6,
          entries: [entry(3, 6), entry(11, 4)],
        )
      )
      strike = file.color_bitmap_locations.strikes.first
      cblc = file.color_bitmap_locations

      expect(cblc.location_for(strike, 3).end_offset -
             cblc.location_for(strike, 3).start_offset).to eq(6)
      expect(cblc.location_for(strike, 11).image_format).to eq(6)
      expect(cblc.location_for(strike, 4)).to be_nil
    end

    it 'parses fixed-size consecutive images (index format 2)' do
      metrics = CbdtFontBuilder.metrics(width: 2, height: 2)
      fixed = CbdtFontBuilder::Subtable.new(
        index_format: 2,
        image_format: 5,
        fixed_size: 10,
        fixed_metrics: metrics,
        entries: [
          CbdtFontBuilder::Entry.new(
            glyph_id: 4, payload: "\xcc".b * 10, metrics: metrics
          ),
          CbdtFontBuilder::Entry.new(
            glyph_id: 5, payload: "\xdd".b * 10, metrics: metrics
          ),
        ],
      )
      file = font_with(fixed)
      strike = file.color_bitmap_locations.strikes.first
      cblc = file.color_bitmap_locations

      first = cblc.location_for(strike, 4)
      second = cblc.location_for(strike, 5)
      expect(first.fixed_image_size).to eq(10)
      expect(second.start_offset - first.start_offset).to eq(10)
      expect(first.fixed_metrics.width).to eq(2)
    end

    it 'parses sparse fixed-size composite images (index format 5)' do
      metrics = CbdtFontBuilder.metrics(width: 4, height: 4)
      composite = CbdtFontBuilder::Subtable.new(
        index_format: 5,
        image_format: 19,
        fixed_size: 12,
        fixed_metrics: metrics,
        entries: [
          CbdtFontBuilder::Entry.new(
            glyph_id: 6, payload: "\x01".b * 12, metrics: metrics
          ),
          CbdtFontBuilder::Entry.new(
            glyph_id: 9, payload: "\x02".b * 12, metrics: metrics
          ),
        ],
      )
      file = font_with(composite)
      strike = file.color_bitmap_locations.strikes.first
      cblc = file.color_bitmap_locations

      expect(cblc.location_for(strike, 6).image_format).to eq(19)
      expect(cblc.location_for(strike, 9).start_offset -
             cblc.location_for(strike, 6).start_offset).to eq(12)
      expect(cblc.location_for(strike, 7)).to be_nil
    end
  end

  describe 'malformed data' do
    it 'raises when an index subtable points past the table' do
      subtable = empty_subtable(1, 17, 1)
      builder = CbdtFontBuilder.new(20)
      builder.add_strike(
        ppem: 16, bit_depth: 32, subtables: [subtable]
      )
      bytes = builder.build
      info = TTFunk::Directory.new(StringIO.new(bytes)).tables['CBLC']
      # Corrupt the additionalOffsetToIndexSubtable field.
      bytes.setbyte(info[:offset] + 56 + 4, 0xFF)
      bytes.setbyte(info[:offset] + 56 + 7, 0xFF)
      font = TTFunk::File.open(StringIO.new(bytes))

      expect { font.color_bitmap_locations.strikes }
        .to raise_error(TTFunk::Error, /truncated|invalid/i)
    end
  end
end
