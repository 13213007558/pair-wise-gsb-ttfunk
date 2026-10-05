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
        @variation_sequences = Set.new
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
      # @param selector [Integer, nil] Unicode variation selector codepoint.
      #   When specified the character along with the selector forms
      #   a variation sequence. The selector itself is not added to
      #   the subset as a character.
      # @return [void]
      def use(character, selector = nil)
        if selector
          @variation_sequences << [character, selector]
        else
          @subset << character
        end
      end

      # Can this subset include the character?
      #
      # @param _character [Integer] Unicode codepoint
      # @param _selector [Integer, nil] Unicode variation selector codepoint
      # @return [true]
      def covers?(_character, _selector = nil)
        true
      end

      # Does this subset actually has the character?
      #
      # @param character [Integer] Unicode codepoint
      # @param selector [Integer, nil] Unicode variation selector codepoint
      # @return [Boolean]
      def includes?(character, selector = nil)
        if selector
          @variation_sequences.include?([character, selector])
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
          begin
            mapping =
              @subset.each_with_object({}) do |code, map|
                map[code] = unicode_cmap[code]
              end

            @variation_sequences.each do |(code, selector)|
              glyph_id = variation_glyph_id(code, selector)

              if glyph_id
                mapping[[code, selector]] = glyph_id
              else
                # The sequence is either mapped to the default glyph or
                # not supported by the font at all. In both cases the
                # base character is rendered with the default glyph so
                # it has to be included in the subset. Only default
                # variation sequences are recorded in the `cmap`
                # format 14 table.
                mapping[code] ||= unicode_cmap[code]
                mapping[[code, selector]] = nil if default_uvs?(code, selector)
              end
            end

            TTFunk::Table::Cmap.encode(mapping, :unicode)
          end
      end

      # Get the list of Glyph IDs from the original font that are in this
      # subset.
      #
      # @return [Array<Integer>]
      def original_glyph_ids
        glyph_ids = new_cmap_table[:charmap].values.map { |ids| ids[:old] }
        ([0] + glyph_ids).uniq.sort
      end

      private

      # Get the Unicode Variation Sequences `cmap` of the original font.
      #
      # @return [TTFunk::Table::Cmap::Subtable, nil]
      def uvs_cmap
        @uvs_cmap ||= @original.cmap.uvs
      end

      # Get glyph ID for the variation sequence in the original font.
      #
      # @param code [Integer] Unicode codepoint
      # @param selector [Integer] Unicode variation selector codepoint
      # @return [Integer, nil] glyph ID for a non-default variation
      #   sequence, `nil` otherwise
      def variation_glyph_id(code, selector)
        uvs_cmap&.[](code, selector)
      end

      # Is the variation sequence mapped to the default glyph in the
      # original font?
      #
      # @param code [Integer] Unicode codepoint
      # @param selector [Integer] Unicode variation selector codepoint
      # @return [Boolean]
      def default_uvs?(code, selector)
        uvs_cmap&.default_uvs?(code, selector) || false
      end
    end
  end
end
