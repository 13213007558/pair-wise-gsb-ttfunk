# frozen_string_literal: true

require 'set'

module TTFunk
  # Freezes a variable TrueType font at one axis location.
  class VariableFontInstantiator
    Result = Struct.new(
      :font_data,
      :user_coordinates,
      :clamped_coordinates,
      :normalized_coordinates,
      :removed_tables,
      :rewritten_tables,
      keyword_init: true
    )

    UNSUPPORTED_VARIATION_TABLES = %w[
      CFF2 HVAR MVAR VVAR cvar
    ].freeze

    REMOVED_TABLES = %w[avar DSIG fvar gvar].freeze
    REWRITTEN_TABLES = %w[glyf head hhea hmtx loca].freeze
    REQUIRED_TABLES = %w[glyf head hhea hmtx loca maxp].freeze

    # @param file [TTFunk::File]
    # @param coordinates [Hash{String, Symbol => Numeric}]
    def initialize(file, coordinates)
      @file = file
      @user_coordinates = stringify_coordinates(coordinates)
      @processed_glyph_ids = Set.new
    end

    # Build a static TrueType instance.
    #
    # @return [Result]
    def instantiate
      validate!
      clamp_coordinates!
      normalize_coordinates!
      apply_avar!
      apply_variations!
      build_font
    end

    private

    attr_reader :clamped_coordinates, :normalized_coordinates

    def validate!
      unless @file.directory.tables.include?('fvar')
        raise Error, 'font has no fvar table and cannot be instantiated'
      end

      if @file.directory.tables.include?('CFF ') ||
         @file.directory.tables.include?('CFF2')
        raise Error, 'instantiating CFF-based variable fonts is not supported'
      end

      missing_tables = REQUIRED_TABLES - @file.directory.tables.keys
      unless missing_tables.empty?
        raise Error,
          "variable TrueType font is missing required table(s): #{missing_tables.join(', ')}"
      end

      unsupported = UNSUPPORTED_VARIATION_TABLES & @file.directory.tables.keys
      unsupported += unsupported_versioned_tables
      unless unsupported.empty?
        raise Error,
          "unsupported variation-related table(s): #{unsupported.join(', ')}"
      end

      missing = @file.font_variations.axes.map(&:tag) -
                @user_coordinates.keys
      unless missing.empty?
        raise ArgumentError,
          "missing axis coordinates: #{missing.join(', ')}"
      end
    end

    def unsupported_versioned_tables
      tables = []
      tables << 'BASE' if table_version('BASE') >= 0x00010001
      tables << 'COLR' if @file.directory.tables.include?('COLR') &&
                           table_version('COLR') >= 1
      tables
    end

    def table_version(tag)
      info = @file.directory.tables[tag]
      return 0x0001_0000 unless info

      @file.contents.string.byteslice(info[:offset], 4).unpack1('N')
    end

    def clamp_coordinates!
      @clamped_coordinates =
        @file.font_variations.axes.each_with_object({}) do |axis, result|
          value = @user_coordinates.fetch(axis.tag)
          result[axis.tag] = [[value, axis.min_value].max, axis.max_value].min
        end
    end

    def normalize_coordinates!
      @normalized_coordinates =
        @file.font_variations.axes.each_with_object({}) do |axis, result|
          value = @clamped_coordinates.fetch(axis.tag)
          result[axis.tag] = normalize_axis(value, axis)
        end
    end

    def normalize_axis(value, axis)
      return 0.0 if value == axis.default_value

      if value < axis.default_value
        (value - axis.default_value).to_f /
          (axis.default_value - axis.min_value)
      else
        (value - axis.default_value).to_f /
          (axis.max_value - axis.default_value)
      end
    end

    def apply_avar!
      return unless @file.axis_variations.exists?

      @normalized_coordinates = @file.axis_variations.apply(@normalized_coordinates)
    end

    def apply_variations!
      @metrics = {}
      @glyf_table = +''
      @loca_offsets = []

      @file.maximum_profile.num_glyphs.times do |glyph_id|
        instantiate_glyph(glyph_id)
      end

      @loca_offsets << @glyf_table.length
    end

    def instantiate_glyph(glyph_id, parents = Set.new)
      return if @processed_glyph_ids.include?(glyph_id)
      raise Error, 'cyclic composite glyph reference' if parents.include?(glyph_id)

      glyph = @file.glyph_outlines.for(glyph_id)
      unless glyph
        instantiate_empty_glyph(glyph_id)
        return
      end

      current_parents = parents + [glyph_id]
      if glyph.compound?
        glyph.glyph_ids.each do |child_id|
          instantiate_glyph(child_id, current_parents)
        end
      end

      original_coordinates = base_coordinates(glyph_id, glyph)
      inferred_deltas = variation_deltas(glyph_id, glyph, original_coordinates)
      reject_vertical_deltas(glyph_id, inferred_deltas)
      reject_unsupported_component_deltas(glyph_id, glyph, inferred_deltas)

      coordinates = apply_deltas(original_coordinates, inferred_deltas)
      instantiate_from_coordinates(glyph_id, glyph, coordinates)
      @processed_glyph_ids << glyph_id
    end

    def instantiate_empty_glyph(glyph_id)
      metric = @file.horizontal_metrics.for(glyph_id)
      coordinates = [
        [0.0, 0.0],
        [metric.advance_width.to_f, 0.0],
        [0.0, 0.0],
        [0.0, 0.0],
      ]
      deltas = variation_deltas(glyph_id, nil, coordinates)
      reject_vertical_deltas(glyph_id, deltas)
      coordinates = apply_deltas(coordinates, deltas)

      record_metric(glyph_id, nil, coordinates)
      append_glyph(nil)
      @processed_glyph_ids << glyph_id
    end

    def base_coordinates(glyph_id, glyph)
      metric = @file.horizontal_metrics.for(glyph_id)
      left_x = glyph.x_min - metric.left_side_bearing
      right_x = left_x + metric.advance_width

      outline =
        if glyph.compound?
          glyph.components.map { |component| [component.arg1.to_f, component.arg2.to_f] }
        else
          glyph.coordinates.map { |x, y| [x.to_f, y.to_f] }
        end

      outline + phantom_coordinates(left_x, right_x)
    end

    def phantom_coordinates(left_x, right_x)
      [
        [left_x.to_f, 0.0],
        [right_x.to_f, 0.0],
        [0.0, 0.0],
        [0.0, 0.0],
      ]
    end

    def variation_deltas(glyph_id, glyph, coordinates)
      return zero_deltas(coordinates.length) unless @file.glyph_variations.exists?

      variations = @file.glyph_variations.for(glyph_id)
      combined = zero_deltas(coordinates.length)

      variations.each do |variation|
        scalar = region_scalar(variation)
        next if scalar.zero?

        inferred = infer_deltas(
          variation.deltas,
          coordinates,
          endpoints_for(glyph, coordinates.length),
        )

        inferred.each_with_index do |(x_delta, y_delta), index|
          combined[index][0] += x_delta * scalar
          combined[index][1] += y_delta * scalar
        end
      end

      combined
    end

    def zero_deltas(count)
      Array.new(count) { [0.0, 0.0] }
    end

    def endpoints_for(glyph, point_count)
      if glyph.nil? || glyph.compound?
        (0...(point_count - 4)).to_a
      else
        glyph.end_points_of_contours
      end
    end

    def region_scalar(variation)
      @file.font_variations.axes.reduce(1.0) do |scalar, axis|
        peak = variation.peak[axis.tag].to_f
        start = variation.intermediate_start.fetch(axis.tag, 0.0).to_f
        finish = variation.intermediate_end.fetch(axis.tag, 0.0).to_f
        coordinate = @normalized_coordinates.fetch(axis.tag)

        if peak.zero?
          region_scalar = coordinate.between?(start, finish) ? 1.0 : 0.0
        else
          next scalar unless coordinate.between?(start, finish)

          region_scalar = coordinate / peak
        end

        scalar * region_scalar
      end
    end

    def infer_deltas(raw_deltas, coordinates, endpoints)
      point_count = coordinates.length
      result = zero_deltas(point_count)
      groups = delta_groups(point_count, endpoints)

      groups.each do |indices|
        explicit = indices.select { |index| raw_deltas[index] }
        next if explicit.empty?

        [0, 1].each do |dimension|
          explicit.each do |index|
            result[index][dimension] = raw_deltas[index][dimension].to_f
          end

          if explicit.one?
            index = explicit.first
            indices.each do |group_index|
              result[group_index][dimension] = raw_deltas[index][dimension].to_f
            end
            next
          end

          ordered = explicit.sort
          ordered.each_cons(2) do |left, right|
            fill_between(result, coordinates, indices, left, right, dimension)
          end

          fill_wraps(result, coordinates, indices, ordered, dimension)
        end
      end

      result
    end

    def delta_groups(point_count, endpoints)
      groups = []
      start = 0

      endpoints.each do |finish|
        groups << (start..finish).to_a
        start = finish + 1
      end

      groups << [start] if start < point_count - 4
      4.times { |index| groups << [point_count - 4 + index] }
      groups
    end

    def fill_between(result, coordinates, indices, left, right, dimension)
      left_position = indices.index(left)
      right_position = indices.index(right)

      ((left_position + 1)...right_position).each do |position|
        index = indices[position]
        result[index][dimension] =
          interpolate(result, coordinates, left, right, index, dimension)
      end
    end

    def fill_wraps(result, coordinates, indices, explicit, dimension)
      first = explicit.first
      last = explicit.last
      first_position = indices.index(first)
      last_position = indices.index(last)

      (last_position + 1...indices.length).each do |position|
        index = indices[position]
        result[index][dimension] =
          interpolate(result, coordinates, last, first, index, dimension)
      end

      (0...first_position).each do |position|
        index = indices[position]
        result[index][dimension] =
          interpolate(result, coordinates, last, first, index, dimension)
      end
    end

    def interpolate(deltas, coordinates, left, right, index, dimension)
      left_coordinate = coordinates[left][dimension]
      right_coordinate = coordinates[right][dimension]
      coordinate = coordinates[index][dimension]

      if left_coordinate == right_coordinate
        return deltas[left][dimension] == deltas[right][dimension] ?
          deltas[left][dimension] : 0.0
      end

      left_value, right_value, left_delta, right_delta =
        ordered_reference(
          left_coordinate, right_coordinate,
          deltas[left][dimension], deltas[right][dimension],
        )

      return left_delta if coordinate <= left_value
      return right_delta if coordinate >= right_value

      left_delta +
        ((coordinate - left_value) * (right_delta - left_delta) /
         (right_value - left_value))
    end

    def ordered_reference(left_coordinate, right_coordinate, left_delta, right_delta)
      if left_coordinate <= right_coordinate
        [left_coordinate, right_coordinate, left_delta, right_delta]
      else
        [right_coordinate, left_coordinate, right_delta, left_delta]
      end
    end

    def apply_deltas(coordinates, deltas)
      coordinates.map.with_index do |(x, y), index|
        x_delta, y_delta = deltas[index]
        [x + x_delta, y + y_delta]
      end
    end

    def instantiate_from_coordinates(glyph_id, glyph, coordinates)
      phantom = coordinates.last(4)
      outline = coordinates[0...-4]

      if glyph.compound?
        outline.each_with_index do |(x, y), index|
          original = glyph.components[index]
          x_delta = ot_round(x - original.arg1)
          y_delta = ot_round(y - original.arg2)
          glyph.translate_component(index, x_delta, y_delta)
        end

        glyph.recalculate_bounds(@file.glyph_outlines)
      else
        rounded = outline.map { |x, y| [ot_round(x), ot_round(y)] }
        glyph.recode_with_coordinates(rounded)
      end

      record_metric(glyph_id, glyph, phantom)
      append_glyph(glyph)
    end

    def record_metric(glyph_id, glyph, phantom_or_coordinates)
      left_x = phantom_or_coordinates[0][0]
      right_x = phantom_or_coordinates[1][0]
      advance_width = [ot_round(right_x - left_x), 0].max
      left_side_bearing =
        if glyph
          ot_round(glyph.x_min - left_x)
        else
          ot_round(-left_x)
        end

      @metrics[glyph_id] = [advance_width, left_side_bearing]
    end

    def append_glyph(glyph)
      @loca_offsets << @glyf_table.length
      @glyf_table << glyph.raw if glyph
    end

    def build_font
      tables = copied_tables.merge(
        'glyf' => @glyf_table.dup,
        'loca' => @loca_offsets.pack('N*'),
        'hmtx' => encode_hmtx,
        'hhea' => encode_hhea,
        'head' => encode_head,
      )

      font_data = encode_sfnt(tables)

      Result.new(
        font_data: font_data,
        user_coordinates: @user_coordinates,
        clamped_coordinates: clamped_coordinates,
        normalized_coordinates: normalized_coordinates,
        removed_tables: present_tables(REMOVED_TABLES),
        rewritten_tables: present_tables(REWRITTEN_TABLES),
      )
    end

    def copied_tables
      @file.directory.tables.each_with_object({}) do |(tag, info), result|
        next if REMOVED_TABLES.include?(tag) || REWRITTEN_TABLES.include?(tag)

        result[tag] = @file.contents.string.byteslice(
          info[:offset], info[:length]
        ).dup.force_encoding(Encoding::BINARY)
      end
    end

    def present_tables(tags)
      tags.select { |tag| @file.directory.tables.include?(tag) }
    end

    def encode_hmtx
      @file.maximum_profile.num_glyphs.times.map do |glyph_id|
        @metrics[glyph_id]
      end.flatten.pack('n*')
    end

    def encode_hhea
      hhea = @file.horizontal_header
      widths = @metrics.values.map(&:first)
      lsbs = @metrics.values.map(&:last)

      right_side_bearings = []
      extents = []

      @metrics.each do |glyph_id, (advance_width, left_side_bearing)|
        glyph = @file.glyph_outlines.for(glyph_id)
        next unless glyph

        extent = glyph.x_max - glyph.x_min
        right_side_bearings <<
          advance_width - left_side_bearing - extent
        extents << left_side_bearing + extent
      end

      data = hhea.raw.dup
      data[10, 2] = [widths.max || 0].pack('n')
      data[12, 2] = [unsigned_short(lsbs.min || 0)].pack('n')
      data[14, 2] = [unsigned_short(right_side_bearings.min || 0)].pack('n')
      data[16, 2] = [extents.max || 0].pack('n')
      data[34, 2] = [@file.maximum_profile.num_glyphs].pack('n')
      data
    end

    def encode_head
      head = @file.header
      bounds = font_bounds
      data = head.raw.dup
      data[8, 4] = [0].pack('N')
      data[36, 8] = bounds.pack('s>*')
      data[50, 2] = [1].pack('n')
      data
    end

    def font_bounds
      bounds = []

      @file.maximum_profile.num_glyphs.times do |glyph_id|
        glyph = @file.glyph_outlines.for(glyph_id)
        bounds << [glyph.x_min, glyph.y_min, glyph.x_max, glyph.y_max] if glyph
      end

      [0, 0, 0, 0].tap do |result|
        next if bounds.empty?

        result[0] = bounds.map { |bounds_item| bounds_item[0] }.min
        result[1] = bounds.map { |bounds_item| bounds_item[1] }.min
        result[2] = bounds.map { |bounds_item| bounds_item[2] }.max
        result[3] = bounds.map { |bounds_item| bounds_item[3] }.max
      end
    end

    def encode_sfnt(tables)
      tags = tables.keys.sort
      search_range = (2**Integer(Math.log2(tables.length).floor)) * 16
      entry_selector = Integer(Math.log2(2**Integer(Math.log2(tags.length).floor)))
      range_shift = [(tags.length * 16) - search_range, 0].max

      directory = +[
        @file.directory.scaler_type,
        tags.length,
        search_range,
        entry_selector,
        range_shift,
      ].pack('Nn*')

      table_data = +''
      offsets = {}

      table_order(tags).each do |tag|
        offsets[tag] = 12 + (tags.length * 16) + table_data.length
        table_data << tables[tag]
        table_data << "\0" * ((4 - (table_data.length % 4)) % 4)
      end

      tags.each do |tag|
        directory << [
          tag,
          checksum(tables[tag]),
          offsets[tag],
          tables[tag].length,
        ].pack('A4NNN')
      end

      checksum_adjustment =
        (0xB1B0AFBA - checksum(directory + table_data)) & 0xFFFF_FFFF
      head_data_offset = offsets.fetch('head')
      table_data_start = 12 + (tags.length * 16)
      head_local_offset = head_data_offset - table_data_start
      table_data[head_local_offset + 8, 4] = [checksum_adjustment].pack('N')

      font = directory + table_data
      font
    end

    def table_order(tags)
      preferred = %w[
        head hhea maxp OS/2 hmtx LTSH VDMX hdmx cmap fpgm prep cvt loca glyf
        kern name post gasp PCLT
      ]
      (preferred & tags) + (tags - preferred)
    end

    def checksum(data)
      padded = data.b + ("\0" * ((4 - (data.length % 4)) % 4))
      padded.unpack('N*').sum & 0xFFFF_FFFF
    end

    def unsigned_short(value)
      value & 0xFFFF
    end

    def reject_vertical_deltas(glyph_id, deltas)
      vertical = deltas.last(2).any? { |_x, y| y.abs >= 0.5 }
      return unless vertical

      raise Error,
        "glyph #{glyph_id} includes unsupported vertical phantom variation"
    end

    def reject_unsupported_component_deltas(glyph_id, glyph, deltas)
      return unless glyph&.compound?

      component_count = glyph.components.length
      deltas.first(component_count).each_with_index do |(x_delta, y_delta), index|
        component = glyph.components[index]
        next if x_delta.abs < 0.5 && y_delta.abs < 0.5
        next if component.flags.allbits?(TTFunk::Table::Glyf::Compound::ARGS_ARE_XY_VALUES)

        raise Error,
          "glyph #{glyph_id} uses unsupported anchor-point component variations"
      end
    end

    def ot_round(value)
      Integer((value.to_f + 0.5).floor)
    end

    def stringify_coordinates(coordinates)
      coordinates.each_with_object({}) do |(tag, value), result|
        result[tag.to_s] = Float(value)
      end
    end
  end
end
