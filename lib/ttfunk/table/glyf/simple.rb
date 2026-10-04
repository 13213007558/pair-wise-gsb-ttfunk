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

        # Total number of bytes for instructions.
        # @return [Integer]
        attr_reader :instruction_length

        # Instruction byte code.
        # @return [Array<Integer>]
        attr_reader :instructions

        # Coordinate flags, including one entry per expanded repeat.
        # @return [Array<Integer>]
        attr_reader :coordinate_flags

        # Absolute X coordinates.
        # @return [Array<Integer>]
        attr_reader :x_coordinates

        # Absolute Y coordinates.
        # @return [Array<Integer>]
        attr_reader :y_coordinates

        # Absolute X coordinates.
        # @return [Array<Integer>]
        attr_reader :x_coordinates

        # Simple glyph flag bytes.
        # @return [Array<Integer>]
        attr_reader :coordinate_flags

        # End point indices for each contour.
        # @return [Array<Integer>]
        attr_reader :end_points_of_contours

        # True glyph instruction bytes.
        # @return [Array<Integer>]
        attr_reader :instructions

        # @param id [Integer] glyph ID.
        # @param raw [String]
        def initialize(id, raw)
          @id = id
          @raw = raw
          io = StringIO.new(raw)

          @number_of_contours, @x_min, @y_min, @x_max, @y_max =
            io.read(10).unpack('s>4n').map.with_index do |value, index|
              index.zero? ? value : BinUtils.twos_comp_to_int(value, bit_width: 16)
            end

        @end_points_of_contours = io.read(@number_of_contours * 2).unpack('n*')
        @instruction_length = io.read(2).unpack1('n')
        @instructions = io.read(@instruction_length).unpack('C*')

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

      X_SHORT_FLAG = 0x02
      Y_SHORT_FLAG = 0x04
      SAME_X_FLAG = 0x10
      SAME_Y_FLAG = 0x20
      REPEAT_FLAG = 0x08
      private_constant :X_SHORT_FLAG, :Y_SHORT_FLAG, :SAME_X_FLAG, :SAME_Y_FLAG, :REPEAT_FLAG

      def deltas_for(values)
        previous = 0
        values.map do |value|
          delta = value - previous
          previous = value
          delta
        end
      end

      def encoded_deltas(deltas, x_axis:)
        short_flag = x_axis ? X_SHORT_FLAG : Y_SHORT_FLAG
        same_flag = x_axis ? SAME_X_FLAG : SAME_Y_FLAG
        flags = []
        bytes = +''.b

        deltas.each do |delta|
          flag = coordinate_flags[flags.length]

          if delta.zero?
            flag |= same_flag
          elsif delta.abs <= 0xFF
            flag |= short_flag | (delta.positive? ? same_flag : 0)
            bytes << delta.abs
          else
            bytes << [delta].pack('s>')
          end

          flags << flag
        end

        [flags, bytes]
      end

      def encode_coordinate_values(deltas, flags, short_flag, same_flag)
        bytes = +''.b

        deltas.each_with_index do |delta, index|
          flag = flags[index]
          flag &= ~(short_flag | same_flag)

          if delta.zero?
            flag |= same_flag
          elsif delta.abs <= 0xFF
            flag |= short_flag
            flag |= same_flag if delta.positive?
            bytes << delta.abs
          else
            bytes << [delta].pack('s>')
          end
          flags[index] = flag
        end

        bytes
      end

      def encode_flags(flags)
        flags.pack('C*')
      end

        # End point index of last contour.
        # @return [Integer]
      def end_point_of_last_contour
        end_points_of_contours.last + 1
      end

      def encode_with_coordinates(coordinates)
        flags = nil
        xs = +''.b
        ys = +''.b
        x_coordinates = coordinates.map(&:first)
        y_coordinates = coordinates.map(&:last)
        x_deltas = deltas_for(x_coordinates)
        y_deltas = deltas_for(y_coordinates)
        flags = Array.new(x_coordinates.length) do |index|
          coordinate_flags.fetch(index)
        end
        xs = encode_coordinate_values(x_deltas, flags, X_SHORT_FLAG, SAME_X_FLAG)
        ys = encode_coordinate_values(y_deltas, flags, Y_SHORT_FLAG, SAME_Y_FLAG)
        encoded_flags = encode_flags(flags)

        ''.b.tap do |glyph|
          glyph << [
            number_of_contours,
            x_coordinates.min,
            y_coordinates.min,
            x_coordinates.max,
            y_coordinates.max,
          ].pack('s>5')
          glyph << end_points_of_contours.pack('n*')
          glyph << [instructions.length, *instructions].pack('nC*')
          glyph << encoded_flags
          glyph << xs
          glyph << ys
        end
      end

        private

      ON_CURVE = 0x01
      X_SHORT = 0x02
        Y_SHORT = 0x04
        REPEAT = 0x08
        SAME_X = 0x10
        SAME_Y = 0x20
        private_constant :ON_CURVE, :X_SHORT, :Y_SHORT, :REPEAT, :SAME_X, :SAME_Y

        def parse_coordinates(io)
          @coordinate_flags = []
          while @coordinate_flags.length < end_point_of_last_contour
            flag = io.read(1).unpack1('C')
            count = 1
            count += io.read(1).unpack1('C') if flag.allbits?(REPEAT)
            @coordinate_flags.concat(Array.new(count, flag))
          end

          @x_coordinates = absolute_coordinates(io, X_SHORT, SAME_X)
          @y_coordinates = absolute_coordinates(io, Y_SHORT, SAME_Y)
        end

        def absolute_coordinates(io, short_flag, same_flag)
          values = []
          coordinate_flags.each do |flag|
            delta =
              if flag.allbits?(short_flag)
                value = io.read(1).unpack1('C')
                flag.allbits?(same_flag) ? value : -value
              elsif flag.allbits?(same_flag)
                0
              else
                BinUtils.twos_comp_to_int(io.read(2).unpack1('n'), bit_width: 16)
              end

            values << (values.last || 0) + delta
          end
          values
        end

        def deltas_for(values)
          previous = 0
          values.map do |value|
            delta = value - previous
            previous = value
            delta
          end
        end

        def encoded_deltas(deltas, x_axis:)
          flags = []
          bytes = +''

          deltas.each_with_index do |delta, index|
            flag = coordinate_flags[index]
            short = x_axis ? X_SHORT : Y_SHORT
            same = x_axis ? SAME_X : SAME_Y

            if delta.zero?
              flag |= same
            elsif delta.abs <= 0xFF
              flag |= short
              flag |= same if delta.positive?
              bytes << [delta.abs].pack('C')
            else
              bytes << [delta].pack('s>')
            end

            flags << flag
          end

          [flags, bytes]
        end

        def encode_flags(flags)
          encoded = +''
          index = 0

          while index < flags.length
            flag = flags[index]
            run = 1
            run += 1 while index + run < flags.length && flags[index + run] == flag

            if run > 1 && flag.nobits?(REPEAT)
              encoded << [flag | REPEAT, run - 1].pack('C2')
              index += run
            else
              encoded << [flag].pack('C')
              index += 1
            end
          end

          encoded
        end

        public

        def on_curve?(index)
          coordinate_flags[index].allbits?(ON_CURVE)
        end
      end
    end
  end
end
