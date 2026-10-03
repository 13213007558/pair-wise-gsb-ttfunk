# frozen_string_literal: true

module TTFunk
  class Table
    class Glyf
      # TrueType-compatible representation of a CFF glyph.
      class PathBased
        # Glyph outline.
        # @return [TTFunk::Table::Cff::Path]
        attr_reader :path

        # Glyph horizontal metrics.
        # @return [TTFunk::Table::Hmtx::HorizontalMetric]
        attr_reader :horizontal_metrics

        # Minimum X.
        # @return [Integer, Float]
        attr_reader :x_min

        # Minimum Y.
        # @return [Integer, Float]
        attr_reader :y_min

        # Maximum X.
        # @return [Integer, Float]
        attr_reader :x_max

        # Maximum Y.
        # @return [Integer, Float]
        attr_reader :y_max

        # Left side bearing.
        # @return [Integer, Float]
        attr_reader :left_side_bearing

        # Rigth side bearing.
        # @return [Integer, Float]
        attr_reader :right_side_bearing

        # @param path [TTFunk::Table::Cff::Path]
        # @param horizontal_metrics [TTFunk::Table::Hmtx::HorizontalMetric]
        def initialize(path, horizontal_metrics, glyph_id = nil)
          @path = path
          @horizontal_metrics = horizontal_metrics
          @glyph_id = glyph_id
          @true_type_outline = nil

          coordinates =
            path.commands.flat_map do |command|
              case command.first
              when :move, :line
                [[command[1], command[2]]]
              when :curve
                [
                  [command[1], command[2]],
                  [command[3], command[4]],
                  [command[5], command[6]],
                ]
              else
                []
              end
            end.reject { |point| point.any?(&:nil?) }
          if coordinates.empty?
            @x_min = 0
            @y_min = 0
            @x_max = 0
            @y_max = 0
          else
            @x_min = coordinates.map(&:first).min
            @y_min = coordinates.map(&:last).min
            @x_max = coordinates.map(&:first).max
            @y_max = coordinates.map(&:last).max
          end

          @left_side_bearing = horizontal_metrics.left_side_bearing
          @right_side_bearing =
            horizontal_metrics.advance_width -
            @left_side_bearing -
            (@x_max - @x_min)
        end

        # Number of contour.
        #
        # @return [Integer]
        def number_of_contours
          true_type_outline&.number_of_contours || path.number_of_contours
        end

        # Is this glyph compound?
        #
        # @return [false]
        def compound?
          false
        end

        # Recode as an unhinted TrueType simple glyph.
        #
        # @param tolerance [Numeric] maximum outline and quantization error in
        #   font units
        # @return [self]
        def convert_to_true_type(tolerance)
          advance_width = horizontal_metrics.advance_width
          unless advance_width.is_a?(Integer) &&
              advance_width >= 0 && advance_width <= 0xFFFF
            raise TTFunk::Error,
              'horizontal advance width is outside the unsigned 16-bit hmtx range'
          end

          @true_type_outline =
            QuadraticOutline.from_path(path, tolerance, glyph_id: @glyph_id)

          unless @true_type_outline.number_of_contours.zero?
            @horizontal_metrics =
              Hmtx::HorizontalMetric.new(
                horizontal_metrics.advance_width,
                @true_type_outline.x_min,
              )
          end

          self
        end

        # Recode this glyph for a TrueType font.
        #
        # @param _mapping [Hash] unused, here for API compatibility
        # @return [String]
        def recode(_mapping = nil)
          unless true_type_outline
            raise TTFunk::Error,
              'CFF path glyphs must be converted to TrueType before encoding'
          end

          true_type_outline.recode
        end

        def end_point_of_last_contour
          true_type_outline&.end_point_of_last_contour || 0
        end

        def instruction_length
          true_type_outline&.instruction_length || 0
        end

        def x_min
          true_type_outline&.number_of_contours&.zero? == false ?
            true_type_outline.x_min : @x_min
        end

        def y_min
          true_type_outline&.number_of_contours&.zero? == false ?
            true_type_outline.y_min : @y_min
        end

        def x_max
          true_type_outline&.number_of_contours&.zero? == false ?
            true_type_outline.x_max : @x_max
        end

        def y_max
          true_type_outline&.number_of_contours&.zero? == false ?
            true_type_outline.y_max : @y_max
        end

        def left_side_bearing
          horizontal_metrics.left_side_bearing
        end

        def right_side_bearing
          horizontal_metrics.advance_width -
            left_side_bearing -
            (x_max - x_min)
        end

        private

        attr_reader :true_type_outline
      end
    end
  end
end
