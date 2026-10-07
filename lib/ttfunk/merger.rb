# frozen_string_literal: true

require_relative 'table/simple'

module TTFunk
  # Merges glyphs from fallback fonts into a primary TrueType font.
  #
  # A Merger takes a primary font and supplements it with glyphs for
  # characters the primary font doesn't cover, taken from fallback fonts.
  # The caller explicitly chooses which font each supplemented character
  # comes from; Unicode conflicts are never resolved by guessing, they raise
  # an error instead.
  #
  # The merged font:
  # * uses the primary font's units-per-em; outlines and metrics taken from
  #   fallback fonts are scaled to it;
  # * re-assigns all glyph IDs and character mappings;
  # * migrates composite glyph components (recursively) along with the glyphs
  #   that reference them;
  # * combines global metrics (ascent/descent/line gap) from all contributing
  #   fonts by taking the enclosing envelope: the highest ascent, the lowest
  #   descent, and the largest line gap, each scaled to the primary font's
  #   units-per-em;
  # * contains only glyf-based TrueType outlines.
  #
  # Tables that can't be migrated (layout tables such as GSUB/GPOS/kern,
  # variation tables such as fvar/gvar, etc.) are dropped. Dropped tables are
  # reported in the result's limitation list instead of emitting a font whose
  # internal references would be broken.
  #
  # @example
  #   merger = TTFunk::Merger.new(TTFunk::File.open('primary.ttf'))
  #   merger.add(0x4E2D, TTFunk::File.open('fallback.ttf'))
  #   result = merger.merge
  #   result.font        # => binary TrueType font, ready for embedding
  #   result.limitations # => ["layout table 'GSUB' ...", ...]
  class Merger
    # Generic merger error.
    class Error < TTFunk::Error; end

    # Raised when a font can't be used in a merge.
    class UnsupportedFontError < Error; end

    # Raised on character coverage conflicts.
    class ConflictError < Error; end

    # Raised when a requested character is not in the chosen source font.
    class MissingGlyphError < Error; end

    # Tables (re)generated for the merged font.
    GENERATED_TABLES = %w[
      head hhea maxp OS/2 hmtx cmap loca glyf name post
    ].freeze

    # Tables copied verbatim from the primary font.
    COPIED_TABLES = ['fpgm', 'prep', 'cvt ', 'gasp'].freeze

    # Layout tables. They encode shaping behavior referring to glyph IDs and
    # can't be merged.
    LAYOUT_TABLES = %w[GSUB GPOS GDEF kern mort morx lcar JSTF BASE].freeze

    # Variation tables. Merging variable fonts is not supported.
    VARIATION_TABLES = %w[fvar gvar avar MVAR HVAR VVAR STAT CFF2].freeze

    # Font-wide hinting program tables.
    HINTING_TABLES = ['fpgm', 'prep', 'cvt '].freeze

    # Maximum Unicode codepoint.
    UNICODE_MAX = 0x10FFFF

    # Maximum codepoint representable in a BMP (format 4) cmap.
    BMP_MAX = 0xFFFF

    # Checksum adjustment magic number.
    CHECKSUM_MAGIC = 0xB1B0AFBA

    # Merge result.
    class Result
      # Merged font in its binary representation, ready for embedding.
      # @return [String]
      attr_reader :font

      # List of limitations of the merged font: tables and features that
      # could not be migrated from the source fonts.
      # @return [Array<String>]
      attr_reader :limitations

      # Character map of the merged font: Unicode codepoint to glyph ID.
      # @return [Hash{Integer => Integer}]
      attr_reader :charmap

      # @param font [String]
      # @param limitations [Array<String>]
      # @param charmap [Hash{Integer => Integer}]
      def initialize(font:, limitations:, charmap:)
        @font = font
        @limitations = limitations
        @charmap = charmap
      end
    end

    # Primary font.
    # @return [TTFunk::File]
    attr_reader :primary

    # @param primary [TTFunk::File] primary font. Its full character set is
    #   preserved in the merged font.
    # @raise [UnsupportedFontError] if the font can't be used in a merge
    def initialize(primary)
      @primary = primary
      validate_font!(primary, 'primary font')

      @sources = [primary]
      @source_indices = { primary.object_id => 0 }
      @additions = {}
    end

    # Add a character from a fallback font to the merged font.
    #
    # @param codepoint [Integer] Unicode codepoint
    # @param font [TTFunk::File] font to take the glyph from
    # @return [self]
    # @raise [ConflictError] if the character is already covered by the
    #   primary font or was already added
    # @raise [MissingGlyphError] if the font doesn't contain the character
    # @raise [UnsupportedFontError] if the font can't be used in a merge
    def add(codepoint, font)
      unless codepoint.is_a?(Integer) && codepoint.between?(0, UNICODE_MAX)
        raise ArgumentError, "invalid Unicode codepoint: #{codepoint.inspect}"
      end

      validate_font!(font, font_label(font))

      if primary_cmap[codepoint].positive?
        raise ConflictError,
          format(
            'character U+%<code>04X is already covered by the primary font; ' +              'not guessing which source to use',
            code: codepoint,
          )
      end

      if @additions.key?(codepoint)
        raise ConflictError,
          format(
            'character U+%<code>04X was already assigned to a source font; ' +              'not guessing which source to use',
            code: codepoint,
          )
      end

      if unicode_cmap_for(font)[codepoint].zero?
        raise MissingGlyphError,
          format(
            'font %<label>s does not contain a glyph for U+%<code>04X',
            label: font_label(font),
            code: codepoint,
          )
      end

      @additions[codepoint] = source_index_for(font)
      self
    end

    # Merge the fonts.
    #
    # @return [TTFunk::Merger::Result]
    def merge
      old_charmap = merged_old_charmap
      if old_charmap.empty?
        raise Error, 'nothing to merge: the primary font maps no characters'
      end

      encoding = old_charmap.keys.max > BMP_MAX ? :unicode_ucs4 : :unicode
      cmap_result = TTFunk::Table::Cmap.encode(old_charmap, encoding)

      old_to_new = assign_glyph_ids(cmap_result)
      new_to_old = old_to_new.invert
      num_glyphs = old_to_new.length
      source_mappings = source_glyph_mappings(old_to_new)

      glyf_result = encode_glyf(new_to_old, num_glyphs, source_mappings)
      loca_result = TTFunk::Table::Loca.encode(glyf_result[:offsets])
      metrics = merged_metrics(new_to_old, num_glyphs)

      tables = {
        'cmap' => cmap_result[:table],
        'glyf' => glyf_result[:table],
        'loca' => loca_result[:table],
        'hmtx' => encode_hmtx(metrics),
        'hhea' => encode_hhea(new_to_old, metrics, num_glyphs),
        'maxp' => encode_maxp(new_to_old, num_glyphs),
        'head' => encode_head(new_to_old, loca_result),
        'OS/2' => encode_os2(old_charmap.keys, metrics, num_glyphs),
        'post' => encode_post,
        'name' => encode_name(glyf_result[:table]),
      }
      copy_primary_tables(tables)

      Result.new(
        font: assemble(tables.compact),
        limitations: collect_limitations,
        charmap: cmap_result[:charmap].transform_values { |ids| ids[:new] },
      )
    end

    private

    def validate_font!(font, label)
      if font.cff.exists?
        raise UnsupportedFontError,
          "#{label} has CFF outlines; " +            'only glyf-based TrueType fonts are supported'
      end

      unless font.directory.tables.key?('glyf')
        raise UnsupportedFontError,
          "#{label} has no 'glyf' table; " +            'only glyf-based TrueType fonts are supported'
      end

      if font.cmap.unicode.empty?
        raise UnsupportedFontError, "#{label} has no Unicode cmap"
      end
    end

    def font_label(font, index = @sources.index(font))
      name = font.name.exists? ? font.name.postscript_name.to_s : 'unnamed'
      role =
        if index.nil?
          'font'
        elsif index.zero?
          'primary font'
        else
          "fallback font #{index}"
        end
      "#{role} '#{name}'"
    end

    def source_index_for(font)
      @source_indices.fetch(font.object_id) do
        index = @sources.length
        @sources << font
        @source_indices[font.object_id] = index
      end
    end

    def unicode_cmap_for(font)
      font.cmap.unicode.first
    end

    def primary_cmap
      @primary_cmap ||= unicode_cmap_for(primary)
    end

    # Character map of the merged font. Keys are Unicode codepoints, values
    # are glyph references: [source index, glyph ID in that source].
    #
    # @return [Hash{Integer => Array(Integer, Integer)}]
    def merged_old_charmap
      charmap = {}

      primary_cmap.code_map.each do |code, glyph_id|
        charmap[code] = [0, glyph_id] if glyph_id.positive?
      end

      @additions.each do |code, src|
        charmap[code] = [src, unicode_cmap_for(@sources[src])[code]]
      end

      charmap
    end

    # Assigns glyph IDs in the merged font to all referenced glyphs,
    # including composite glyph components.
    #
    # @param cmap_result [Hash] result of encoding the merged cmap
    # @return [Hash{Array(Integer, Integer) => Integer}] maps glyph
    #   references ([source index, glyph ID in that source]) to glyph IDs in
    #   the merged font
    def assign_glyph_ids(cmap_result)
      old_to_new = { [0, 0] => 0 }
      cmap_result[:charmap].each_value do |ids|
        old_to_new[ids[:old]] = ids[:new]
      end

      # migrate composite components: collect the transitive closure of
      # component glyph references
      component_keys = []
      queue = old_to_new.keys
      until queue.empty?
        src, glyph_id = queue.shift
        glyph = @sources[src].glyph_outlines.for(glyph_id)
        next unless glyph&.compound?

        glyph.glyph_ids.each do |component_id|
          key = [src, component_id]
          next if old_to_new.key?(key)

          old_to_new[key] = nil
          component_keys << key
          queue << key
        end
      end

      next_glyph_id = cmap_result[:max_glyph_id]
      component_keys.group_by(&:first).sort.each do |(src, keys)|
        keys.map(&:last).sort.each do |glyph_id|
          old_to_new[[src, glyph_id]] = next_glyph_id
          next_glyph_id += 1
        end
      end

      old_to_new
    end

    # @param old_to_new [Hash{Array(Integer, Integer) => Integer}]
    # @return [Array<Hash{Integer => Integer}>] per-source mappings of glyph
    #   IDs in the source font to glyph IDs in the merged font
    def source_glyph_mappings(old_to_new)
      @sources.each_index.map { {} }.tap do |mappings|
        old_to_new.each do |(src, glyph_id), new_id|
          mappings[src][glyph_id] = new_id
        end
      end
    end

    # Scale factor between a source font's units-per-em and the merged
    # font's units-per-em (the primary font's).
    #
    # @param src [Integer] source font index
    # @return [Rational]
    def scale_ratio(src)
      Rational(
        primary.header.units_per_em,
        @sources[src].header.units_per_em,
      )
    end

    # Scale a font-units value from a source font to the merged font's
    # units-per-em.
    #
    # @param value [Numeric]
    # @param src [Integer] source font index
    # @return [Integer]
    def scale_value(value, src)
      (value * scale_ratio(src)).round
    end

    # Encode the merged glyf table.
    #
    # @param new_to_old [Hash{Integer => Array(Integer, Integer)}]
    # @param num_glyphs [Integer]
    # @param source_mappings [Array<Hash{Integer => Integer}>]
    # @return [Hash]
    def encode_glyf(new_to_old, num_glyphs, source_mappings)
      table = +''
      offsets = []

      num_glyphs.times do |new_id|
        src, glyph_id = new_to_old[new_id]
        offsets << table.length

        glyph = @sources[src].glyph_outlines.for(glyph_id)
        next unless glyph

        table << recode_glyph(glyph, src, source_mappings[src])
      end

      # include an offset at the end of the table, for use in computing the
      # size of the last glyph
      offsets << table.length

      { table: table, offsets: offsets }
    end

    # Re-encode a glyph for the merged font: remap component references and
    # scale outlines to the merged font's units-per-em.
    #
    # @param glyph [TTFunk::Table::Glyf::Simple, TTFunk::Table::Glyf::Compound]
    # @param src [Integer] source font index
    # @param mapping [Hash{Integer => Integer}]
    # @return [String]
    def recode_glyph(glyph, src, mapping)
      ratio = scale_ratio(src)

      if ratio == 1
        glyph.recode(mapping)
      elsif glyph.compound?
        scale_compound(glyph.raw, ratio, mapping)
      else
        scale_simple(glyph.raw, ratio)
      end
    end

    # Re-encode a simple glyph scaling its coordinates by the given ratio.
    #
    # @param raw [String] binary glyph data
    # @param ratio [Rational]
    # @return [String]
    def scale_simple(raw, ratio)
      io = StringIO.new(raw)
      number_of_contours, x_min, y_min, x_max, y_max = io.read(10).unpack('s>5')
      end_points = io.read(number_of_contours * 2).unpack('n*')
      instruction_length = io.read(2).unpack1('n')
      instructions = io.read(instruction_length)

      point_count = end_points.empty? ? 0 : end_points.last + 1

      flags = []
      while flags.length < point_count
        flag = io.readbyte
        flags << flag
        # REPEAT_FLAG: the flag is repeated the given number of times
        flags += [flag] * io.readbyte if flag.allbits?(0x08)
      end

      xs = read_coordinates(io, flags, short_bit: 0x02, same_bit: 0x10)
      ys = read_coordinates(io, flags, short_bit: 0x04, same_bit: 0x20)

      result = [
        number_of_contours,
        (x_min * ratio).round, (y_min * ratio).round,
        (x_max * ratio).round, (y_max * ratio).round,
      ].pack('s>5')
      result << end_points.pack('n*')
      result << [instruction_length].pack('n')
      result << instructions

      # keep only the on-curve and overlap bits; coordinates are re-encoded
      # as signed 16-bit deltas
      result << flags.map { |flag| flag & 0x41 }.pack('C*')
      result << encode_deltas(xs.map { |x| (x * ratio).round })
      result << encode_deltas(ys.map { |y| (y * ratio).round })
      result
    end

    # Read absolute glyph coordinates.
    #
    # @param io [StringIO]
    # @param flags [Array<Integer>]
    # @param short_bit [Integer] flag bit indicating a single-byte coordinate
    # @param same_bit [Integer] flag bit indicating the sign of a single-byte
    #   coordinate, or a repeated coordinate for two-byte coordinates
    # @return [Array<Integer>]
    def read_coordinates(io, flags, short_bit:, same_bit:)
      coordinates = []
      current = 0

      flags.each do |flag|
        if flag.allbits?(short_bit)
          delta = io.readbyte
          current += flag.allbits?(same_bit) ? delta : -delta
        elsif flag.nobits?(same_bit)
          current += io.read(2).unpack1('s>')
        end
        coordinates << current
      end

      coordinates
    end

    # Encode absolute coordinates as signed 16-bit deltas.
    #
    # @param values [Array<Integer>]
    # @return [String]
    def encode_deltas(values)
      deltas = []
      previous = 0

      values.each do |value|
        deltas << value - previous
        previous = value
      end

      deltas.pack('s>*')
    end

    # Re-encode a compound glyph: remap component glyph references and scale
    # component offsets by the given ratio.
    #
    # @param raw [String] binary glyph data
    # @param ratio [Rational]
    # @param mapping [Hash{Integer => Integer}]
    # @return [String]
    def scale_compound(raw, ratio, mapping)
      io = StringIO.new(raw)
      _contours, x_min, y_min, x_max, y_max = io.read(10).unpack('s>5')

      result = [
        -1,
        (x_min * ratio).round, (y_min * ratio).round,
        (x_max * ratio).round, (y_max * ratio).round,
      ].pack('s>5')

      flags = 0
      loop do
        flags, glyph_id = io.read(4).unpack('n2')
        new_id = mapping.fetch(glyph_id)

        words = flags.allbits?(0x0001) # ARG_1_AND_2_ARE_WORDS
        xy_values = flags.allbits?(0x0002) # ARGS_ARE_XY_VALUES

        arg1, arg2 =
          if words
            io.read(4).unpack(xy_values ? 's>2' : 'n2')
          else
            io.read(2).unpack(xy_values ? 'c2' : 'C2')
          end

        # point-matching arguments refer to points that are scaled along
        # with their glyphs; explicit offsets need scaling
        if xy_values
          arg1 = (arg1 * ratio).round
          arg2 = (arg2 * ratio).round
        end

        transform =
          if flags.allbits?(0x0080) # WE_HAVE_A_TWO_BY_TWO
            io.read(8)
          elsif flags.allbits?(0x0040) # WE_HAVE_AN_X_AND_Y_SCALE
            io.read(4)
          elsif flags.allbits?(0x0008) # WE_HAVE_A_SCALE
            io.read(2)
          end

        result << [flags, new_id].pack('n2')
        result <<
          if words
            [arg1, arg2].pack(xy_values ? 's>2' : 'n2')
          else
            [arg1, arg2].pack(xy_values ? 'c2' : 'C2')
          end
        result << transform if transform

        break if flags.nobits?(0x0020) # MORE_COMPONENTS
      end

      if flags.allbits?(0x0100) # WE_HAVE_INSTRUCTIONS
        instruction_length = io.read(2).unpack1('n')
        result << [instruction_length].pack('n') << io.read(instruction_length)
      end

      result
    end

    # Horizontal metrics of all glyphs in the merged font, scaled to the
    # merged font's units-per-em.
    #
    # @param new_to_old [Hash{Integer => Array(Integer, Integer)}]
    # @param num_glyphs [Integer]
    # @return [Array<Array(Integer, Integer)>] advance width and left side
    #   bearing pairs
    def merged_metrics(new_to_old, num_glyphs)
      num_glyphs.times.map do |new_id|
        src, glyph_id = new_to_old[new_id]
        metric = @sources[src].horizontal_metrics.for(glyph_id)
        [
          scale_value(metric.advance_width, src),
          scale_value(metric.left_side_bearing, src),
        ]
      end
    end

    # @param metrics [Array<Array(Integer, Integer)>]
    # @return [String]
    def encode_hmtx(metrics)
      metrics.flatten.pack('n*')
    end

    # Encode the hhea table. Global vertical metrics are combined from all
    # contributing fonts as an enclosing envelope: the highest ascent, the
    # lowest descent, and the largest line gap, each scaled to the merged
    # font's units-per-em.
    #
    # @param new_to_old [Hash{Integer => Array(Integer, Integer)}]
    # @param metrics [Array<Array(Integer, Integer)>]
    # @param num_glyphs [Integer]
    # @return [String]
    def encode_hhea(new_to_old, metrics, num_glyphs)
      hhea = primary.horizontal_header

      ascents = []
      descents = []
      line_gaps = []
      @sources.each_index do |src|
        header = @sources[src].horizontal_header
        ascents << scale_value(header.ascent, src)
        descents << scale_value(header.descent, src)
        line_gaps << scale_value(header.line_gap, src)
      end

      min_lsb = Min.new
      min_rsb = Min.new
      max_aw = Max.new
      max_extent = Max.new

      num_glyphs.times do |new_id|
        advance, lsb = metrics[new_id]
        min_lsb << lsb
        max_aw << advance

        src, glyph_id = new_to_old[new_id]
        glyph = @sources[src].glyph_outlines.for(glyph_id)
        next unless glyph

        x_delta = scale_value(glyph.x_max, src) - scale_value(glyph.x_min, src)
        min_rsb << (advance - lsb - x_delta)
        max_extent << (lsb + x_delta)
      end

      [hhea.version].pack('N') << [
        ascents.max, descents.min, line_gaps.max,
        max_aw.value_or(0), min_lsb.value_or(0), min_rsb.value_or(0),
        max_extent.value_or(0),
        hhea.caret_slope_rise, hhea.caret_slope_run, hhea.caret_offset,
        0, 0, 0, 0, hhea.metric_data_format, num_glyphs,
      ].pack('n*')
    end

    # Encode the head table. The bounding box spans all merged glyphs.
    #
    # @param new_to_old [Hash{Integer => Array(Integer, Integer)}]
    # @param loca_result [Hash] result of encoding the loca table
    # @return [EncodedString]
    def encode_head(new_to_old, loca_result)
      head = primary.header

      x_min = Min.new
      x_max = Max.new
      y_min = Min.new
      y_max = Max.new

      new_to_old.each_value do |(src, glyph_id)|
        glyph = @sources[src].glyph_outlines.for(glyph_id)
        next unless glyph

        x_min << scale_value(glyph.x_min, src)
        x_max << scale_value(glyph.x_max, src)
        y_min << scale_value(glyph.y_min, src)
        y_max << scale_value(glyph.y_max, src)
      end

      EncodedString.new do |table|
        table <<
          [head.version, head.font_revision].pack('N2') <<
          Placeholder.new(:checksum, length: 4) <<
          [
            head.magic_number,
            head.flags, head.units_per_em,
            head.created, head.modified,
            x_min.value_or(0), y_min.value_or(0),
            x_max.value_or(0), y_max.value_or(0),
            head.mac_style, head.lowest_rec_ppem, head.font_direction_hint,
            loca_result[:type] || 0, head.glyph_data_format,
          ].pack('Nn2q>2n*')
      end
    end

    # Encode the maxp table. Glyph statistics are recomputed over the merged
    # glyph set; instruction-related limits come from the primary font,
    # whose font-wide hinting programs are the ones being kept.
    #
    # @param new_to_old [Hash{Integer => Array(Integer, Integer)}]
    # @param num_glyphs [Integer]
    # @return [String]
    def encode_maxp(new_to_old, num_glyphs)
      maxp = primary.maximum_profile
      table = [maxp.version, num_glyphs].pack('Nn')

      if maxp.version == 0x10000
        stats = maxp_stats(new_to_old)
        table << [
          stats[:max_points],
          stats[:max_contours],
          stats[:max_component_points],
          stats[:max_component_contours],
          maxp.max_zones,
          maxp.max_twilight_points,
          maxp.max_storage,
          maxp.max_function_defs,
          maxp.max_instruction_defs,
          maxp.max_stack_elements,
          stats[:max_size_of_instructions],
          stats[:max_component_elements],
          stats[:max_component_depth],
        ].pack('n*')
      end

      table
    end

    # @param new_to_old [Hash{Integer => Array(Integer, Integer)}]
    # @return [Hash]
    def maxp_stats(new_to_old)
      max_points = Max.new
      max_contours = Max.new
      max_component_points = Max.new
      max_component_contours = Max.new
      max_component_elements = Max.new
      max_component_depth = Max.new
      max_size_of_instructions = Max.new

      new_to_old.each_value do |(src, glyph_id)|
        glyph = @sources[src].glyph_outlines.for(glyph_id)
        next unless glyph

        if glyph.compound?
          max_component_elements << glyph.glyph_ids.size
          totals = component_totals(src, glyph, 1)
          max_component_points << totals[:points]
          max_component_contours << totals[:contours]
          max_component_depth << totals[:depth]
        else
          max_points << glyph.end_point_of_last_contour
          max_contours << glyph.number_of_contours
          max_size_of_instructions << glyph.instruction_length
        end
      end

      {
        max_points: max_points.value_or(0),
        max_contours: max_contours.value_or(0),
        max_component_points: max_component_points.value_or(0),
        max_component_contours: max_component_contours.value_or(0),
        max_component_elements: max_component_elements.value_or(0),
        max_component_depth: max_component_depth.value_or(0),
        max_size_of_instructions: max_size_of_instructions.value_or(0),
      }
    end

    # Total point and contour counts of a composite glyph's components,
    # resolved within its source font.
    #
    # @param src [Integer] source font index
    # @param glyph [TTFunk::Table::Glyf::Compound]
    # @param depth [Integer]
    # @return [Hash]
    def component_totals(src, glyph, depth)
      points = 0
      contours = 0
      max_depth = depth

      glyph.glyph_ids.each do |component_id|
        component = @sources[src].glyph_outlines.for(component_id)
        next unless component

        if component.compound?
          totals = component_totals(src, component, depth + 1)
          points += totals[:points]
          contours += totals[:contours]
          max_depth = [max_depth, totals[:depth]].max
        else
          points += component.end_point_of_last_contour
          contours += component.number_of_contours
        end
      end

      { points: points, contours: contours, depth: max_depth }
    end

    # Encode the OS/2 table. Classification fields come from the primary
    # font; Unicode ranges are recomputed from the merged character set;
    # vertical metrics are combined from all contributing fonts as an
    # enclosing envelope, scaled to the merged font's units-per-em.
    #
    # @param codepoints [Array<Integer>]
    # @param metrics [Array<Array(Integer, Integer)>]
    # @param num_glyphs [Integer]
    # @return [String, nil]
    def encode_os2(codepoints, metrics, num_glyphs)
      return unless primary.os2.exists?

      os2 = primary.os2

      table = [
        os2.version, avg_char_width(metrics, num_glyphs), os2.weight_class,
        os2.width_class, os2.type, os2.y_subscript_x_size,
        os2.y_subscript_y_size, os2.y_subscript_x_offset,
        os2.y_subscript_y_offset, os2.y_superscript_x_size,
        os2.y_superscript_y_size, os2.y_superscript_x_offset,
        os2.y_superscript_y_offset, os2.y_strikeout_size,
        os2.y_strikeout_position, os2.family_class,
      ].pack('n*')

      table << os2.panose

      table << BinUtils
        .slice_int(
          char_range_field(codepoints).value,
          bit_width: 32,
          slice_count: 4,
        )
        .pack('N*')

      table << os2.vendor_id

      # These fields cannot represent supplementary character values
      # (codepoints greater than 0xFFFF).
      first_char_index = [codepoints.min, BMP_MAX].min
      last_char_index = [codepoints.max, BMP_MAX].min
      table << [os2.selection, first_char_index, last_char_index].pack('n*')

      if os2.version.positive?
        table << combined_os2_metrics.pack('n*')

        # The merged font covers the primary font's scripts; claiming whole
        # code pages of the fallback fonts would overstate coverage.
        table << BinUtils
          .slice_int(os2.code_page_range.value, bit_width: 32, slice_count: 2)
          .pack('N*')

        if os2.version > 1
          table << [
            os2.x_height, os2.cap_height, os2.default_char, os2.break_char,
            0, # max_context: the merged font has no layout tables
          ].pack('n*')
        end
      end

      table
    end

    # Average advance width over all glyphs in the merged font.
    #
    # @param metrics [Array<Array(Integer, Integer)>]
    # @param num_glyphs [Integer]
    # @return [Integer]
    def avg_char_width(metrics, num_glyphs)
      metrics.sum(0) { |(advance, _)| advance } / num_glyphs
    end

    # Unicode range bits for the merged character set.
    #
    # @param codepoints [Array<Integer>]
    # @return [TTFunk::BitField]
    def char_range_field(codepoints)
      field = BitField.new(0)
      blocks = TTFunk::Table::OS2::UNICODE_BLOCKS
      ranges = TTFunk::Table::OS2::UNICODE_RANGES

      codepoints.each do |code|
        range = ranges.find { |r| r.cover?(code) }
        bit = blocks[range]
        field.on(bit) if bit
      end

      field
    end

    # Typographic and Windows vertical metrics combined from all
    # contributing fonts as an enclosing envelope: the highest ascent, the
    # lowest descent, and the largest line gap, each scaled to the merged
    # font's units-per-em.
    #
    # @return [Array(Integer, Integer, Integer, Integer, Integer)]
    def combined_os2_metrics
      ascents = []
      descents = []
      line_gaps = []
      win_ascents = []
      win_descents = []

      @sources.each_index do |src|
        os2 = @sources[src].os2
        next unless os2.exists?

        ascents << scale_value(os2.ascent, src)
        descents << scale_value(os2.descent, src)
        line_gaps << scale_value(os2.line_gap, src)
        win_ascents << scale_value(os2.win_ascent, src)
        win_descents << scale_value(os2.win_descent, src)
      end

      [
        ascents.max || 0,
        descents.min || 0,
        line_gaps.max || 0,
        win_ascents.max || 0,
        win_descents.max || 0,
      ]
    end

    # Encode the post table in format 3.0 (no glyph names).
    #
    # @return [String, nil]
    def encode_post
      return unless primary.postscript.exists?

      post = primary.postscript
      [
        0x00030000, post.italic_angle, post.underline_position,
        post.underline_thickness, post.fixed_pitch, post.min_mem_type42,
        post.max_mem_type42, post.min_mem_type1, post.max_mem_type1,
      ].pack('N2n2N5')
    end

    # Encode the name table. Names come from the primary font, with a
    # subset tag derived from the merged outlines.
    #
    # @param glyf_table [String]
    # @return [String, nil]
    def encode_name(glyf_table)
      return unless primary.name.exists?

      TTFunk::Table::Name.encode(primary.name, glyf_table)
    end

    # Copy font-global tables that are valid as-is from the primary font.
    #
    # @param tables [Hash{String => String}]
    # @return [void]
    def copy_primary_tables(tables)
      COPIED_TABLES.each do |tag|
        next unless primary.directory.tables.key?(tag)

        tables[tag] = TTFunk::Table::Simple.new(primary, tag).raw
      end
    end

    # Limitations of the merged font: everything present in the source fonts
    # that could not be migrated.
    #
    # @return [Array<String>]
    def collect_limitations
      notes = []

      @sources.each_with_index do |font, index|
        label = font_label(font, index)

        font.directory.tables.each_key do |tag|
          next if GENERATED_TABLES.include?(tag) || COPIED_TABLES.include?(tag)

          notes << limitation_note(tag, label)
        end

        next unless index.positive? &&
          (font.directory.tables.keys & HINTING_TABLES).any?

        notes <<
          "font-wide hinting programs of #{label} were not migrated; " +            "glyph instructions from it are interpreted with the primary " +            "font's hinting environment"
      end

      notes
    end

    # @param tag [String] table tag
    # @param label [String] font label
    # @return [String]
    def limitation_note(tag, label)
      if LAYOUT_TABLES.include?(tag)
        "layout table '#{tag}' from #{label} was not migrated; the merged " +          'font does not preserve its glyph substitution/positioning behavior'
      elsif VARIATION_TABLES.include?(tag)
        "variation table '#{tag}' from #{label} was not migrated; the " +          'merged font is static'
      elsif tag == 'DSIG'
        "digital signature from #{label} was dropped"
      else
        "table '#{tag}' from #{label} was not migrated"
      end
    end

    # Assemble the sfnt file from encoded tables.
    #
    # @param tables [Hash{String => String, EncodedString}]
    # @return [String]
    def assemble(tables)
      search_range = (2**Math.log2(tables.length).floor) * 16
      entry_selector = Integer(Math.log2(2**Math.log2(tables.length).floor))
      range_shift = (tables.length * 16) - search_range
      range_shift = 0 if range_shift.negative?

      newfont = EncodedString.new

      newfont << [
        primary.directory.scaler_type,
        tables.length,
        search_range,
        entry_selector,
        range_shift,
      ].pack('Nn*')

      # Tables are supposed to be listed in ascending order whereas there is
      # a known optimal order for table data.
      tables.keys.sort.each do |tag|
        newfont << [tag, checksum(tables[tag])].pack('A4N')
        newfont << Placeholder.new(tag, length: 4)
        newfont << [tables[tag].length].pack('N')
      end

      optimal_table_order(tables).each do |tag|
        newfont.resolve_placeholder(tag, [newfont.length].pack('N'))
        newfont << tables[tag]
        newfont.align!(4)
      end

      adjustment = CHECKSUM_MAGIC - checksum(newfont)
      newfont.resolve_placeholder(:checksum, [adjustment].pack('N'))

      newfont.string
    end

    # @param tables [Hash{String => String}]
    # @return [Array<String>]
    def optimal_table_order(tables)
      TTFunk::TTFEncoder::OPTIMAL_TABLE_ORDER +
        (tables.keys - TTFunk::TTFEncoder::OPTIMAL_TABLE_ORDER)
    end

    # @param data [String, EncodedString]
    # @return [Integer]
    def checksum(data)
      align(raw(data), 4).unpack('N*').sum & 0xFFFF_FFFF
    end

    # @param data [String, EncodedString]
    # @return [String]
    def raw(data)
      data.respond_to?(:unresolved_string) ? data.unresolved_string : data
    end

    # @param data [String]
    # @param width [Integer]
    # @return [String]
    def align(data, width)
      if (data.length % width).positive?
        data + ("\0" * (width - (data.length % width)))
      else
        data
      end
    end
  end
end
