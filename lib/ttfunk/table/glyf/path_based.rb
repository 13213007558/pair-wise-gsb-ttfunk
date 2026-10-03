# frozen_string_literal: true

require_relative 'true_type_path_encoder'

module TTFunk
  class Table
    class Glyf
      # TrueType-compatible representation of a CFF glyph.
      class PathBased
        # Raised when a CFF glyph cannot be converted to TrueType safely.
        class ConversionError < TTFunk::Error; end

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
        # @param tolerance [Numeric, nil] maximum total error in font units
        # @param glyph_id [Integer, nil] source glyph identifier
        def initialize(path, horizontal_metrics, tolerance = nil, glyph_id = nil)
          @path = path
          @horizontal_metrics = horizontal_metrics
          @tolerance = tolerance
          @glyph_id = glyph_id

          coordinates = path.commands.reject { |command| command[0] == :close }.flat_map { |command|
            command[1..].each_slice(2).to_a
          }

          @x_min, @x_max = coordinates.map(&:first).minmax
          @y_min, @y_max = coordinates.map(&:last).minmax
          @x_min ||= @y_min = @x_max = @y_max = 0

          @left_side_bearing = horizontal_metrics.left_side_bearing
          @right_side_bearing =
            horizontal_metrics.advance_width -
            @left_side_bearing -
            (@x_max - @x_min)
        end

        # Convert and serialize this glyph as a TrueType simple glyph.
        #
        # @param _mapping Unused, here for API compatibility.
        # @return [String]
        def recode(_mapping = nil)
          true_type_encoding[:raw]
        end

        # Point indices for the last point of each contour.
        #
        # @return [Array<Integer>]
        def end_points_of_contours
          true_type_encoding[:end_points_of_contours]
        end

        def right_side_bearing
          return super unless @tolerance
          return @horizontal_metrics.advance_width - left_side_bearing if empty?

          @horizontal_metrics.advance_width -
            left_side_bearing -
            (x_max - x_min)
        end

        # Total number of bytes for instructions. Converted CFF glyphs are
        # always unhinted.
        #
        # @return [0]
        def instruction_length
          0
        end

        # Instruction byte code. Converted CFF glyphs are always unhinted.
        #
        # @return [Array<Integer>]
        def instructions
          []
        end

        # End point index of last contour.
        #
        # @return [Integer]
        def end_point_of_last_contour
          end_points_of_contours.last.to_i + (number_of_contours.zero? ? 0 : 1)
        end

        # Is this glyph empty in the output glyf table?
        #
        # @return [Boolean]
        def empty?
          return false unless @tolerance

          true_type_encoding[:raw].empty?
        end

        def x_min
          converted_bound(:x_min) { @x_min }
        end

        def y_min
          converted_bound(:y_min) { @y_min }
        end

        def x_max
          converted_bound(:x_max) { @x_max }
        end

        def y_max
          converted_bound(:y_max) { @y_max }
        end

        # Number of contour.
        #
        # @return [Integer]
        def number_of_contours
          @tolerance ? true_type_encoding[:number_of_contours] : path.number_of_contours
        end

        # Is this glyph compound?
        #
        # @return [false]
        def compound?
          false
        end

        private

        def true_type_encoding
          @true_type_encoding ||=
            begin
              raise ArgumentError, 'TrueType outline conversion tolerance is required' unless @tolerance

              TrueTypePathEncoder.encode(path, @tolerance, @glyph_id)
            end
        end

        def converted_bound(name)
          return yield unless @tolerance

          encoding = true_type_encoding
          encoding[:raw].empty? ? 0 : encoding.fetch(name)
        end
      end
    end
  end
end
