# frozen_string_literal: true

module TTFunk
  module Variation
    class Instance
      # One glyph of the static instance: the result of applying the glyph's
      # `gvar` deltas (including the phantom-point deltas that drive
      # horizontal metrics) at the requested location.
      class InstantiatedGlyph
        ARG_1_AND_2_ARE_WORDS = 0x0001
        ARGS_ARE_XY_VALUES = 0x0002

        # @return [Integer] glyph id.
        attr_reader :glyph_id

        # @return [Integer] instanced advance width.
        attr_reader :advance_width

        # @return [Integer] instanced left side bearing.
        attr_reader :left_side_bearing

        # @return [Array(Integer, Integer, Integer, Integer)] xMin, yMin,
        #   xMax, yMax.
        attr_reader :bounds

        # @return [String] encoded glyf table bytes for this glyph.
        attr_reader :raw

        # @param glyph_id [Integer]
        # @param raw_glyph [TTFunk::Table::Glyf::Simple,
        #   TTFunk::Table::Glyf::Compound, nil]
        # @param metric [TTFunk::Table::Hmtx::HorizontalMetric]
        # @param variations [Array] decoded gvar tuples.
        # @param location [Hash{String => Float}] mapped normalized location.
        # @param bounds_resolver [#call] callable returning the resolved
        #   InstantiatedGlyph of a component glyph id.
        def initialize(glyph_id, raw_glyph, metric, variations, location,
                       bounds_resolver)
          @glyph_id = glyph_id
          @raw_glyph = raw_glyph
          @metric = metric
          @variations = variations
          @location = location
          @bounds_resolver = bounds_resolver

          apply
        end

        def compound?
          @raw_glyph&.compound? || false
        end

        def blank?
          @raw_glyph.nil?
        end

        # @return [Integer] outline point count (simple) or component count
        #   (composite), for maxp statistics.
        def outline_size
          return 0 unless @raw_glyph

          if @raw_glyph.compound?
            @raw_glyph.glyph_ids.length
          else
            @raw_glyph.end_point_of_last_contour
          end
        end

        # @return [Integer] number of contours for a simple glyph.
        def number_of_contours
          @raw_glyph&.number_of_contours || 0
        end

        # @return [Array<Integer>] component glyph ids (composite only).
        def component_ids
          @raw_glyph&.glyph_ids || []
        end

        # Resolve the composite bounding box after all referenced component
        # glyphs have been built. Called by Instance during its second pass.
        #
        # @return [void]
        def resolve_composite
          outline = @pending_outline
          bounds = composite_bounds(outline)
          outline.bounds = bounds
          @raw = outline.encode
          assign_metrics(@pending_coordinates, @pending_deltas, bounds)
          @pending_outline = nil
        end

        # @return [Integer] byte length of the glyph's instructions.
        def instruction_length
          @raw_glyph&.respond_to?(:instruction_length) ?
            @raw_glyph.instruction_length : 0
        end

        private

        def apply
          if @raw_glyph.nil?
            apply_blank
          elsif @raw_glyph.compound?
            apply_compound
          else
            apply_simple
          end
        end

        def apply_blank
          @raw = +''
          @bounds = [0, 0, 0, 0]

          # Empty glyphs have no outline, but gvar may still move their four
          # phantom points, changing the advance width.
          coordinates = phantom_points(@metric, 0, 0)
          deltas = sum_deltas(coordinates, [])

          if deltas
            left_x = coordinates[-4][0] + deltas[-4][0]
            right_x = coordinates[-3][0] + deltas[-3][0]
            @advance_width = [ot_round(right_x - left_x), 0].max
            left_x = ot_round(left_x)
            @left_side_bearing = -left_x
          else
            @advance_width = @metric.advance_width
            @left_side_bearing = @metric.left_side_bearing
          end
        end

        def apply_simple
          outline = GlyphOutline::SimpleOutline.decode(@raw_glyph.raw)
          coordinates = outline.coordinates_x.zip(outline.coordinates_y)
          coordinates.concat(
            phantom_points(@metric, outline.x_min, outline.x_max)
          )

          deltas = sum_deltas(
            coordinates, outline.end_points_of_contours
          )

          if deltas
            outline.coordinates_x.each_index do |index|
              outline.coordinates_x[index] =
                ot_round(coordinates[index][0] + deltas[index][0])
              outline.coordinates_y[index] =
                ot_round(coordinates[index][1] + deltas[index][1])
            end
          end

          bounds = [
            outline.coordinates_x.min,
            outline.coordinates_y.min,
            outline.coordinates_x.max,
            outline.coordinates_y.max,
          ]
          outline.bounds = bounds
          @raw = outline.encode

          assign_metrics(coordinates, deltas, bounds)
        end

        def apply_compound
          outline = GlyphOutline::CompoundOutline.decode(@raw_glyph.raw)
          coordinates = outline.components.map do |component|
            [component.arg1, component.arg2]
          end
          coordinates.concat(
            phantom_points(@metric, outline.x_min, outline.x_max)
          )

          deltas = sum_deltas(
            coordinates, outline.components.each_index.to_a
          )

          if deltas
            outline.components.each_with_index do |component, index|
              # gvar only moves XY-offset arguments; point-matched anchors
              # are left untouched. Argument size (bytes/words) is fixed up
              # when the glyph is re-encoded.
              next if component.flags & ARGS_ARE_XY_VALUES == 0

              component.arg1 = clamp_int16(
                ot_round(coordinates[index][0] + deltas[index][0])
              )
              component.arg2 = clamp_int16(
                ot_round(coordinates[index][1] + deltas[index][1])
              )
            end
          end

          # Bounds are resolved separately (see Instance#build_glyphs)
          # because components may reference other glyphs.
          @pending_outline = outline
          @pending_coordinates = coordinates
          @pending_deltas = deltas
        end

        def composite_bounds(outline)
          x_min = y_min = x_max = y_max = nil

          outline.components.each do |component|
            child = @bounds_resolver.call(component.glyph_index)
            next unless child && !child.blank?

            child_bounds = child.bounds
            next if degenerate_bounds?(child_bounds)

            tx = component.arg1
            ty = component.arg2

            corners = transformed_corners(
              child_bounds,
              GlyphOutline::CompoundOutline.matrix_for(component),
              tx, ty
            )

            corners.each do |x, y|
              x_min = safe_min(x_min, x)
              y_min = safe_min(y_min, y)
              x_max = safe_max(x_max, x)
              y_max = safe_max(y_max, y)
            end
          end

          [x_min || 0, y_min || 0, x_max || 0, y_max || 0]
        end

        def transformed_corners(bounds, matrix, tx, ty)
          cx_min, cy_min, cx_max, cy_max = bounds
          corners = [
            [cx_min, cy_min], [cx_min, cy_max],
            [cx_max, cy_min], [cx_max, cy_max],
          ]
          return corners.map { |x, y| [x + tx, y + ty] } unless matrix

          xx, yx, xy, yy = matrix
          corners.map do |x, y|
            [ot_round(xx * x + xy * y + tx),
             ot_round(yx * x + yy * y + ty)]
          end
        end

        def degenerate_bounds?(bounds)
          bounds[0] == bounds[2] || bounds[1] == bounds[3]
        end

        # Four phantom points. Without a vmtx table the vertical phantoms
        # are (0, 0), matching the OpenType and fontTools reference.
        def phantom_points(metric, x_min, _x_max)
          left_x = x_min - metric.left_side_bearing
          right_x = left_x + metric.advance_width
          [[left_x, 0], [right_x, 0], [0, 0], [0, 0]]
        end

        def assign_metrics(coordinates, deltas, bounds)
          @bounds = bounds

          left_delta = deltas ? deltas[-4][0] : 0.0
          right_delta = deltas ? deltas[-3][0] : 0.0
          left_x = coordinates[-4][0] + left_delta
          right_x = coordinates[-3][0] + right_delta
          @advance_width = [ot_round(right_x - left_x), 0].max
          left_x = ot_round(left_x)
          @left_side_bearing = bounds[0] - left_x
        end

        def sum_deltas(coordinates, contour_ends)
          total = nil
          @variations.each do |variation|
            scalar = Scalar.for_region(variation.axes, @location)
            next if scalar.zero?

            deltas = Iup.expand(variation.deltas, coordinates, contour_ends)
            total ||= Array.new(deltas.length) { [0.0, 0.0] }
            deltas.each_with_index do |(dx, dy), index|
              total[index][0] += dx * scalar
              total[index][1] += dy * scalar
            end
          end
          total
        end

        def ot_round(value)
          (value + 0.5).floor
        end

        def clamp_int16(value)
          [[value, 32_767].min, -32_768].max.to_i
        end

        def safe_min(current, candidate)
          current.nil? ? candidate : [current, candidate].min
        end

        def safe_max(current, candidate)
          current.nil? ? candidate : [current, candidate].max
        end
      end
    end
  end
end
