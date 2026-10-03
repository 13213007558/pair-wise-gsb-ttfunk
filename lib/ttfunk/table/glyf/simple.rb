# frozen_string_literal: true

require_relative '../../reader'
require_relative 'outline'

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

        # Point flag bit 4: x-coordinate is the same as the previous one (or
        # the stored x-coordinate is positive when X_SHORT_VECTOR is set).
        X_IS_SAME_OR_POSITIVE = 0x10

        # Point flag bit 5: y-coordinate is the same as the previous one (or
        # the stored y-coordinate is positive when Y_SHORT_VECTOR is set).
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
        def initialize(id, raw)
          @id = id
          @raw = raw
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

        # End point index of last contour.
        # @return [Integer]
        def end_point_of_last_contour
          end_points_of_contours.last + 1
        end

        # Points of this glyph in glyph order.
        #
        # @return [Array<TTFunk::Table::Glyf::OutlinePoint>]
        def points
          @points ||= parse_points
        end

        # Expand this glyph into an outline. For simple glyphs this is the
        # glyph's own points and metrics.
        #
        # @param _glyf_table Unused, here for API compatibility with
        #   {TTFunk::Table::Glyf::Compound#decompose}.
        # @param hmtx_table [TTFunk::Table::Hmtx] horizontal metrics table.
        # @param _chain Unused, here for API compatibility with
        #   {TTFunk::Table::Glyf::Compound#decompose}.
        # @return [TTFunk::Table::Glyf::Outline]
        def decompose(_glyf_table, hmtx_table, _chain = [])
          Outline.new(
            points,
            end_points_of_contours,
            hmtx_table.for(id),
          )
        end

        private

        def parse_points
          point_count = end_point_of_last_contour
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

          xs = decode_coordinates(
            io, flags, point_count, X_SHORT_VECTOR, X_IS_SAME_OR_POSITIVE
          )
          ys = decode_coordinates(
            io, flags, point_count, Y_SHORT_VECTOR, Y_IS_SAME_OR_POSITIVE
          )

          Array.new(point_count) { |i|
            OutlinePoint.new(xs[i], ys[i], flags[i].allbits?(ON_CURVE_POINT))
          }
        end

        def decode_coordinates(io, flags, point_count, short_bit, same_bit)
          coordinates = []
          current = 0

          point_count.times do |i|
            flag = flags[i]
            if flag.allbits?(short_bit)
              delta = io.read(1).unpack1('C')
              current += flag.allbits?(same_bit) ? delta : -delta
            elsif flag.nobits?(same_bit)
              current += BinUtils.twos_comp_to_int(
                io.read(2).unpack1('n'),
                bit_width: 16,
              )
            end
            coordinates << current
          end

          coordinates
        end
      end
    end
  end
end
