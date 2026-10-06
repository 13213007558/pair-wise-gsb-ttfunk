# frozen_string_literal: true

module TTFunk
  class Table
    class Gsub < Table
      # Binary reading helpers for GSUB table data.
      # @api private
      module BinReader
        module_function

        # Read an unsigned 16-bit integer.
        #
        # @param data [String]
        # @param offset [Integer]
        # @return [Integer]
        def u16(data, offset)
          data[offset, 2].unpack1('n')
        end

        # Read a signed 16-bit integer.
        #
        # @param data [String]
        # @param offset [Integer]
        # @return [Integer]
        def i16(data, offset)
          data[offset, 2].unpack1('s>')
        end

        # Read an unsigned 32-bit integer.
        #
        # @param data [String]
        # @param offset [Integer]
        # @return [Integer]
        def u32(data, offset)
          data[offset, 4].unpack1('N')
        end

        # Read an array of unsigned 16-bit integers.
        #
        # @param data [String]
        # @param offset [Integer]
        # @param count [Integer]
        # @return [Array<Integer>]
        def u16s(data, offset, count)
          data[offset, count * 2].unpack("n#{count}")
        end

        # Read a 4-byte tag.
        #
        # @param data [String]
        # @param offset [Integer]
        # @return [String]
        def tag(data, offset)
          data[offset, 4]
        end
      end
    end
  end
end
