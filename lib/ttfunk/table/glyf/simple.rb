# frozen_string_literal: true

require_relative '../../reader'

module TTFunk
  class Table
    class Glyf
      # Simple TrueType glyph
      class Simple
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

        # Outline points in glyf storage order.
        # @return [Array<Hash>]
        attr_reader :points

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
            io.read(10).unpack('n5').map { |i|
              BinUtils.twos_comp_to_int(i, bit_width: 16)
            }

          @end_points_of_contours = io.read(number_of_contours * 2).unpack('n*')
          @instruction_length = io.read(2).unpack1('n')
          @instructions = io.read(instruction_length).unpack('C*')
          parse_points(io)
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

        private
        def parse_points(io)
          @points = []
          flags = []

          while flags.length < end_point_of_last_contour
            flag = io.read(1).unpack1('C')
            if (flag & 0x08) == 0x08
              repeat_count = io.read(1).unpack1('C')
              (repeat_count + 1).times { flags << flag }
            else
              flags << flag
            end
          end

          x_coordinates = read_coordinates(io, flags, short_bit: 0x02, same_bit: 0x10)
          y_coordinates = read_coordinates(io, flags, short_bit: 0x04, same_bit: 0x20)
          x = 0
          y = 0

          flags.each_with_index do |flag, index|
            x += x_coordinates[index]
            y += y_coordinates[index]
            @points << {
              x: x,
              y: y,
              on_curve: (flag & 0x01) == 0x01,
            }
          end
        end

        def read_coordinates(io, flags, short_bit:, same_bit:)
          flags.map do |flag|
            if (flag & short_bit).positive?
              value = io.read(1).unpack1('C')
              (flag & same_bit).positive? ? value : -value
            elsif (flag & same_bit).positive?
              0
            else
              io.read(2).unpack1('s>')
            end
          end
        end
      end
    end
  end
end
