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
      # @param uvs [Hash{Integer => Hash}, nil] Unicode Variation Sequences to
      #   include in the table as a format 14 subtable. Keys are variation
      #   selector code points, values are hashes as expected by
      #   {TTFunk::Table::Cmap::Format14.encode}.
      # @return [Hash]
      #   * `:charmap` (<tt>Hash{Integer => Hash}</tt>) keys are the characrers in
      #     `charset`, values are hashes:
      #     * `:old` (<tt>Integer</tt>) - glyph ID in the original font.
      #     * `:new` (<tt>Integer</tt>) - glyph ID in the subset font.
      #     that maps the characters in charmap to a
      #   * `:table` (<tt>String</tt>) - serialized table.
      #   * `:max_glyph_id` (<tt>Integer</tt>) - maximum glyph ID in the new font.
      def self.encode(charmap, encoding, uvs: nil)
        result = Cmap::Subtable.encode(charmap, encoding)

        subtables = [
          [result[:platform_id], result[:encoding_id], result.delete(:subtable)],
        ]

        if uvs && !uvs.empty?
          subtables << [
            Cmap::Subtable::UVS_ENCODING[:platform_id],
            Cmap::Subtable::UVS_ENCODING[:encoding_id],
            Cmap::Format14.encode(uvs)[:subtable],
          ]
        end

        # pack 'version' and 'table-count'
        table = [0, subtables.length].pack('n2')

        offset = 4 + (8 * subtables.length)
        subtables.each do |platform_id, encoding_id, subtable|
          table << [platform_id, encoding_id, offset].pack('nnN')
          offset += subtable.length
        end
        subtables.each { |(_, _, subtable)| table << subtable }

        result[:table] = table
        result
      end

      # Get Unicode Variation Sequences encoding records.
      #
      # @return [Array<TTFunk::Table::Cmap::Subtable>]
      def uvs
        @uvs ||=
          @tables.select { |table| table.format == 14 && table.supported? }
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
