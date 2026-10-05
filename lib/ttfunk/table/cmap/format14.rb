# frozen_string_literal: true

require 'set'
require_relative '../../bin_utils'

module TTFunk
  class Table
    class Cmap
      # Format 14: Unicode Variation Sequences.
      #
      # This module conditionally extends {TTFunk::Table::Cmap::Subtable}.
      module Format14
        # Encode the encoding record to format 14.
        #
        # @param charmap [Hash{Array(Integer, Integer) => Integer}] keys are
        #   two-element arrays of a Unicode codepoint and a variation selector
        #   codepoint, values are glyph IDs in the original font. Glyph ID 0
        #   denotes a default UVS entry, i.e. the sequence is rendered with
        #   the default glyph of the base character.
        # @param glyph_map [Hash{Integer => Integer}] glyph ID mapping from
        #   the original font to the subset font. It is used (and extended) to
        #   keep non-default UVS glyph IDs consistent with the rest of the
        #   cmap table.
        # @return [Hash]
        #   * +:charmap+ (<tt>Hash{Array(Integer, Integer) => Hash}</tt>) keys
        #     are the character/selector pairs, values are hashes:
        #     * +:old+ (<tt>Integer</tt>) - glyph ID in the original font.
        #     * +:new+ (<tt>Integer</tt>) - glyph ID in the subset font.
        #   * +:subtable+ (<tt>String</tt>) - serialized encoding record.
        #   * +:max_glyph_id+ (<tt>Integer</tt>) - maximum glyph ID in the new
        #     font.
        def self.encode(charmap, glyph_map: { 0 => 0 })
          next_id = glyph_map.values.max
          new_map = {}
          selectors = {}

          charmap.sort.each do |(code, selector), old_glyph_id|
            new_glyph_id = glyph_map[old_glyph_id] ||= next_id += 1
            new_map[[code, selector]] = { old: old_glyph_id, new: new_glyph_id }

            entry = (selectors[selector] ||= { default: [], non_default: [] })
            if old_glyph_id.zero?
              entry[:default] << code
            else
              entry[:non_default] << [code, new_glyph_id]
            end
          end

          sorted_selectors = selectors.keys.sort
          records = []
          tables = +''
          # header (10 bytes) + variation selector records (11 bytes each)
          offset = 10 + (11 * sorted_selectors.size)

          sorted_selectors.each do |selector|
            entry = selectors[selector]
            default_offset = 0
            non_default_offset = 0

            if entry[:default].any?
              ranges = uvs_ranges(entry[:default])
              table = [ranges.size].pack('N')
              ranges.each do |start, additional_count|
                table << pack_uint24(start) << [additional_count].pack('C')
              end
              default_offset = offset
              tables << table
              offset += table.length
            end

            if entry[:non_default].any?
              mappings = entry[:non_default].sort_by(&:first)
              table = [mappings.size].pack('N')
              mappings.each do |code, glyph_id|
                table << pack_uint24(code) << [glyph_id].pack('n')
              end
              non_default_offset = offset
              tables << table
              offset += table.length
            end

            records << [selector, default_offset, non_default_offset]
          end

          subtable = +[14, offset, sorted_selectors.size].pack('nNN')
          records.each do |selector, default_offset, non_default_offset|
            subtable << pack_uint24(selector) <<
              [default_offset, non_default_offset].pack('NN')
          end
          subtable << tables

          { charmap: new_map, subtable: subtable, max_glyph_id: next_id + 1 }
        end

        # Pack an integer as a big-endian uint24.
        #
        # @param value [Integer]
        # @return [String]
        def self.pack_uint24(value)
          [value].pack('N')[1, 3]
        end

        # Turn a list of character codes into a list of
        # [start, additionalCount] ranges. +additionalCount+ is a uint8 so
        # long ranges are split.
        #
        # @param codes [Array<Integer>]
        # @return [Array<Array(Integer, Integer)>]
        def self.uvs_ranges(codes)
          TTFunk::BinUtils.rangify(codes.sort).flat_map { |start, count|
            ranges = []
            while count > 0xFF
              ranges << [start, 0xFF]
              start += 0x100
              count -= 0x100
            end
            ranges << [start, count]
            ranges
          }
        end

        # Get glyph ID for a character/variation selector pair.
        #
        # @param code [Integer] character code.
        # @param selector [Integer] variation selector code.
        # @return [Integer] glyph ID for a non-default mapping.
        # @return [0] if the sequence maps to the default glyph of the base
        #   character.
        # @return [nil] if the variation sequence is not supported.
        def [](code, selector)
          if @non_default_uvs.key?([code, selector])
            @non_default_uvs[[code, selector]]
          elsif @default_uvs.key?(selector) && @default_uvs[selector].include?(code)
            0
          end
        end

        # Is this encoding record format supported?
        #
        # @return [true]
        def supported?
          true
        end

        # Is this an encoding record for Unicode?
        #
        # Format 14 records supplement Unicode cmaps but can't be used for
        # regular character mapping on their own.
        #
        # @return [false]
        def unicode?
          false
        end

        private

        def parse_cmap!
          _length, num_selectors = read(8, 'NN')

          records =
            Array.new(num_selectors) do
              [read_uint24, *read(8, 'NN')]
            end

          @default_uvs = {}
          @non_default_uvs = {}

          records.each do |selector, default_offset, non_default_offset|
            if default_offset.positive?
              @default_uvs[selector] = parse_default_uvs(default_offset)
            end

            if non_default_offset.positive?
              parse_non_default_uvs(selector, non_default_offset)
            end
          end
        end

        def parse_default_uvs(offset)
          parse_from(@offset + offset) do
            range_count = read(4, 'N').first
            codes = []
            range_count.times do
              start = read_uint24
              additional_count = read(1, 'C').first
              codes.concat((start..(start + additional_count)).to_a)
            end
            codes.to_set
          end
        end

        def parse_non_default_uvs(selector, offset)
          parse_from(@offset + offset) do
            mapping_count = read(4, 'N').first
            mapping_count.times do
              code = read_uint24
              glyph_id = read(2, 'n').first
              @non_default_uvs[[code, selector]] = glyph_id
            end
          end
        end

        def read_uint24
          high, mid, low = read(3, 'C3')
          (high << 16) | (mid << 8) | low
        end
      end
    end
  end
end
