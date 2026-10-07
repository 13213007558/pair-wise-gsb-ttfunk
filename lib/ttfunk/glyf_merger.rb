# frozen_string_literal: true

require_relative 'table/loca'
require_relative 'table/simple'

module TTFunk
  Restriction = Struct.new(:source, :code, :tag, :message) do
    def to_h
      { source: source, code: code, tag: tag, message: message }
    end
  end

  GlyfMergeResult = Struct.new(:font, :restrictions) do
    def success?
      restrictions.empty?
    end
  end

  class GlyfMergeError < Error
    attr_reader :restrictions

    def initialize(restrictions)
      @restrictions = restrictions
      super(restrictions.map(&:message).join('; '))
    end
  end

  # Merges explicitly selected glyphs from TrueType glyf fonts into a primary
  # TrueType font. Glyph and component IDs, horizontal metrics, and cmap
  # mappings are rebuilt for the resulting font.
  class GlyfMerger
    ARG_1_AND_2_ARE_WORDS = 0x0001
    ARGS_ARE_XY_VALUES = 0x0002
    WE_HAVE_A_SCALE = 0x0008
    MORE_COMPONENTS = 0x0020
    WE_HAVE_AN_X_AND_Y_SCALE = 0x0040
    WE_HAVE_A_TWO_BY_TWO = 0x0080
    WE_HAVE_INSTRUCTIONS = 0x0100

    ON_CURVE_POINT = 0x01
    X_SHORT_VECTOR = 0x02
    Y_SHORT_VECTOR = 0x04
    REPEAT_FLAG = 0x08
    X_SAME_OR_POSITIVE = 0x10
    Y_SAME_OR_POSITIVE = 0x20
    OVERLAP_SIMPLE = 0x40

    UNSUPPORTED_TABLES = %w[
      BASE GDEF GPOS GSUB JSTF DSIG VORG vhea vmtx morx mort kerx trak
      ankr feat fvar gvar avar cvar HVAR MVAR VVAR STAT sbix COLR CPAL
      CBDT CBLC EBDT EBLC EBSC SVG  kern CFF2
    ].freeze + ['CFF ']

    REQUIRED_TABLES = %w[cmap glyf head hhea hmtx loca maxp name].freeze
    COPIED_TABLES = %w[prep fpgm cvt  gasp].freeze

    TABLE_ORDER = [
      'head', 'hhea', 'maxp', 'OS/2', 'hmtx', 'cmap',
      'fpgm', 'prep', 'cvt ', 'loca', 'glyf', 'name', 'post', 'gasp',
    ].freeze

    Component = Struct.new(:flags, :gid, :arg1, :arg2, :transform_bytes, :a, :b, :c, :d, :new_gid)
    GlyphRecord = Struct.new(:source, :gid, :new_gid, :glyph, :components, :encoded, :bounds)

    # Returns a GlyfMergeResult. Restricted merges return a result with a nil
    # font and a non-empty frozen restrictions list.
    def self.merge(primary, selections = {})
      new(primary, selections).merge
    end

    # Returns the encoded TrueType font or raises GlyfMergeError.
    def self.merge!(primary, selections = {})
      new(primary, selections).merge!
    end

    def initialize(primary, selections = {})
      raise ArgumentError, 'primary must be a TTFunk::File' unless primary.is_a?(TTFunk::File)

      pairs =
        case selections
        when Hash
          selections.to_a
        when Array
          selections
        else
          raise ArgumentError, 'selections must be a Hash or Array of Unicode scalar/source pairs'
        end

      selected = {}
      pairs.each do |code_point, source|
        unless scalar?(code_point) && source.is_a?(TTFunk::File)
          raise ArgumentError, 'selections must map Unicode scalar values to TTFunk::File objects'
        end
        if selected.key?(code_point) && !selected[code_point].equal?(source)
          raise ArgumentError, "ambiguous source selection for #{format_code(code_point)}"
        end
        selected[code_point] = source
      end

      @primary = primary
      @selections = selected
      @restrictions = []
      @sources = []
      @records_by_key = {}
      @records_by_new_gid = {}
      @global_gid_map = {}
      @next_gid = 0
      @loca_type = nil
    end

    def merge
      result = merge_result
      return result unless result.success?

      GlyfMergeResult.new(result.font, result.restrictions.freeze).freeze
    end

    def merge!
      result = merge_result
      raise GlyfMergeError.new(result.restrictions) unless result.success?

      result.font
    end

    private

    def scalar?(code_point)
      code_point.is_a?(Integer) &&
        ((0..0xD7FF).cover?(code_point) || (0xE000..0x10FFFF).cover?(code_point))
    end

    def merge_result
      prepare_sources
      return failure unless @restrictions.empty?

      build_records
      return failure unless @restrictions.empty?

      font = encode_font
      @restrictions.empty? ? GlyfMergeResult.new(font, []) : failure
    end

    def prepare_sources
      register_source(@primary, 0)
      @selections.sort.each do |_code_point, file|
        register_source(file, source_index(file)) unless file.equal?(@primary)
      end
    end

    def register_source(file, index)
      return if @sources[index]

      source = { file: file, scale: nil, label: index.zero? ? 'primary' : "fallback-#{index}" }
      @sources[index] = source

      unsupported = UNSUPPORTED_TABLES.select { |tag| file.directory_info(tag) }
      unsupported.each do |tag|
        add_restriction(index, :unsupported_table, tag, "#{source[:label]} contains an unmigratable #{tag.inspect} table")
      end

      unless file.directory.scaler_type == 0x00010000 && file.directory_info('glyf')
        add_restriction(index, :unsupported_outline_format, 'glyf', "#{source[:label]} is not a TrueType glyf font")
      end

      missing = REQUIRED_TABLES.reject { |tag| file.directory_info(tag) }
      missing.each do |tag|
        add_restriction(index, :missing_table, tag, "#{source[:label]} is missing required #{tag.inspect} table")
      end

      if file.directory_info('head') && @primary.directory_info('head')
        upm = file.header.units_per_em
        unless (16..16_384).cover?(upm)
          add_restriction(index, :invalid_units_per_em, 'head', "#{source[:label]} has invalid unitsPerEm #{upm}")
        end
        source[:scale] = Rational(@primary.header.units_per_em, upm)
      end

      if file.directory_info('cmap') && unicode_cmap(file, index).nil?
        add_restriction(index, :missing_unicode_cmap, 'cmap', "#{source[:label]} has no supported Unicode cmap")
      end
    end

    def unicode_cmap(file, source)
      file.cmap.unicode.first
    rescue StandardError => error
      add_restriction(source, :invalid_cmap, 'cmap', "cmap could not be parsed in #{@sources[source][:label]}: #{error.message}")
      nil
    end

    def source_index(file)
      index = @sources.index { |source| source && source[:file].equal?(file) }
      return index if index

      index = @sources.length
      index += 1 while @sources[index]
      register_source(file, index)
      index
    end

    def build_records
      primary_count = @primary.maximum_profile.num_glyphs
      primary_count.times do |gid|
        glyph =
          begin
            @primary.glyph_outlines.for(gid)
          rescue StandardError => error
            add_restriction(0, :invalid_glyph, 'glyf', "glyph #{gid} could not be parsed in primary: #{error.message}")
            nil
          end
        components = glyph&.compound? ? parse_components(0, gid, glyph.raw) : []
        register_record(0, gid, gid, glyph, components)
      end
      @next_gid = primary_count

      @selections.sort.each do |code_point, file|
        index = file.equal?(@primary) ? 0 : source_index(file)
        cmap = unicode_cmap(file, index)
        local_gid = cmap && cmap[code_point]
        if local_gid.nil? || local_gid.zero?
          add_restriction(index, :missing_glyph, 'cmap', "#{format_code(code_point)} is not mapped in #{@sources[index][:label]}")
          next
        end
        assign_glyph(index, local_gid, [])
      end

      if @next_gid > 65_535
        add_restriction(0, :too_many_glyphs, 'maxp', 'merged font contains more than 65535 glyphs')
      end
    end

    def register_record(source, gid, new_gid, glyph, components)
      record = GlyphRecord.new(source, gid, new_gid, glyph, components, nil, nil)
      @records_by_key[[source, gid]] = record
      @records_by_new_gid[new_gid] = record
      @global_gid_map[[source, gid]] = new_gid
      record
    end

    def assign_glyph(source, gid, active_path)
      key = [source, gid]
      return @global_gid_map[key] if @global_gid_map.key?(key)
      return 0 if gid.zero?

      file = @sources[source][:file]
      if gid >= file.maximum_profile.num_glyphs
        add_restriction(source, :invalid_glyph_reference, 'glyf', "glyph #{gid} is out of range in #{@sources[source][:label]}")
        return nil
      end

      if active_path.include?(key)
        add_restriction(source, :composite_cycle, 'glyf', "composite glyph #{gid} creates a component cycle in #{@sources[source][:label]}")
        return nil
      end

      glyph =
        begin
          file.glyph_outlines.for(gid)
        rescue StandardError => error
          add_restriction(source, :invalid_glyph, 'glyf', "glyph #{gid} could not be parsed in #{@sources[source][:label]}: #{error.message}")
          nil
        end

      if glyph.nil?
        add_restriction(source, :missing_glyph, 'glyf', "glyph #{gid} is empty in #{@sources[source][:label]}")
        return nil
      end

      components = glyph.compound? ? parse_components(source, gid, glyph.raw) : []
      record = register_record(source, gid, @next_gid, glyph, components)
      @next_gid += 1

      if glyph.compound?
        components.each do |component|
          component_new_gid = assign_glyph(source, component.gid, active_path + [key])
          component[:new_gid] = component_new_gid
        end
      end

      record.new_gid
    end

    def parse_components(source, gid, raw)
      components = []
      offset = 10

      loop do
        flags, component_gid = raw[offset, 4].unpack('n2')
        arg_offset = offset + 4
        word_args = (flags & ARG_1_AND_2_ARE_WORDS).positive?
        arg1, arg2 =
          if word_args
            raw[arg_offset, 4].unpack('s>2')
          else
            raw[arg_offset, 2].unpack('c2')
          end

        transform_offset = arg_offset + (word_args ? 4 : 2)
        transform_bytes, a, b, c, d =
          if (flags & WE_HAVE_A_TWO_BY_TWO).positive?
            bytes = raw[transform_offset, 8]
            values = bytes.unpack('s>4').map { |value| Rational(value, 16_384) }
            [bytes, values[0], values[1], values[2], values[3]]
          elsif (flags & WE_HAVE_AN_X_AND_Y_SCALE).positive?
            bytes = raw[transform_offset, 4]
            values = bytes.unpack('s>2').map { |value| Rational(value, 16_384) }
            [bytes, values[0], 0, 0, values[1]]
          elsif (flags & WE_HAVE_A_SCALE).positive?
            bytes = raw[transform_offset, 2]
            value = Rational(bytes.unpack1('s>'), 16_384)
            [bytes, value, 0, 0, value]
          else
            ['', 1, 0, 0, 1]
          end

        components << Component.new(flags, component_gid, arg1, arg2, transform_bytes, a, b, c, d)
        break if (flags & MORE_COMPONENTS).zero?
        offset = transform_offset + transform_bytes.length
      end

      components
    rescue StandardError => error
      add_restriction(source, :invalid_compound, 'glyf', "composite glyph #{gid} could not be parsed in #{@sources[source][:label]}: #{error.message}")
      []
    end

    def code_map
      @code_map ||=
        begin
          map = {}
          @primary.cmap.unicode.first.code_map.each do |code_point, gid|
            next unless scalar?(code_point) && gid.positive?
            map[code_point] = gid
          end

          @selections.sort.each do |code_point, file|
            source = file.equal?(@primary) ? 0 : source_index(file)
            cmap = unicode_cmap(file, source)
            gid = cmap && cmap[code_point]
            if gid.nil? || gid.zero?
              add_restriction(source, :missing_glyph, 'cmap', "#{format_code(code_point)} is not mapped in #{@sources[source][:label]}")
            else
              map[code_point] = @global_gid_map[[source, gid]]
            end
          end

          map
        end
    end

    def encode_font
      @code_map = code_map
      return nil unless @restrictions.empty?

      glyf = encode_glyf
      return nil unless @restrictions.empty?

      loca = Table::Loca.encode(glyf[:offsets])
      @loca_type = loca[:type]
      bounds = combined_bounds

      tables = {
        'cmap' => encode_cmap,
        'glyf' => glyf[:table],
        'loca' => loca[:table],
        'hmtx' => encode_hmtx,
        'hhea' => encode_hhea,
        'maxp' => encode_maxp,
        'post' => encode_post,
        'name' => Table::Simple.new(@primary, 'name').raw,
        'head' => encode_head(bounds),
      }

      if @primary.os2.exists?
        tables['OS/2'] = encode_os2
      end

      COPIED_TABLES.each do |tag|
        tables[tag] = Table::Simple.new(@primary, tag).raw if @primary.directory_info(tag)
      end

      return nil unless @restrictions.empty?

      write_font(tables)
    end

    def encode_glyf
      table = (+'').b
      offsets = []

      @next_gid.times do |new_gid|
        offsets << table.length
        encoded = encoded_glyph(new_gid)
        table << encoded if encoded
        table << "\0" if table.length.odd?
      end

      offsets << table.length
      { table: table, offsets: offsets }
    end

    def encoded_glyph(new_gid)
      primary_gid = new_gid < @primary.maximum_profile.num_glyphs ? new_gid : nil
      return @primary.glyph_outlines.for(primary_gid)&.raw if primary_gid

      record = @records_by_new_gid[new_gid]
      return unless record
      return record.encoded if record.encoded

      if record.glyph.compound?
        record.encoded = encode_compound(record)
        record.bounds = compound_bounds(record)
      else
        outline = SimpleOutline.new(record.glyph.raw)
        record.encoded, record.bounds = outline.encode(@sources[record.source][:scale])
      end

      unless signed_range?(record.bounds, 16)
        add_restriction(record.source, :glyph_out_of_range, 'glyf', "glyph #{record.gid} is outside signed 16-bit bounds after scaling")
      end

      record.encoded
    rescue StandardError => error
      add_restriction(record&.source || 0, :invalid_glyph, 'glyf', "glyph #{record&.gid || new_gid} could not be encoded: #{error.message}")
      nil
    end

    def encode_compound(record)
      scale = @sources[record.source][:scale]
      data = (+'').b

      record.components.each_with_index do |component, index|
        flags = component.flags
        flags |= ARG_1_AND_2_ARE_WORDS
        flags &= ~WE_HAVE_INSTRUCTIONS
        flags |= MORE_COMPONENTS if index < record.components.length - 1

        new_gid = component[:new_gid]
        unless new_gid
          add_restriction(record.source, :invalid_component_reference, 'glyf', "composite glyph #{record.gid} references unavailable glyph #{component.gid}")
          next
        end

        arg1 = component.arg1
        arg2 = component.arg2
        if (flags & ARGS_ARE_XY_VALUES).positive?
          arg1 = round_half_up(Rational(arg1) * scale)
          arg2 = round_half_up(Rational(arg2) * scale)
          unless signed_range?([arg1, arg2], 16)
            add_restriction(record.source, :glyph_out_of_range, 'glyf', "composite glyph #{record.gid} has component offsets outside signed 16-bit range")
          end
        end

        data << [flags, new_gid, arg1, arg2].pack('n4').b
        data << component.transform_bytes.b
      end

      bounds = compound_bounds(record)
      [-1, *bounds].pack('s>5').b + data
    end

    def compound_bounds(record, active = {})
      return record.bounds if record.bounds
      return nil if active[[record.source, record.gid]]

      active[[record.source, record.gid]] = true
      scale = @sources[record.source][:scale]
      corners = []

      record.components.each do |component|
        child = @records_by_key[[record.source, component.gid]]
        next unless child

        bounds = glyph_bounds(child, active)
        next unless bounds

        if (component.flags & ARGS_ARE_XY_VALUES).zero?
          add_restriction(record.source, :unsupported_component_arguments, 'glyf', "composite glyph #{record.gid} uses point-number component arguments")
          next
        end

        x0, y0, x1, y1 = bounds.map { |value| Rational(value) }
        tx = Rational(component.arg1) * scale
        ty = Rational(component.arg2) * scale

        [[x0, y0], [x0, y1], [x1, y0], [x1, y1]].each do |x, y|
          corners << [component.a * x + component.c * y + tx, component.b * x + component.d * y + ty]
        end
      end

      return nil if corners.empty?

      xs = corners.map(&:first)
      ys = corners.map(&:last)
      [xs.min.floor, ys.min.floor, xs.max.ceil, ys.max.ceil]
    end

    def glyph_bounds(record, active)
      if record.source.zero?
        glyph = @primary.glyph_outlines.for(record.gid)
        glyph ? [glyph.x_min, glyph.y_min, glyph.x_max, glyph.y_max] : nil
      elsif record.glyph.compound?
        compound_bounds(record, active)
      else
        encoded_glyph(record.new_gid)
        record.bounds
      end
    end

    def fallback_records
      @fallback_records ||= @records_by_key.values.reject { |record| record.source.zero? }
    end

    def encode_hmtx
      metrics = []
      @next_gid.times do |new_gid|
        if new_gid < @primary.maximum_profile.num_glyphs
          metric = @primary.horizontal_metrics.for(new_gid)
          metrics << [metric.advance_width, metric.left_side_bearing]
        else
          record = @records_by_new_gid[new_gid]
          next unless record
          metric = @sources[record.source][:file].horizontal_metrics.for(record.gid)
          scale = @sources[record.source][:scale]
          width = round_half_up(Rational(metric.advance_width) * scale)
          lsb = round_half_up(Rational(metric.left_side_bearing) * scale)
          unless (0..65_535).cover?(width) && signed_range?([lsb], 16)
            add_restriction(record.source, :metric_out_of_range, 'hmtx', "glyph #{record.gid} has horizontal metrics outside supported range")
          end
          metrics << [width, lsb]
        end
      end

      metrics.flatten.pack('n*')
    end

    def encode_hhea
      raw = @primary.horizontal_header.raw.dup.b
      metrics = combined_metrics
      extrema = horizontal_extrema
      values = [
        metrics[:ascent], metrics[:descent], metrics[:line_gap],
        *extrema,
      ]
      raw[4, 16] = values.pack('n*')
      raw[34, 2] = [@next_gid].pack('n')
      raw
    end

    def horizontal_extrema
      min_lsb = nil
      min_rsb = nil
      max_advance = nil
      max_extent = nil

      each_metric_with_bounds do |metric, bounds|
        width = metric[:width]
        lsb = metric[:lsb]
        min_lsb = lsb if min_lsb.nil? || lsb < min_lsb
        max_advance = width if max_advance.nil? || width > max_advance
        next unless bounds

        extent = lsb + (bounds[2] - bounds[0])
        rsb = width - lsb - (bounds[2] - bounds[0])
        min_rsb = rsb if min_rsb.nil? || rsb < min_rsb
        max_extent = extent if max_extent.nil? || extent > max_extent
      end

      [max_advance || 0, min_lsb || 0, min_rsb || 0, max_extent || 0]
    end

    def each_metric_with_bounds
      @next_gid.times do |new_gid|
        if new_gid < @primary.maximum_profile.num_glyphs
          metric = @primary.horizontal_metrics.for(new_gid)
          glyph = @primary.glyph_outlines.for(new_gid)
          bounds = glyph ? [glyph.x_min, glyph.y_min, glyph.x_max, glyph.y_max] : nil
          yield({ width: metric.advance_width, lsb: metric.left_side_bearing }, bounds)
        else
          record = @records_by_new_gid[new_gid]
          source_metric = @sources[record.source][:file].horizontal_metrics.for(record.gid)
          scale = @sources[record.source][:scale]
          encoded_glyph(new_gid)
          yield(
            {
              width: round_half_up(Rational(source_metric.advance_width) * scale),
              lsb: round_half_up(Rational(source_metric.left_side_bearing) * scale),
            },
            record.bounds
          )
        end
      end
    end

    def combined_metrics
      ascents = []
      descents = []
      line_heights = []
      win_ascents = []
      win_descents = []

      @sources.each do |source|
        next unless source

        metrics = source_metrics(source)
        ascents << metrics[:ascent]
        descents << metrics[:descent]
        line_heights << metrics[:line_height]
        win_ascents << metrics[:win_ascent]
        win_descents << metrics[:win_descent]
      end

      ascent = ascents.max.ceil
      descent = descents.min.floor
      line_height = line_heights.max.ceil
      line_gap = [0, line_height - (ascent - descent)].max

      {
        ascent: ascent,
        descent: descent,
        line_gap: line_gap,
        win_ascent: win_ascents.max.ceil,
        win_descent: win_descents.max.ceil,
      }
    end

    def source_metrics(source)
      file = source[:file]
      scale = source[:scale] || Rational(1)
      hhea = file.horizontal_header
      if file.os2.exists? && file.os2.version.positive?
        ascent = Rational(file.os2.ascent.nonzero? || hhea.ascent) * scale
        descent = Rational(file.os2.descent.nonzero? || hhea.descent) * scale
        gap = Rational(file.os2.line_gap) * scale
        win_ascent = Rational(file.os2.win_ascent) * scale
        win_descent = Rational(file.os2.win_descent) * scale
      else
        ascent = Rational(hhea.ascent) * scale
        descent = Rational(hhea.descent) * scale
        gap = Rational(hhea.line_gap) * scale
        win_ascent = ascent
        win_descent = -descent
      end

      {
        ascent: ascent,
        descent: descent,
        line_gap: gap,
        line_height: ascent - descent + gap,
        win_ascent: win_ascent,
        win_descent: win_descent,
      }
    end

    def encode_os2
      raw = @primary.os2.raw.dup.b
      metrics = combined_metrics
      advance_total = 0
      advance_count = 0
      each_metric_with_bounds do |metric, _bounds|
        if metric[:width].positive?
          advance_total += metric[:width]
          advance_count += 1
        end
      end
      average = advance_count.zero? ? 0 : advance_total / advance_count

      bits = unicode_range_bits
      bmp = code_map.keys.select { |code_point| code_point <= 0xFFFF }

      raw[2, 2] = [average].pack('n')
      raw[42, 16] = BinUtils.slice_int(bits, bit_width: 32, slice_count: 4).pack('N*')
      raw[64, 2] = [bmp.first || 0].pack('n')
      raw[66, 2] = [bmp.last || 0].pack('n')
      if @primary.os2.version.positive?
        raw[68, 10] = [
          metrics[:ascent], metrics[:descent], metrics[:line_gap],
          metrics[:win_ascent], metrics[:win_descent],
        ].pack('n*')
      end
      raw
    end

    def unicode_range_bits
      bit_field = BitField.new(@primary.os2.exists? ? @primary.os2.char_range.value : 0)
      blocks = Table::OS2::UNICODE_BLOCKS
      code_points = code_map.keys.sort

      blocks.each do |range, bit|
        next if code_points.bsearch { |code_point| code_point >= range.min }.nil?
        bit_field.on(bit) if code_points.any? { |code_point| range.cover?(code_point) }
      end

      bit_field.value
    end

    def encode_maxp
      raw = @primary.maximum_profile.raw.dup.b
      raw[4, 2] = [@next_gid].pack('n')
      return raw unless @primary.maximum_profile.version == 0x10000

      stats = maxp_stats
      raw[6, 26] = [
        stats[:max_points],
        stats[:max_contours],
        stats[:max_component_points],
        stats[:max_component_contours],
        @primary.maximum_profile.max_zones,
        @primary.maximum_profile.max_twilight_points,
        @primary.maximum_profile.max_storage,
        @primary.maximum_profile.max_function_defs,
        @primary.maximum_profile.max_instruction_defs,
        @primary.maximum_profile.max_stack_elements,
        stats[:max_size_of_instructions],
        stats[:max_component_elements],
        stats[:max_component_depth],
      ].pack('n*')
      raw
    end

    def maxp_stats
      stats = Hash.new(0)
      fallback_records.each do |record|
        encoded_glyph(record.new_gid)
        if record.glyph.compound?
          totals = component_stats(record)
          stats[:max_component_points] = [stats[:max_component_points], totals[:points]].max
          stats[:max_component_contours] = [stats[:max_component_contours], totals[:contours]].max
          stats[:max_component_depth] = [stats[:max_component_depth], totals[:depth]].max
          stats[:max_component_elements] = [stats[:max_component_elements], record.components.length].max
        else
          outline = SimpleOutline.new(record.glyph.raw)
          stats[:max_points] = [stats[:max_points], outline.point_count].max
          stats[:max_contours] = [stats[:max_contours], outline.number_of_contours].max
        end
      end

      [
        :max_points, :max_contours, :max_component_points,
        :max_component_contours, :max_component_elements, :max_component_depth,
      ].each do |key|
        primary_value = @primary.maximum_profile.public_send(key)
        stats[key] = [stats[key], primary_value].max
      end
      stats[:max_size_of_instructions] = @primary.maximum_profile.max_size_of_instructions
      stats
    end

    def component_stats(record, active = {})
      key = [record.source, record.gid]
      return { points: 0, contours: 0, depth: 1 } if active[key]

      active[key] = true
      points = 0
      contours = 0
      max_child_depth = 0

      record.components.each do |component|
        child = @records_by_key[[record.source, component.gid]]
        next unless child

        if child.glyph.compound?
          totals = component_stats(child, active)
          points += totals[:points]
          contours += totals[:contours]
          max_child_depth = [max_child_depth, totals[:depth]].max
        else
          outline = SimpleOutline.new(child.glyph.raw)
          points += outline.point_count
          contours += outline.number_of_contours
        end
      end

      { points: points, contours: contours, depth: max_child_depth + 1 }
    ensure
      active.delete(key)
    end

    def combined_bounds
      x_min = nil
      y_min = nil
      x_max = nil
      y_max = nil

      @next_gid.times do |new_gid|
        bounds =
          if new_gid < @primary.maximum_profile.num_glyphs
            glyph = @primary.glyph_outlines.for(new_gid)
            glyph ? [glyph.x_min, glyph.y_min, glyph.x_max, glyph.y_max] : nil
          else
            encoded_glyph(new_gid)
            record = @records_by_new_gid[new_gid]
            record&.bounds
          end
        next unless bounds

        x_min = bounds[0] if x_min.nil? || bounds[0] < x_min
        y_min = bounds[1] if y_min.nil? || bounds[1] < y_min
        x_max = bounds[2] if x_max.nil? || bounds[2] > x_max
        y_max = bounds[3] if y_max.nil? || bounds[3] > y_max
      end

      [x_min || 0, y_min || 0, x_max || 0, y_max || 0]
    end

    def encode_head(bounds)
      EncodedString.new do |table|
        head = @primary.header
        table << [head.version, head.font_revision].pack('N2')
        table << Placeholder.new(:checksum, length: 4)
        table << [
          head.magic_number, head.flags, head.units_per_em,
          head.created, head.modified,
          *bounds,
          head.mac_style, head.lowest_rec_ppem, head.font_direction_hint,
          @loca_type || 0, head.glyph_data_format,
        ].pack('Nn2q>2n*')
      end
    end

    def encode_post
      source = @primary.postscript
      raw = source.exists? ? source.raw.dup.b[0, 32].ljust(32, "\0") : ("\0" * 32).b
      raw[0, 4] = [0x00030000].pack('N')
      raw
    end

    def encode_cmap
      groups = cmap_groups
      subtable = [12, 0].pack('n2').b
      subtable += [16 + (12 * groups.length), 0, groups.length].pack('NNN').b
      groups.each do |group|
        subtable += group.pack('N3').b
      end

      [0, 1].pack('n2').b + [3, 10, 12].pack('nnN').b + subtable
    end

    def cmap_groups
      sorted = code_map.select { |_code_point, gid| gid }.sort
      groups = []
      sorted.each do |code_point, gid|
        previous = groups.last
        if previous && code_point == previous[1] + 1 && gid == previous[2] + 1
          previous[1] = code_point
        else
          groups << [code_point, code_point, gid]
        end
      end
      groups
    end

    def write_font(tables)
      count = tables.length
      search_range = (2**Math.log2(count).floor) * 16
      entry_selector = Integer(Math.log2(2**Math.log2(count).floor))
      range_shift = (count * 16) - search_range
      range_shift = 0 if range_shift.negative?

      font = EncodedString.new
      font << [
        @primary.directory.scaler_type, count,
        search_range, entry_selector, range_shift,
      ].pack('Nn*')

      tables.keys.sort.each do |tag|
        font << [tag, checksum(tables[tag])].pack('A4N')
        font << Placeholder.new(tag, length: 4)
        font << [tables[tag].length].pack('N')
      end

      TABLE_ORDER.each do |tag|
        next unless tables.key?(tag)

        font.resolve_placeholder(tag, [font.length].pack('N'))
        font << tables[tag]
        font.align!(4)
      end

      adjustment = (0xB1B0AFBA - checksum(font)) & 0xFFFF_FFFF
      font.resolve_placeholder(:checksum, [adjustment].pack('N'))
      font.string
    end

    def checksum(data)
      raw = data.respond_to?(:unresolved_string) ? data.unresolved_string : data
      padding = raw.length.modulo(4).zero? ? '' : "\0" * (4 - raw.length.modulo(4))
      (raw + padding).unpack('N*').sum & 0xFFFF_FFFF
    end

    def add_restriction(source, code, tag, message)
      @restrictions << Restriction.new(
        @sources[source] ? @sources[source][:label] : source.to_s,
        code,
        tag,
        message,
      )
    end

    def failure
      unique = @restrictions.uniq do |restriction|
        [restriction.source, restriction.code, restriction.tag, restriction.message]
      end
      GlyfMergeResult.new(nil, unique.freeze).freeze
    end

    def signed_range?(values, bits)
      minimum = -(2**(bits - 1))
      maximum = (2**(bits - 1)) - 1
      values.all? { |value| value.is_a?(Integer) && value >= minimum && value <= maximum }
    end

    def round_half_up(value)
      value.round(half: :up)
    end

    def format_code(code_point)
      format('U+%04X', code_point)
    end

    class SimpleOutline
      attr_reader :number_of_contours, :end_points, :flags, :x_coordinates, :y_coordinates, :bounds

      def initialize(raw)
        io = StringIO.new(raw)
        header = io.read(10).unpack('n*').map do |value|
          BinUtils.twos_comp_to_int(value, bit_width: 16)
        end
        @number_of_contours = header.first
        @bounds = header[1, 4]
        @end_points = @number_of_contours.zero? ? [] : io.read(@number_of_contours * 2).unpack('n*')
        instruction_length = io.read(2).unpack1('n')
        io.read(instruction_length)
        @flags = read_flags(io)
        @x_coordinates = read_coordinates(io, @flags, X_SHORT_VECTOR, X_SAME_OR_POSITIVE)
        @y_coordinates = read_coordinates(io, @flags, Y_SHORT_VECTOR, Y_SAME_OR_POSITIVE)
      end

      def point_count
        @point_count ||= @end_points.empty? ? 0 : @end_points.last + 1
      end

      def encode(scale)
        xs = @x_coordinates.map { |value| (Rational(value) * scale).round(half: :up) }
        ys = @y_coordinates.map { |value| (Rational(value) * scale).round(half: :up) }
        flags = []
        x_data = (+'').b
        y_data = (+'').b
        x = 0
        y = 0

        point_count.times do |index|
          x_flag, x_bytes = encode_delta(xs[index] - x, X_SHORT_VECTOR, X_SAME_OR_POSITIVE)
          y_flag, y_bytes = encode_delta(ys[index] - y, Y_SHORT_VECTOR, Y_SAME_OR_POSITIVE)
          base_flag = @flags[index] & (ON_CURVE_POINT | OVERLAP_SIMPLE)
          flags << (base_flag | x_flag | y_flag)
          x_data << x_bytes
          y_data << y_bytes
          x = xs[index]
          y = ys[index]
        end

        bounds = [xs.min || 0, ys.min || 0, xs.max || 0, ys.max || 0]
        data = [number_of_contours, *bounds].pack('s>5').b
        data << @end_points.pack('n*').b
        data << [0].pack('n').b
        flags.each { |flag| data << [flag].pack('C') }
        data << x_data
        data << y_data
        [data, bounds]
      end

      private

        def read_flags(io)
          flags = []
          while flags.length < point_count
            flag = io.read(1).unpack1('C')
            repeat = (flag & REPEAT_FLAG).positive? ? io.read(1).unpack1('C') : 0
            remaining = point_count - flags.length
            [repeat + 1, remaining].min.times { flags << flag }
          end
          flags
        end

      def read_coordinates(io, flags, short_flag, same_flag)
        coordinate = 0
        flags.map do |flag|
          delta =
            if (flag & short_flag).positive?
              value = io.read(1).unpack1('C')
              (flag & same_flag).zero? ? -value : value
            elsif (flag & same_flag).zero?
              value = io.read(2).unpack1('n')
              value >= 0x8000 ? value - 0x10000 : value
            else
              0
            end
          coordinate += delta
        end
      end

      def encode_delta(delta, short_flag, same_flag)
        return [same_flag, ''] if delta.zero?
        return [same_flag | short_flag, [delta].pack('C')] if delta >= 1 && delta <= 255
        return [short_flag, [-delta].pack('C')] if delta <= -1 && delta >= -255

        [0, [delta].pack('s>')]
      end
    end
  end
end
