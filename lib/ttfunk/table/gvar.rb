# frozen_string_literal: true

require_relative '../table'
require_relative '../bin_utils'

module TTFunk
  class Table
    # Glyph Variations (`gvar`) table. Stores per-glyph tuple variations
    # over the axes declared by `fvar`.
    #
    # Only the structures needed to instantiate a static instance are
    # decoded. The original binary data is retained and is never written to
    # static instances.
    class Gvar < Table
      TAG = 'gvar'

      # Tuple Variation Header flags.
      # See https://learn.microsoft.com/typography/opentype/spec/otvarcommonformats
      EMBEDDED_PEAK_TUPLE     = 0x8000
      INTERMEDIATE_REGION     = 0x4000
      PRIVATE_POINT_NUMBERS   = 0x2000
      # GlyphVariationData header flag: point numbers are shared between
      # tuples and stored once at the start of the serialized data.
      TUPLES_SHARE_POINT_NUMBERS = 0x8000
      TUPLE_COUNT_MASK        = 0x0FFF
      TUPLE_INDEX_MASK        = 0x0FFF
      DELTAS_ARE_ZERO        = 0x80
      DELTAS_ARE_WORDS       = 0x40
      DELTAS_ARE_LONGS       = 0x20
      DELTA_RUN_COUNT_MASK   = 0x3F
      POINTS_ARE_WORDS       = 0x80
      POINT_RUN_COUNT_MASK   = 0x7F

      # One tuple variation as decoded from a GlyphVariationData block.
      #
      # @!attribute regions
      #   @return [Hash{String => Array(Float, Float, Float)}] start, peak,
      #     end normalized coordinates for each axis touched by the tuple
      # @!attribute deltas
      #   @return [Array<Array(Integer, Integer), nil>] per-point (x, y)
      #     deltas. Missing entries are inferred through IUP interpolation.
      TupleVariation = Struct.new(:regions, :deltas, keyword_init: true)

      # @return [Integer] number of variation axes
      attr_reader :axis_count

      # @return [Integer] number of glyphs in the font
      attr_reader :glyph_count

      # @return [Boolean] whether glyph variation offsets are 32 bits long
      attr_reader :long_offsets

      # Tuple variations for the given glyph.
      #
      # @param glyph_id [Integer]
      # @param point_count [Integer] number of interpolatable points, the
      #   four phantom points included
      # @return [Array<TupleVariation>]
      def variations_for(glyph_id, point_count)
        range = glyph_offset_range(glyph_id)
        return [] if range.nil? || range.begin == range.end

        parse_variation_data(
          @raw_data.byteslice(range.begin, range.end - range.begin), point_count
        )
      end

      private

      def parse!
        raw = file.contents.string.byteslice(offset, length)

        @version = raw.byteslice(0, 4).unpack1('N')
        _reserved = raw.byteslice(4, 2).unpack1('n')
        @axis_count = raw.byteslice(4, 2).unpack1('n')
        shared_tuple_count = raw.byteslice(6, 2).unpack1('n')
        shared_tuples_offset = raw.byteslice(8, 4).unpack('N').first
        @glyph_count = raw.byteslice(12, 2).unpack1('n')
        @flags = raw.byteslice(14, 2).unpack1('n')
        data_offset = raw.byteslice(16, 4).unpack('N').first
        @long_offsets = (@flags & 0x0001) == 1

        @shared_tuples = Array.new(shared_tuple_count) do |tuple_index|
          tuple_position = shared_tuples_offset + (tuple_index * @axis_count * 2)
          Array.new(@axis_count) do |axis_index|
            value = raw
              .byteslice(tuple_position + (axis_index * 2), 2)
              .unpack1('n')
            BinUtils.twos_comp_to_int(value, bit_width: 16) / 16384.0
          end
        end

        @glyph_offsets = read_glyph_offsets(raw)
        @raw_data = raw.byteslice(data_offset, raw.length - data_offset)
      end

      def read_glyph_offsets(raw)
        size = long_offsets ? 4 : 2
        raw_offsets = Array.new(glyph_count + 1) do
          position = 20 + (_1 * size)
          raw.byteslice(position, size).unpack1(long_offsets ? 'N' : 'n')
        end

        offsets = long_offsets ? raw_offsets : raw_offsets.map { |value| value * 2 }

        offsets
      end

      def glyph_offset_range(glyph_id)
        # The on-disk array holds glyphCount+1 offsets (the final value is
        # shared by empty glyphs at the end and equals the next distinct
        # start). Each glyph ends at the next strictly larger offset, or at
        # the end of the glyph variation data.
        start_index = @glyph_offsets[glyph_id]
        following = @glyph_offsets[(glyph_id + 1)..].filter_map { |value|
          value if value > start_index
        }
        end_index = following.first || @raw_data.length
        return nil if start_index.nil? || end_index.nil?

        start_index...end_index
      end

      def read_raw(data_offset, size)
        io.seek(offset + data_offset)
        io.read(size)
      end

      def parse_variation_data(raw, point_count)
        data = StringIO.new(raw)
        tuple_count_and_flags = data.read(2).unpack1('n')
        # The local serialized-data offset is 2 bytes in a short gvar and
        # 3 bytes in a long gvar.
        data_offset_size = long_offsets ? 3 : 2
        data_offset = read_uint(data, data_offset_size)
        share_points = (tuple_count_and_flags & TUPLES_SHARE_POINT_NUMBERS) != 0
        tuple_count = tuple_count_and_flags & TUPLE_COUNT_MASK

        headers_position = data.pos
        data.seek(data_offset)
        shared_points =
          if share_points
            points, = read_packed_points(data, point_count)
            points
          else
            []
          end

        serialized_data_position = data.pos
        header_position = headers_position

        Array.new(tuple_count) do
          tuple_data_size = raw[header_position, 2].unpack1('n')
          tuple_flags = raw[header_position + 2, 2].unpack1('n')
          tuple_size = tuple_header_size(tuple_flags)
          tuple_header = raw[header_position, tuple_size]

          tuple_data = raw[serialized_data_position, tuple_data_size]
          variation = parse_tuple(
            tuple_header, tuple_data, shared_points, point_count
          )

          header_position += tuple_size
          serialized_data_position += tuple_data_size
          variation
        end
      end

      def tuple_header_size(flags)
        size = 4
        size += axis_count * 2 if (flags & EMBEDDED_PEAK_TUPLE) != 0
        size += axis_count * 4 if (flags & INTERMEDIATE_REGION) != 0
        size
      end

      def parse_tuple(header, tuple_data, shared_points, point_count)
        flags = header[2, 2].unpack1('n')
        tuple_io = StringIO.new(header)
        tuple_io.read(4)

        peak =
          if (flags & EMBEDDED_PEAK_TUPLE) != 0
            Array.new(axis_count) { read_f2dot14_from(tuple_io) }
          else
            index = flags & TUPLE_INDEX_MASK
            @shared_tuples.fetch(index)
          end

        if (flags & INTERMEDIATE_REGION) != 0
          start_tuple = Array.new(axis_count) { read_f2dot14_from(tuple_io) }
          end_tuple = Array.new(axis_count) { read_f2dot14_from(tuple_io) }
        else
          start_tuple = peak.map { |value| value < 0 ? value : 0.0 }
          end_tuple = peak.map { |value| value > 0 ? value : 0.0 }
        end

        regions = build_regions(start_tuple, peak, end_tuple)
        delta_io = StringIO.new(tuple_data)

        points =
          if (flags & PRIVATE_POINT_NUMBERS) != 0
            private_points, advanced = read_packed_points(delta_io, point_count)
            delta_io = StringIO.new(tuple_data[advanced..])
            private_points
          else
            shared_points
          end

        x_deltas = read_deltas(delta_io, points.length)
        y_deltas = read_deltas(delta_io, points.length)

        deltas = Array.new(point_count)
        points.each_with_index do |point, index|
          next if point.negative? || point >= point_count

          deltas[point] = [x_deltas[index], y_deltas[index]]
        end

        TupleVariation.new(regions: regions, deltas: deltas)
      end

      def build_regions(start_tuple, peak, end_tuple)
        axes = file.font_variations.axes

        axes.each_with_index.each_with_object({}) do |(axis, index), regions|
          start_value = start_tuple[index]
          peak_value = peak[index]
          end_value = end_tuple[index]
          next if start_value.zero? && peak_value.zero? && end_value.zero?

          regions[axis.tag] = [start_value, peak_value, end_value]
        end
      end

      def read_packed_points(io, point_count)
        first = read_uint(io, 1)
        if (first & POINTS_ARE_WORDS) != 0
          second = read_uint(io, 1)
          total = ((first & POINT_RUN_COUNT_MASK) << 8) | second
        else
          total = first
        end

        return [Array.new(point_count) { |i| i }, io.pos] if total.zero?

        relative = []
        while relative.length < total
          run_header = read_uint(io, 1)
          count = (run_header & POINT_RUN_COUNT_MASK) + 1
          values =
            if (run_header & POINTS_ARE_WORDS) != 0
              Array.new(count) { read_uint(io, 2) }
            else
              Array.new(count) { read_uint(io, 1) }
            end
          relative.concat(values)
        end

        points = []
        current = 0
        relative.each do |delta|
          current += delta
          points << current
        end

        [points, io.pos]
      end

      def read_deltas(io, count)
        deltas = []

        while deltas.length < count
          header = read_uint(io, 1)
          run_count = (header & DELTA_RUN_COUNT_MASK) + 1

          if (header & DELTAS_ARE_ZERO) != 0
            deltas.concat(Array.new(run_count, 0))
          elsif (header & DELTAS_ARE_WORDS) != 0 &&
                (header & DELTAS_ARE_LONGS).zero?
            deltas.concat(read_signed_values(io, run_count, 2))
          elsif (header & DELTAS_ARE_LONGS) != 0
            deltas.concat(read_signed_values(io, run_count, 4))
          else
            deltas.concat(read_signed_values(io, run_count, 1))
          end
        end

        deltas
      end

      def read_signed_values(io, count, size)
        format = { 1 => 'c', 2 => 's>', 4 => 'l>' }.fetch(size)
        Array.new(count) { io.read(size).unpack1(format) }
      end

      def read_uint(io, size)
        return io.read(2).unpack1('n') if size == 2

        io.read(size).bytes.reduce(0) { |value, byte| (value << 8) | byte }
      end

      def read_f2dot14
        read_f2dot14_from(io)
      end

      def read_f2dot14_from(io)
        value = io.read(2).unpack1('n')
        BinUtils.twos_comp_to_int(value, bit_width: 16) / 16384.0
      end
    end
  end
end
