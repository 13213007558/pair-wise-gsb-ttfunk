# frozen_string_literal: true

require 'stringio'

# Builds SFNT fonts containing synthesized `kern` tables for specs.
module KernFontHelpers
  MODULE_MAGIC_NUMBER = 0x5F0F3CF5

  # Rebuild an SFNT font, replacing its `kern` table with `kern_data`.
  def rebuild_font_with_kern(font_path, kern_data)
    blob = File.binread(font_path).b
    scaler, table_count = blob.unpack('Nn')

    tables = {}
    table_count.times do |i|
      record_pos = 12 + (i * 16)
      tag, = blob.unpack('A4', offset: record_pos)
      tables[tag] = blob.unpack('NNNN', offset: record_pos + 4)
    end

    blobs = {}
    tables.each do |tag, (_checksum, offset, length)|
      blobs[tag] = blob[offset, length]
    end
    blobs['kern'] = kern_data

    head = blobs['head'].dup
    head[8, 4] = [0].pack('N')
    blobs['head'] = head

    tags = blobs.keys.sort
    directory = [scaler, tags.length,
                 search_range(tags.length, 16),
                 entry_selector(tags.length, 16),
                 (tags.length * 16) - search_range(tags.length, 16)].pack('Nn*')

    records = +''
    body = +''
    offset = 12 + (tags.length * 16)

    tags.each do |tag|
      data = blobs[tag]
      checksum = table_checksum(tag == 'head' ? head : data)
      records << [tag, checksum, offset, data.length].pack('A4NNN')
      body << data
      padding = data.length.odd? ? "\0" : ''
      body << padding
      offset += data.length + padding.length
    end

    font = directory + records + body

    adjustment = (0xB1B0AFBA - table_checksum(font)) & 0xFFFFFFFF
    head_offset = 12 + (tags.length * 16) + body.index(head)
    font[head_offset + 8, 4] = [adjustment].pack('N')
    font
  end

  # Encode a version-0 `kern` table out of the given encoded subtables.
  def kern_table(subtables)
    body = subtables.join
    [0, subtables.length, body].pack('nnA*')
  end

  # Encode a format 2 kerning subtable.
  #
  # `matrix` is an array of rows. Left and right class tables use Apple
  # class table format 0 by default; pass `left_format: 1` to encode the
  # left class table in format 1.
  def format2_subtable(matrix, left_classes, right_classes,
                       coverage: 0, left_format: 0)
    values = matrix.flatten
    columns = matrix.first.length
    row_width = columns * 2

    left_table =
      if left_format == 1
        class_table_format1(left_classes)
      else
        class_table_format0(left_classes)
      end
    right_table = class_table_format0(right_classes)

    left_offset = 12 + (values.length * 2)
    right_offset = left_offset + left_table.length
    length = right_offset + right_table.length

    header = [
      0, length, 0x0200 | coverage,
      row_width, left_offset, right_offset,
      values.map { |value| value & 0xFFFF }
    ].flatten.pack('n*')
    header + left_table + right_table
  end

  # Encode a format 0 kerning subtable.
  def format0_subtable(pairs, coverage: 0)
    ordered = pairs.sort_by { |(left, right), _value| [left, right] }
    num_pairs = ordered.length
    search_range = 6 * largest_power_of_two(num_pairs)
    entry_selector = Math.log2(largest_power_of_two(num_pairs)).to_i
    range_shift = (num_pairs * 6) - search_range

    data = ordered.flatten.flatten
    header = [
      0, (num_pairs * 6) + 14, 0x0000 | coverage,
      num_pairs, search_range, entry_selector, range_shift
    ].pack('n*')
    header + data.map { |value| value & 0xFFFF }.pack('n*')
  end

  # Encode an Apple class table format 0. `glyph_classes` maps glyph ids to
  # (non-zero) class byte offsets.
  def class_table_format0(glyph_classes)
    glyphs = glyph_classes.keys.sort
    return [0, 0, 0].pack('n*') if glyphs.empty?

    first_glyph = glyphs.first
    glyph_count = (glyphs.last - first_glyph) + 1
    values = glyph_count.times.map do |i|
      glyph_classes[first_glyph + i] || 0
    end

    [0, glyph_count, first_glyph, values].flatten.pack('n*')
  end

  # Encode an Apple class table format 1.
  def class_table_format1(glyph_classes)
    glyphs = glyph_classes.keys.sort
    first_glyph = glyphs.first
    glyph_count = (glyphs.last - first_glyph) + 1
    by_glyph = glyph_classes

    # Every classified glyph gets a two-word value record: the class and a
    # (unused) tuple count. Records follow the offset array; offsets are
    # relative to the start of the class table.
    records = []
    offset_array = glyph_count.times.map do |i|
      glyph = first_glyph + i
      if by_glyph.key?(glyph)
        offset = 6 + (glyph_count * 2) + (records.length * 2)
        records << by_glyph[glyph] << 0
        offset
      else
        0
      end
    end

    [1, glyph_count, first_glyph, offset_array, records].flatten.pack('n*')
  end

  private

  def largest_power_of_two(number)
    2 ** Integer(Math.log2([number, 1].max))
  end

  def search_range(count, entry_size)
    largest_power_of_two(count) * entry_size
  end

  def entry_selector(count, entry_size)
    Integer(Math.log2(search_range(count, entry_size) / entry_size))
  end

  def table_checksum(data)
    padded = data.b + ("\0" * ((4 - (data.length % 4)) % 4))
    sum = padded.unpack('N*').reduce(0) { |total, long| (total + long) & 0xFFFFFFFF }
    sum
  end
end

RSpec.configure { |config| config.include(KernFontHelpers) }
