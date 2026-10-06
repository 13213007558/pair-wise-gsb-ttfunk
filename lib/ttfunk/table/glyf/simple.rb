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

        # On-curve flags for every coordinate.
        # @return [Array<Integer>]
        attr_reader :coordinate_flags

        # Absolute glyph coordinates.
        # @return [Array<Array(Integer, Integer)>]
        attr_reader :coordinates

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

          parse_coordinates(io)
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
          end_points_of_contours.any? ? end_points_of_contours.last + 1 : 0
        end

        # Replace coordinates and return a recoded glyph.
        #
        # @param new_coordinates [Array<Array(Integer, Integer)>]
        # @return [String]
        def recode_with_coordinates(new_coordinates)
          @coordinates = new_coordinates
          xs = new_coordinates.map(&:first)
          ys = new_coordinates.map(&:last)
          @x_min = xs.min || 0
          @x_max = xs.max || 0
          @y_min = ys.min || 0
          @y_max = ys.max || 0
          @raw = encode
        end

        private

        def parse_coordinates(io)
          point_count = end_point_of_last_contour
          @coordinate_flags = []

          while @coordinate_flags.length < point_count
            flag = io.read(1).unpack1('C')

            if (flag & 0x08).nonzero?
              repeat_count = io.read(1).unpack1('C') + 1
            else
              repeat_count = 1
            end

            @coordinate_flags.concat(Array.new(repeat_count, flag & ~0x08))
          end

          xs = read_coordinate_values(io, @coordinate_flags, 0x02, 0x10)
          ys = read_coordinate_values(io, @coordinate_flags, 0x04, 0x20)
          @coordinates = xs.zip(ys)
        end

        def read_coordinate_values(io, flags, short_flag, same_or_word_flag)
          values = []

          flags.each do |flag|
            if (flag & short_flag).nonzero?
              delta = io.read(1).unpack1('C')
              delta = -delta if (flag & same_or_word_flag).zero?
            elsif (flag & short_flag).zero? && (flag & same_or_word_flag).nonzero?
              delta = 0
            else
              delta = io.read(2).unpack1('s>')
            end

            values << (values.last || 0) + delta
          end

          values
        end

        def encode
          encoded_coordinates = coordinates
          header = [
            number_of_contours,
            x_min, y_min, x_max, y_max,
          ].pack('n*')

          endpoints = end_points_of_contours.pack('n*')
          instruction_data = [instruction_length].pack('n') + instructions.pack('C*')
          x_values = encoded_coordinates.map(&:first)
          y_values = encoded_coordinates.map(&:last)
          x_deltas = relative_coordinates(x_values)
          y_deltas = relative_coordinates(y_values)
          x_flag_bits = encode_coordinate_flags(
            x_deltas, short_flag: 0x02, same_or_word_flag: 0x10,
          )
          y_flag_bits = encode_coordinate_flags(
            y_deltas, short_flag: 0x04, same_or_word_flag: 0x20,
          )
          flags = encoded_coordinates.each_with_index.map do |_coordinate, index|
            (coordinate_flags[index] & 0x01) |
              x_flag_bits[index] | y_flag_bits[index]
          end.pack('C*')
          coordinates_data =
            encode_coordinate_values(x_deltas) +
            encode_coordinate_values(y_deltas)

          header + endpoints + instruction_data + flags + coordinates_data
        end

        def relative_coordinates(values)
          values.each_with_index.map do |value, index|
            value - (index.zero? ? 0 : values[index - 1])
          end
        end

        def encode_coordinate_flags(deltas, short_flag:, same_or_word_flag:)
          deltas.map do |delta|
            coordinate_flag_bits(
              delta,
              short_flag: short_flag,
              same_or_word_flag: same_or_word_flag,
            )
          end
        end

        def coordinate_flag_bits(delta, short_flag:, same_or_word_flag:)
          if delta.zero?
            same_or_word_flag
          elsif delta.abs <= 255
            delta.positive? ? short_flag | same_or_word_flag : short_flag
          else
            0
          end
        end

        def encode_coordinate_values(values)
          values.each_with_object(+'') do |delta, data|
            if delta.zero?
              next
            elsif delta.abs <= 255
              data << [delta.abs].pack('C')
            else
              data << [delta].pack('s>')
            end
          end
        end
      end
    end
  end
end
