# frozen_string_literal: true

module TTFunk
  class Table
    class Cmap
      # Format 14: Unicode Variation Sequences.
      #
      # This module conditionally extends {TTFunk::Table::Cmap::Subtable}.
      module Format14
        # Subtable length in bytes.
        # @return [Integer]
        attr_reader :length

        # Encode a format 14 subtable.
        #
        # @param records [Hash{Integer => Hash}] keys are variation selector
        #   code points, values are hashes:
        #   * +:default+ (<tt>Array<Integer></tt>) - character codes that use
        #     the default UVS, i.e. the glyph from the base cmap.
        #   * +:non_default+ (<tt>Hash{Integer => Integer}</tt>) - character
        #     codes mapped to specific glyph IDs.
        # @return [Hash]
        #   * +:subtable+ (<tt>String</tt>) - serialized subtable (without the
        #     encoding record header).
        def self.encode(records)
          selectors = records.keys.sort
          header_length = 10 + (selectors.length * 11)

          offset = header_length
          selector_records = +''
          tables = +''

          selectors.each do |selector|
            record = records[selector]
            default = Array(record[:default]).sort
            non_default = record[:non_default] || {}

            default_offset = 0
            unless default.empty?
              default_offset = offset
              ranges = merge_uvs_ranges(default)
              table = [ranges.length].pack('N')
              ranges.each do |start, count|
                table << uint24(start) << [count].pack('C')
              end
              tables << table
              offset += table.length
            end

            non_default_offset = 0
            unless non_default.empty?
              non_default_offset = offset
              table = [non_default.length].pack('N')
              non_default.keys.sort.each do |code|
                table << uint24(code) << [non_default[code]].pack('n')
              end
              tables << table
              offset += table.length
            end

            selector_records <<
              uint24(selector) <<
              [default_offset, non_default_offset].pack('N2')
          end

          subtable =
            [14, offset, selectors.length].pack('nN2') <<
            selector_records <<
            tables

          { subtable: subtable }
        end

        # Merge sorted character codes into UVS ranges.
        #
        # @param codes [Array<Integer>]
        # @return [Array<Array(Integer, Integer)>] pairs of range start and
        #   additional count.
        def self.merge_uvs_ranges(codes)
          codes.sort.each_with_object([]) do |code, ranges|
            if ranges.any? && code == ranges.last[0] + ranges.last[1] + 1
              ranges.last[1] += 1
            else
              ranges << [code, 0]
            end
          end
        end
        private_class_method :merge_uvs_ranges

        # Pack a 24-bit unsigned integer.
        #
        # @param value [Integer]
        # @return [String]
        def self.uint24(value)
          [value].pack('N')[1, 3]
        end
        private_class_method :uint24

        # Get glyph ID for a character code and variation selector.
        #
        # Non-default UVS mappings return the glyph ID from this subtable.
        # Default UVS mappings return the glyph ID from the font's selected
        # Unicode cmap.
        #
        # @param code [Integer] character code.
        # @param selector [Integer] variation selector code.
        # @return [Integer, nil] glyph ID or +nil+ if the variation sequence
        #   is not supported.
        def [](code, selector)
          record = @selectors[selector]
          return if record.nil?

          if record[:non_default].key?(code)
            record[:non_default][code]
          elsif default_uvs?(code, selector)
            @file.cmap.unicode.first&.[](code)
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
        # A format 14 subtable doesn't map characters to glyphs by itself so
        # it can't be used as a Unicode charmap.
        #
        # @return [false]
        def unicode?
          false
        end

        # Does this subtable define a default UVS mapping for the sequence?
        #
        # @param code [Integer] character code.
        # @param selector [Integer] variation selector code.
        # @return [Boolean]
        def default_uvs?(code, selector)
          record = @selectors[selector]
          return false if record.nil?

          record[:default].any? { |(start, count)|
            code >= start && code <= start + count
          }
        end

        # Does this subtable map the sequence to a specific glyph?
        #
        # @param code [Integer] character code.
        # @param selector [Integer] variation selector code.
        # @return [Boolean]
        def non_default_uvs?(code, selector)
          record = @selectors[selector]
          !record.nil? && record[:non_default].key?(code)
        end

        # All variation selectors in this subtable.
        #
        # @return [Array<Integer>]
        def variation_selectors
          @selectors.keys
        end

        # Default UVS ranges for a variation selector.
        #
        # @param selector [Integer] variation selector code.
        # @return [Array<Array(Integer, Integer)>] pairs of range start and
        #   additional count.
        def default_uvs_ranges(selector)
          record = @selectors[selector]
          record ? record[:default] : []
        end

        # Non-default UVS mappings for a variation selector.
        #
        # @param selector [Integer] variation selector code.
        # @return [Hash{Integer => Integer}] character code to glyph ID map.
        def non_default_uvs_mappings(selector)
          record = @selectors[selector]
          record ? record[:non_default] : {}
        end

        private

        def parse_cmap!
          @length, num_selectors = read(8, 'N2')
          header_size = 10 + (num_selectors * 11)

          @selectors = {}
          num_selectors.times do
            selector = read_uint24
            default_offset, non_default_offset = read(8, 'N2')

            if @selectors.key?(selector)
              raise TTFunk::Error,
                Kernel.format(
                  'cmap format 14: duplicate variation selector 0x%06X',
                  selector,
                )
            end

            @selectors[selector] = {
              default: parse_default_uvs(selector, default_offset, header_size),
              non_default: parse_non_default_uvs(selector, non_default_offset, header_size),
            }
          end
        end

        def parse_default_uvs(selector, offset, header_size)
          return [] if offset.zero?

          check_offset!(selector, offset, header_size, 'default UVS')

          parse_from(@offset + offset) do
            count = read(4, 'N').first
            check_table_size!(selector, offset, 4 + (count * 4), 'default UVS')

            Array.new(count) { [read_uint24, read(1, 'C').first] }
          end
        end

        def parse_non_default_uvs(selector, offset, header_size)
          return {} if offset.zero?

          check_offset!(selector, offset, header_size, 'non-default UVS')

          parse_from(@offset + offset) do
            count = read(4, 'N').first
            check_table_size!(selector, offset, 4 + (count * 5), 'non-default UVS')

            Array.new(count) { [read_uint24, read(2, 'n').first] }.to_h
          end
        end

        def check_offset!(selector, offset, header_size, description)
          return if offset >= header_size && offset < @length

          raise TTFunk::Error,
            Kernel.format(
              'cmap format 14: %s offset %d out of bounds for variation ' \
                'selector 0x%06X (subtable length %d)',
              description, offset, selector, @length
            )
        end

        def check_table_size!(selector, offset, size, description)
          return if offset + size <= @length

          raise TTFunk::Error,
            Kernel.format(
              'cmap format 14: %s table at offset %d exceeds subtable ' \
                'length %d for variation selector 0x%06X',
              description, offset, @length, selector
            )
        end

        def read_uint24
          bytes = read(3, 'C3')
          (bytes[0] << 16) | (bytes[1] << 8) | bytes[2]
        end
      end
    end
  end
end
