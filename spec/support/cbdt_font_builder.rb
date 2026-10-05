# frozen_string_literal: true

require 'stringio'

# Minimal builder for synthetic SFNT fonts containing `CBLC`/`CBDT` tables.
# Binary layouts are produced directly so the specs can exercise individual
# index and image formats deterministically.
class CbdtFontBuilder
  LineMetricsData = Struct.new(
    :ascender, :descender, :width_max,
    :caret_slope_numerator, :caret_slope_denominator, :caret_offset,
    :min_origin_side_bearing, :min_advance_side_bearing,
    :max_before_base_line, :min_after_base_line
  ) do
    def encode
      [
        ascender, descender, width_max, caret_slope_numerator,
        caret_slope_denominator, caret_offset, min_origin_side_bearing,
        min_advance_side_bearing, max_before_base_line, min_after_base_line,
        0, 0,
      ].pack('c2 C c7 C2')
    end
  end

  Metrics = Struct.new(
    :width, :height,
    :horizontal_bearing_x, :horizontal_bearing_y, :horizontal_advance,
    :vertical_bearing_x, :vertical_bearing_y, :vertical_advance,
    keyword_init: true
  ) do
    def small_encode
      [
        height, width, horizontal_bearing_x, horizontal_bearing_y,
        horizontal_advance,
      ].pack('CCccc')
    end

    def big_encode
      [
        height, width, horizontal_bearing_x, horizontal_bearing_y,
        horizontal_advance, vertical_bearing_x, vertical_bearing_y,
        vertical_advance,
      ].pack('CCccCCcc')
    end
  end

  ComponentData = Struct.new(
    :glyph_id, :x_offset, :y_offset, keyword_init: true
  )

  # One glyph entry. `payload` is the exact image bytes stored in CBDT.
  Entry = Struct.new(
    :glyph_id, :payload, :width, :height, :metrics, keyword_init: true
  )

  Subtable = Struct.new(
    :index_format, :image_format, :entries, :fixed_size, :fixed_metrics,
    keyword_init: true
  )

  StrikeData = Struct.new(
    :ppem, :bit_depth, :horizontal, :vertical, :subtables, keyword_init: true
  )

  def self.line_metrics
    LineMetricsData.new(14, -4, 16, 0, 0, 0, 0, 0, 14, -4)
  end

  def self.metrics(attrs = {})
    defaults = {
      width: 2,
      height: 2,
      horizontal_bearing_x: 1,
      horizontal_bearing_y: 14,
      horizontal_advance: 16,
      vertical_bearing_x: 8,
      vertical_bearing_y: 0,
      vertical_advance: 18,
    }
    Metrics.new(**defaults.merge(attrs))
  end

  # Payload for an image format that stores small metrics inline.
  def self.small_payload(format, metrics, bitmap_data, png: false)
    body = png ? [bitmap_data.bytesize].pack('N') + bitmap_data : bitmap_data
    metrics.small_encode + body
  end

  # Payload for an image format that stores big metrics inline.
  def self.big_payload(format, metrics, bitmap_data, png: false)
    body = png ? [bitmap_data.bytesize].pack('N') + bitmap_data : bitmap_data
    metrics.big_encode + body
  end

  # Composite payload. Formats: 8 (small metrics), 9 (big metrics),
  # 18 (big metrics, color), 19 (fixed metrics, color).
  def self.composite_payload(format, metrics, components)
    records = components.map {
      [_1.glyph_id, _1.x_offset, _1.y_offset].pack('ncc')
    }.join

    case format
    when 8
      metrics.small_encode + "\0".b + [components.length].pack('n') + records
    when 9
      metrics.big_encode + [components.length].pack('n') + records
    when 18
      metrics.big_encode + [records.bytesize].pack('N') + records
    when 19
      [records.bytesize].pack('N') + records
    end
  end

  def initialize(num_glyphs)
    @num_glyphs = num_glyphs
    @strikes = []
  end

  attr_reader :strikes

  def add_strike(ppem:, bit_depth: 32, subtables: [])
    @strikes << StrikeData.new(
      ppem: ppem,
      bit_depth: bit_depth,
      horizontal: self.class.line_metrics,
      vertical: self.class.line_metrics,
      subtables: subtables,
    )
  end

  def build
    cblc, cbdt = build_tables
    assemble('CBLC' => cblc, 'CBDT' => cbdt)
  end

  private

  # Returns encoded [cblc, cbdt]. Image data offsets in CBLC are absolute
  # positions within CBDT, so both tables are built in subtable order.
  def build_tables
    size_tables = String.new
    index_blocks = String.new
    cbdt = [0x00020000].pack('N')

    @strikes.each_with_index do |strike, strike_index|
      array_and_data, image_data = encode_strike(strike, cbdt.bytesize)
      index_blocks << array_and_data
      cbdt << image_data

      size_tables << bitmap_size_table(
        strike, strike_index, array_and_data.bytesize
      )
    end

    cblc = [0x00020000, @strikes.length].pack('NN') + size_tables + index_blocks
    [cblc, cbdt]
  end

  def bitmap_size_table(strike, strike_index, index_block_size)
    # indexSubTableArrayOffset is relative to the beginning of CBLC.
    header_and_sizes = 8 + (@strikes.length * 48)
    array_offset = header_and_sizes + previous_index_block_size(strike_index)
    part1 = [
      array_offset, index_block_size, strike.subtables.length, 0
    ].pack('N4')
    part2 = [
      0, @num_glyphs - 1, strike.ppem, strike.ppem, strike.bit_depth, 1
    ].pack('n2CCcC')
    part1 + strike.horizontal.encode + strike.vertical.encode + part2
  end

  def previous_index_block_size(strike_index)
    @strikes.first(strike_index).sum do |strike|
      encode_strike_size(strike)
    end
  end

  def encode_strike_size(strike)
    # Array records (8 bytes each) plus encoded subtable bodies.
    (strike.subtables.length * 8) +
      strike.subtables.sum { |subtable| subtable_body_size(subtable) }
  end

  def subtable_body_size(subtable)
    8 + index_body_size(subtable)
  end

  def index_body_size(subtable)
    case subtable.index_format
    when 1
      entry_count(subtable) * 4
    when 2
      4 + 8
    when 3
      entry_count(subtable) * 2
    when 4
      4 + ((subtable.entries.length + 1) * 4)
    when 5
      4 + 8 + 4 + (subtable.entries.length * 2) + padding(subtable.entries.length * 2, 2)
    end
  end

  def padding(offset, alignment)
    remainder = offset % alignment
    remainder.zero? ? 0 : alignment - remainder
  end

  def entry_count(subtable)
    subtable.entries.last.glyph_id -
      subtable.entries.first.glyph_id + 2
  end

  # Encodes the index subtable array followed by subtable records for one
  # strike. Returns [index_block, image_data].
  def encode_strike(strike, cbdt_offset)
    array_bytes = String.new
    record_bytes = String.new
    image_data = String.new
    record_start = strike.subtables.length * 8

    strike.subtables.each_with_index do |subtable, i|
      first = subtable.entries.first.glyph_id
      last = subtable.entries.last.glyph_id
      additional_offset = record_start +
        strike.subtables.first(i).sum { |s| subtable_body_size(s) }
      array_bytes << [first, last, additional_offset].pack('n2N')

      image_data_offset = cbdt_offset + image_data.bytesize
      record, sub_image = encode_subtable(subtable, image_data_offset)
      record_bytes << record
      image_data << sub_image
    end

    [array_bytes + record_bytes, image_data]
  end

  def encode_subtable(subtable, image_data_offset)
    header = [
      subtable.index_format, subtable.image_format, image_data_offset
    ].pack('n2N')
    body = encode_index_body(subtable)
    image = subtable.entries.map {
      _1.payload.ljust(subtable.fixed_size || _1.payload.bytesize, "\0".b)
    }.join
    [header + body, image]
  end

  def encode_index_body(subtable)
    case subtable.index_format
    when 1
      consecutive_offsets(subtable, 4)
    when 2
      [subtable.fixed_size].pack('N') + subtable.fixed_metrics.big_encode
    when 3
      consecutive_offsets(subtable, 2)
    when 4
      sparse_offsets(subtable)
    when 5
      composite_index(subtable)
    end
  end

  def consecutive_offsets(subtable, offset_size)
    first = subtable.entries.first.glyph_id
    last = subtable.entries.last.glyph_id
    by_id = subtable.entries.to_h { [_1.glyph_id, _1] }
    format = offset_size == 4 ? 'N' : 'n'

    offsets = []
    cursor = 0
    (first..last).each do |glyph_id|
      offsets << cursor
      entry = by_id[glyph_id]
      cursor += entry.payload.bytesize if entry
    end
    offsets << cursor
    offsets.map { [_1].pack(format) }.join
  end

  def sparse_offsets(subtable)
    offsets = []
    cursor = 0
    subtable.entries.each do |entry|
      offsets << cursor
      cursor += entry.payload.bytesize
    end
    offsets << cursor

    pairs = subtable.entries.each_with_index.map {
      [_1.glyph_id, offsets[_2]].pack('n2')
    }.join
    padding_pair = [0, offsets.last].pack('n2')
    [subtable.entries.length].pack('N') + pairs + padding_pair
  end

  def composite_index(subtable)
    ids = subtable.entries.map { [_1.glyph_id].pack('n') }.join
    [subtable.fixed_size].pack('N') + subtable.fixed_metrics.big_encode +
      [subtable.entries.length].pack('N') + ids
  end

  def assemble(tables)
    tags = tables.keys
    offset = 12 + (tags.length * 16)
    directory = String.new
    body = String.new
    tables.each do |tag, bytes|
      directory << [tag, checksum(bytes), offset, bytes.bytesize].pack('a4NNN')
      body << bytes
      offset += bytes.bytesize
    end
    [0x00010000, tags.length, 0, 0, 0].pack('Nn4') + directory + body
  end

  def checksum(bytes)
    padded = bytes.dup
    padded << "\0".b * ((4 - (padded.bytesize % 4)) % 4)
    padded.unpack('N*').sum(0) % 0x100000000
  end
end
