# frozen_string_literal: true

# Builds a tiny synthetic TrueType font with a Unicode Variation Sequences
# (cmap format 14) subtable for testing.
#
# Glyph layout of the font built with the default options:
# * 0 - .notdef (blank)
# * 1 - space (blank)
# * 2 - simple glyph, base of character 0x41
# * 3 - simple glyph, base of character 0x42
# * 4 - compound glyph referencing glyph 6, dedicated variant of 0x42
# * 5 - simple glyph, unused by any cmap entry
# * 6 - simple glyph, component of glyph 4
#
# cmap format 14 records of the default font:
# * selector 0xE0100 - default UVS for 0x41, non-default UVS 0x42 => glyph 4
# * selector 0xE0101 - non-default UVS 0x41 => glyph 3
module UVSFontBuilder
  # Base character of the default variation sequence.
  DEFAULT_BASE_CODE = 0x41
  # Base character of the dedicated (non-default) variation sequence.
  DEDICATED_BASE_CODE = 0x42
  # Variation selector of the default and dedicated variation sequences.
  SELECTOR = 0xE0100
  # Variation selector not requested by the subsets in tests.
  OTHER_SELECTOR = 0xE0101

  # Glyph ID of the dedicated variant glyph.
  DEDICATED_GLYPH_ID = 4
  # Glyph ID of the compound component glyph.
  COMPONENT_GLYPH_ID = 6

  # Default UVS records.
  DEFAULT_UVS_RECORDS = [
    {
      selector: SELECTOR,
      default: [[DEFAULT_BASE_CODE, 0]],
      non_default: { DEDICATED_BASE_CODE => DEDICATED_GLYPH_ID },
    }.freeze,
    {
      selector: OTHER_SELECTOR,
      non_default: { DEFAULT_BASE_CODE => 3 },
    }.freeze,
  ].freeze

  class << self
    # Build a synthetic TrueType font.
    #
    # @param uvs_records [Array<Hash>] cmap format 14 variation selector
    #   records. Each record has a +:selector+ and can have:
    #   * +:default+ - array of (range start, additional count) pairs.
    #   * +:non_default+ - hash of character code to glyph ID.
    #   * +:default_offset+, +:non_default_offset+ - explicit offsets, used
    #     verbatim instead of computing them (for corrupt font testing).
    # @return [String] font binary.
    def build(uvs_records: DEFAULT_UVS_RECORDS)
      tables = {
        'OS/2' => os2_table,
        'cmap' => cmap_table(uvs_records),
        'glyf' => glyf_table,
        'head' => head_table,
        'hhea' => hhea_table,
        'hmtx' => hmtx_table,
        'loca' => loca_table,
        'maxp' => maxp_table,
        'name' => name_table,
        'post' => post_table,
      }

      font = [0x00010000, tables.length, 0, 0, 0].pack('Nn4')
      offset = 12 + (tables.length * 16)
      records = +''
      data = +''

      tables.sort.each do |tag, bytes|
        records << [tag, checksum(bytes), offset, bytes.length].pack('a4N3')
        data << bytes
        padding = (4 - (bytes.length % 4)) % 4
        data << ("\0" * padding)
        offset += bytes.length + padding
      end

      font << records << data
    end

    private

    def checksum(bytes)
      padding = (4 - (bytes.length % 4)) % 4
      (bytes + ("\0" * padding)).unpack('N*').sum & 0xFFFF_FFFF
    end

    def uint24(value)
      [value].pack('N')[1, 3]
    end

    def head_table
      [0x00010000, 0x00010000, 0, 0x5F0F3CF5].pack('N4') <<
        [0, 1000].pack('n2') <<
        [0, 0].pack('q>2') <<
        [0, 0, 250, 500].pack('n4') <<
        [0, 8, 2, 1, 0].pack('n5')
    end

    def hhea_table
      [0x00010000].pack('N') <<
        [
          800, -200, 0, # ascent, descent, lineGap
          600, # advanceWidthMax
          0, 0, 250, # minLSB, minRSB, xMaxExtent
          1, 0, 0, # caretSlopeRise, caretSlopeRun, caretOffset
          0, 0, 0, 0, # reserved
          0, # metricDataFormat
          7, # numberOfHMetrics
        ].pack('n*')
    end

    def maxp_table
      [0x00010000, 7].pack('Nn') <<
        [4, 1, 4, 1, 2, 0, 0, 0, 0, 0, 0, 1, 1].pack('n*')
    end

    def hmtx_table
      [600, 0].pack('n2') * 7
    end

    def simple_glyph
      [1, 0, 0, 250, 250].pack('n5') <<
        [3].pack('n') <<
        [0].pack('n') <<
        [0x31, 0x21, 0x11, 0x21].pack('C4') <<
        [250, -250].pack('n2') <<
        [250].pack('n')
    end

    def compound_glyph
      [0xFFFF, 0, 0, 250, 500].pack('n5') <<
        [0x0003, COMPONENT_GLYPH_ID, 0, 250].pack('n4')
    end

    def glyf_table
      simple = simple_glyph
      (simple * 2) << compound_glyph << (simple * 2)
    end

    def loca_table
      simple = simple_glyph
      offsets = [0, 0, 0]
      offsets << offsets.last + simple.length
      offsets << offsets.last + simple.length
      offsets << offsets.last + compound_glyph.length
      offsets << offsets.last + simple.length
      offsets << offsets.last + simple.length
      offsets.pack('N*')
    end

    def cmap_table(uvs_records)
      format04 =
        TTFunk::Table::Cmap::Format04.encode(
          0x20 => 1, DEFAULT_BASE_CODE => 2, DEDICATED_BASE_CODE => 3,
        )[:subtable]
      format14 = format14_subtable(uvs_records)

      offset = 4 + (2 * 8)
      [0, 2].pack('n2') <<
        [3, 1, offset].pack('nnN') <<
        [0, 5, offset + format04.length].pack('nnN') <<
        format04 <<
        format14
    end

    def format14_subtable(records)
      offset = 10 + (records.length * 11)
      selector_records = +''
      tables = +''

      records.each do |record|
        default_offset = 0
        if record.key?(:default_offset)
          default_offset = record[:default_offset]
        elsif record[:default] && !record[:default].empty?
          default_offset = offset
          table = [record[:default].length].pack('N')
          record[:default].each do |start, count|
            table << uint24(start) << [count].pack('C')
          end
          tables << table
          offset += table.length
        end

        non_default_offset = 0
        if record.key?(:non_default_offset)
          non_default_offset = record[:non_default_offset]
        elsif record[:non_default] && !record[:non_default].empty?
          non_default_offset = offset
          mappings = record[:non_default]
          table = [mappings.length].pack('N')
          mappings.each do |code, glyph_id|
            table << uint24(code) << [glyph_id].pack('n')
          end
          tables << table
          offset += table.length
        end

        selector_records <<
          uint24(record[:selector]) <<
          [default_offset, non_default_offset].pack('N2')
      end

      [14, offset, records.length].pack('nN2') << selector_records << tables
    end

    def name_table
      strings = [[1, 'UVS Test'], [6, 'UVSTest-Regular']]
      storage = strings.map(&:last).join

      table = [0, strings.length, 6 + (strings.length * 12)].pack('n3')
      offset = 0
      strings.each do |id, string|
        table << [1, 0, 0, id, string.length, offset].pack('n6')
        offset += string.length
      end
      table << storage
    end

    def post_table
      [0x00030000, 0].pack('N2') <<
        [0, 0].pack('n2') <<
        [0, 0, 0, 0, 0].pack('N5')
    end

    def os2_table
      [
        0, # version
        500, # xAvgCharWidth
        400, 5, # usWeightClass, usWidthClass
        0, # fsType
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, # sub/superscript, strikeout metrics
        0, # sFamilyClass
      ].pack('n*') <<
        ("\0" * 10) << # panose
        [1, 0, 0, 0].pack('N4') << # ulUnicodeRange: Basic Latin
        'TEST' << # achVendID
        [0, 0x20, 0x42].pack('n3') # fsSelection, usFirst/LastCharIndex
    end
  end
end
