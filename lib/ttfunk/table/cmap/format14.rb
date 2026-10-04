# frozen_string_literal: true

module TTFunk
  class Table
    class Cmap
      # Format 14: Unicode Variation Sequences.
      #
      # This module conditionally extends {TTFunk::Table::Cmap::Subtable}.
      module Format14
        # Indicates that a variation sequence maps to the default glyph, i.e.
        # the glyph the regular Unicode cmap maps the base character to.
        DEFAULT_MAPPING = :default

        # Encode a Unicode Variation Sequences subtable.
        #
        # @param uvs [Hash{Integer => Hash}] keys are variation selector
        #   code points, values are hashes:
        #   * +:default+ (+Array<Integer>+) - code points whose variation
        #     sequence maps to the default glyph.
        #   * +:non_default+ (+Hash{Integer => Integer}+) - maps code points
        #     to glyph IDs for non-default variation sequences.
        # @return [String] serialized subtable.
        def self.encode(uvs)
          selectors = uvs.keys.sort

          default_tables = {}
          non_default_tables = {}
          selectors.each do |selector|
            record = uvs[selector] || {}

            default = record[:default]
            unless default.nil? || default.empty?
              default_tables[selector] = encode_default_uvs(default)
            end

            non_default = record[:non_default]
            unless non_default.nil? || non_default.empty?
              non_default_tables[selector] = encode_non_default_uvs(non_default)
            end
          end

          offset = 10 + (selectors.length * 11)

          default_offsets = {}
          selectors.each do |selector|
            next unless (table = default_tables[selector])

            default_offsets[selector] = offset
            offset += table.length
          end

          non_default_offsets = {}
          selectors.each do |selector|
            next unless (table = non_default_tables[selector])

            non_default_offsets[selector] = offset
            offset += table.length
          end

          subtable = [14, offset, selectors.length].pack('nNN')
          selectors.each do |selector|
            subtable << uint24(selector)
            subtable << [
              default_offsets[selector] || 0,
              non_default_offsets[selector] || 0,
            ].pack('NN')
          end
          selectors.each do |selector|
            subtable << default_tables[selector] if default_tables[selector]
          end
          selectors.each do |selector|
            subtable << non_default_tables[selector] if non_default_tables[selector]
          end

          subtable
        end

        # Encode a Default UVS table.
        #
        # @param code_points [Array<Integer>]
        # @return [String]
        def self.encode_default_uvs(code_points)
          ranges = []
          code_points.sort.each do |code|
            if ranges.empty? || ranges.last[1] == 0xFF ||
                code != ranges.last[0] + ranges.last[1] + 1
              ranges << [code, 0]
            else
              ranges.last[1] += 1
            end
          end

          [ranges.length].pack('N') +
            ranges.map { |start, count| uint24(start) + [count].pack('C') }.join
        end

        # Encode a Non-Default UVS table.
        #
        # @param mapping [Hash{Integer => Integer}] maps code points to glyph
        #   IDs.
        # @return [String]
        def self.encode_non_default_uvs(mapping)
          entries = mapping.sort_by { |code, _glyph_id| code }

          [entries.length].pack('N') +
            entries.map { |code, glyph_id|
              uint24(code) + [glyph_id].pack('n')
            }.join
        end

        # Pack an integer as a 24-bit big-endian unsigned integer.
        #
        # @param value [Integer]
        # @return [String]
        def self.uint24(value)
          [value].pack('N')[1, 3]
        end

        # Variation selector code points in this subtable.
        #
        # @return [Array<Integer>]
        def selectors
          @records.keys.sort
        end

        # Is this encoding record format supported?
        #
        # @return [true]
        def supported?
          true
        end

        # Look up a Unicode variation sequence.
        #
        # @param code [Integer] base character code point.
        # @param selector [Integer] variation selector code point.
        # @return [Integer] glyph ID for a non-default UVS.
        # @return [:default] for a default UVS, meaning the glyph comes from
        #   the regular Unicode cmap.
        # @return [nil] if the sequence is not supported by this subtable.
        def [](code, selector)
          record = @records[selector]
          return nil unless record

          if record[:non_default].key?(code)
            record[:non_default][code]
          elsif record[:default].any? { |range| range.cover?(code) }
            DEFAULT_MAPPING
          end
        end

        private

        def parse_cmap!
          @length, num_selectors = read(8, 'NN')
          header_size = 10 + (num_selectors * 11)

          @records = {}
          num_selectors.times do
            hi, mid, lo, default_offset, non_default_offset = read(11, 'C3NN')
            selector = (hi << 16) | (mid << 8) | lo

            if @records.key?(selector)
              raise TTFunk::Error,
                Kernel.format('duplicate variation selector U+%04X in cmap format 14', selector)
            end

            @records[selector] = {
              default: parse_default_uvs(selector, default_offset, header_size),
              non_default: parse_non_default_uvs(selector, non_default_offset, header_size),
            }
          end
        end

        def parse_default_uvs(selector, offset, header_size)
          return [] if offset.zero?

          check_offset!(selector, offset, header_size)

          parse_from(@offset + offset) do
            num_ranges = read(4, 'N').first
            Array.new(num_ranges) do
              hi, mid, lo, additional_count = read(4, 'C4')
              start = (hi << 16) | (mid << 8) | lo
              (start..(start + additional_count))
            end
          end
        end

        def parse_non_default_uvs(selector, offset, header_size)
          return {} if offset.zero?

          check_offset!(selector, offset, header_size)

          parse_from(@offset + offset) do
            num_mappings = read(4, 'N').first
            Array.new(num_mappings) do
              hi, mid, lo, glyph_id = read(5, 'C3n')
              [((hi << 16) | (mid << 8) | lo), glyph_id]
            end.to_h
          end
        end

        def check_offset!(selector, offset, header_size)
          return if offset >= header_size && offset < @length

          raise TTFunk::Error,
            Kernel.format(
              'cmap format 14: offset %d for variation selector U+%04X is out of bounds',
              offset,
              selector,
            )
        end
      end
    end
  end
end
