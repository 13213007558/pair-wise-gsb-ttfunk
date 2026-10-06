# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/subset'

RSpec.describe 'shaping-aware subsetting' do # rubocop: disable RSpec/DescribeClass
  # Builds a minimal GSUB table.
  #
  # @param script [String] script tag for the single script record.
  # @param features [Array<Array(String, Array<Integer>)>] feature tags
  #   with their lookup indices. All features are referenced from the
  #   script's default LangSys.
  # @param lookups [Array<String>] encoded lookups.
  # @return [String]
  def build_gsub(script:, features:, lookups:)
    feature_indices = features.each_index.to_a
    langsys = [0, 0xFFFF, feature_indices.length, *feature_indices].pack('nnnn*')
    script_data = [4, 0].pack('nn') + langsys
    script_list = [1].pack('n') + [script, 8].pack('a4n') + script_data

    blocks = features.map { |(_, indices)|
      [0, indices.length, *indices].pack('nnn*')
    }
    records = +''
    position = 2 + (features.length * 6)
    features.each_with_index do |(tag, _), i|
      records += [tag, position].pack('a4n')
      position += blocks[i].bytesize
    end
    feature_list = [features.length].pack('n') + records + blocks.join

    offsets = []
    position = 2 + (lookups.length * 2)
    lookups.each do |lookup|
      offsets << position
      position += lookup.bytesize
    end
    lookup_list = [lookups.length].pack('n') + offsets.pack('n*') + lookups.join

    header = [
      0x00010000,
      10,
      10 + script_list.bytesize,
      10 + script_list.bytesize + feature_list.bytesize,
    ].pack('Nnnn')
    header + script_list + feature_list + lookup_list
  end

  # Build a lookup wrapping the given subtables.
  #
  # @return [String]
  def build_lookup(type, *subtables)
    offsets = []
    position = 6 + (subtables.length * 2)
    subtables.each do |subtable|
      offsets << position
      position += subtable.bytesize
    end
    [type, 0, subtables.length, *offsets].pack('nnnn*') + subtables.join
  end

  # Build a single substitution subtable (format 2).
  #
  # @param pairs [Hash{Integer => Integer}] glyph substitutions.
  # @return [String]
  def single_subst_subtable(pairs)
    glyphs = pairs.keys.sort
    coverage = [1, glyphs.length, *glyphs].pack('nnn*')
    substitutes = glyphs.map { |glyph_id| pairs[glyph_id] }
    [2, 6 + (substitutes.length * 2), substitutes.length, *substitutes].pack('nnnn*') +
      coverage
  end

  # Build a single substitution lookup.
  #
  # @param pairs [Hash{Integer => Integer}] glyph substitutions.
  # @return [String]
  def build_single_subst_lookup(pairs)
    build_lookup(1, single_subst_subtable(pairs))
  end

  # Build a chaining contextual substitution subtable (format 1) with a
  # single rule: when the covered glyph is followed by the lookahead
  # glyphs, apply the nested lookup at the covered glyph.
  #
  # @return [String]
  def build_chaining_subtable(coverage_glyph, lookahead, nested_lookup_index)
    rule = [0, 1, lookahead.length, *lookahead, 1, 0, nested_lookup_index].pack('n*')
    rule_set = [1, 4].pack('nn') + rule
    coverage = [1, 1, coverage_glyph].pack('nnn')
    [1, 8 + rule_set.bytesize, 1, 8].pack('nnnn') + rule_set + coverage
  end

  # Build an extension substitution subtable wrapping another subtable.
  #
  # @return [String]
  def build_extension_subtable(inner_type, inner_subtable)
    [1, inner_type, 8].pack('nnN') + inner_subtable
  end

  # Build a lookup of an arbitrary type with no meaningful subtables.
  #
  # @return [String]
  def build_raw_lookup(type)
    [type, 0, 1, 8, 0].pack('nnnnn')
  end

  # Rebuild a font file with the given GSUB table replacing any existing
  # one.
  #
  # @return [TTFunk::File]
  def font_with_gsub(font_path, gsub)
    data = File.binread(font_path)
    scaler_type = data.unpack1('N')
    tables = []
    data.unpack1('n', offset: 4).times do |i|
      tag, _checksum, offset, length = data[12 + (i * 16), 16].unpack('a4NNN')
      tables << [tag, data[offset, length]] unless tag == 'GSUB'
    end
    tables << ['GSUB', gsub]
    tables.sort_by!(&:first)

    count = tables.length
    max_power = 2**Math.log2(count).floor
    header = [
      scaler_type,
      count,
      max_power * 16,
      Math.log2(max_power).to_i,
      (count * 16) - (max_power * 16),
    ].pack('Nnnnn')
    records = +''
    body = +''
    tables.each do |tag, bytes|
      aligned = bytes + ("\0" * ((4 - (bytes.bytesize % 4)) % 4))
      checksum = aligned.unpack('N*').sum & 0xFFFF_FFFF
      records += [tag, checksum, 12 + (count * 16) + body.bytesize, bytes.bytesize].pack('a4NNN')
      body += aligned
    end

    TTFunk::File.new(header + records + body)
  end

  # Apply the enabled lookups of a font to a glyph sequence, mimicking
  # shaping.
  #
  # @return [Array<Integer>]
  def shape(font, glyph_ids, script:, features:)
    font.gsub.lookups_for(script: script, features: features).each do |lookup|
      glyph_ids = apply_lookup(font.gsub, lookup, glyph_ids)
    end
    glyph_ids
  end

  def apply_lookup(gsub, lookup, glyph_ids)
    lookup.subtables.each do |subtable|
      glyph_ids = apply_subtable(gsub, subtable, glyph_ids)
    end
    glyph_ids
  end

  def apply_subtable(gsub, subtable, glyph_ids)
    case subtable[:type]
    when 1
      glyph_ids.map { |glyph_id| apply_single(subtable, glyph_id) }
    when 4
      apply_ligatures(subtable, glyph_ids)
    when 6
      apply_chaining(gsub, subtable, glyph_ids)
    when 7
      apply_subtable(gsub, subtable[:inner], glyph_ids)
    else
      glyph_ids
    end
  end

  def apply_chaining(gsub, subtable, glyph_ids)
    result = glyph_ids.dup
    index = 0
    while index < result.length
      set_index = subtable[:coverage].glyphs.index(result[index])
      rule = set_index && subtable[:rule_sets][set_index]&.find { |candidate|
        chain_rule_match?(candidate, result, index)
      }
      if rule
        rule[:records].each do |record|
          nested = gsub.lookups[record[:lookup_index]]
          position = index + record[:sequence_index]
          result[position, 1] = apply_lookup(gsub, nested, result[position, 1])
        end
      end
      index += 1
    end
    result
  end

  def chain_rule_match?(rule, glyph_ids, index)
    backtrack = rule[:backtrack]
    input = rule[:input]
    lookahead = rule[:lookahead]

    return false if index < backtrack.length
    return false unless glyph_ids[index - backtrack.length, backtrack.length] == backtrack
    return false unless glyph_ids[index + 1, input.length] == input

    glyph_ids[index + 1 + input.length, lookahead.length] == lookahead
  end

  def apply_single(subtable, glyph_id)
    index = subtable[:coverage].glyphs.index(glyph_id)
    return glyph_id unless index

    case subtable[:format]
    when 1 then (glyph_id + subtable[:delta]) & 0xFFFF
    when 2 then subtable[:substitutes][index]
    end
  end

  def apply_ligatures(subtable, glyph_ids)
    result = []
    index = 0
    while index < glyph_ids.length
      set_index = subtable[:coverage].glyphs.index(glyph_ids[index])
      ligature =
        set_index &&
        subtable[:ligature_sets][set_index].find { |candidate|
          candidate[:components] == glyph_ids[(index + 1), candidate[:components].length]
        }
      if ligature
        result << ligature[:ligature]
        index += 1 + ligature[:components].length
      else
        result << glyph_ids[index]
        index += 1
      end
    end
    result
  end

  let(:font_path) { test_font('DejaVuSans') }
  let(:cmap) { TTFunk::File.open(font_path).cmap.unicode.first }
  let(:glyphs) do
    {
      'A' => cmap['A'.ord],
      'B' => cmap['B'.ord],
      'C' => cmap['C'.ord],
      'D' => cmap['D'.ord],
      'X' => cmap['X'.ord],
      'Z' => cmap['Z'.ord],
    }
  end

  # Lookup 0 substitutes A with B, lookup 1 substitutes B with C, so the
  # output of one substitution is the input of the next. Lookup 2 is
  # referenced only by the 'dlig' feature which is never enabled, making
  # it (and the Z glyph it produces) completely unreachable.
  let(:gsub) do
    build_gsub(
      script: 'DFLT',
      features: [['liga', [0, 1]], ['dlig', [2]]],
      lookups: [
        build_single_subst_lookup(glyphs['A'] => glyphs['B']),
        build_single_subst_lookup(glyphs['B'] => glyphs['C']),
        build_single_subst_lookup(glyphs['X'] => glyphs['Z']),
      ],
    )
  end
  let(:font) { font_with_gsub(font_path, gsub) }
  let(:subset) do
    TTFunk::Subset.for(font, :shaping, script: 'DFLT', features: ['liga']).tap do |s|
      s.use('A'.ord)
      s.use('X'.ord)
    end
  end

  it 'keeps glyphs produced by chained substitutions' do
    expect(subset.original_glyph_ids).to include(glyphs['B'], glyphs['C'])
  end

  it 'does not retain glyphs only reachable through disabled features' do
    expect(subset.original_glyph_ids).to include(glyphs['X'])
    expect(subset.original_glyph_ids).to_not include(glyphs['Z'])
    expect(subset.old_to_new_glyph).to_not include(glyphs['Z'])
  end

  it 'produces a glyph sequence equivalent to the original font' do
    new_font = TTFunk::File.new(subset.encode)

    original_result = shape(font, [glyphs['A']], script: 'DFLT', features: ['liga'])
    expect(original_result).to eq([glyphs['C']])

    subset_result = shape(
      new_font,
      [subset.old_to_new_glyph[glyphs['A']]],
      script: 'DFLT',
      features: ['liga'],
    )
    expect(subset_result.map { |id| subset.new_to_old_glyph[id] }).to eq(original_result)
  end

  it 'keeps only the enabled features and reachable lookups in the subset GSUB' do
    new_gsub = TTFunk::File.new(subset.encode).gsub

    expect(new_gsub.features.map { |feature| feature[:tag] }).to eq(['liga'])
    expect(new_gsub.lookups.length).to eq(2)
    expect(new_gsub.scripts.keys).to eq(['DFLT'])
  end

  it 'remaps glyph IDs in the subset GSUB' do
    new_gsub = TTFunk::File.new(subset.encode).gsub
    coverage = new_gsub.lookups[0].subtables.first[:coverage].glyphs
    expect(coverage).to eq([subset.old_to_new_glyph[glyphs['A']]])
  end

  it 'raises on unknown lookup types instead of silently dropping them' do
    broken_gsub = build_gsub(
      script: 'DFLT',
      features: [['liga', [0]]],
      lookups: [build_raw_lookup(8)],
    )
    broken_font = font_with_gsub(font_path, broken_gsub)
    broken_subset = TTFunk::Subset.for(broken_font, :shaping, script: 'DFLT', features: ['liga'])
    broken_subset.use('A'.ord)

    expect { broken_subset.encode }.to raise_error(TTFunk::Error, /unsupported GSUB lookup type 8/)
  end

  it 'ignores unknown lookup types in disabled features' do
    partial_gsub = build_gsub(
      script: 'DFLT',
      features: [['liga', [0]], ['dlig', [1]]],
      lookups: [
        build_single_subst_lookup(glyphs['A'] => glyphs['B']),
        build_raw_lookup(8),
      ],
    )
    partial_font = font_with_gsub(font_path, partial_gsub)
    partial_subset = TTFunk::Subset.for(partial_font, :shaping, script: 'DFLT', features: ['liga'])
    partial_subset.use('A'.ord)

    expect { partial_subset.encode }.to_not raise_error
  end

  it 'omits the GSUB table when no features are enabled' do
    plain_subset = TTFunk::Subset.for(font, :shaping, script: 'DFLT', features: [])
    plain_subset.use('A'.ord)
    expect(TTFunk::File.new(plain_subset.encode).gsub.exists?).to be(false)
  end

  it 'omits the GSUB table when the requested features are not in the font' do
    plain_subset = TTFunk::Subset.for(font, :shaping, script: 'DFLT', features: ['xxxx'])
    plain_subset.use('A'.ord)
    expect(TTFunk::File.new(plain_subset.encode).gsub.exists?).to be(false)
  end

  describe 'with contextual and extension lookups' do
    # Lookup 0 is a chaining contextual lookup: when A is followed by B it
    # applies lookup 2 (nested, not referenced by any feature) at the first
    # position. Lookup 3 is an extension lookup substituting B with D.
    # Lookup 1 is only referenced by the disabled 'dlig' feature, making it
    # and the Z glyph it produces unreachable.
    let(:gsub) do
      build_gsub(
        script: 'DFLT',
        features: [['liga', [0, 3]], ['dlig', [1]]],
        lookups: [
          build_lookup(6, build_chaining_subtable(glyphs['A'], [glyphs['B']], 2)),
          build_single_subst_lookup(glyphs['X'] => glyphs['Z']),
          build_single_subst_lookup(glyphs['A'] => glyphs['C']),
          build_lookup(
            7,
            build_extension_subtable(1, single_subst_subtable(glyphs['B'] => glyphs['D'])),
          ),
        ],
      )
    end

    let(:subset) do
      TTFunk::Subset.for(font, :shaping, script: 'DFLT', features: ['liga']).tap do |s|
        s.use('A'.ord)
        s.use('B'.ord)
        s.use('X'.ord)
      end
    end

    it 'keeps glyphs produced through nested and extension lookups' do
      expect(subset.original_glyph_ids).to include(glyphs['C'], glyphs['D'])
      expect(subset.original_glyph_ids).to_not include(glyphs['Z'])
    end

    it 'keeps nested lookups and remaps their indices' do
      new_gsub = TTFunk::File.new(subset.encode).gsub

      expect(new_gsub.lookups.map(&:type)).to eq([6, 1, 7])
      records = new_gsub.lookups[0].subtables.first[:rule_sets].first.first[:records]
      expect(records).to eq([{ sequence_index: 0, lookup_index: 1 }])
    end

    it 'produces a glyph sequence equivalent to the original font' do
      new_font = TTFunk::File.new(subset.encode)
      input = [glyphs['A'], glyphs['B']]

      original_result = shape(font, input, script: 'DFLT', features: ['liga'])
      expect(original_result).to eq([glyphs['C'], glyphs['D']])

      new_input = input.map { |id| subset.old_to_new_glyph[id] }
      subset_result = shape(new_font, new_input, script: 'DFLT', features: ['liga'])
      expect(subset_result.map { |id| subset.new_to_old_glyph[id] }).to eq(original_result)
    end
  end

  describe 'with a real font' do
    let(:real_font) { TTFunk::File.open(font_path) }
    let(:real_subset) do
      TTFunk::Subset.for(real_font, :shaping, script: 'latn', features: ['liga']).tap do |s|
        s.use('f'.ord)
        s.use('i'.ord)
      end
    end

    it 'keeps ligature glyphs in the subset' do
      plain = TTFunk::Subset.for(real_font, :unicode)
      plain.use('f'.ord)
      plain.use('i'.ord)

      expect(real_subset.original_glyph_ids.length).to be > plain.original_glyph_ids.length
    end

    it 'produces a ligature glyph sequence equivalent to the original font' do
      input = [cmap['f'.ord], cmap['i'.ord]]
      original_result = shape(real_font, input, script: 'latn', features: ['liga'])
      expect(original_result.length).to eq(1)

      new_font = TTFunk::File.new(real_subset.encode)
      new_input = input.map { |id| real_subset.old_to_new_glyph[id] }
      subset_result = shape(new_font, new_input, script: 'latn', features: ['liga'])

      expect(subset_result.map { |id| real_subset.new_to_old_glyph[id] }).to eq(original_result)
    end
  end
end
