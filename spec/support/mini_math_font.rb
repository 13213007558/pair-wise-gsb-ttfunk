# frozen_string_literal: true

module MiniMathFont
  module_function

  def build
    vertical_glyphs = [10, 30, 40]
    horizontal_glyphs = [20]
    italics_glyphs = [11]

    vertical_coverage = coverage(vertical_glyphs)
    horizontal_coverage = coverage(horizontal_glyphs)
    italics_coverage = coverage(italics_glyphs)

    brace_variants = [
      variant(11, 120),
    ]
    brace_assembly = assembly(
      7,
      [
        part(1, 40, 10, 40, false),
        part(2, 10, 10, 30, true),
        part(3, 10, 15, 40, true),
        part(4, 15, 40, 40, false),
      ],
    )
    brace_construction = construction(brace_assembly, brace_variants.join)

    no_assembly_construction = construction(nil, variant(31, 90))

    fixed_assembly = assembly(
      0,
      [
        part(8, 20, 10, 30, false),
        part(9, 10, 20, 30, false),
      ],
    )
    fixed_construction = construction(fixed_assembly, '')

    arrow_variants = [variant(21, 45)]
    arrow_assembly = assembly(
      0,
      [
        part(5, 30, 10, 30, false),
        part(6, 10, 20, 20, true),
        part(7, 20, 30, 30, false),
      ],
    )
    arrow_construction = construction(arrow_assembly, arrow_variants.join)

    italics_table = italics(italics_coverage, [5])
    glyph_info = [8, 0, 0, 0].pack('n*') + italics_table
    variants = math_variants(
      vertical_coverage,
      horizontal_coverage,
      [
        brace_construction,
        no_assembly_construction,
        fixed_construction,
      ],
      [arrow_construction],
    )

    math_table = pack_math(variants, glyph_info)
    font_table(math_table)
  end

  def coverage(glyphs)
    [1, glyphs.length].pack('n*') + glyphs.pack('n*')
  end

  def variant(glyph_id, advance)
    [glyph_id, advance].pack('n*')
  end

  def part(glyph_id, start_connector, end_connector, advance, extender)
    [
      glyph_id,
      start_connector,
      end_connector,
      advance,
      extender ? 1 : 0,
    ].pack('n*')
  end

  def assembly(italic_correction, parts)
    [italic_correction, 0, parts.length].pack('s>nn') + parts.join
  end

  def construction(assembly_data, variants_data)
    assembly_offset = assembly_data.nil? ? 0 : 4 + variants_data.bytesize
    [assembly_offset, variants_data.length / 4].pack('n*') +
      variants_data + (assembly_data || '')
  end

  def italics(coverage_data, values)
    records = values.map { |value| [value, 0].pack('s>n') }.join
    [records.bytesize + 4, values.length].pack('n*') +
      records + coverage_data
  end

  def math_variants(
    vertical_coverage, horizontal_coverage,
    vertical_constructions, horizontal_constructions
  )
    header_size = 10 +
      (vertical_constructions.length + horizontal_constructions.length) * 2
    vertical_offset = header_size
    horizontal_offset = vertical_offset + vertical_coverage.bytesize
    construction_offset =
      horizontal_offset + horizontal_coverage.bytesize

    offsets = []
    blobs = []
    (vertical_constructions + horizontal_constructions).each do |blob|
      offsets << construction_offset
      blobs << blob
      construction_offset += blob.bytesize
    end

    [
      10,
      vertical_offset,
      horizontal_offset,
      vertical_constructions.length,
      horizontal_constructions.length,
    ].pack('n*') +
      offsets.pack('n*') +
      vertical_coverage +
      horizontal_coverage +
      blobs.join
  end

  def pack_math(variants_data, italics_data)
    variants_offset = 10
    glyph_info_offset = variants_offset + variants_data.bytesize
    [
      0x00010000,
      0,
      glyph_info_offset,
      variants_offset,
    ].pack('Nn3') + variants_data + italics_data
  end

  def font_table(math_table)
    table_count = 1
    search_range = 16
    entry_selector = 0
    range_shift = 0
    header = [
      0x00010000,
      table_count,
      search_range,
      entry_selector,
      range_shift,
    ].pack('Nn*')
    table_offset = header.bytesize + 16
    directory = ['MATH', 0, table_offset, math_table.bytesize].pack('a4N*')
    header + directory + math_table
  end
end
