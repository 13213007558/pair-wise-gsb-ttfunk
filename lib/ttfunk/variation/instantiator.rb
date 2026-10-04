# frozen_string_literal: true

require_relative '../table/fvar'
require_relative '../table/avar'
require_relative '../table/gvar'
require_relative '../table/hvar'
require_relative 'glyph_interpolation'
require_relative 'static_font_encoder'

module TTFunk
  module Variation
    # Builds a static TrueType instance of a variable font at a given set of
    # fvar user-space coordinates.
    #
    # @api private
    class Instantiator
      # @param file [TTFunk::File] parsed variable font
      # @param coordinates [Hash{String, Symbol => Numeric}] requested axis
      #   coordinates. Missing axes use their fvar default values.
      def initialize(file, coordinates)
        @file = file
        @coordinates = coordinates
      end

      # Validate the font up front so that an unsupported variation model can
      # never result in a partially written static font.
      #
      # @return [void]
      def validate!
        unless @file.directory_info(Table::Fvar::TAG)
          raise Error, 'font has no fvar table and cannot be instantiated'
        end

        unless @file.directory_info('glyf')
          raise Error,
            'only glyf/gvar variable fonts can be instantiated' \
            ' (no glyf table found; CFF2 is not supported)'
        end

        if @file.directory_info('CFF2') || @file.cff.exists?
          raise Error,
            'CFF/CFF2 outlines are not supported for static instantiation' \
            ' (only the glyf/gvar route is supported)'
        end

        if @file.directory_info('VVAR')
          raise Error,
            'VVAR-based vertical metrics variations are not supported'
        end
      end

      # Produce the complete static font binary.
      #
      # @return [String]
      def encode
        validate!

        normalized = normalize_coordinates
        glyphs = interpolate_all(normalized)
        StaticFontEncoder.new(@file, glyphs).encode
      end

      private

      # One interpolated glyph.
      #
      # @!attribute raw
      #   @return [String, nil] encoded glyf data
      # @!attribute bbox
      #   @return [Array(Integer, Integer, Integer, Integer), nil]
      # @!attribute advance_width
      #   @return [Integer]
      # @!attribute left_side_bearing
      #   @return [Integer]
      GlyphResult = Struct.new(:raw, :bbox, :advance_width, :left_side_bearing,
        keyword_init: true)

      def normalize_coordinates
        normalized = fvar.normalized_coordinates(@coordinates)
        return normalized unless @file.axis_variations.exists?

        normalized.each_with_object({}) do |(tag, value), mapped|
          mapped[tag] = @file.axis_variations.map(tag, value)
        end
      end

      def fvar
        @file.font_variations
      end

      def gvar
        @file.glyph_variations
      end

      def hvar
        @file.horizontal_metrics_variations
      end

      def interpolate_all(normalized)
        glyph_count = @file.maximum_profile.num_glyphs
        glyphs = {}
        ordered = order_by_component_depth((0...glyph_count).to_a)

        ordered.each do |glyph_id|
          glyph = @file.glyph_outlines.for(glyph_id)
          metric = @file.horizontal_metrics.for(glyph_id)

          if glyph.nil?
            glyphs[glyph_id] = GlyphResult.new(
              raw: nil, bbox: nil,
              advance_width: metric.advance_width,
              left_side_bearing: metric.left_side_bearing,
            )
            next
          end

          glyphs[glyph_id] =
            if glyph.compound?
              interpolate_compound(glyph, metric, normalized, glyphs)
            else
              interpolate_simple(glyph, metric, normalized)
            end
        end

        glyphs
      end

      def interpolate_simple(glyph, metric, normalized)
        decoded = GlyphInterpolation.decode_simple_glyph(glyph.raw)
        outline_count = decoded[:end_points_of_contours].last + 1
        coordinates =
          decoded[:coordinates] + phantom_points(decoded[:bbox], metric)

        apply_variations(coordinates, decoded[:end_points_of_contours],
          glyph.id, normalized)

        decoded[:coordinates] = coordinates[0...outline_count].map do |x, y|
          [GlyphInterpolation.round(x), GlyphInterpolation.round(y)]
        end

        bbox = GlyphInterpolation.bbox_of(decoded[:coordinates])
        encoded = GlyphInterpolation.encode_simple_glyph(decoded)
        advance_width, left_side_bearing =
          metrics_from_phantoms(glyph.id, metric, bbox, coordinates, normalized)

        GlyphResult.new(
          raw: encoded, bbox: bbox,
          advance_width: advance_width,
          left_side_bearing: left_side_bearing,
        )
      end

      def interpolate_compound(glyph, metric, normalized, completed)
        components = parse_components(glyph)
        coordinates = component_anchor_points(components) +
          phantom_points([glyph.x_min, glyph.y_min, glyph.x_max, glyph.y_max], metric)

        apply_variations(coordinates, (0...components.length).to_a,
          glyph.id, normalized)

        new_anchors = coordinates[0...components.length].map do |x, y|
          [GlyphInterpolation.round(x), GlyphInterpolation.round(y)]
        end
        encoded = rebuild_compound(glyph, components, new_anchors)

        bbox = component_bounds(components, new_anchors, completed)
        advance_width, left_side_bearing =
          metrics_from_phantoms(glyph.id, metric, bbox, coordinates, normalized)

        GlyphResult.new(
          raw: encoded, bbox: bbox,
          advance_width: advance_width,
          left_side_bearing: left_side_bearing,
        )
      end

      def metrics_from_phantoms(glyph_id, metric, bbox, coordinates, normalized)
        left_side_x = coordinates[-4][0]
        right_side_x = coordinates[-3][0]

        if hvar.exists?
          # Per the OpenType HVAR specification, when HVAR is present its
          # advance variation data is authoritative: the horizontal right
          # phantom point delta from gvar must not be used to derive the
          # advance width. The left phantom continues to drive the side
          # bearing unless HVAR provides an explicit LSB mapping.
          advance_delta =
            GlyphInterpolation.round(hvar.advance_delta_for(glyph_id, normalized))
          advance_width = non_negative(metric.advance_width + advance_delta)

          left_side_bearing =
            if hvar.left_side_bearing_mapping?
              non_negative_bearing(
                metric.left_side_bearing +
                  GlyphInterpolation.round(
                    hvar.left_side_bearing_delta_for(glyph_id, normalized)
                  )
              )
            else
              GlyphInterpolation.round(bbox[0] - left_side_x)
            end
        else
          advance_width = non_negative(
            GlyphInterpolation.round(right_side_x - left_side_x)
          )
          left_side_bearing = GlyphInterpolation.round(bbox[0] - left_side_x)
        end

        [advance_width, left_side_bearing]
      end

      def apply_variations(coordinates, end_points, glyph_id, normalized)
        variations = gvar.variations_for(glyph_id, coordinates.length)

        variations.each do |variation|
          scalar = tuple_scalar(variation.regions, normalized)
          next if scalar.zero?

          deltas = GlyphInterpolation.infer_deltas(
            variation.deltas, coordinates, end_points
          )

          deltas.each_with_index do |(dx, dy), index|
            coordinates[index][0] += dx * scalar
            coordinates[index][1] += dy * scalar
          end
        end
      end

      def tuple_scalar(regions, normalized)
        fvar.axes.reduce(1.0) do |product, axis|
          region = regions[axis.tag]
          next(product) unless region

          start_value, peak_value, end_value = region
          product * scalar(
            normalized.fetch(axis.tag, 0.0),
            start_value, peak_value, end_value,
          )
        end
      end

      def scalar(value, start_value, peak_value, end_value)
        return 0.0 if peak_value.zero?
        return 1.0 if value == peak_value
        return 0.0 unless value > [start_value, end_value].min
        return 0.0 unless value < [start_value, end_value].max

        if value < peak_value
          return 0.0 if start_value == peak_value

          (value - start_value).to_f / (peak_value - start_value)
        else
          return 0.0 if end_value == peak_value

          (end_value - value).to_f / (end_value - peak_value)
        end
      end

      def phantom_points(bbox, metric)
        x_min, _y_min, _x_max, _y_max = bbox
        left_side_x = x_min - metric.left_side_bearing
        right_side_x = left_side_x + metric.advance_width
        [[left_side_x, 0], [right_side_x, 0], [0, 0], [0, 0]]
      end

      ComponentRecord = Struct.new(:glyph_id, :flags, :arg1, :arg2,
        :x_scale, :scale01, :scale10, :y_scale, :header_offset,
        keyword_init: true)

      def parse_components(glyph)
        components = []
        offset = 10

        loop do
          flags, component_id = glyph.raw[offset, 4].unpack('n2')
          record = ComponentRecord.new(
            glyph_id: component_id, flags: flags, header_offset: offset
          )

          if (flags & Table::Glyf::Compound::ARG_1_AND_2_ARE_WORDS) != 0
            record.arg1, record.arg2 = glyph.raw[offset + 4, 4].unpack('s>2')
          else
            record.arg1, record.arg2 = glyph.raw[offset + 4, 2].unpack('c2')
          end

          components << record
          break if (flags & Table::Glyf::Compound::MORE_COMPONENTS).zero?

          offset += 4
          offset += words?(flags) ? 4 : 2
          offset += transform_size(flags)
        end

        components
      end

      def words?(flags)
        (flags & Table::Glyf::Compound::ARG_1_AND_2_ARE_WORDS) != 0
      end

      def transform_size(flags)
        if (flags & Table::Glyf::Compound::WE_HAVE_A_TWO_BY_TWO) != 0
          8
        elsif (flags & Table::Glyf::Compound::WE_HAVE_AN_X_AND_Y_SCALE) != 0
          4
        elsif (flags & Table::Glyf::Compound::WE_HAVE_A_SCALE) != 0
          2
        else
          0
        end
      end

      def component_anchor_points(components)
        components.map do |component|
          if (component.flags & Table::Glyf::Compound::ARGS_ARE_XY_VALUES) != 0
            [component.arg1, component.arg2]
          else
            # Point-matched anchors cannot be expressed as translations of
            # the component outline itself. Their gvar deltas move the
            # matched reference points, which requires reworking the
            # component geometry and is not part of this route.
            raise Error,
              'point-matched compound component variations are not supported'
          end
        end
      end

      def rebuild_compound(glyph, components, anchors)
        result = glyph.raw.dup

        components.each_with_index do |component, index|
          x, y = anchors[index]

          if words?(component.flags)
            result[component.header_offset + 4, 4] = [x, y].pack('s>2')
          else
            unless x.between?(-128, 127) && y.between?(-128, 127)
              raise Error,
                'instantiated compound offset exceeds signed byte range'
            end

            result[component.header_offset + 4, 2] = [x, y].pack('c2')
          end
        end

        result
      end

      def component_bounds(components, anchors, completed)
        bounds = []

        components.each_with_index do |component, index|
          child = completed[component.glyph_id]
          next unless child && child.bbox

          x, y = anchors[index]
          x_min, y_min, x_max, y_max = child.bbox
          bounds << [x_min + x, y_min + y, x_max + x, y_max + y]
        end

        return [0, 0, 0, 0] if bounds.empty?

        [
          bounds.map { |b| b[0] }.min,
          bounds.map { |b| b[1] }.min,
          bounds.map { |b| b[2] }.max,
          bounds.map { |b| b[3] }.max,
        ]
      end

      def order_by_component_depth(ids)
        depth = {}

        depth_of = lambda do |id|
          next depth[id] if depth.key?(id)

          glyph = @file.glyph_outlines.for(id)
          depth[id] =
            if glyph&.compound?
              children = glyph.glyph_ids
              1 + children.map { |child_id| depth_of.call(child_id) }.max
            else
              0
            end
        end

        ids.sort_by { |id| [depth_of.call(id), id] }
      end

      def non_negative(value)
        value.negative? ? 0 : value
      end

      def non_negative_bearing(value)
        value
      end
    end
  end
end
