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
        @uvs = Set.new
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

      # Add a character to subset. A character can be followed by a variation
      # selector. In this case the pair is added to the subset as a Unicode
      # Variation Sequence. The selector itself is not added as a character.
      #
      # @param characters [Array<Integer>] Unicode codepoints
      # @return [void]
      def use(*characters)
        @subset << characters.first
        @uvs << characters.first(2) if characters.size > 1
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
      # @return [Boolean]
      def includes?(character)
        @subset.include?(character)
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
            mapping =
              @subset.each_with_object({}) do |code, map|
                map[code] = unicode_cmap[code]
              end

            uvs_mapping =
              if variation_cmap
                @uvs.each_with_object({}) do |(code, selector), map|
                  glyph_id = variation_cmap[code, selector]
                  # Unsupported variation sequences are skipped. Default UVS entries
                  # map to glyph 0 and are preserved as such.
                  map[[code, selector]] = glyph_id if glyph_id
                end
              end

            TTFunk::Table::Cmap.encode(mapping, :unicode, uvs_mapping)
          end
      end

      # Get the list of Glyph IDs from the original font that are in this
      # subset.
      #
      # @return [Array<Integer>]
      def original_glyph_ids
        uvs_glyph_ids =
          if variation_cmap
            @uvs.map { |(code, selector)| variation_cmap[code, selector] }
          else
            []
          end

        ([0] + @subset.map { |code| unicode_cmap[code] } + uvs_glyph_ids)
          .compact
          .uniq
          .sort
      end
    end
  end
end
