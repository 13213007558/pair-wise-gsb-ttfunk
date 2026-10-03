# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'ttfunk/subset'

describe 'CFF to TrueType conversion' do # rubocop:disable RSpec/DescribeClass
  let(:font_path) { test_font('AlbertTextBold', :otf) }
  let(:font) { TTFunk::File.open(font_path) }

  let(:encoded_font) do
    subset = TTFunk::Subset.for(font, :unicode)
    [32, 97, 98].each { |code_point| subset.use(code_point) }
    subset.encode(truetype_outline_tolerance: 2)
  end

  let(:new_font) { TTFunk::File.open(StringIO.new(encoded_font)) }

  it 'emits a real TrueType sfnt with glyf and loca and no CFF tables' do
    expect(new_font.directory.scaler_type).to eq(0x00010000)
    expect(new_font.directory.tables).to include('glyf', 'loca')
    expect(new_font.directory.tables).not_to include('CFF ', 'VORG', 'DSIG')
    expect(new_font.directory.tables).not_to include('fpgm', 'prep', 'cvt ')
  end

  it 'rebuilds maxp, head, hhea and hmtx from converted glyphs' do
    expect(new_font.maximum_profile.version).to eq(0x10000)
    expect(new_font.maximum_profile.num_glyphs).to eq(4)
    expect(new_font.maximum_profile.max_points).to eq(51)
    expect(new_font.maximum_profile.max_size_of_instructions).to eq(0)
    expect(new_font.horizontal_header.number_of_metrics).to eq(4)

    head_info = new_font.directory.tables['head']
    head = encoded_font[head_info[:offset], head_info[:length]]
    bbox = head[36, 8].unpack('s>4')

    expect(bbox).to eq(
      [new_font.header.x_min, new_font.header.y_min, new_font.header.x_max, new_font.header.y_max],
    )
    expect(bbox).to eq([0, 0, 438, 808])
  end

  it 'can reread converted glyphs as unhinted simple TrueType glyphs' do
    glyph_ids = 0...new_font.maximum_profile.num_glyphs

    glyph_ids.each do |glyph_id|
      glyph = new_font.glyph_outlines.for(glyph_id)

      if glyph
        expect(glyph).not_to be_compound
        expect(glyph.instruction_length).to eq(0)
      end
    end

    expect(new_font.glyph_outlines.for(1)).to be_nil
  end

  it 'preserves horizontal metrics for the empty and non-empty glyphs' do
    expect(new_font.horizontal_metrics.for(0).advance_width).to eq(
      font.horizontal_metrics.for(0).advance_width,
    )
    expect(new_font.horizontal_metrics.for(1).advance_width).to eq(
      font.horizontal_metrics.for(font.cmap.unicode.first[32]).advance_width,
    )
  end

  it 'adjusts the whole-font checksum' do
    padded = encoded_font + ('\0' * (-(encoded_font.length) % 4))
    checksum = padded.bytes.each_slice(4).sum { |bytes|
      bytes.each_with_index.sum { |byte, index| byte << (8 * (3 - index)) }
    } & 0xFFFF_FFFF

    expect(checksum).to eq(0xB1B0AFBA)
  end

  it 'rejects a smaller tolerance rather than relaxing it' do
    expect {
      another_font = TTFunk::File.open(font_path)
      another_subset = TTFunk::Subset.for(another_font, :unicode)
      another_subset.use(97)
      another_subset.encode(truetype_outline_tolerance: 0.1)
    }.to raise_error(TTFunk::Table::Glyf::PathBased::ConversionError)
  end

  it 'rejects a non-positive tolerance' do
    subset = TTFunk::Subset.for(font, :unicode)

    expect {
      subset.encode(truetype_outline_tolerance: 0)
    }.to raise_error(ArgumentError, /positive finite/)
  end

  it 'does not accept the conversion option for TrueType input' do
    truetype_font = TTFunk::File.open(test_font('DejaVuSans'))
    subset = TTFunk::Subset.for(truetype_font, :unicode)

    expect {
      subset.encode(truetype_outline_tolerance: 2)
    }.to raise_error(ArgumentError, /only supported for CFF fonts/)
  end
end
