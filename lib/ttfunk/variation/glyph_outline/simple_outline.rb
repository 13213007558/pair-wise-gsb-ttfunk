# frozen_string_literal: true

module TTFunk
  module Variation
    module GlyphOutline
      # Decoded simple (non-compound) TrueType glyph.
      class SimpleOutline
        include GlyphOutline

        # @return [Integer] number of contours (negative contours are stored
        #   as-is by the parser, though TrueType hinting rarely uses them).
        attr_reader :number_of_contours

        # @return [Array<Integer>] indices of the last point of each contour.
        attr_reader :end_points_of_contours

        # @return [Array<Integer>] per-point on-curve flag (0 or 1).
        attr_reader :on_curve

        # @return [String] glyph instruction bytecode.
        attr_reader :instructions

        # @return [Array<Integer>] x coordinate of every point.
        attr_accessor :coordinates_x

        # @return [Array<Integer>] y coordinate of every point.
        attr_accessor :coordinates_y

        # Decode a simple glyph.
        #
        # @param raw [String] the glyph's bytes as stored in `glyf`.
        # @return [SimpleOutline]
        def self.decode(raw)
          new(raw)
        end

        def initialize(raw)
          io = StringIO.new(raw)

          @number_of_contours = read_int16(io)
          unless @number_of_contours >= 0
            raise Error,
              "unsupported negative contour count (#{@number_of_contours})"
          end
          @x_min = read_int16(io)
          @y_min = read_int16(io)
          @x_max = read_int16(io)
          @y_max = read_int16(io)

          @end_points_of_contours =
            io.read(@number_of_contours * 2).unpack('n*')

          instruction_length = io.read(2).unpack1('n')
          @instructions = io.read(instruction_length).b

          point_count = end_point_of_last_contour
          flags = read_flags(io, point_count)
          @on_curve = flags.map { |flag| flag & ON_CURVE }
          @coordinates_x = read_coordinates(io, flags, true)
          @coordinates_y = read_coordinates(io, flags, false)
        end

        # @return [Integer] total number of points.
        def point_count
          coordinates_x.length
        end

        # @return [Integer] index of the final point.
        def end_point_of_last_contour
          end_points_of_contours.last + 1
        end

        # Encode the glyph back into the `glyf` binary format using the
        # current coordinates and bounding box. Flags are rebuilt, so the
        # coordinate streams are always optimally (re)packed; instructions
        # are preserved verbatim.
        #
        # @return [String]
        def encode
          flags = build_flags
          flag_bytes = encode_flags(flags)

          body = +''
          body << [number_of_contours].pack('s>')
          body << pack_bounds
          body << end_points_of_contours.pack('n*')
          body << [@instructions.length].pack('n')
          body << @instructions
          body << flag_bytes
          body << encode_coordinates(coordinates_x, flags, true)
          body << encode_coordinates(coordinates_y, flags, false)
          body
        end

        private

        def read_int16(io)
          io.read(2).unpack1('s>')
        end

        # Expand the flag stream (handling the repeat flag) into one flag
        # byte per point.
        def read_flags(io, point_count)
          flags = []
          while flags.length < point_count
            flag = io.read(1).unpack1('C')
            if flag & REPEAT != 0
              repeat_count = io.read(1).unpack1('C')
              total = repeat_count + 1
              remaining = point_count - flags.length
              count = [total, remaining].min
              flags.concat([flag] * count)
            else
              flags << flag
            end
          end
          flags
        end

        # Decode the delta-encoded coordinate stream for one axis.
        def read_coordinates(io, flags, x_axis)
          short_bit = x_axis ? X_SHORT : Y_SHORT
          same_bit = x_axis ? X_SAME : Y_SAME

          values = []
          current = 0

          flags.each do |flag|
            delta =
              if flag & short_bit != 0
                value = io.read(1).unpack1('C')
                value = -value if flag & same_bit == 0
                value
              elsif flag & same_bit != 0
                0
              else
                bytes = io.read(2)
                raise Error, "#{x_axis ? 'x' : 'y'} long overrun at #{io.pos} of #{io.length} flag=#{flag.to_s(16)}" if bytes.nil?
                bytes.unpack1('s>')
              end

            current += delta
            values << current
          end

          values
        end

        # Build a minimal per-point flag byte (on-curve bit + coordinate
        # encoding bits for the current deltas).
        def build_flags
          x_deltas = deltas_for(coordinates_x)
          y_deltas = deltas_for(coordinates_y)

          Array.new(point_count) do |index|
            flag = on_curve[index] || 0
            flag |= coordinate_flags(x_deltas[index], X_SHORT, X_SAME)
            flag |= coordinate_flags(y_deltas[index], Y_SHORT, Y_SAME)
            flag
          end
        end

        def deltas_for(coordinates)
          previous = 0
          coordinates.map do |coordinate|
            delta = coordinate - previous
            previous = coordinate
            delta
          end
        end

        # Choose the shortest encoding for a coordinate delta.
        def coordinate_flags(delta, short_bit, same_bit)
          return same_bit if delta.zero?

          if (-255..255).cover?(delta)
            short_bit | (delta.positive? ? same_bit : 0)
          else
            0
          end
        end

        # Encode per-point flags, collapsing runs into REPEAT groups.
        def encode_flags(flags)
          bytes = +''
          index = 0

          while index < flags.length
            flag = flags[index]
            run_length = 1
            while index + run_length < flags.length &&
                  flags[index + run_length] == flag &&
                  run_length < 256
              run_length += 1
            end

            if run_length >= 2
              bytes << [flag | REPEAT, run_length - 1].pack('C2')
            else
              bytes << [flag].pack('C')
            end

            index += run_length
          end

          bytes
        end

        def encode_coordinates(coordinates, flags, x_axis)
          short_bit = x_axis ? X_SHORT : Y_SHORT
          same_bit = x_axis ? X_SAME : Y_SAME
          bytes = +''
          previous = 0

          coordinates.each_with_index do |coordinate, index|
            delta = coordinate - previous
            previous = coordinate
            flag = flags[index]

            if flag & short_bit != 0
              value = delta.abs
              bytes << [value].pack('C')
            elsif flag & same_bit == 0
              bytes << [delta].pack('s>')
            end
          end

          bytes
        end
      end
    end
  end
end
