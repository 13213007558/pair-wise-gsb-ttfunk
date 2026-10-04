# frozen_string_literal: true

# Builds a tiny synthetic TrueType font containing a cmap format 14
# (Unicode Variation Sequences) subtable for testing.
#
# Glyphs:
# * 0 - .notdef (empty)
# * 1 - U+0020 (empty)
# * 2 - U+4E00 base glyph (simple)
# * 3 - U+4E00 + U+FE01 variant glyph (compound, references glyph 2)
#
# Variation sequences:
# * U+4E00 U+FE00 - default UVS (uses the base glyph)
# * U+4E00 U+FE01 - non-default UVS (uses glyph 3)
# * U+4E00 U+FE02 - non-default UVS (uses glyph 3), meant to be left
#   unrequested so tests can verify unrequested selectors are dropped
module UVSTestFont
  BASE_CHAR = 0x4E00
  BASE_GLYPH_ID = 2
  VARIANT_GLYPH_ID = 3
  DEFAULT_SELECTOR = 0xFE00
  VARIANT_SELECTOR = 0xFE01
  EXTRA_SELECTOR = 0xFE02

  module_function

  def build
    tables = {
      'OS/2' => os2_table,
      'cmap' => cmap_table,
      'glyf' => glyf_table,
      'head' => head_table,
      'hhea' => hhea_table,
      'hmtx' => hmtx_table,
      'loca' => loca_table,
      'maxp' => maxp_table,
      'name' => name_table,
      'post' => post_table,
    }

    tags = tables.keys.sort
    offset = 12 + (tags.length * 16)
    directory = []
    data = +''.b

    tags.each do |tag|
      table = tables[tag]
      directory << [tag, checksum(table), offset, table.length].pack('a4N3')
      data << table
      padding = (4 - (table.length % 4)) % 4
      data << "\0".b * padding
      offset += table.length + padding
    end

    max_power = 2**Math.log2(tags.length).floor
    header = [
      0x00010000,
      tags.length,
      max_power * 16,
      Integer(Math.log2(max_power)),
      (tags.length * 16) - (max_power * 16),
    ].pack('Nn4')

    header + directory.join + data
  end

  def checksum(table)
    padded = table.dup
    padded << "\0".b * ((4 - (padded.length % 4)) % 4)
    padded.unpack('N*').sum & 0xFFFFFFFF
  end

  def head_table
    [0x00010000, 0x00010000, 0, 0x5F0F3CF5].pack('N4') +
      [0, 1000].pack('n2') +
      [0, 0].pack('q>2') +
      [0, 0, 500, 500].pack('n4') +
      [0, 8, 2, 0, 0].pack('n5')
  end

  def hhea_table
    [0x00010000].pack('N') +
      [
        800, -200, 0,
        500,
        0, 0, 500,
        1, 0, 0,
        0, 0, 0, 0,
        0,
        4,
      ].pack('n16')
  end

  def maxp_table
    [0x00010000, 4].pack('Nn') + ([0] * 13).pack('n13')
  end

  def hmtx_table
    ([500, 0] * 4).pack('n8')
  end

  def glyf_table
    simple = [1, 0, 0, 500, 500].pack('n5') + [0, 0].pack('n2')
    compound =
      [-1, 0, 0, 500, 500].pack('n5') +
      [0x0001, BASE_GLYPH_ID, 0, 0].pack('n4')

    simple + compound
  end

  def loca_table
    [0, 0, 0, 7, 16].pack('n5')
  end

  def cmap_table
    format4 =
      TTFunk::Table::Cmap::Format04.encode(
        0x20 => 1,
        BASE_CHAR => BASE_GLYPH_ID,
      )[:subtable]
    format14 = uvs_subtable

    header_size = 4 + (2 * 8)
    [0, 2].pack('nn') +
      [3, 1, header_size].pack('nnN') +
      [0, 5, header_size + format4.length].pack('nnN') +
      format4 +
      format14
  end

  def uvs_subtable
    default_uvs = [1].pack('N') + uint24(BASE_CHAR) + [0].pack('C')
    non_default_uvs =
      [1].pack('N') + uint24(BASE_CHAR) + [VARIANT_GLYPH_ID].pack('n')

    offset = 10 + (3 * 11)
    default_offset = offset
    variant_offset = default_offset + default_uvs.length
    extra_offset = variant_offset + non_default_uvs.length
    length = extra_offset + non_default_uvs.length

    [14, length, 3].pack('nNN') +
      uint24(DEFAULT_SELECTOR) + [default_offset, 0].pack('NN') +
      uint24(VARIANT_SELECTOR) + [0, variant_offset].pack('NN') +
      uint24(EXTRA_SELECTOR) + [0, extra_offset].pack('NN') +
      default_uvs +
      non_default_uvs +
      non_default_uvs
  end

  def name_table
    string = 'UVSTestF'
    [0, 1, 18].pack('n3') +
      [1, 0, 0, 1, string.length, 0].pack('n6') +
      string
  end

  def post_table
    [0x00030000, 0].pack('N2') +
      [0, 0].pack('n2') +
      ([0] * 5).pack('N5')
  end

  def os2_table
    [
      1,
      500,
      400, 5,
      0,
      650, 600, 0, 75,
      650, 600, 0, 350,
      50, 250,
      0,
    ].pack('n16') +
      ("\0".b * 10) +
      [1, 0, 0, 0].pack('N4') +
      'TEST' +
      [0x40, 0x20, BASE_CHAR].pack('n3') +
      [800, -200, 0].pack('n3') +
      [800, 200].pack('n2') +
      [1, 0].pack('N2')
  end

  def uint24(value)
    [value].pack('N')[1, 3]
  end
end
