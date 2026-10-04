# frozen_string_literal: true

require_relative 'min'
require_relative 'max'
require_relative 'table/loca'
require_relative 'table/glyf/simple'
require_relative 'table/glyf/compound'

module TTFunk
  # Builds a static TrueType instance from glyf and gvar data.
  class VariableFontInstantiator
    UNSUPPORTED_VARIATION_TABLES = %w[CFF2 VVAR cvar].freeze

    # @param file [TTFunk::File]
    # @param coordinates [Hash{String, Symbol => Numeric}]
    def initialize(file, coordinates)
      @file = file
      @requested_coordinates = coordinates
    end

    # Validate and encode the complete instance entirely in memory.
    #
    # @return [String]
    def encode
      validate!

      encoded_glyf = +''
      offsets = []
      metrics = []
      glyph_bounds = []

      glyph_count.times do |glyph_id|
        offsets << encoded_glyf.bytesize
        encoded_glyph, metric, bounds =
          instantiate_glyph(glyph_id)
        encoded_glyf << encoded_glyph if encoded_glyph
        metrics << metric
        glyph_bounds[glyph_id] = bounds
      end
      offsets << encoded_glyf.bytesize

      loca = TTFunk::Table::Loca.encode(offsets)
      hmtx = TTFunk::Table::Hmtx.encode_metrics(metrics)
      tables = {
        'glyf' => encoded_glyf,
        'loca' => loca.fetch(:table),
        'hmtx' => hmtx.fetch(:table),
        'hhea' => encode_hhea(hmtx, metrics, glyph_bounds),
        'head' => encode_head(loca, global_bounds(glyph_bounds)),
      }

      StaticFontEncoder.new(@file, tables).encode
    end

    private

    def validate!
      unless @file.font_variations
        raise TTFunk::Error, 'font has no fvar table and cannot be instantiated'
      end

      if @file.directory.tables['CFF '] || @file.directory.tables['CFF2']
        raise TTFunk::Error, 'CFF/CFF2 variable font instantiation is not supported'
      end

      unless @file.directory.tables['glyf'] && @file.directory.tables['gvar']
        raise TTFunk::Error, 'only glyf/gvar variable fonts can be instantiated'
      end

      unsupported = UNSUPPORTED_VARIATION_TABLES & @file.directory.tables.keys
      unless unsupported.empty?
        raise TTFunk::Error, "unsupported variation table: #{unsupported.first}"
      end

      normalized_coordinates
      axis_tags
    end

    def glyph_count
      @glyph_count ||= @file.maximum_profile.num_glyphs
    end

    def normalized_coordinates
      @normalized_coordinates ||=
        @file.font_variations.normalized_coordinates(
          @requested_coordinates,
          @file.axis_variations,
        )
    end

    def axis_tags
      @axis_tags ||= @file.font_variations.axes.map(&:tag)
    end

    def instantiate_glyph(glyph_id)
      @current_glyph_id = glyph_id
      glyph = @file.glyph_outlines.for(glyph_id)
      metric = @file.horizontal_metrics.for(glyph_id)
      outline_count = glyph_point_count(glyph)
      x_values, y_values = base_coordinates(glyph, metric, outline_count)

      apply_variations(glyph, outline_count, x_values, y_values)
      round_values!(x_values, y_values)

      static_metric = static_metric(metric, x_values, outline_count)
      encoded_glyph, bounds =
        encode_glyph(glyph, outline_count, x_values, y_values)
      [encoded_glyph, static_metric, bounds]
    end

    def glyph_point_count(glyph)
      return 0 unless glyph
      return glyph.end_point_of_last_contour unless glyph.compound?

      raise TTFunk::Error, 'compound glyph variations are not supported'
    end

    def base_coordinates(glyph, metric, outline_count)
      x_values = glyph ? glyph.x_coordinates.dup : []
      y_values = glyph ? glyph.y_coordinates.dup : []
      x_values.concat(
        [
          metric.left_side_bearing,
          metric.left_side_bearing + metric.advance_width,
          0,
          0,
        ],
      )
      y_values.concat([0, 0, glyph&.y_min || 0, glyph&.y_max || 0])
      [x_values, y_values]
    end

    def apply_variations(glyph, outline_count, x_values, y_values)
      variations = @file.glyph_variations.variations_for(
        @current_glyph_id,
        outline_count + 4,
      )
      contour_end_points = glyph ? glyph.end_points_of_contours : []

      variations.each do |variation|
        scalar = @file.glyph_variations.scalar_for(
          variation,
          normalized_coordinates,
          axis_tags,
        )
        next if scalar.zero?

        point_indices = resolve_indices(variation.points, outline_count)
        x_explicit = {}
        y_explicit = {}

        point_indices.each_with_index do |point_index, delta_index|
          x_explicit[point_index] = true
          y_explicit[point_index] = true
          x_values[point_index] += variation.x_deltas.fetch(delta_index) * scalar
          y_values[point_index] += variation.y_deltas.fetch(delta_index) * scalar
        end

        interpolate_missing_outline_points!(
          x_values, contour_end_points, x_explicit,
        )
        interpolate_missing_outline_points!(
          y_values, contour_end_points, y_explicit,
        )
      end
    end

    def resolve_indices(indices, outline_count)
      indices.map do |index|
        case index
        when -1 then outline_count
        when -2 then outline_count + 1
        when -3 then outline_count + 2
        when -4 then outline_count + 3
        else index
        end
      end
    end

    def interpolate_missing_outline_points!(values, contour_end_points, explicit)
      contour_start = 0
      contour_end_points.each do |contour_end|
        indices = (contour_start..contour_end).to_a
        known = indices.select { |index| explicit[index] }

        if known.empty?
          contour_start = contour_end + 1
          next
        end

        indices.each do |index|
          next if explicit[index]

          values[index] = interpolated_value(values, index, known)
        end

        contour_start = contour_end + 1
      end

      values
    end

    def interpolated_value(values, point_index, known)
      before = known.select { |index| index < point_index }.max
      after = known.select { |index| index > point_index }.min

      return values[before] if before && !after
      return values[after] if after && !before
      return values[point_index] unless before && after

      position = Rational(point_index - before, after - before)
      values[before] + (values[after] - values[before]) * position
    end

    def round_values!(x_values, y_values)
      x_values.map! { |value| round_value(value) }
      y_values.map! { |value| round_value(value) }
    end

    def round_value(value)
      integer = value.truncate
      fraction = value - integer
      return integer if fraction.zero?

      if value.positive?
        fraction.abs >= Rational(1, 2) ? integer + 1 : integer
      else
        fraction.abs >= Rational(1, 2) ? integer - 1 : integer
      end
    end

    def static_metric(original_metric, x_values, outline_count)
      left_side_bearing = x_values[outline_count]
      advance_width =
        if @file.horizontal_metrics_variations
          # When HVAR exists it is the normative source of advance width.
          # gvar phantom x1 remains part of outline variation, but its width
          # contribution must not be added to the HVAR-derived width.
          original_metric.advance_width +
            round_value(
              @file.horizontal_metrics_variations.advance_delta_for(
                @current_glyph_id,
                normalized_coordinates,
              ),
            )
        else
          x_values[outline_count + 1]
        end

      TTFunk::Table::Hmtx::HorizontalMetric.new(
        clamp_uint16(advance_width),
        clamp_int16(left_side_bearing),
      )
    end

    def clamp_uint16(value)
      raise TTFunk::Error, 'instantiated advance width does not fit hmtx' unless value.between?(0, 0xFFFF)

      Integer(value)
    end

    def clamp_int16(value)
      raise TTFunk::Error, 'instantiated side bearing does not fit hmtx' unless value.between?(-0x8000, 0x7FFF)

      Integer(value)
    end

    def encode_glyph(glyph, outline_count, x_values, y_values)
      return [nil, nil] unless glyph

      outline_x = x_values.first(outline_count)
      outline_y = y_values.first(outline_count)
      coordinates = outline_x.zip(outline_y)
      bounds = [
        outline_x.min, outline_y.min,
        outline_x.max, outline_y.max,
      ]
      [glyph.encode_with_coordinates(coordinates), bounds]
    end

    def encode_hhea(hmtx, metrics, glyph_bounds)
      hhea = @file.horizontal_header
      min_lsb = Min.new
      min_rsb = Min.new
      max_extent = Max.new

      metrics.each_with_index do |metric, glyph_id|
        bounds = glyph_bounds[glyph_id]
        next unless bounds

        x_min, _y_min, x_max, _y_max = bounds
        width = x_max - x_min
        min_lsb << metric.left_side_bearing
        min_rsb << metric.advance_width - metric.left_side_bearing - width
        max_extent << metric.left_side_bearing + width
      end

      ''.b.tap do |table|
        table << [hhea.version].pack('N')
        table << [hhea.ascent, hhea.descent, hhea.line_gap].pack('s>*')
        table << [metrics.map(&:advance_width).max].pack('n')
        table << [
          min_lsb.value_or(0),
          min_rsb.value_or(0),
          max_extent.value_or(0),
          hhea.caret_slope_rise,
          hhea.caret_slope_run,
          hhea.caret_offset,
          0, 0, 0, 0,
          hhea.metric_data_format,
        ].pack('s>*')
        table << [hmtx.fetch(:number_of_metrics)].pack('n')
      end
    end

    def encode_head(loca, bounds)
      head = @file.header.raw.dup
      head[8, 4] = [0].pack('N')
      head[36, 8] = bounds.pack('s>*')
      head[50, 2] = [loca.fetch(:type)].pack('s>')
      head
    end

    def global_bounds(glyph_bounds)
      compact = glyph_bounds.compact
      return [0, 0, 0, 0] if compact.empty?

      [
        compact.map { |bounds| bounds[0] }.min,
        compact.map { |bounds| bounds[1] }.min,
        compact.map { |bounds| bounds[2] }.max,
        compact.map { |bounds| bounds[3] }.max,
      ]
    end
  end
end
