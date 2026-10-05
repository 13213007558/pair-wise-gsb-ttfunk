# frozen_string_literal: true

# Helpers for building synthetic CBLC/CBDT font data.
module BitmapFontHelpers
  # Build a minimal sfnt font containing the given tables.
  #
  # @param tables [Hash{String => String}] table tag to table data mapping
  # @return [TTFunk::File]
  def build_font(tables)
    num_tables = tables.size
    header = [0x00010000, num_tables, 0, 0, 0].pack('Nnnnn')
    offset = 12 + (num_tables * 16)
    directory = String.new.b
    body = String.new.b

    tables.each do |tag, data|
      directory << [tag, 0, offset, data.bytesize].pack('a4N3')
      body << data
      offset += data.bytesize
      padding = (4 - (offset % 4)) % 4
      body << ("\0" * padding)
      offset += padding
    end

    TTFunk::File.open(StringIO.new(header + directory + body))
  end

  def small_metrics(overrides = {})
    { height: 2, width: 2, bearing_x: 0, bearing_y: 2, advance: 4 }
      .merge(overrides)
  end

  def big_metrics(overrides = {})
    {
      height: 2, width: 2,
      hori_bearing_x: 0, hori_bearing_y: 2, hori_advance: 4,
      vert_bearing_x: 1, vert_bearing_y: 1, vert_advance: 5,
    }.merge(overrides)
  end

  def small_metrics_bytes(metrics)
    [
      metrics[:height], metrics[:width],
      metrics[:bearing_x], metrics[:bearing_y], metrics[:advance],
    ].pack('C2c2C')
  end

  def big_metrics_bytes(metrics)
    [
      metrics[:height], metrics[:width],
      metrics[:hori_bearing_x], metrics[:hori_bearing_y],
      metrics[:hori_advance],
      metrics[:vert_bearing_x], metrics[:vert_bearing_y],
      metrics[:vert_advance],
    ].pack('C2c2Cc2C')
  end

  def sbit_line_metrics_bytes
    [10, -2, 20, 1, 1, 0, 0, 0, 10, -2, 0, 0].pack('c2Cc7c2')
  end

  # Build a CBLC table.
  #
  # @param strikes [Array<Hash>] each strike is a hash with +:ppem+,
  #   +:bit_depth+, and +:subtables+ keys. Each subtable is a hash with
  #   +:first+, +:last+, and +:data+ keys.
  # @return [String]
  def build_cblc(strikes)
    header = [0x00020000, strikes.size].pack('N2')
    records = String.new.b
    arrays = String.new.b
    array_offset = 8 + (strikes.size * 48)

    strikes.each do |strike|
      subtables = strike[:subtables]
      array_size = (subtables.size * 8) + subtables.sum { |s| s[:data].bytesize }

      records << [array_offset, array_size, subtables.size, 0].pack('N4')
      records << sbit_line_metrics_bytes << sbit_line_metrics_bytes
      records << [
        subtables.map { |s| s[:first] }.min,
        subtables.map { |s| s[:last] }.max,
        strike[:ppem], strike[:ppem], strike[:bit_depth], 1,
      ].pack('n2C4')

      subtable_offset = subtables.size * 8
      subtables.each do |subtable|
        arrays << [subtable[:first], subtable[:last], subtable_offset].pack('n2N')
        subtable_offset += subtable[:data].bytesize
      end
      subtables.each { |subtable| arrays << subtable[:data] }

      array_offset += array_size
    end

    header + records + arrays
  end

  # Build an index subtable.
  def index_subtable(index_format:, image_format:, image_data_offset:, body:)
    [index_format, image_format, image_data_offset].pack('n2N') + body
  end

  # Build a CBDT table from glyph data chunks.
  #
  # @param chunks [Array<String>]
  # @return [Array(String, Array<Integer>)] table data and offsets of the
  #   chunks within it
  def build_cbdt(chunks)
    offsets = []
    position = 4
    chunks.each do |chunk|
      offsets << position
      position += chunk.bytesize
    end

    [[0x00020000].pack('N') + chunks.join, offsets]
  end

  def image_glyph_17(metrics, data)
    small_metrics_bytes(metrics) + [data.bytesize].pack('N') + data
  end

  def image_glyph_18(metrics, data)
    big_metrics_bytes(metrics) + [data.bytesize].pack('N') + data
  end

  def image_glyph_19(data)
    [data.bytesize].pack('N') + data
  end

  # Image format 1 or 2 (small metrics + bitmap).
  def bitmap_glyph(metrics, pixels, byte_aligned: true)
    small_metrics_bytes(metrics) + pack_bitmap(pixels, byte_aligned: byte_aligned)
  end

  # Image format 6 or 7 (big metrics + bitmap).
  def bitmap_glyph_big(metrics, pixels, byte_aligned: true)
    big_metrics_bytes(metrics) + pack_bitmap(pixels, byte_aligned: byte_aligned)
  end

  # Image format 5 (bitmap only, metrics are in the index subtable).
  def bitmap_glyph_5(pixels)
    pack_bitmap(pixels, byte_aligned: false)
  end

  def composite_glyph_8(metrics, components)
    small_metrics_bytes(metrics) + "\0".b + composite_components(components)
  end

  def composite_glyph_9(metrics, components)
    big_metrics_bytes(metrics) + composite_components(components)
  end

  private

  def pack_bitmap(pixels, byte_aligned:)
    if byte_aligned
      pixels.map { |row| [row.join].pack('B*') }.join
    else
      [pixels.flatten.join].pack('B*')
    end
  end

  def composite_components(components)
    [components.size].pack('n') +
      components.map { |c| [c[:glyph_id], c[:x], c[:y]].pack('nc2') }.join
  end
end
