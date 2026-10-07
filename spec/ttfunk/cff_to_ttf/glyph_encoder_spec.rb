# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TTFunk::CffToTtf::GlyphEncoder do
  it 'encodes empty contours as an empty glyph' do
    glyph = described_class.encode([])

    expect(glyph.raw).to eq(''.b)
    expect(glyph).to be_empty
    expect(glyph.number_of_contours).to eq(0)
    expect(glyph.number_of_points).to eq(0)
  end

  it 'encodes a simple contour' do
    glyph = described_class.encode([
      [[0, 0, true], [100, 0, true], [50, 80, true]],
    ])

    expect(glyph.number_of_contours).to eq(1)
    expect(glyph.number_of_points).to eq(3)
    expect(glyph.x_min).to eq(0)
    expect(glyph.y_min).to eq(0)
    expect(glyph.x_max).to eq(100)
    expect(glyph.y_max).to eq(80)

    number_of_contours, x_min, y_min, x_max, y_max = glyph.raw[0, 10].unpack('s>5')
    expect(number_of_contours).to eq(1)
    expect([x_min, y_min, x_max, y_max]).to eq([0, 0, 100, 80])
    expect(glyph.raw[10, 2].unpack1('n')).to eq(2) # end point of contour
    expect(glyph.raw[12, 2].unpack1('n')).to eq(0) # no instructions
  end

  it 'encodes no instructions' do
    glyph = described_class.encode([
      [[0, 0, true], [100, 0, true], [50, 80, true]],
    ])

    instruction_length = glyph.raw[12, 2].unpack1('n')
    expect(instruction_length).to eq(0)
  end

  it 'marks off-curve points in the flags' do
    glyph = described_class.encode([
      [[0, 0, true], [50, 50, false], [100, 0, true]],
    ])

    flags = glyph.raw[14, 3].bytes
    expect(flags[0] & 0x01).to eq(1)
    expect(flags[1] & 0x01).to eq(0)
    expect(flags[2] & 0x01).to eq(1)
  end

  it 'round-trips points through the binary encoding' do
    contours = [
      [[0, 0, true], [50, 50, false], [100, 0, true]],
      [[-300, -200, true], [300, -200, true], [0, 400, false], [-300, -200, true]],
    ]

    glyph = described_class.encode(contours)

    expect(decode_simple_glyph_points(glyph.raw)).to eq(contours)
  end

  it 'uses compact coordinate encodings when possible' do
    glyph = described_class.encode([
      [[0, 0, true], [100, 0, true], [100, 100, true]],
    ])

    # All deltas fit in one byte or are zero: no 2-byte coordinates.
    # header (10) + end points (2) + instruction length (2) + flags (3)
    # + x deltas (1) + y deltas (1)
    expect(glyph.raw.length).to eq(19)
  end
end
