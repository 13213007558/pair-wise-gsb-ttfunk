# frozen_string_literal: true

require 'spec_helper'

describe 'merging' do # rubocop: disable RSpec/DescribeClass
  let(:primary) { TTFunk::File.open(test_font('DejaVuSans')) }
  let(:fallback) { TTFunk::File.open(test_font('Mplus1p')) }
  let(:primary_cmap) { primary.cmap.unicode.first }
  let(:fallback_cmap) { fallback.cmap.unicode.first }

  # Characters the fallback font has and the primary font doesn't.
  def uncovered_characters(count)
    fallback_cmap.code_map
      .select { |_, glyph_id| glyph_id.positive? }
      .keys
      .reject { |code| primary_cmap[code].positive? }
      .first(count)
  end

  def merge(&block)
    merger = TTFunk::Merger.new(primary)
    block&.call(merger)
    merger.merge
  end

  def font_checksum(data)
    padded = data + ("\0" * ((4 - (data.length % 4)) % 4))
    padded.unpack('N*').sum & 0xFFFF_FFFF
  end

  it 'produces a valid TrueType font' do
    result = merge { |m| uncovered_characters(3).each { |c| m.add(c, fallback) } }

    expect(font_checksum(result.font)).to eq(0xB1B0AFBA)

    merged = TTFunk::File.new(result.font)
    expect(merged.directory.scaler_type).to eq(primary.directory.scaler_type)
    expect(merged.maximum_profile.num_glyphs).to eq(
      merged.glyph_locations.offsets.length - 1,
    )
  end

  it 'keeps the whole character set of the primary font' do
    result = merge { |m| m.add(uncovered_characters(1).first, fallback) }
    merged = TTFunk::File.new(result.font)
    merged_cmap = merged.cmap.unicode.first

    primary_cmap.code_map.each do |code, glyph_id|
      next unless glyph_id.positive?

      expect(merged_cmap[code]).to be_positive
    end
  end

  it 'adds explicitly chosen characters from fallback fonts' do
    codes = uncovered_characters(3)
    result = merge { |m| codes.each { |c| m.add(c, fallback) } }
    merged = TTFunk::File.new(result.font)
    merged_cmap = merged.cmap.unicode.first

    codes.each do |code|
      expect(merged_cmap[code]).to be_positive
    end

    codes.each do |code|
      expect(result.charmap[code]).to eq(merged_cmap[code])
    end
  end

  it 'unifies units-per-em and scales fallback outlines' do
    code = uncovered_characters(5).last
    result = merge { |m| m.add(code, fallback) }
    merged = TTFunk::File.new(result.font)

    expect(merged.header.units_per_em).to eq(primary.header.units_per_em)

    ratio = Rational(
      primary.header.units_per_em,
      fallback.header.units_per_em,
    )
    source_glyph = fallback.glyph_outlines.for(fallback_cmap[code])
    merged_glyph = merged.glyph_outlines.for(merged.cmap.unicode.first[code])

    expect(merged_glyph.x_min).to eq((source_glyph.x_min * ratio).round)
    expect(merged_glyph.y_min).to eq((source_glyph.y_min * ratio).round)
    expect(merged_glyph.x_max).to eq((source_glyph.x_max * ratio).round)
    expect(merged_glyph.y_max).to eq((source_glyph.y_max * ratio).round)
  end

  it 'scales fallback horizontal metrics' do
    code = uncovered_characters(5).last
    result = merge { |m| m.add(code, fallback) }
    merged = TTFunk::File.new(result.font)

    ratio = Rational(
      primary.header.units_per_em,
      fallback.header.units_per_em,
    )
    source_metric = fallback.horizontal_metrics.for(fallback_cmap[code])
    merged_metric =
      merged.horizontal_metrics.for(merged.cmap.unicode.first[code])

    expect(merged_metric.advance_width).to eq(
      (source_metric.advance_width * ratio).round,
    )
    expect(merged_metric.left_side_bearing).to eq(
      (source_metric.left_side_bearing * ratio).round,
    )
  end

  it 'scales simple glyph coordinates' do
    code = fallback_cmap.code_map.find { |char, glyph_id|
      glyph_id.positive? &&
        primary_cmap[char].zero? &&
        (glyph = fallback.glyph_outlines.for(glyph_id)) &&
        !glyph.compound? &&
        glyph.number_of_contours > 1
    }.first

    result = merge { |m| m.add(code, fallback) }
    merged = TTFunk::File.new(result.font)

    source_glyph = fallback.glyph_outlines.for(fallback_cmap[code])
    merged_glyph = merged.glyph_outlines.for(merged.cmap.unicode.first[code])

    source_points = simple_glyph_points(source_glyph.raw)
    merged_points = simple_glyph_points(merged_glyph.raw)
    ratio = Rational(
      primary.header.units_per_em,
      fallback.header.units_per_em,
    )

    expect(merged_points[:x]).to eq(
      source_points[:x].map { |x| (x * ratio).round },
    )
    expect(merged_points[:y]).to eq(
      source_points[:y].map { |y| (y * ratio).round },
    )
    expect(merged_points[:on_curve]).to eq(source_points[:on_curve])
  end

  it 'migrates composite components and remaps their references' do
    # Mplus1p has no composite glyphs, so merge in the other direction:
    # supplement an Mplus1p primary with a DejaVuSans composite.
    mplus = TTFunk::File.open(test_font('Mplus1p'))
    dejavu = TTFunk::File.open(test_font('DejaVuSans'))
    mplus_cmap = mplus.cmap.unicode.first
    dejavu_cmap = dejavu.cmap.unicode.first

    code = dejavu_cmap.code_map.find { |char, glyph_id|
      glyph_id.positive? &&
        mplus_cmap[char].zero? &&
        dejavu.glyph_outlines.for(glyph_id)&.compound?
    }.first

    merger = TTFunk::Merger.new(mplus)
    merger.add(code, dejavu)
    merged = TTFunk::File.new(merger.merge.font)

    source_glyph = dejavu.glyph_outlines.for(dejavu_cmap[code])
    merged_glyph = merged.glyph_outlines.for(merged.cmap.unicode.first[code])

    expect(merged_glyph).to be_compound
    expect(merged_glyph.glyph_ids.length).to eq(source_glyph.glyph_ids.length)

    num_glyphs = merged.maximum_profile.num_glyphs
    merged_glyph.glyph_ids.each do |glyph_id|
      expect(glyph_id).to be < num_glyphs
      expect(merged.glyph_outlines.for(glyph_id)).to_not be_nil
    end

    # component offsets are scaled to the merged units-per-em
    ratio = Rational(
      mplus.header.units_per_em,
      dejavu.header.units_per_em,
    )
    expect(merged_glyph.x_max).to eq((source_glyph.x_max * ratio).round)
    expect(merged_glyph.y_max).to eq((source_glyph.y_max * ratio).round)
  end

  it 'combines global metrics as an enclosing envelope' do
    result = merge { |m| m.add(uncovered_characters(1).first, fallback) }
    merged = TTFunk::File.new(result.font)

    ratio = Rational(
      primary.header.units_per_em,
      fallback.header.units_per_em,
    )

    expected_ascent = [
      primary.horizontal_header.ascent,
      (fallback.horizontal_header.ascent * ratio).round,
    ].max
    expected_descent = [
      primary.horizontal_header.descent,
      (fallback.horizontal_header.descent * ratio).round,
    ].min

    expect(merged.horizontal_header.ascent).to eq(expected_ascent)
    expect(merged.horizontal_header.descent).to eq(expected_descent)

    expected_typo_ascent = [
      primary.os2.ascent,
      (fallback.os2.ascent * ratio).round,
    ].max
    expect(merged.os2.ascent).to eq(expected_typo_ascent)
  end

  it 'drops unmigratable tables and lists them as limitations' do
    result = merge { |m| m.add(uncovered_characters(1).first, fallback) }
    merged = TTFunk::File.new(result.font)

    expect(merged.directory.tables).to_not include('GSUB', 'GPOS', 'kern')

    limitations = result.limitations.join("\n")
    expect(limitations).to include("layout table 'GSUB'")
    expect(limitations).to include("layout table 'GPOS'")
    expect(limitations).to include("layout table 'kern'")
  end

  it 'raises on Unicode conflict with the primary font instead of guessing' do
    covered = primary_cmap.code_map.find { |_, glyph_id| glyph_id.positive? }.first

    merger = TTFunk::Merger.new(primary)
    expect { merger.add(covered, fallback) }.to raise_error(
      TTFunk::Merger::ConflictError,
      /already covered by the primary font/,
    )
  end

  it 'raises when a character is assigned twice instead of guessing' do
    code = uncovered_characters(1).first

    merger = TTFunk::Merger.new(primary)
    merger.add(code, fallback)
    expect { merger.add(code, fallback) }.to raise_error(
      TTFunk::Merger::ConflictError,
      /already assigned/,
    )
  end

  it 'raises when the chosen font does not contain the character' do
    merger = TTFunk::Merger.new(primary)
    expect { merger.add(0x10FFFE, fallback) }.to raise_error(
      TTFunk::Merger::MissingGlyphError,
    )
  end

  it 'rejects CFF-based primary fonts' do
    cff_font = TTFunk::File.open(test_font('Exo-Regular', :otf))

    expect { TTFunk::Merger.new(cff_font) }.to raise_error(
      TTFunk::Merger::UnsupportedFontError,
      /CFF/,
    )
  end

  it 'rejects CFF-based fallback fonts' do
    cff_font = TTFunk::File.open(test_font('Exo-Regular', :otf))

    merger = TTFunk::Merger.new(primary)
    expect { merger.add(0x3042, cff_font) }.to raise_error(
      TTFunk::Merger::UnsupportedFontError,
      /CFF/,
    )
  end

  it 'merges a primary font with no additions' do
    result = merge
    merged = TTFunk::File.new(result.font)

    expect(font_checksum(result.font)).to eq(0xB1B0AFBA)
    expect(merged.cmap.unicode.first[0x41]).to be_positive
  end

  # Decodes absolute coordinates and on-curve flags of a simple glyph.
  def simple_glyph_points(raw)
    io = StringIO.new(raw)
    number_of_contours = io.read(10).unpack1('s>')
    end_points = io.read(number_of_contours * 2).unpack('n*')
    instruction_length = io.read(2).unpack1('n')
    io.read(instruction_length)

    point_count = end_points.empty? ? 0 : end_points.last + 1
    flags = []
    while flags.length < point_count
      flag = io.readbyte
      flags << flag
      flags += [flag] * io.readbyte if flag.allbits?(0x08)
    end

    {
      x: read_glyph_coordinates(io, flags, short_bit: 0x02, same_bit: 0x10),
      y: read_glyph_coordinates(io, flags, short_bit: 0x04, same_bit: 0x20),
      on_curve: flags.map { |flag| flag.allbits?(0x01) },
    }
  end

  def read_glyph_coordinates(io, flags, short_bit:, same_bit:)
    current = 0
    flags.map do |flag|
      if flag.allbits?(short_bit)
        delta = io.readbyte
        current += flag.allbits?(same_bit) ? delta : -delta
      elsif flag.nobits?(same_bit)
        current += io.read(2).unpack1('s>')
      end
      current
    end
  end
end
