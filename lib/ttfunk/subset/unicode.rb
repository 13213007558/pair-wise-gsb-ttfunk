# frozen_string_literal: true

require 'set'
require_relative 'base'

module TTFunk
  module Subset
    # Unicode-based subset.
    class Unicode < Base
      # Space character code
      SPACE_CHAR = 0x20

      # @param original [TTFunk::File]
      def initialize(original)
        super
        @subset = Set.new
        @uvs = {}
        use(SPACE_CHAR)
      end

      # Is this a Unicode-based subset?
      #
      # @return [true]
      def unicode?
        true
      end

      # Get a mapping from this subset to Unicode.
      #
      # @return [Hash{Integer => Integer}]
      def to_unicode_map
        @subset.each_with_object({}) { |code, map| map[code] = code }
      end

      # Add a character to subset.
      #
      # @param character [Integer] Unicode codepoint
      # @param selector [Integer, nil] variation selector codepoint. When
      #   given, the variation sequence (character, selector) is added to the
      #   subset and the corresponding cmap format 14 information is preserved
      #   in the subset font.
      # @return [void]
      def use(character, selector = nil)
        if selector.nil?
          @subset << character
          return
        end

        case (glyph_id = uvs_glyph_id(character, selector))
        when TTFunk::Table::Cmap::Format14::DEFAULT_MAPPING
          @subset << character
          uvs_record(selector)[:default] << character
        when Integer
          @subset << character
          uvs_record(selector)[:non_default][character] = glyph_id
        else
          raise TTFunk::Error,
            format('unsupported variation sequence: U+%04X U+%04X', character, selector)
        end
      end

      # Can this subset include the character?
      #
      # @param _character [Integer] Unicode codepoint
      # @return [true]
      def covers?(_character)
        true
      end

      # Does this subset actually has the character?
      #
      # @param character [Integer] Unicode codepoint
      # @param selector [Integer, nil] variation selector codepoint
      # @return [Boolean]
      def includes?(character, selector = nil)
        if selector.nil?
          @subset.include?(character)
        else
          record = @uvs[selector]
          !record.nil? &&
            (record[:default].include?(character) ||
              record[:non_default].key?(character))
        end
      end

      # Get character code for Unicode codepoint.
      #
      # @param character [Integer] Unicode codepoint
      # @return [Integer]
      def from_unicode(character)
        character
      end

      # Get `cmap` table for this subset.
      #
      # @return [TTFunk::Table::Cmap]
      def new_cmap_table
        @new_cmap_table ||=
          begin
            result = base_cmap_table

            if (uvs = new_cmap_uvs)
              result = result.merge(
                table: TTFunk::Table::Cmap.encode_with_uvs(result[:table], uvs),
              )
            end

            result
          end
      end

      # Glyph ID mapping from the original font to this subset.
      #
      # @return [Hash{Integer => Integer}]
      def old_to_new_glyph
        @old_to_new_glyph ||= compute_old_to_new_glyph(base_cmap_table)
      end

      # Get the list of Glyph IDs from the original font that are in this
      # subset.
      #
      # @return [Array<Integer>]
      def original_glyph_ids
        variant_ids =
          @uvs.values.flat_map { |record| record[:non_default].values }

        ([0] + @subset.map { |code| unicode_cmap[code] } + variant_ids).uniq.sort
      end

      private

      # cmap table for this subset without the Unicode Variation Sequences
      # subtable.
      #
      # @return [Hash]
      def base_cmap_table
        @base_cmap_table ||=
          begin
            mapping =
              @subset.each_with_object({}) do |code, map|
                map[code] = unicode_cmap[code]
              end

            TTFunk::Table::Cmap.encode(mapping, :unicode)
          end
      end

      # Encoded cmap format 14 subtable containing only the variation
      # sequences requested for this subset, with glyph IDs remapped to the
      # subset font.
      #
      # @return [String, nil]
      def new_cmap_uvs
        return nil if @uvs.empty?

        uvs =
          @uvs.each_with_object({}) do |(selector, record), map|
            map[selector] = {
              default: record[:default].to_a.sort,
              non_default: record[:non_default].transform_values { |old_id|
                old_to_new_glyph.fetch(old_id)
              },
            }
          end

        TTFunk::Table::Cmap::Format14.encode(uvs)
      end

      # Glyph ID for a variation sequence in the original font.
      #
      # @param character [Integer] Unicode codepoint
      # @param selector [Integer] variation selector codepoint
      # @return [Integer, :default, nil]
      def uvs_glyph_id(character, selector)
        uvs = original.cmap.uvs

        if uvs.nil?
          raise TTFunk::Error,
            'font does not contain a cmap format 14 (UVS) table'
        end

        uvs[character, selector]
      end

      # @param selector [Integer] variation selector codepoint
      # @return [Hash]
      def uvs_record(selector)
        (@uvs[selector] ||= { default: Set.new, non_default: {} })
      end
    end
  end
end
