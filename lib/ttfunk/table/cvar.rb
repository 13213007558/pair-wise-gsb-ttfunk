# frozen_string_literal: true

require_relative '../table'
require_relative 'variation/tuple_variation'

module TTFunk
  class Table
    # Control Value Table Variations (`cvar`) table. Supplies deltas to the
    # control value (`cvt `) table entries across the variation space.
    #
    # https://learn.microsoft.com/en-us/typography/opentype/spec/cvar
    class Cvar < Table
      include Variation::TupleVariation

      TAG = 'cvar'

      TupleDecoder = Variation::TupleVariation
      private_constant :TupleDecoder

      # Decode the single table-wide tuple variation store.
      #
      # @param cvt_count [Integer] number of entries in the `cvt ` table.
      # @return [Array<Variation::TupleVariation::Variation>]
      def variations(cvt_count = nil)
        @cache ||= {}
        cvt_count ||= cvt_count!
        @cache[cvt_count] ||=
          begin
            data = raw
            # The cvar table starts with its own 4-byte version, followed by
            # a tuple variation store that never uses shared peak tuples.
            tuple_count_word = data[4, 2].unpack1('n')
            offset_to_data = data[6, 2].unpack1('n')

            TupleDecoder.decode(
              data, 4, 8, offset_to_data, cvt_count,
              file.fvar.axes.map(&:tag), [], TAG
            )
          end
      end

      private

      def cvt_count!
        info = file.directory_info('cvt ')
        info ? info[:length] / 2 : 0
      end

      def tag
        TAG
      end

    end
  end
end
