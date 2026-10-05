# frozen_string_literal: true

module TTFunk
  class Table
    class Cmap
      # Format 14: Unicode Variation Sequences.
      #
      # This module conditionally extends {TTFunk::Table::Cmap::Subtable}.
      module Format14
        # Unicode platform ID.
        UNICODE_PLATFORM_ID = 0

        # Unicode Variation Sequences encoding ID.
        UVS_ENCODING_ID = 5

        # Variation selector records. Keys are variation selector code
        # points, values are hashes:
        # * `:default` (<tt>Array<Array(Integer, Integer)></tt>) - default UVS
        #   ranges. Each range is a pair of the first character code and the
        #   number of code points in the range.
        # * `:non_default` (<tt>Hash{Integer => Integer}</tt>) - non-default
        #   UVS mapping of character codes to glyph IDs.
        #
        # @return [Hash{Integer => Hash}]
        attr_reader :variation_selectors

        # Encode the encoding record to format 14.
        #
        # @param charmap [Hash{Array(Integer, Integer) => Integer, nil}] keys
        #   are `[character code, variation selector]` pairs, values are glyph
        #   IDs in the original font for non-default UVS mappings or `nil` for
        #   default UVS mappings.
        # @param base_charmap [Hash{Integer => Hash}] encoded base character
        #   map. Keys are character codes, values are hashes:
        #   * `:old` (<tt>Integer</tt>) - glyph ID in the original font.
        #   * `:new` (<tt>Integer</tt>) - glyph ID in the subset font.
        #   It's used to resolve glyph IDs of default UVS mappings.
        # @param max_glyph_id [Integer] first unassigned glyph ID in the new
        #   font.
        # @return [Hash]
        #   * `:charmap` (<tt>Hash{Array(Integer, Integer) => Hash}</tt>) keys
        #     are `[character code, variation selector]` pairs of non-default
        #     UVS mappings, values are hashes:
        #     * `:old` (<tt>Integer</tt>) - glyph ID in the original font.
        #     * `:new` (<tt>Integer</tt>) - glyph ID in the subset font.
        #     Default UVS mappings are not included since they use the same
        #     glyphs as their base characters.
        #   * `:subtable` (<tt>String</tt>) - serialized encoding record.
        #   * `:max_glyph_id` (<tt>Integer</tt>) - maximum glyph ID in the new
        #     font.
        def self.encode(charmap, base_charmap, max_glyph_id)
          glyph_map = { 0 => 0 }
          base_charmap.each_value do |ids|
            glyph_map[ids[:old]] = ids[:new]
          end
          next_id = max_glyph_id - 1

          selectors = {}
          new_map = {}

          charmap
            .sort_by { |(code, selector), _glyph_id| [selector, code] }
            .each do |(code, selector), old_glyph_id|
              record =
                (selectors[selector] ||= { default: [], non_default: {} })

              if old_glyph_id
                glyph_map[old_glyph_id] ||= next_id += 1
                record[:non_default][code] = glyph_map[old_glyph_id]
                new_map[[code, selector]] = {
                  old: old_glyph_id,
                  new: glyph_map[old_glyph_id],
                }
              else
                base = base_charmap[code]
                if base.nil?
                  raise ArgumentError,
                    "no base glyph for default variation sequence " \
                      "[#{code}, #{selector}]"
                end

                record[:default] << code
              end
            end

          records = []
          tables = []
          # format (2) + length (4) + numVarSelectorRecords (4)
          offset = 10 + (11 * selectors.size)

          selectors.keys.sort.each do |selector|
            record = selectors[selector]
            default_table = encode_default_uvs(record[:default])
            non_default_table = encode_non_default_uvs(record[:non_default])

            if default_table
              records << [selector, offset]
              tables << default_table
              offset += default_table.length
            else
              records << [selector, 0]
            end

            if non_default_table
              records.last << offset
              tables << non_default_table
              offset += non_default_table.length
            else
              records.last << 0
            end
          end

          subtable = [14, offset, selectors.size].pack('nNN')
          records.each do |selector, default_offset, non_default_offset|
            subtable << pack_uint24(selector)
            subtable << [default_offset, non_default_offset].pack('NN')
          end
          tables.each { |table| subtable << table }

          { charmap: new_map, subtable: subtable, max_glyph_id: next_id + 1 }
        end

        # Get glyph ID for the variation sequence.
        #
        # @param code [Integer] character code.
        # @param selector [Integer] variation selector code.
        # @return [Integer, nil] glyph ID for a non-default UVS mapping, `nil`
        #   if the sequence is not in this table or uses the default glyph.
        def [](code, selector)
          record = @variation_selectors[selector]
          record && record[:non_default][code]
        end

        # Does this table map the variation sequence to the default glyph?
        #
        # @param code [Integer] character code.
        # @param selector [Integer] variation selector code.
        # @return [Boolean]
        def default_uvs?(code, selector)
          record = @variation_selectors[selector]
          return false if record.nil?

          record[:default].any? do |start, count|
            code >= start && code < start + count
          end
        end

        # Is this encoding record format supported?
        #
        # @return [true]
        def supported?
          true
        end

        private

        def parse_cmap!
          _length, record_count = read(8, 'NN')

          records = Array.new(record_count) do
            selector, default_offset, non_default_offset = read(11, 'a3NN')
            [unpack_uint24(selector), default_offset, non_default_offset]
          end

          @variation_selectors = {}

          records.each do |selector, default_offset, non_default_offset|
            record = { default: [], non_default: {} }

            unless default_offset.zero?
              parse_from(@offset + default_offset) do
                range_count = read(4, 'N').first
                range_count.times do
                  start, additional_count = read(4, 'a3C')
                  record[:default] <<
                    [unpack_uint24(start), additional_count + 1]
                end
              end
            end

            unless non_default_offset.zero?
              parse_from(@offset + non_default_offset) do
                mapping_count = read(4, 'N').first
                mapping_count.times do
                  code, glyph_id = read(5, 'a3n')
                  record[:non_default][unpack_uint24(code)] = glyph_id
                end
              end
            end

            @variation_selectors[selector] = record
          end
        end

        def unpack_uint24(bytes)
          ("\0" + bytes).unpack1('N')
        end

        class << self
          private

          def pack_uint24(value)
            [value].pack('N')[1..]
          end

          def encode_default_uvs(codes)
            return if codes.empty?

            ranges = []
            codes.sort.each do |code|
              if ranges.empty? || code != ranges.last[0] + ranges.last[1] ||
                  ranges.last[1] == 256
                ranges << [code, 1]
              else
                ranges.last[1] += 1
              end
            end

            ranges.reduce([ranges.length].pack('N')) do |table, (start, count)|
              table << pack_uint24(start) << [count - 1].pack('C')
            end
          end

          def encode_non_default_uvs(mapping)
            return if mapping.empty?

            mapping
              .sort
              .reduce([mapping.length].pack('N')) do |table, (code, glyph_id)|
                table << pack_uint24(code) << [glyph_id].pack('n')
              end
          end
        end
      end
    end
  end
end
