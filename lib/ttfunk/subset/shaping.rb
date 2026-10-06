# frozen_string_literal: true

require_relative 'unicode'

module TTFunk
  module Subset
    # Shaping-aware Unicode subset.
    #
    # In addition to the glyphs directly referenced by characters, keeps
    # the glyphs producible by the selected GSUB features so that later
    # shaping (ligatures, contextual substitutions, etc.) works on the
    # subset font. The GSUB table itself is subsetted accordingly and
    # included in the encoded font.
    class Shaping < Unicode
      # Script tag for GSUB feature selection.
      #
      # @return [String]
      attr_reader :script

      # Language tag for GSUB feature selection.
      #
      # @return [String, nil]
      attr_reader :language

      # Enabled GSUB feature tags.
      #
      # @return [Array<String>]
      attr_reader :features

      # @param original [TTFunk::File]
      # @param script [String] script tag, defaults to `DFLT`.
      # @param language [String, nil] language tag.
      # @param features [Array<String>] GSUB feature tags to enable.
      def initialize(original, script: 'DFLT', language: nil, features: [])
        super(original)
        @script = script
        @language = language
        @features = features
      end

      # Get the list of Glyph IDs from the original font that are in this
      # subset.
      #
      # @return [Array<Integer>]
      def original_glyph_ids
        @original_glyph_ids ||=
          begin
            seed = super
            if gsub_available?
              (seed + gsub_subset.closure(seed).to_a).uniq.sort
            else
              seed
            end
          end
      end

      # Encoded GSUB table for this subset.
      #
      # @return [String, nil] nil if the original font has no GSUB table or
      #   no features are enabled.
      def new_gsub_table
        if gsub_available?
          gsub_subset.encode(old_to_new_glyph)
        end
      end

      private

      def gsub_available?
        !features.empty? && original.gsub.exists?
      end

      def gsub_subset
        @gsub_subset ||= TTFunk::Table::Gsub::Subset.new(
          original.gsub,
          script: script,
          language: language,
          feature_tags: features,
        )
      end
    end
  end
end
