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
        @uvs_subset = Set.new
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
      #   provided the variation sequence is added to the subset along with
      #   the base character.
      # @return [void]
      def use(character, selector = nil)
        @subset << character
        @uvs_subset << [character, selector] if selector
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
        if selector
          @uvs_subset.include?([character, selector])
        else
          @subset.include?(character)
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
          if @uvs_subset.empty?
            base_cmap_table
          else
            TTFunk::Table::Cmap.encode(
              charmap_source,
              :unicode,
              uvs: new_uvs_records,
            )
          end
      end

      # Character map of the new `cmap` table.
      #
      # @return [Hash{Integer => Hash}]
      def new_cmap_charmap
        base_cmap_table[:charmap]
      end

      # First glyph ID after the ones assigned by the new `cmap` table.
      #
      # @return [Integer]
      def new_cmap_max_glyph_id
        base_cmap_table[:max_glyph_id]
      end

      # Get the list of Glyph IDs from the original font that are in this
      # subset.
      #
      # @return [Array<Integer>]
      def original_glyph_ids
        ([0] + @subset.map { |code| unicode_cmap[code] } + uvs_glyph_ids)
          .uniq.sort
      end

      private

      def charmap_source
        @subset.each_with_object({}) do |code, map|
          map[code] = unicode_cmap[code]
        end
      end

      def base_cmap_table
        @base_cmap_table ||=
          TTFunk::Table::Cmap.encode(charmap_source, :unicode)
      end

      def uvs_cmap
        original.cmap.uvs.first
      end

      def uvs_glyph_ids
        return [] if uvs_cmap.nil?

        @uvs_subset.filter_map do |code, selector|
          uvs_cmap.non_default_uvs_mappings(selector)[code]
        end
      end

      def new_uvs_records
        @uvs_subset.sort.each_with_object({}) do |(code, selector), records|
          record = records[selector] ||= { default: [], non_default: {} }

          if uvs_cmap&.non_default_uvs?(code, selector)
            old_glyph_id = uvs_cmap.non_default_uvs_mappings(selector)[code]
            record[:non_default][code] = old_to_new_glyph[old_glyph_id]
          elsif uvs_cmap&.default_uvs?(code, selector)
            record[:default] << code
          else
            raise TTFunk::Error,
              format(
                'variation sequence U+%04X U+%06X is not supported by this font',
                code, selector
              )
          end
        end
      end
    end
  end
end
