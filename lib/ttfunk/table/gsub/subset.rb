# frozen_string_literal: true

require 'set'

module TTFunk
  class Table
    class Gsub < Table
      # Shaping-aware subset of a GSUB table.
      #
      # Keeps only the features enabled for the requested script and
      # language along with the lookups reachable from them, computes the
      # closure of glyphs those lookups can produce, and re-encodes the
      # table with remapped glyph IDs and lookup indices.
      class Subset
        # GSUB table to subset.
        #
        # @return [TTFunk::Table::Gsub]
        attr_reader :gsub

        # Script tag.
        #
        # @return [String]
        attr_reader :script

        # Language tag.
        #
        # @return [String, nil]
        attr_reader :language

        # Enabled feature tags.
        #
        # @return [Array<String>]
        attr_reader :feature_tags

        # @param gsub [TTFunk::Table::Gsub]
        # @param script [String]
        # @param language [String, nil]
        # @param feature_tags [Array<String>]
        def initialize(gsub, script:, language:, feature_tags:)
          @gsub = gsub
          @script = script
          @language = language
          @feature_tags = feature_tags
        end

        # Features enabled for the requested script and language, in
        # FeatureList order. Each entry has :tag, :lookup_indices, and
        # :required.
        #
        # @return [Array<Hash>]
        def enabled_features
          @enabled_features ||=
            begin
              langsys = gsub.langsys_for(script: script, language: language)
              if langsys
                required = langsys[:required_feature_index]
                indices = langsys[:feature_indices].dup
                indices << required if required != 0xFFFF

                indices.uniq.sort.filter_map do |index|
                  feature = gsub.features[index]
                  next unless feature && feature_tags.include?(feature[:tag])

                  {
                    tag: feature[:tag],
                    lookup_indices: feature[:lookup_indices],
                    required: index == required,
                  }
                end
              else
                []
              end
            end
        end

        # Indices of lookups reachable from the enabled features, including
        # lookups nested in contextual subtables, in LookupList order.
        #
        # @return [Array<Integer>]
        def reachable_lookup_indices
          @reachable_lookup_indices ||=
            begin
              seen = Set.new
              queue = enabled_features.flat_map { |feature| feature[:lookup_indices] }

              until queue.empty?
                index = queue.shift
                next if seen.include?(index)

                seen << index
                lookup = gsub.lookups[index]
                unless lookup
                  raise TTFunk::Error, "GSUB lookup index #{index} is out of range"
                end

                queue.concat(
                  lookup.subtables.flat_map { |subtable|
                    Subtable.nested_lookup_indices(subtable)
                  },
                )
              end

              seen.to_a.sort
            end
        end

        # Closure of glyph IDs producible from the seed glyphs by the
        # reachable lookups. Includes the seed glyphs.
        #
        # @param seed_glyphs [Array<Integer>]
        # @return [Set<Integer>]
        def closure(seed_glyphs)
          glyphs = seed_glyphs.to_set

          loop do
            additions = reachable_lookup_indices.flat_map { |index|
              gsub.lookups[index].subtables.flat_map { |subtable|
                Subtable.produced_glyphs(subtable, glyphs)
              }
            }.to_set - glyphs
            break if additions.empty?

            glyphs.merge(additions)
          end

          glyphs
        end

        # Encode the subset GSUB table.
        #
        # @param old_to_new [Hash{Integer => Integer}] glyph ID mapping
        #   from the original font to the subset font.
        # @return [String, nil] nil if no enabled features survive.
        def encode(old_to_new)
          lookups = remap_lookups(old_to_new)
          return nil if lookups.empty?

          lookup_map = lookups.each_with_index.to_h { |(old_index, _, _), i|
            [old_index, i]
          }
          features = enabled_features.filter_map { |feature|
            indices = feature[:lookup_indices].filter_map { |index| lookup_map[index] }
            next if indices.empty?

            { tag: feature[:tag], lookup_indices: indices, required: feature[:required] }
          }
          return nil if features.empty?

          script_list = encode_script_list(features)
          feature_list = encode_feature_list(features)
          lookup_list = encode_lookup_list(lookups)

          script_list_offset = 10
          feature_list_offset = script_list_offset + script_list.bytesize
          lookup_list_offset = feature_list_offset + feature_list.bytesize

          (
            [0x00010000, script_list_offset, feature_list_offset, lookup_list_offset].pack('Nnnn') +
            script_list +
            feature_list +
            lookup_list
          )
        end

        private

        # Remap reachable lookups to the subset glyph space. Returns an
        # array of [original index, lookup, remapped subtables] for lookups
        # that survive. Iterates to a fixpoint because dropping a lookup
        # can leave dangling references in contextual subtables of other
        # lookups.
        def remap_lookups(old_to_new)
          candidates = reachable_lookup_indices

          loop do
            lookup_map = candidates.each_with_index.to_h
            survivors = candidates.filter_map { |index|
              lookup = gsub.lookups[index]
              subtables = lookup.subtables.filter_map { |subtable|
                Subtable.remap(subtable, old_to_new, lookup_map)
              }
              [index, lookup, subtables] unless subtables.empty?
            }
            new_candidates = survivors.map(&:first)
            return survivors if new_candidates == candidates

            candidates = new_candidates
          end
        end

        def encode_script_list(features)
          feature_indices = features.each_index.to_a
          required_index = features.index { |feature| feature[:required] } || 0xFFFF
          langsys = [0, required_index, feature_indices.length, *feature_indices].pack('nnnn*')

          script_data =
            if language
              [0, 1].pack('nn') + [language, 10].pack('a4n') + langsys
            else
              [4, 0].pack('nn') + langsys
            end

          [1].pack('n') + [script, 8].pack('a4n') + script_data
        end

        def encode_feature_list(features)
          blocks = features.map { |feature|
            [0, feature[:lookup_indices].length, *feature[:lookup_indices]].pack('nnn*')
          }

          records = +''
          position = 2 + (features.length * 6)
          features.each_with_index do |feature, i|
            records += [feature[:tag], position].pack('a4n')
            position += blocks[i].bytesize
          end

          [features.length].pack('n') + records + blocks.join
        end

        def encode_lookup_list(lookups)
          blocks = lookups.map { |(_, lookup, subtables)|
            Lookup.encode(
              lookup.type,
              lookup.flag,
              lookup.mark_filtering_set,
              subtables.map { |subtable| Subtable.encode(subtable) },
            )
          }

          offsets = []
          position = 2 + (blocks.length * 2)
          blocks.each do |block|
            offsets << position
            position += block.bytesize
          end

          [blocks.length].pack('n') + offsets.pack('n*') + blocks.join
        end
      end
    end
  end
end
