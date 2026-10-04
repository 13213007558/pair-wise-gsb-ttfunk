# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Glyph Variations (`gvar`) table.
    class Gvar < Table
      Tuple = Struct.new(:coordinates, :data_offset, :data_size)
      Variation = Struct.new(
        :coordinates, :intermediate, :points, :x_deltas, :y_deltas,
      )

      LONG_OFFSETS = 0x0001
      EMBEDDED_PEAK_TUPLE = 0x8000
      INTERMEDIATE_REGION = 0x4000
      PRIVATE_POINT_NUMBERS_FLAG = 0x2000

      # @return [Array<Tuple>]
      attr_reader :global_tuples

      # @return [Array<Integer>]
      attr_reader :glyph_offsets

      # Variations applied to a glyph.
      #
      # @param glyph_id [Integer]
      # @param point_count [Integer] outline points plus four phantom points
      # @return [Array<Variation>]
      def variations_for(glyph_id, point_count)
        start = glyph_offsets.fetch(glyph_id)
        finish = glyph_offsets.fetch(glyph_id + 1)
        return [] if start == finish

        parse_from(offset + start) do
          tuple_count = io.read(2).unpack1('n')
          serialized_offset_size = io.read(2).unpack1('n')
          data_offsets = []
          headers = []

          tuple_count.times do
            variation_data_size = io.read(2).unpack1('n')
            tuple_index = io.read(2).unpack1('n')
            header_position = io.pos
            shared = tuple_index.nobits?(EMBEDDED_PEAK_TUPLE)
            shared_index = tuple_index & 0x000F
            coordinates = shared ? global_tuples.fetch(shared_index).coordinates : read_tuple

            intermediate =
              if tuple_index.allbits?(INTERMEDIATE_REGION)
                [read_tuple, read_tuple]
              end

            points =
              if tuple_index.allbits?(PRIVATE_POINT_NUMBERS_FLAG)
                read_packed_points(io, point_count)
              end

            headers << {
              coordinates: coordinates,
              intermediate: intermediate,
              points: points,
              data_offset: shared ?
                global_tuples.fetch(shared_index).data_offset :
                @glyph_data_offset,
              data_size: shared ?
                global_tuples.fetch(shared_index).data_size :
                variation_data_size,
              shared: shared,
            }
          end

          shared_point_position = io.pos
          headers.map do |header|
            if header[:points].nil?
              io.pos = shared_point_position
              points = read_packed_points(io, point_count)
            else
              points = header[:points]
            end

            io.pos = header[:data_offset]
            data_start = io.pos
            x_deltas = read_deltas(points.length)
            y_deltas = read_deltas(points.length)
            unless header[:shared] || io.pos == data_start + header[:data_size]
              raise TTFunk::Error, 'invalid gvar variation data size'
            end

            Variation.new(
              header[:coordinates],
              header[:intermediate],
              points,
              x_deltas,
              y_deltas,
            )
          end
        end
      end

      # Product scalar for a tuple at the supplied normalized location.
      #
      # @param variation [Variation]
      # @param coordinates [Hash{String => Numeric}]
      # @param axis_tags [Array<String>]
      # @return [Numeric]
      def scalar_for(variation, coordinates, axis_tags)
        axis_tags.map.with_index do |axis_tag, axis_index|
          peak = variation.coordinates.fetch(axis_index)
          next Rational(0) if peak.zero?

          coordinate = coordinates.fetch(axis_tag, Rational(0))
          if variation.intermediate
            start_tuple, end_tuple = variation.intermediate
            axis_scalar(
              coordinate,
              start_tuple.fetch(axis_index),
              peak,
              end_tuple.fetch(axis_index),
            )
          else
            axis_scalar(coordinate, -peak.abs, peak, peak.abs)
          end
        end.inject(Rational(1), :*)
      end

      private

      def parse!
        parse_from(offset) do
          _major = io.read(2).unpack1('n')
          _minor = io.read(2).unpack1('n')
          _axis_count = io.read(2).unpack1('n')
          global_tuple_count = io.read(2).unpack1('n')
          global_coordinates_offset = io.read(4).unpack1('N')
          glyph_count = io.read(2).unpack1('n')
          flags = io.read(2).unpack1('n')
          long_offsets = flags.allbits?(LONG_OFFSETS)
          count = glyph_count + 1
          values = io.read(count * (long_offsets ? 4 : 2)).unpack(long_offsets ? 'N*' : 'n*')
          @glyph_offsets = long_offsets ? values : values.map { |value| value * 2 }
          glyph_data_array_offset = io.read(4).unpack1('N')
          @global_tuple_count = global_tuple_count
          @global_coordinates_offset = global_coordinates_offset
          @glyph_data_offset = offset + glyph_data_array_offset
        end

        parse_from(offset + @global_coordinates_offset) do
          @global_tuples = []

          @global_tuple_count.times do
            record_start = io.pos
            tuple_size, shared_offset = io.read(4).unpack('n2')
            coordinates = read_tuple
            coordinate_size = io.pos - record_start - 4

            @global_tuples << Tuple.new(
              coordinates,
              record_start + shared_offset,
              tuple_size - 2 - coordinate_size,
            )
          end
        end
      end

      def read_tuple
        flags = io.read(2).unpack1('n')

        file.font_variations.axes.length.times.map do |axis_index|
          short_bit = 0x8000 >> axis_index
          byte_bit = short_bit >> 8

          if flags.allbits?(short_bit)
            read_fixed(2)
          elsif flags.allbits?(byte_bit)
            read_fixed(1)
          else
            Rational(0)
          end
        end
      end

      def axis_scalar(coordinate, start_value, peak, finish)
        return Rational(0) if peak.zero?

        if peak.positive?
          return Rational(0) unless coordinate.between?(start_value, finish)

          if coordinate < peak
            return Rational(0) if start_value == peak

            Rational(coordinate - start_value) / Rational(peak - start_value)
          else
            return Rational(0) if peak == finish

            Rational(finish - coordinate) / Rational(finish - peak)
          end
        else
          return Rational(0) unless coordinate.between?(finish, start_value)

          if coordinate > peak
            return Rational(0) if start_value == peak

            Rational(start_value - coordinate) / Rational(start_value - peak)
          else
            return Rational(0) if finish == peak

            Rational(coordinate - finish) / Rational(peak - finish)
          end
        end
      end

      def read_packed_points(stream, point_count)
        points = []
        accumulated = 0

        while points.length < point_count
          control = stream.read(1).unpack1('C')
          return (0...point_count).to_a if control.zero?

          count = control & 0x7F
          word = count >= 64
          count -= 64 if word
          signed = control.allbits?(0x80)

          count.times do
            if signed
              value = word ? read_int16(stream) : read_int8(stream)
            else
              raw = word ? stream.read(2).unpack1('n') : stream.read(1).unpack1('C')
              raw += word ? 0x8000 : 1 if points.empty?
              accumulated += raw
              value = accumulated
            end

            points << value
            break if points.length == point_count
          end
        end

        points
      end

      def read_deltas(count)
        deltas = []

        while deltas.length < count
          control = io.read(1).unpack1('C')
          run_count = [control & 0x3F, count - deltas.length].min
          signed = control.allbits?(0x80)
          word = control.allbits?(0x40)

          if word && !signed
            run_count = [
              (run_count << 8) | io.read(1).unpack1('C'),
              count - deltas.length,
            ].min
          end

          deltas.concat(Array.new(run_count, Rational(0)))
          if signed && deltas.length < count
            deltas << (word ? read_int16(io) : read_int8(io))
          end
        end

        deltas
      end

      def read_fixed(size)
        Rational(size == 1 ? read_int8(io) : read_int16(io), 0x10000)
      end

      def read_int8(stream)
        value = stream.read(1).unpack1('C')
        value >= 0x80 ? value - 0x100 : value
      end

      def read_int16(stream)
        value = stream.read(2).unpack1('n')
        value >= 0x8000 ? value - 0x10000 : value
      end
    end
  end
end
