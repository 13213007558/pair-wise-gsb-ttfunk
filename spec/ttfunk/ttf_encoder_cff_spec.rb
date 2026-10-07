# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/subset'

RSpec.describe 'CFF to TrueType encoding' do
  let(:original) { TTFunk::File.open(test_font('Exo-Regular', :otf)) }
  let(:subset) do
    TTFunk::Subset::Unicode.new(original).tap do |selected|
      selected.use('a'.ord)
    end
  end

  it 'writes readable glyf, loca, mappings, and horizontal metrics' do
    encoded = subset.encode(
      cff_to_truetype: { max_error: 1.0, max_segments: 256 },
    )
    font = TTFunk::File.open(StringIO.new(encoded))

    old_gid = original.cmap.unicode.first['a'.ord]
    new_gid = font.cmap.unicode.first['a'.ord]
    glyph = font.glyph_outlines.for(new_gid)
    glyf_info = font.directory.tables['glyf']
    offsets = font.glyph_locations.offsets

    expect(font.directory.scaler_type).to eq(0x00010000)
    expect(font.directory.tables).to include('glyf', 'loca', 'hmtx', 'maxp', 'head')
    expect(font.directory.tables).not_to include('CFF ', 'VORG', 'DSIG')
    expect(font.maximum_profile.version).to eq(0x10000)
    expect(font.header.index_to_loc_format).to be_between(0, 1)
    expect(glyph.number_of_contours).to eq(
      original.find_glyph(old_gid).number_of_contours,
    )
    expect(glyph.instruction_length).to eq(0)
    expect(font.horizontal_metrics.for(new_gid).advance_width).to eq(
      original.horizontal_metrics.for(old_gid).advance_width,
    )
    expect(offsets.count).to eq(font.maximum_profile.num_glyphs + 1)
    expect(offsets.first).to eq(0)
    expect(offsets).to eq(offsets.sort)
    expect(offsets.last).to eq(glyf_info[:length])
    expect(font.glyph_locations.index_of(new_gid)).to eq(offsets[new_gid])
    expect(glyph.end_point_of_last_contour).to be <= font.maximum_profile.max_points
  end

  it 'fails before emitting output when one glyph exceeds its subdivision budget' do
    expect do
      subset.encode(
        cff_to_truetype: { max_error: 0.0001, max_segments: 1 },
      )
    end.to raise_error(ArgumentError, /more than 1 segment/)
  end
end
