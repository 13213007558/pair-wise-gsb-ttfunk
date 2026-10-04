# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TTFunk::VariableFontInstantiator do
  let(:font) { TTFunk::File.new(build_variation_font) }

  it 'uses the default location when no coordinates are supplied' do
    instance = font.instantiate_variable_font({})
    glyph, metrics = decode_instance(instance)

    expect(coordinates_of(glyph)).to eq([
      [0, 0], [100, 0], [100, 100], [0, 100],
    ])
    expect(metrics.advance_width).to eq(120)
  end

  it 'instantiates positive and negative extrema through fvar and avar' do
    positive = font.instantiate_variable_font('wght' => 900, 'wdth' => 150)
    positive_glyph, positive_metrics = decode_instance(positive)
    expect(coordinates_of(positive_glyph)).to eq([
      [0, 0], [149, 0], [149, 149], [0, 149],
    ])
    expect(positive_metrics.advance_width).to eq(169)

    negative = font.instantiate_variable_font('wght' => 100, 'wdth' => 50)
    negative_glyph, negative_metrics = decode_instance(negative)
    expect(coordinates_of(negative_glyph)).to eq([
      [0, 0], [51, 0], [51, 51], [0, 51],
    ])
    expect(negative_metrics.advance_width).to eq(71)
  end

  it 'instantiates an intermediate avar-mapped location and fills sparse points' do
    instance = font.instantiate_variable_font('wght' => 500, 'wdth' => 80)
    glyph, metrics = decode_instance(instance)

    expect(coordinates_of(glyph)).to eq([
      [0, 0], [80, 0], [80, 130], [0, 130],
    ])
    expect(metrics.advance_width).to eq(80)
  end

  it 'defaults unspecified axes independently' do
    instance = font.instantiate_variable_font('wght' => 900)
    glyph, metrics = decode_instance(instance)

    expect(coordinates_of(glyph)).to eq([
      [0, 0], [100, 0], [100, 149], [0, 149],
    ])
    expect(metrics.advance_width).to eq(120)
  end

  it 'removes variation tables and keeps the result a valid static TTF' do
    instance = font.instantiate_variable_font('wght' => 500, 'wdth' => 80)
    static_font = TTFunk::File.new(instance)

    aggregate_failures do
      %w[avar fvar gvar HVAR STAT MVAR CFF2].each do |tag|
        expect(static_font.directory.tables).not_to include(tag)
      end
      expect(static_font.directory.tables).to include('glyf', 'loca', 'hmtx', 'head')
      expect(instance_checksum(static_font, instance)).to eq(0xB1B0AFBA)
    end
  end

  it 'rejects coordinates outside the fvar range without producing output' do
    expect {
      font.instantiate_variable_font('wght' => 950)
    }.to raise_error(ArgumentError, /outside/)
  end

  it 'rejects unsupported CFF2 variable fonts before writing' do
    cff2_font = TTFunk::File.new(build_variation_font('CFF2'))

    expect {
      cff2_font.instantiate_variable_font('wght' => 900)
    }.to raise_error(TTFunk::Error, /CFF/)
  end

  def coordinates_of(glyph)
    glyph.x_coordinates.zip(glyph.y_coordinates)
  end

  def decode_instance(instance)
    static_font = TTFunk::File.new(instance)
    [static_font.glyph_outlines.for(1), static_font.horizontal_metrics.for(1)]
  end

  def instance_checksum(static_font, data)
    checksum_for(data) + static_font.header.checksum_adjustment
  end

  def checksum_for(data)
    padded = data.b + ("\0" * ((4 - data.bytesize % 4) % 4))
    padded.unpack('N*').sum & 0xFFFF_FFFF
  end

  def build_variation_font(extra_tag = nil)
    tables = {
      'head' => head_table,
      'hhea' => hhea_table,
      'maxp' => maxp_table,
      'hmtx' => [120, 0].pack('ns>') * 2,
      'cmap' => cmap_table,
      'name' => [0, 0].pack('n2'),
      'post' => [0x00030000].pack('N') + ("\0" * 28),
      'glyf' => glyf_table,
      'loca' => loca_table,
      'fvar' => fvar_table,
      'avar' => avar_table,
      'gvar' => gvar_table,
    }
    tables[extra_tag] = 'CFF2' if extra_tag

    sfnt(tables)
  end

  def sfnt(tables)
    ordered = tables.sort
    header_size = 12 + ordered.length * 16
    offset = header_size
    records = +''
    data = +''

    ordered.each do |tag, table_data|
      padded = table_data.b + ("\0" * ((4 - table_data.bytesize % 4) % 4))
      records << [tag, table_checksum(table_data), offset, table_data.bytesize].pack('A4NNN')
      data << padded
      offset += padded.bytesize
    end

    count = ordered.length
    power = 2 ** Integer(Math.log2(count))
    header = [
      0x00010000, count, power * 16, Integer(Math.log2(power)),
      count * 16 - power * 16,
    ].pack('Nn*')
    header + records + data
  end

  def table_checksum(data)
    padded = data.b + ("\0" * ((4 - data.bytesize % 4) % 4))
    padded.unpack('N*').sum & 0xFFFF_FFFF
  end

  def head_table
    [0x00010000, 0x00010000].pack('N2') +
      [0].pack('N') +
      [0x5F0F3CF5, 0x000B, 1000].pack('Nn2') +
      [0, 0].pack('q>2') +
      [0, 0, 149, 149, 0, 8, 2, 1].pack('s>*') +
      [0].pack('n')
  end

  def hhea_table
    [0x00010000].pack('N') +
      [800, -200, 0].pack('s>*') +
      [120].pack('n') +
      [0, 0, 149, 1, 0, 0, 0, 0, 0, 0, 0].pack('s>*') +
      [2].pack('n')
  end

  def maxp_table
    [0x00010000, 2].pack('Nn') + ("\0" * 26)
  end

  def cmap_table
    encoding = [3, 1, 0].pack('nnN')
    subtable = [0, 262, 0].pack('n3') +
    ([0] * 65 + [1] + [0] * 190).pack('C*')
    [0, 1].pack('n2') + encoding + subtable
  end

  def glyf_table
    square = +''
    square << [1, 0, 0, 100, 100].pack('s>5')
    square << [3].pack('n')
    square << [0].pack('n')
    square << [0x31, 0x33, 0x31, 0x31].pack('C4')
    square << [100].pack('C')
    square << [100].pack('C')
    square
  end

  def loca_table
    [0, 0, 24].pack('N*')
  end

  def fvar_table
    header = [1, 0].pack('n2') +
      [20].pack('N') +
      [2, 0, 2, 20, 0, 0].pack('n*')
    weight_axis = axis('wght', 100, 400, 900)
    width_axis = axis('wdth', 50, 100, 150)
    header + weight_axis + width_axis
  end

  def axis(tag, minimum, default, maximum)
    [tag].pack('A4') +
      [fixed(minimum), fixed(default), fixed(maximum)].pack('N3') +
      [0, 0].pack('n2')
  end

  def fixed(value)
    (value * 0x10000).to_i
  end

  def avar_table
    [1, 0, 2].pack('n3') +
      avar_axis('wght', [-0.75, -0.5], [0.5, 0.75]) +
      avar_axis('wdth', [-0.5, -0.75], [0.5, 0.25])
  end

  def avar_axis(tag, negative, positive)
    [tag, 5].pack('A4n') +
      [f2dot14(-1), f2dot14(-1),
       f2dot14(negative[0]), f2dot14(negative[1]),
       0, 0,
       f2dot14(positive[0]), f2dot14(positive[1]),
       f2dot14(1), f2dot14(1)].pack('s>*')
  end

  def gvar_table
    global_records = [
      [0xC000, [f2dot14(1), 0], [1, 1, 1, 49, 0, 0, 0, 0]],
      [0x4000, [f2dot14(1), 0], [-1, -1, -1, -49, 0, 0, 0, 0]],
      [0x8000, [0, f2dot14(1)], [0, 0, 0, 0, 0, 0, 0, 0]],
      [0x0001, [0, f2dot14(1)], [0, 0, 0, 0, 0, 0, 0, 0]],
    ]

    global = +''
    global_records.each do |flags, tuple, deltas|
      global << [28, 28, flags, *tuple].pack('n2n*')
      global << deltas.pack('c*')
    end

    headers = [0xC000, 0x4000, 0xC002, 0x4001].pack('n4')
    glyph_data = [4, 0].pack('n2') + headers + [0].pack('C')
    offsets = [0, 0, glyph_data.bytesize]
    glyph_data_offset = 96 + global.length
    header = [1, 0, 2, 4, 96, 2, 1, glyph_data_offset].pack('n4Nn2N')
    header + offsets.pack('N*') + glyph_data + global
  end

  def hvar_table
    region_list_offset = 14
    item_array_offset = 46
    map_offset = 80
    header = [1].pack('N') +
      [0].pack('N') +
      [map_offset].pack('N') +
      [0, 0].pack('N2')

    store = [1, region_list_offset, 1, item_array_offset].pack('nNnN')
    item_offsets = [0].pack('n')
    regions = [2, 2].pack('n2') +
      [0, f2dot14(-1), f2dot14(0), f2dot14(1)].pack('s>*') +
      [f2dot14(-1), 0, 0].pack('s>*') +
      [f2dot14(0), 0, f2dot14(1)].pack('s>*') +
      [0, f2dot14(-1), f2dot14(0), f2dot14(1)].pack('s>*')
    item = [1, 0, 2, 0].pack('n4') + [0, 0, -20, 20].pack('s>*') + [0, 1].pack('n2')
    map = [0].pack('n') + [3].pack('C') + [0, 0, 0].pack('n3')
    header + store + item_offsets + regions + item + map
  end

  def f2dot14(value)
    [(value * 0x4000).round].pack('s>').unpack1('s>')
  end
end
