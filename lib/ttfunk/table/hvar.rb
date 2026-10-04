# frozen_string_literal: true

require_relative '../table'

module TTFunk
  class Table
    # Horizontal Metrics Variations (`HVAR`) table.
    class Hvar < Table
      Region = Struct.new(:axis_records)
      ItemData = Struct.new(:word_deltas, :region_indexes)
      MappingEntry = Struct.new(:outer_index, :inner_index)

      TAG = 'HVAR'

      def advance_delta_for(glyph_id, coordinates)
        entry = @mapping.fetch(glyph_id, @mapping.last)
        item = @item_data.fetch(entry.outer_index)
        value = Rational(0)

        item.region_indexes.each_with_index do |region_index, index|
          scalar = region_scalar_for(region_index, coordinates)
          next if scalar.zero?

          value += Rational(item.word_deltas.fetch(entry.inner_index + index)) * scalar
        end

        value
      end

      private

      def tag
        TAG
      end

      def parse!
        saved = io.pos
        io.pos = offset

        _version = io.read(4).unpack1('N')
        variation_store_offset = io.read(4).unpack1('N')
        advance_mapping_offset = io.read(4).unpack1('N')
        io.read(8)

        parse_variation_store(offset + variation_store_offset)
        parse_advance_mapping(offset + advance_mapping_offset)
      ensure
        io.pos = saved
      end

      def parse_variation_store(position)
        io.pos = position
        _format = io.read(2).unpack1('n')
        region_list_offset = io.read(4).unpack1('N')
        item_count = io.read(2).unpack1('n')
        item_data_array_offset = io.read(4).unpack1('N')
        item_offsets = io.read(item_count * 2).unpack('n*')

        @item_data = item_offsets.map do |item_offset|
          parse_item_data(position + item_data_array_offset + item_offset)
        end
        @regions = parse_regions(position + region_list_offset)
      end

      def parse_item_data(position)
        io.pos = position
        word_delta_count = io.read(2).unpack1('n')
        region_index_count = io.read(2).unpack1('n')
        _flags = io.read(2).unpack1('n')
        word_deltas = io.read(word_delta_count * 2).unpack('s>*')
        region_indexes = io.read(region_index_count * 2).unpack('n*')
        ItemData.new(word_deltas, region_indexes)
      end

      def parse_regions(position)
        io.pos = position
        axis_count = io.read(2).unpack1('n')
        region_count = io.read(2).unpack1('n')

        Array.new(region_count) do
          records = {}
          axis_count.times do
            axis_tag = file.font_variations.axes.fetch(records.length).tag
            start_value, peak, finish = io.read(6).unpack('s>*').map do |value|
              Rational(value, 0x10000)
            end
            records[axis_tag] = [start_value, peak, finish]
          end
          Region.new(records)
        end
      end

      def parse_advance_mapping(position)
        io.pos = position
        format = io.read(2).unpack1('n')

        @mapping =
          if format.zero?
            map_count = io.read(1).unpack1('C')
            Array.new(map_count) do
              MappingEntry.new(0, io.read(2).unpack1('n'))
            end
          else
            entry_format = io.read(1).unpack1('C')
            map_count = io.read(2).unpack1('n')
            inner_bits = entry_format & 0x0F
            outer_bits = (entry_format >> 4) & 0x0F
            byte_count = ((inner_bits + outer_bits) + 7) / 8

            Array.new(map_count) do
              raw =
                case byte_count
                when 0 then 0
                when 1 then io.read(1).unpack1('C')
                when 2 then io.read(2).unpack1('n')
                else
                  io.read(3).unpack('C3').each_with_index.sum do |byte, index|
                    byte << (16 - index * 8)
                  end
                end

              inner_mask = inner_bits.zero? ? 0 : (1 << inner_bits) - 1
              outer_mask = outer_bits.zero? ? 0 : (1 << outer_bits) - 1
              MappingEntry.new(
                (raw >> inner_bits) & outer_mask,
                raw & inner_mask,
              )
            end
          end
      end

      def region_scalar_for(region_index, coordinates)
        region = @regions.fetch(region_index)
        region.axis_records.map do |axis_tag, (start_value, peak, finish)|
          region_scalar(
            coordinates.fetch(axis_tag, Rational(0)),
            start_value,
            peak,
            finish,
          )
        end.inject(Rational(1), :*)
      end

      def region_scalar(coordinate, start_value, peak, finish)
        return Rational(0) if peak.zero? || coordinate.zero?

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
    end
  end
end
