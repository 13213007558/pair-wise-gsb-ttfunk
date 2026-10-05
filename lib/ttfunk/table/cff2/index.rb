# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      # CFF2 INDEX. Unlike CFF1, CFF2 uses a 32-bit entry count.
      class Index < TTFunk::Table::Cff::Index
        def encode(*)
          raise TTFunk::Error, 'encoding CFF2 INDEX data is not supported'
        end

        private

        def index_count_size
          4
        end

        def index_count_unpack
          'N'
        end
      end
    end
  end
end
