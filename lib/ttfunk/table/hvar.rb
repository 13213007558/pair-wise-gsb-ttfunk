# frozen_string_literal: true

require_relative '../table'
require_relative '../bin_utils'

module TTFunk
  class Table
    # Horizontal Metrics Variations (`HVAR`) table.
    #
    # Per the OpenType specification, when `HVAR` is present its variation
    # data is authoritative for horizontal metrics: a renderer must not
    # derive horizontal advance widths from the last two horizontal phantom
    # points in `gvar`. TTFunk therefore computes advances from HVAR and
    # ignores phantom-point advance deltas while still letting gvar move the
    # outline and the left side bearing phantom point.
    class Hvar < Table
      TAG = 'HVAR'

      def tag
        TAG
      end

      attr_reader :version

      def advance_delta_for(glyph_id, coordinates)
        delta_for(@advance_width_offset, glyph_id, coordinates)
      end

      def left_side_bearing_delta_for(glyph_id, coordinates)
        delta_for(@left_side_bearing_offset, glyph_id, coordinates)
      end

      def left_side_bearing_mapping?
        @left_side_bearing_offset != 0
      end

      private

      def parse!
        raw = file.contents.string.byteslice(offset, length)

        @version = uint32(raw, 0)
        variation_store_offset = uint32(raw, 4)
        @advance_width_offset = uint32(raw, 8)
        @left_side_bearing_offset = uint32(raw, 12)
        _right_side_bearing_offset = uint32(raw, 16)

        @variation_store = parse_variation_store(raw, variation_store_offset)
      end

      def parse_variation_store(raw, position)
        _format = uint16(raw, position)
        region_list_offset = uint32(raw, position + 2)
        item_data_count = uint16(raw, position + 6)

        item_data_offsets = Array.new(item_data_count) do |index|
          uint32(raw, position + 8 + (index * 4))
        end

        {
          regions: parse_region_list(raw, position + region_list_offset),
          item_data: item_data_offsets.map do |item_offset|
            parse_item_variation_data(raw, position + item_offset)
          end,
        }
      end

      # @return [Array<Array<Hash>>] regions[region_index][axis_index]
      def parse_region_list(raw, position)
        _format = uint16(raw, position)
        axis_count = uint16(raw, position + 2)
        region_count = uint16(raw, position + 4)

        Array.new(region_count) do |region_index|
          Array.new(axis_count) do |axis_index|
            record_position =
              position + 6 + (((region_index * axis_count) + axis_index) * 6)
            {
              start: f2dot14(uint16(raw, record_position)),
              peak: f2dot14(uint16(raw, record_position + 2)),
              end: f2dot14(uint16(raw, record_position + 4)),
            }
          end
        end
      end

      def parse_item_variation_data(raw, position)
        item_count = uint16(raw, position)
        short_delta_count = uint16(raw, position + 2)
        region_index_count = uint16(raw, position + 4)

        region_indices = Array.new(region_index_count) do |index|
          uint16(raw, position + 6 + (index * 2))
        end

        delta_position = position + 6 + (region_index_count * 2)
        short_stride = short_delta_count * 2
        long_count = region_index_count - short_delta_count
        stride = short_stride + (long_count * 4)
        deltas =
          Array.new(item_count) do |item_index|
            Array.new(region_index_count) do |region_index|
              if region_index < short_delta_count
                at = delta_position + (item_index * stride) + (region_index * 2)
                BinUtils.twos_comp_to_int(uint16(raw, at), bit_width: 16)
              else
                long_index = region_index - short_delta_count
                at =
                  delta_position + (item_index * stride) + short_stride +
                  (long_index * 4)
                signed_int32(raw, at)
              end
            end
          end

        { region_indices: region_indices, deltas: deltas }
      end

      def delta_for(mapping_offset, glyph_id, coordinates)
        return 0.0 if mapping_offset.nil?

        outer_index, inner_index = variation_index(mapping_offset, glyph_id)
        item_data = @variation_store[:item_data][outer_index]
        return 0.0 unless item_data

        deltas = item_data[:deltas][inner_index]
        return 0.0 unless deltas

        axes = file.font_variations.axes

        item_data[:region_indices].each_with_index.sum do |region_index, i|
          region = @variation_store[:regions][region_index]
          scalar =
            axes.each_with_index.reduce(1.0) do |product, (axis, axis_index)|
              record = region[axis_index]
              product * region_scalar(
                coordinates.fetch(axis.tag, 0.0),
                record[:start], record[:peak], record[:end],
              )
            end

          deltas[i] * scalar
        end
      end

      def region_scalar(value, start_value, peak_value, end_value)
        return 0.0 if peak_value.zero?
        return 1.0 if value == peak_value
        return 0.0 unless value > [start_value, end_value].min
        return 0.0 unless value < [start_value, end_value].max

        if value < peak_value
          return 0.0 if start_value == peak_value

          (value - start_value).to_f / (peak_value - start_value)
        else
          return 0.0 if end_value == peak_value

          (end_value - value).to_f / (end_value - peak_value)
        end
      end

      def variation_index(mapping_offset, glyph_id)
        return [glyph_id >> 16, glyph_id & 0xFFFF] if mapping_offset.zero?

        raw = file.contents.string.byteslice(offset, length)
        format = raw.byteslice(mapping_offset, 1).unpack1('C')
        return [glyph_id >> 16, glyph_id & 0xFFFF] if format.zero?

        inner_bit_count = format & 0x0F
        entry_size = ((format & 0x30) >> 4) + 1
        raw_value = uint(raw, mapping_offset + 1 + (entry_size * glyph_id), entry_size)
        [raw_value >> 16, raw_value & ((1 << inner_bit_count) - 1)]
      end

      def uint16(raw, position)
        raw.byteslice(position, 2).unpack1('n')
      end

      def uint32(raw, position)
        raw.byteslice(position, 4).unpack('N').first
      end

      def uint(raw, position, size)
        raw.byteslice(position, size).bytes.reduce(0) do |value, byte|
          (value << 8) | byte
        end
      end

      def signed_int32(raw, position)
        value = uint32(raw, position)
        BinUtils.twos_comp_to_int(value, bit_width: 32)
      end

      def f2dot14(value)
        BinUtils.twos_comp_to_int(value, bit_width: 16) / 16384.0
      end
    end
  end
end
