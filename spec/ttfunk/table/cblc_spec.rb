# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/table/cblc'

RSpec.describe TTFunk::Table::Cblc do
  def empty_subtable(image_format: 17)
    {
      first: 1,
      last: 1,
      data: index_subtable(
        index_format: 1,
        image_format: image_format,
        image_data_offset: 4,
        body: [0, 0].pack('N2'),
      ),
    }
  end

  def font_with_strikes(strikes, cbdt_chunks = [])
    cbdt, offsets = build_cbdt(cbdt_chunks)
    font = build_font('CBLC' => build_cblc(strikes), 'CBDT' => cbdt)
    [font, offsets]
  end

  describe 'table parsing' do
    it 'parses version and strike records' do
      font, = font_with_strikes([
        { ppem: 16, bit_depth: 32, subtables: [empty_subtable] },
        { ppem: 32, bit_depth: 1, subtables: [empty_subtable] },
      ])
      cblc = font.cblc

      expect(cblc.version).to eq(0x00020000)
      expect(cblc.strikes.size).to eq(2)

      strike = cblc.strikes.first
      expect(strike.ppem_x).to eq(16)
      expect(strike.ppem_y).to eq(16)
      expect(strike.ppem).to eq(16)
      expect(strike.bit_depth).to eq(32)
      expect(strike.start_glyph_index).to eq(1)
      expect(strike.end_glyph_index).to eq(1)
      expect(strike.hori.ascender).to eq(10)
      expect(strike.hori.descender).to eq(-2)
      expect(strike.hori.width_max).to eq(20)
      expect(strike.vert.ascender).to eq(10)

      expect(cblc.strikes.last.bit_depth).to eq(1)
    end

    it 'is nil when the font has no CBLC table' do
      font = build_font('CBDT' => build_cbdt([]).first)
      expect(font.cblc).to be_nil
    end

    it 'raises on truncated strike records' do
      cblc = build_cblc([{ ppem: 16, bit_depth: 32, subtables: [empty_subtable] }])
      font = build_font('CBLC' => cblc.byteslice(0, 20), 'CBDT' => build_cbdt([]).first)

      expect { font.cblc }.to raise_error(TTFunk::Error)
    end
  end

  describe '#strike_for' do
    let(:font) do
      font_with_strikes([
        { ppem: 16, bit_depth: 32, subtables: [empty_subtable] },
        { ppem: 32, bit_depth: 32, subtables: [empty_subtable] },
        { ppem: 32, bit_depth: 1, subtables: [empty_subtable(image_format: 1)] },
      ]).first
    end

    it 'selects the strike with the exact ppem' do
      expect(font.cblc.strike_for(16).ppem).to eq(16)
      expect(font.cblc.strike_for(32).bit_depth).to eq(32)
    end

    it 'selects the strike with the exact ppem and bit depth' do
      strike = font.cblc.strike_for(32, bit_depth: 1)
      expect(strike.ppem).to eq(32)
      expect(strike.bit_depth).to eq(1)
    end

    it 'falls back to the closest ppem' do
      expect(font.cblc.strike_for(20).ppem).to eq(16)
      expect(font.cblc.strike_for(28).ppem).to eq(32)
      expect(font.cblc.strike_for(8).ppem).to eq(16)
      expect(font.cblc.strike_for(64).ppem).to eq(32)
    end

    it 'prefers the larger strike on ppem ties' do
      expect(font.cblc.strike_for(24).ppem).to eq(32)
    end

    it 'degrades to another bit depth when none matches' do
      strike = font.cblc.strike_for(16, bit_depth: 8)
      expect(strike.ppem).to eq(16)
      expect(strike.bit_depth).to eq(32)
    end

    it 'returns nil when there are no strikes' do
      font = build_font('CBLC' => build_cblc([]), 'CBDT' => build_cbdt([]).first)
      expect(font.cblc.strike_for(16)).to be_nil
    end
  end

  describe '#bitmap_for' do
    def image_font
      glyph1 = image_glyph_17(small_metrics, 'PNG1')
      glyph3 = image_glyph_17(small_metrics, 'PNG3')
      font_with_strikes(
        [{
          ppem: 16,
          bit_depth: 32,
          subtables: [format1_subtable([glyph1, nil, glyph3])],
        }],
        [glyph1, glyph3],
      ).first
    end

    def format1_subtable(glyphs, first: 1, image_format: 17)
      offsets = [0]
      glyphs.each do |glyph|
        # Glyphs without a bitmap have equal offsets.
        offsets << offsets.last + (glyph ? glyph.bytesize : 0)
      end

      {
        first: first,
        last: first + glyphs.size - 1,
        data: index_subtable(
          index_format: 1,
          image_format: image_format,
          image_data_offset: 4,
          body: offsets.pack('N*'),
        ),
      }
    end

    it 'returns the glyph bitmap along with the selected strike' do
      selection = image_font.cblc.bitmap_for(1, ppem: 16)

      expect(selection).to be_a(described_class::BitmapSelection)
      expect(selection.strike.ppem).to eq(16)
      expect(selection.glyph.image_data).to eq('PNG1')
      expect(selection.exact_match?(16)).to be(true)
      expect(selection.exact_match?(16, bit_depth: 32)).to be(true)
    end

    it 'exposes the fallback strike so callers can detect degradation' do
      selection = image_font.cblc.bitmap_for(1, ppem: 24)

      expect(selection.strike.ppem).to eq(16)
      expect(selection.glyph.image_data).to eq('PNG1')
      expect(selection.exact_match?(24)).to be(false)
    end

    it 'returns a selection with nil glyph for glyphs without a bitmap' do
      selection = image_font.cblc.bitmap_for(2, ppem: 16)

      expect(selection.strike.ppem).to eq(16)
      expect(selection.glyph).to be_nil
    end

    it 'returns a selection with nil glyph for uncovered glyphs' do
      selection = image_font.cblc.bitmap_for(42, ppem: 16)

      expect(selection.glyph).to be_nil
    end

    it 'returns nil when there are no strikes' do
      font = build_font('CBLC' => build_cblc([]), 'CBDT' => build_cbdt([]).first)
      expect(font.cblc.bitmap_for(1, ppem: 16)).to be_nil
    end

    it 'raises when the CBDT table is missing' do
      glyph1 = image_glyph_17(small_metrics, 'PNG1')
      font = build_font('CBLC' => build_cblc([
        { ppem: 16, bit_depth: 32, subtables: [format1_subtable([glyph1])] },
      ]))

      expect { font.cblc.bitmap_for(1, ppem: 16) }
        .to raise_error(TTFunk::Error, /CBDT/)
    end
  end

  describe 'index subtables' do
    def font_with_subtable(subtable, glyphs)
      font_with_strikes(
        [{ ppem: 16, bit_depth: 32, subtables: [subtable] }],
        glyphs,
      ).first
    end

    it 'supports format 1 (continuous, 4-byte offsets)' do
      glyphs = [
        image_glyph_17(small_metrics, 'PNG1'),
        image_glyph_17(small_metrics, 'PNG2'),
      ]
      offsets = [0, glyphs[0].bytesize, glyphs.sum(&:bytesize)]
      font = font_with_subtable({
        first: 1,
        last: 2,
        data: index_subtable(
          index_format: 1, image_format: 17, image_data_offset: 4,
          body: offsets.pack('N*'),
        ),
      }, glyphs)

      expect(font.cblc.bitmap_for(1, ppem: 16).glyph.image_data).to eq('PNG1')
      expect(font.cblc.bitmap_for(2, ppem: 16).glyph.image_data).to eq('PNG2')
    end

    it 'supports format 3 (continuous, 2-byte offsets)' do
      glyphs = [
        image_glyph_17(small_metrics, 'PNG1'),
        image_glyph_17(small_metrics, 'PNG2'),
      ]
      offsets = [0, glyphs[0].bytesize, glyphs.sum(&:bytesize)]
      font = font_with_subtable({
        first: 1,
        last: 2,
        data: index_subtable(
          index_format: 3, image_format: 17, image_data_offset: 4,
          body: offsets.pack('n*'),
        ),
      }, glyphs)

      expect(font.cblc.bitmap_for(1, ppem: 16).glyph.image_data).to eq('PNG1')
      expect(font.cblc.bitmap_for(2, ppem: 16).glyph.image_data).to eq('PNG2')
    end

    it 'supports format 4 (sparse, 4-byte offsets)' do
      glyphs = [
        image_glyph_17(small_metrics, 'PNG1'),
        image_glyph_17(small_metrics, 'PNG5'),
        image_glyph_17(small_metrics, 'PNG9'),
      ]
      offsets = [0]
      glyphs.each { |glyph| offsets << offsets.last + glyph.bytesize }
      body = [3].pack('N') +
        [1, 5, 9].zip(offsets).map { |pair| pair.pack('nN') }.join +
        [offsets.last].pack('N')
      font = font_with_subtable({
        first: 1,
        last: 9,
        data: index_subtable(
          index_format: 4, image_format: 17, image_data_offset: 4,
          body: body,
        ),
      }, glyphs)

      expect(font.cblc.bitmap_for(1, ppem: 16).glyph.image_data).to eq('PNG1')
      expect(font.cblc.bitmap_for(5, ppem: 16).glyph.image_data).to eq('PNG5')
      expect(font.cblc.bitmap_for(9, ppem: 16).glyph.image_data).to eq('PNG9')
      expect(font.cblc.bitmap_for(2, ppem: 16).glyph).to be_nil
    end

    it 'supports format 2 (continuous, constant size) with format 5 images' do
      pixels = [[1, 0], [0, 1]]
      glyphs = [bitmap_glyph_5(pixels), bitmap_glyph_5(pixels)]
      body = [glyphs[0].bytesize].pack('N') + big_metrics_bytes(big_metrics)
      font = font_with_subtable({
        first: 1,
        last: 2,
        data: index_subtable(
          index_format: 2, image_format: 5, image_data_offset: 4,
          body: body,
        ),
      }, glyphs)

      glyph = font.cblc.bitmap_for(2, ppem: 16).glyph
      expect(glyph.pixels).to eq(pixels)
      expect(glyph.metrics.hori_advance).to eq(4)
      expect(glyph.metrics.vert_advance).to eq(5)
    end

    it 'supports format 5 (sparse, constant size)' do
      pixels = [[1, 0], [0, 1]]
      glyphs = [bitmap_glyph_5(pixels), bitmap_glyph_5(pixels.reverse)]
      body = [glyphs[0].bytesize].pack('N') +
        big_metrics_bytes(big_metrics) +
        [2].pack('N') +
        [2, 7].pack('n2')
      font = font_with_subtable({
        first: 2,
        last: 7,
        data: index_subtable(
          index_format: 5, image_format: 5, image_data_offset: 4,
          body: body,
        ),
      }, glyphs)

      expect(font.cblc.bitmap_for(2, ppem: 16).glyph.pixels).to eq(pixels)
      expect(font.cblc.bitmap_for(7, ppem: 16).glyph.pixels)
        .to eq(pixels.reverse)
      expect(font.cblc.bitmap_for(3, ppem: 16).glyph).to be_nil
    end

    it 'raises on glyph data offsets outside the CBDT table' do
      glyphs = [image_glyph_17(small_metrics, 'PNG1')]
      font = font_with_subtable({
        first: 1,
        last: 1,
        data: index_subtable(
          index_format: 1, image_format: 17, image_data_offset: 10_000,
          body: [0, glyphs[0].bytesize].pack('N2'),
        ),
      }, glyphs)

      expect { font.cblc.bitmap_for(1, ppem: 16) }
        .to raise_error(TTFunk::Error, /out of bounds/)
    end

    it 'raises on offset arrays extending beyond the CBLC table' do
      glyphs = [image_glyph_17(small_metrics, 'PNG1')]
      font = font_with_subtable({
        first: 1,
        last: 100,
        data: index_subtable(
          index_format: 1, image_format: 17, image_data_offset: 4,
          body: [0, 0].pack('N2'),
        ),
      }, glyphs)

      expect { font.cblc.bitmap_for(1, ppem: 16) }
        .to raise_error(TTFunk::Error, /out of bounds/)
    end

    it 'raises on unsupported index subtable formats' do
      glyphs = [image_glyph_17(small_metrics, 'PNG1')]
      font = font_with_subtable({
        first: 1,
        last: 1,
        data: index_subtable(
          index_format: 42, image_format: 17, image_data_offset: 4,
          body: [0, 0].pack('N2'),
        ),
      }, glyphs)

      expect { font.cblc.bitmap_for(1, ppem: 16) }
        .to raise_error(TTFunk::Error, /index subtable format/)
    end
  end
end
