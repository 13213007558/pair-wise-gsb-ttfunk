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
      # @param uvs_charmap [Hash{Array(Integer, Integer) => Integer}, nil]
      #   optional Unicode Variation Sequences mapping. Keys are two-element
      #   arrays of a Unicode codepoint and a variation selector codepoint,
      #   values are glyph IDs in the original font. Glyph ID 0 denotes
      #   a default UVS entry.
      # @return [Hash]
      #   * `:charmap` (<tt>Hash{Integer => Hash}</tt>) keys are the characrers in
      #     `charset`, values are hashes:
      #     * `:old` (<tt>Integer</tt>) - glyph ID in the original font.
      #     * `:new` (<tt>Integer</tt>) - glyph ID in the subset font.
      #     that maps the characters in charmap to a
      #   * `:table` (<tt>String</tt>) - serialized table.
      #   * `:max_glyph_id` (<tt>Integer</tt>) - maximum glyph ID in the new font.
      #   * `:uvs` (<tt>Hash{Array(Integer, Integer) => Hash}</tt>) - Unicode
      #     Variation Sequences mapping, present only when `uvs_charmap` is
      #     given. Keys are the character/selector pairs, values are hashes:
      #     * `:old` (<tt>Integer</tt>) - glyph ID in the original font.
      #     * `:new` (<tt>Integer</tt>) - glyph ID in the subset font.
      def self.encode(charmap, encoding, uvs_charmap = nil)
        if uvs_charmap.nil? || uvs_charmap.empty?
          result = Cmap::Subtable.encode(charmap, encoding)

          # pack 'version' and 'table-count'
          result[:table] = [0, 1, result.delete(:subtable)].pack('nnA*')
        else
          # With two encoding records both records come first (each 8 bytes
          # long), followed by the subtable bodies.
          result = Cmap::Subtable.encode(charmap, encoding, 20)
          main_record, main_body = result.delete(:subtable).unpack('a8a*')

          # Non-default UVS glyph IDs are renumbered consistently with the
          # main character mapping.
          glyph_map = { 0 => 0 }
          result[:charmap].each_value do |ids|
            glyph_map[ids[:old]] = ids[:new]
          end

          uvs_result = Cmap::Subtable.encode(
            uvs_charmap,
            :unicode_uvs,
            20 + main_body.length,
            glyph_map: glyph_map,
          )
          uvs_record, uvs_body = uvs_result.delete(:subtable).unpack('a8a*')

          result[:uvs] = uvs_result[:charmap]
          result[:max_glyph_id] = uvs_result[:max_glyph_id]

          # pack 'version' and 'table-count'
          result[:table] = [
            0, 2,
            main_record,
            uvs_record,
            main_body,
            uvs_body,
          ].pack('nnA*A*A*A*')
        end

        result
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

      # Get Unicode Variation Sequences encoding record.
      #
      # @return [TTFunk::Table::Cmap::Subtable, nil]
      def variation
        @variation ||=
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
