# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      # CFF2 header.
      class Header
        # CFF table major version.
        # @return [Integer]
        attr_reader :major

        # CFF table minor version.
        # @return [Integer]
        attr_reader :minor

        # Size of the header itself.
        # @return [Integer]
        attr_reader :header_size

        # Length of the top dict.
        # @return [Integer]
        attr_reader :top_dict_length

      end
    end
  end
end
