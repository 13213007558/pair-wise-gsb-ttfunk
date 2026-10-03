# frozen_string_literal: true

require_relative '../../reader'

module TTFunk
  class Table
    class Glyf
      # Simple TrueType glyph
      class Simple
        # Point flag bit 0: point is on the curve.
        ON_CURVE_POINT = 0x01

        # Point flag bit 1: x-coordinate is 1 byte long.
        X_SHORT_VECTOR = 0x02

        # Point flag bit 2: y-coordinate is 1 byte long.
        Y_SHORT_VECTOR = 0x04

        # Point flag bit 3: next byte specifies the number of additional
        # times this flag is to be repeated.
        REPEAT_FLAG = 0x08

        # Point flag bit 4: x-coordinate is the same as the previous one or,
        # for a short vector, positive.
        X_IS_SAME_OR_POSITIVE = 0x10

        # Point flag bit 5: y-coordinate is the same as the previous one or,
        # for a short vector, positive.
        Y_IS_SAME_OR_POSITIVE = 0x20

        # Glyph ID.
        # @return [Integer]
        attr_reader :id

        # Binary serialization of this glyph.
        # @return [String]
        attr_reader :raw

        # Number of contours in this glyph.
        # @return [Integer]
        attr_reader :number_of_contours

        # Minimum x for coordinate.
        # @return [Integer]
        attr_reader :x_min

        # Minimum y for coordinate.
        # @return [Integer]
        attr_reader :y_min

        # Maximum x for coordinate.
        # @return [Integer]
        attr_reader :x_max

        # Maximum y for coordinate.
        # @return [Integer]
        attr_reader :y_max

        # Point indices for the last point of each contour.
        # @return [Array<Integer>]
        attr_reader :end_points_of_contours

        # Total number of bytes for instructions.
        # @return [Integer]
        attr_reader :instruction_length

        # Instruction byte code.
        # @return [Array<Integer>]
        attr_reader :instructions

        # @param id [Integer] glyph ID.
        # @param raw [String]
        # @param file [TTFunk::File, nil] font file this glyph belongs to.
        #   Needed for outline expansion.
        def initialize(id, raw, file = nil)
          @id = id
          @raw = raw
          @file = file
          io = StringIO.new(raw)

          @number_of_contours, @x_min, @y_min, @x_max, @y_max =
            io.read(10).unpack('n*').map { |i|
              BinUtils.twos_comp_to_int(i, bit_width: 16)
            }

          @end_points_of_contours = io.read(number_of_contours * 2).unpack('n*')
          @instruction_length = io.read(2).unpack1('n')
          @instructions = io.read(instruction_length).unpack('C*')
        end

        # Is this glyph compound?
        # @return [false]
        def compound?
          false
        end

        # Recode glyph.
        #
        # @param _mapping Unused, here for API compatibility.
        # @return [String]
        def recode(_mapping)
          raw
        end

        # Expand this glyph into a full outline with effective horizontal
        # metrics.
        #
        # @return [TTFunk::Table::Glyf::Outline]
        # @raise [TTFunk::Error] if the glyph was loaded without a font file
        def expand
          if @file.nil?
            raise TTFunk::Error,
              'cannot expand a glyph without its font file'
          end

          parse_coordinates
          metric = @file.horizontal_metrics.for(id)

          Outline.new(
            points: @points.map(&:dup),
            end_points_of_contours: end_points_of_contours.dup,
            on_curve: @on_curve.dup,
            advance_width: metric.advance_width,
            left_side_bearing: metric.left_side_bearing,
          )
        end

        # Geometry of this glyph for use in compound glyph expansion.
        #
        # @api private
        # @param _chain [Array<Integer>] glyph chain, unused for simple glyphs
        # @return [Array(Array<Array(Numeric, Numeric)>, Array<Integer>,
        #   Array<Boolean>)] points, contour end points, and on-curve flags
        def expanded_geometry(_chain)
          parse_coordinates
          [@points, end_points_of_contours, @on_curve]
        end

        # End point index of last contour.
        # @return [Integer]
        def end_point_of_last_contour
          end_points_of_contours.last + 1
        end

        private

        def parse_coordinates
          return if @coordinates_parsed

          @coordinates_parsed = true

          point_count =
            if number_of_contours.zero?
              0
            else
              end_points_of_contours.last + 1
            end

          io = StringIO.new(raw)
          io.pos = 10 + (number_of_contours * 2) + 2 + instruction_length

          flags = []
          while flags.length < point_count
            flag = io.read(1).unpack1('C')
            flags << flag

            if flag.allbits?(REPEAT_FLAG)
              io.read(1).unpack1('C').times { flags << flag }
            end
          end

          x_coords = decode_coordinates(io, flags, point_count,
            X_SHORT_VECTOR, X_IS_SAME_OR_POSITIVE)
          y_coords = decode_coordinates(io, flags, point_count,
            Y_SHORT_VECTOR, Y_IS_SAME_OR_POSITIVE)

          @points = x_coords.zip(y_coords)
          @on_curve = flags.map { |flag| flag.allbits?(ON_CURVE_POINT) }
        end

        def decode_coordinates(io, flags, point_count, short_bit, same_bit)
          coords = []
          current = 0

          point_count.times do |i|
            flag = flags[i]

            if flag.allbits?(short_bit)
              value = io.read(1).unpack1('C')
              current += flag.allbits?(same_bit) ? value : -value
            elsif flag.nobits?(same_bit)
              current += BinUtils.twos_comp_to_int(
                io.read(2).unpack1('n'), bit_width: 16
              )
            end

            coords << current
          end

          coords
        end
      end
    end
  end
end
