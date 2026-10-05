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
      # @param charmap [Hash{Integer, Array(Integer, Integer) => Integer, nil}]
      #   keys are character codes or `[character code, variation selector]`
      #   pairs, values are glyph IDs in the original font. Variation
      #   sequences that map to the default glyph have `nil` values.
      # @param encoding [Symbol]
      # @return [Hash]
      #   * `:charmap` (<tt>Hash{Integer, Array => Hash}</tt>) keys are the
      #     characters in `charmap`, values are hashes:
      #     * `:old` (<tt>Integer</tt>) - glyph ID in the original font.
      #     * `:new` (<tt>Integer</tt>) - glyph ID in the subset font.
      #   * `:table` (<tt>String</tt>) - serialized table.
      #   * `:max_glyph_id` (<tt>Integer</tt>) - maximum glyph ID in the new font.
      def self.encode(charmap, encoding)
        sequences = {}
        base_charmap = {}
        charmap.each do |code, glyph_id|
          if code.is_a?(Array)
            sequences[code] = glyph_id
          else
            base_charmap[code] = glyph_id
          end
        end

        result = Cmap::Subtable.encode(base_charmap, encoding)

        records = [
          [result[:platform_id], result[:encoding_id], result.delete(:subtable)],
        ]

        unless sequences.empty?
          uvs = Cmap::Format14.encode(
            sequences, result[:charmap], result[:max_glyph_id],
          )
          result[:charmap].merge!(uvs[:charmap])
          result[:max_glyph_id] = uvs[:max_glyph_id]
          records << [
            Cmap::Format14::UNICODE_PLATFORM_ID,
            Cmap::Format14::UVS_ENCODING_ID,
            uvs[:subtable],
          ]
        end

        result[:table] = encode_table(records)
        result
      end

      # Encode table from encoding records.
      #
      # @param records [Array<Array(Integer, Integer, String)>] each record
      #   is a triplet of platform ID, encoding ID, and serialized subtable.
      # @return [String]
      def self.encode_table(records)
        # table header and encoding records
        offset = 4 + (8 * records.length)

        # pack 'version' and 'table-count'
        table = [0, records.length].pack('nn')
        records.each do |platform_id, encoding_id, subtable|
          table << [platform_id, encoding_id, offset].pack('nnN')
          offset += subtable.length
        end
        records.each do |(_platform_id, _encoding_id, subtable)|
          table << subtable
        end

        table
      end

      # Get Unicode Variation Sequences encoding record.
      #
      # @return [TTFunk::Table::Cmap::Subtable, nil]
      def uvs
        @uvs ||= @tables.find { |table| table.format == 14 && table.supported? }
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
