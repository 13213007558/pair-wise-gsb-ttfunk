# frozen_string_literal: true

require_relative '../table'
require_relative 'gsub/bin_reader'
require_relative 'gsub/coverage'
require_relative 'gsub/class_def'
require_relative 'gsub/subtable'
require_relative 'gsub/lookup'
require_relative 'gsub/subset'

module TTFunk
  class Table
    # Glyph Substitution (`GSUB`) table.
    class Gsub < Table
      # Table tag.
      TAG = 'GSUB'

      # Default script tag.
      DEFAULT_SCRIPT = 'DFLT'

      # Table version.
      #
      # @return [Integer]
      attr_reader :version

      # Scripts indexed by their tags. Each entry has a `:default` LangSys
      # (or nil) and a `:languages` hash of LangSys entries indexed by
      # language tag.
      #
      # @return [Hash{String => Hash}]
      attr_reader :scripts

      # Features in FeatureList order. Each feature has a `:tag` and
      # `:lookup_indices`.
      #
      # @return [Array<Hash>]
      attr_reader :features

      # Lookups in LookupList order.
      #
      # @return [Array<TTFunk::Table::Gsub::Lookup>]
      attr_reader :lookups

      # Table tag.
      #
      # @return [String]
      def tag
        TAG
      end

      # LangSys for the given script and language.
      #
      # @param script [String] script tag. Falls back to `DFLT` if not
      #   present in the font.
      # @param language [String, nil] language tag. Falls back to the
      #   script's default LangSys if not present.
      # @return [Hash, nil]
      def langsys_for(script:, language: nil)
        script_entry = scripts[script] || scripts[DEFAULT_SCRIPT]
        return nil unless script_entry

        if language
          langsys = script_entry[:languages][language]
          return langsys if langsys
        end

        script_entry[:default]
      end

      # Indices of features enabled for the given script, language, and
      # feature tags.
      #
      # @param script [String] script tag.
      # @param language [String, nil] language tag.
      # @param feature_tags [Array<String>, nil] feature tags to enable. All
      #   features are enabled if nil.
      # @return [Array<Integer>]
      def feature_indices_for(script:, language: nil, feature_tags: nil)
        langsys = langsys_for(script: script, language: language)
        return [] unless langsys

        indices = langsys[:feature_indices].dup
        required = langsys[:required_feature_index]
        indices << required if required != 0xFFFF

        indices.uniq.sort.select do |index|
          feature = features[index]
          feature && (feature_tags.nil? || feature_tags.include?(feature[:tag]))
        end
      end

      # Lookups enabled for the given script, language, and feature tags,
      # in LookupList order.
      #
      # @param script [String] script tag.
      # @param language [String, nil] language tag.
      # @param features [Array<String>, nil] feature tags to enable. All
      #   features are enabled if nil.
      # @return [Array<TTFunk::Table::Gsub::Lookup>]
      def lookups_for(script:, language: nil, features: nil)
        feature_indices_for(script: script, language: language, feature_tags: features)
          .flat_map { |index| self.features[index][:lookup_indices] }
          .uniq
          .sort
          .map { |index| lookups[index] }
      end

      private

      def parse!
        data = raw
        @version = BinReader.u32(data, 0)
        @scripts = parse_script_list(data, BinReader.u16(data, 4))
        @features = parse_feature_list(data, BinReader.u16(data, 6))
        @lookups = parse_lookup_list(data, BinReader.u16(data, 8))
      end

      def parse_script_list(data, offset)
        scripts = {}
        BinReader.u16(data, offset).times do |i|
          tag = BinReader.tag(data, offset + 2 + (i * 6))
          script_offset = offset + BinReader.u16(data, offset + 2 + (i * 6) + 4)
          scripts[tag] = parse_script(data, script_offset)
        end
        scripts
      end

      def parse_script(data, offset)
        default_offset = BinReader.u16(data, offset)
        languages = {}
        BinReader.u16(data, offset + 2).times do |i|
          tag = BinReader.tag(data, offset + 4 + (i * 6))
          langsys_offset = offset + BinReader.u16(data, offset + 4 + (i * 6) + 4)
          languages[tag] = parse_lang_sys(data, langsys_offset)
        end

        {
          default: default_offset.zero? ? nil : parse_lang_sys(data, offset + default_offset),
          languages: languages,
        }
      end

      def parse_lang_sys(data, offset)
        {
          required_feature_index: BinReader.u16(data, offset + 2),
          feature_indices: BinReader.u16s(data, offset + 6, BinReader.u16(data, offset + 4)),
        }
      end

      def parse_feature_list(data, offset)
        Array.new(BinReader.u16(data, offset)) do |i|
          feature_offset = offset + BinReader.u16(data, offset + 2 + (i * 6) + 4)
          {
            tag: BinReader.tag(data, offset + 2 + (i * 6)),
            lookup_indices: BinReader.u16s(
              data,
              feature_offset + 4,
              BinReader.u16(data, feature_offset + 2),
            ),
          }
        end
      end

      def parse_lookup_list(data, offset)
        Array.new(BinReader.u16(data, offset)) do |i|
          Lookup.parse(data, offset + BinReader.u16(data, offset + 2 + (i * 2)))
        end
      end
    end
  end
end
