# frozen_string_literal: true

module TTFunk
  class Table
    # Character to Glyph Index Mapping (`cmap`) table.
    class Cmap < Table
      # Table version.
      # @return [Integer]
      attr_reader :version

      # Encoding tables.
      # @return [Array<TTFunk::Table::Cmap::Subtable>]
      attr_reader :tables

      # Encode table.
      #
      # @param charmap [Hash{Integer => Integer}]
      # @param encoding [Symbol]
      # @return [Hash]
      #   * `:charmap` (<tt>Hash{Integer => Hash}</tt>) keys are the characrers in
      #     `charset`, values are hashes:
      #     * `:old` (<tt>Integer</tt>) - glyph ID in the original font.
      #     * `:new` (<tt>Integer</tt>) - glyph ID in the subset font.
      #     that maps the characters in charmap to a
      #   * `:table` (<tt>String</tt>) - serialized table.
      #   * `:max_glyph_id` (<tt>Integer</tt>) - maximum glyph ID in the new font.
      def self.encode(charmap, encoding)
        result = Cmap::Subtable.encode(charmap, encoding)

        # pack 'version' and 'table-count'
        result[:table] = [0, 1, result.delete(:subtable)].pack('nnA*')
        result
      end

      # Add a Unicode Variation Sequences (format 14) subtable to an encoded
      # table.
      #
      # @param table [String] serialized table as returned by {.encode}.
      # @param uvs [String] serialized format 14 subtable as returned by
      #   {TTFunk::Table::Cmap::Format14.encode}.
      # @return [String] serialized table with the additional encoding record.
      def self.encode_with_uvs(table, uvs)
        version, count = table.unpack('nn')
        data_start = 4 + (count * 8)
        data = table[data_start..]

        records =
          Array.new(count) do |i|
            platform_id, encoding_id, offset =
              table[4 + (i * 8), 8].unpack('nnN')
            [platform_id, encoding_id, offset + 8]
          end
        records << [0, 5, data_start + 8 + data.length]

        [version, count + 1].pack('nn') +
          records.map { |record| record.pack('nnN') }.join +
          data +
          uvs
      end

      # Get Unicode encoding records.
      #
      # @return [Array<TTFunk::Table::Cmap::Subtable>]
      def unicode
        # Because most callers just call .first on the result, put tables with
        # highest-number format first. Unsupported formats will be ignored.
        @unicode ||=
          @tables
            .select { |table| table.unicode? && table.supported? }
            .sort { |a, b| b.format <=> a.format }
      end

      # Get the Unicode Variation Sequences (format 14) encoding record.
      #
      # @return [TTFunk::Table::Cmap::Subtable, nil]
      def uvs
        @uvs ||=
          @tables.find { |table| table.format == 14 && table.supported? }
      end

      private

      def parse!
        @version, table_count = read(4, 'nn')
        @tables =
          Array.new(table_count) do
            Cmap::Subtable.new(file, offset)
          end
      end
    end
  end
end

require_relative 'cmap/subtable'
