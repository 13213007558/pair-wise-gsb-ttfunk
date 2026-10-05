# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      class Header < TTFunk::SubTable
        attr_reader :major
        attr_reader :minor
        attr_reader :header_size
        attr_reader :top_dict_length

        attr_reader :length

        private

        def parse!
          @length = 4
          @major, @minor, @header_size, top_dict_length_size = read(4, 'C*')
          @length = @header_size
          @top_dict_length = read(top_dict_length_size, 'C*').inject(0) { |value, byte|
            (value << 8) | byte
          }
        end
      end
    end
  end
end
