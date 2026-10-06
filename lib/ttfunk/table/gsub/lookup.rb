# frozen_string_literal: true

module TTFunk
  class Table
    class Gsub < Table
      # GSUB Lookup. Subtables are parsed lazily so that merely opening a
      # font containing unsupported lookup types doesn't fail; unsupported
      # types raise only when their subtables are actually needed.
      class Lookup
        # Lookup types supported for subsetting.
        SUPPORTED_TYPES = [1, 2, 3, 4, 5, 6, 7].freeze

        # Lookup type.
        #
        # @return [Integer]
        attr_reader :type

        # Lookup flag.
        #
        # @return [Integer]
        attr_reader :flag

        # Mark filtering set. Present only if the lookup flag has bit 0x0010
        # set.
        #
        # @return [Integer, nil]
        attr_reader :mark_filtering_set

        # Parse a Lookup table header.
        #
        # @param data [String] GSUB table content.
        # @param offset [Integer] offset of the lookup in the data.
        # @return [TTFunk::Table::Gsub::Lookup]
        def self.parse(data, offset)
          type, flag, count = BinReader.u16s(data, offset, 3)
          subtable_offsets = BinReader.u16s(data, offset + 6, count)
          mark_filtering_set =
            if (flag & 0x0010).zero?
              nil
            else
              BinReader.u16(data, offset + 6 + (count * 2))
            end

          new(data, offset, type, flag, subtable_offsets, mark_filtering_set)
        end

        # Serialize a lookup with the given subtable binaries.
        #
        # @param type [Integer]
        # @param flag [Integer]
        # @param mark_filtering_set [Integer, nil]
        # @param subtables [Array<String>]
        # @return [String]
        def self.encode(type, flag, mark_filtering_set, subtables)
          data_start = 6 + (subtables.length * 2) + (mark_filtering_set ? 2 : 0)
          offsets = []
          position = data_start
          subtables.each do |subtable|
            offsets << position
            position += subtable.bytesize
          end

          result = [type, flag, subtables.length, *offsets].pack('nnnn*')
          result += [mark_filtering_set].pack('n') if mark_filtering_set
          result + subtables.join
        end

        # @api private
        def initialize(data, offset, type, flag, subtable_offsets, mark_filtering_set)
          @data = data
          @offset = offset
          @type = type
          @flag = flag
          @subtable_offsets = subtable_offsets
          @mark_filtering_set = mark_filtering_set
        end

        # Subtables of this lookup.
        #
        # @raise [TTFunk::Error] if the lookup type is not supported.
        # @return [Array<Hash>]
        def subtables
          @subtables ||=
            begin
              unless SUPPORTED_TYPES.include?(type)
                raise TTFunk::Error, "unsupported GSUB lookup type #{type}"
              end

              @subtable_offsets.map do |subtable_offset|
                Subtable.parse(@data, @offset + subtable_offset, type)
              end
            end
        end
      end
    end
  end
end
