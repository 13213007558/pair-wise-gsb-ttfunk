# frozen_string_literal: true

module TTFunk
  class Table
    class Gsub < Table
      # Operations on GSUB lookup subtables: parsing, glyph closure,
      # remapping, and encoding.
      #
      # Subtables are represented as plain hashes. All of them have a +:type+
      # key (the effective lookup type) and a +:format+ key. Extension
      # subtables keep type 7 and nest the wrapped subtable under +:inner+.
      # @api private
      module Subtable
        module_function

        # Parse a subtable.
        #
        # @param data [String] GSUB table content.
        # @param offset [Integer] offset of the subtable in the data.
        # @param lookup_type [Integer] lookup type of the parent lookup.
        # @raise [TTFunk::Error] for unsupported lookup types and formats.
        # @return [Hash]
        def parse(data, offset, lookup_type)
          case lookup_type
          when 1 then parse_single(data, offset)
          when 2 then parse_multiple(data, offset)
          when 3 then parse_alternate(data, offset)
          when 4 then parse_ligature(data, offset)
          when 5 then parse_context(data, offset)
          when 6 then parse_chaining(data, offset)
          when 7 then parse_extension(data, offset)
          else
            raise TTFunk::Error, "unsupported GSUB lookup type #{lookup_type}"
          end
        end

        # Glyphs this subtable can produce given a set of available glyphs.
        # Contextual lookups produce no glyphs directly; their nested lookups
        # are accounted for separately.
        #
        # @param subtable [Hash]
        # @param glyphs [Set<Integer>] available glyph IDs.
        # @return [Array<Integer>]
        def produced_glyphs(subtable, glyphs)
          case subtable[:type]
          when 1
            case subtable[:format]
            when 1
              subtable[:coverage].glyphs.filter_map { |glyph_id|
                ((glyph_id + subtable[:delta]) & 0xFFFF) if glyphs.include?(glyph_id)
              }
            when 2
              subtable[:coverage].glyphs.each_with_index.filter_map { |glyph_id, i|
                subtable[:substitutes][i] if glyphs.include?(glyph_id)
              }
            end
          when 2, 3
            key = subtable[:type] == 2 ? :sequences : :alternates
            subtable[:coverage].glyphs.each_with_index.flat_map { |glyph_id, i|
              glyphs.include?(glyph_id) ? subtable[key][i] : []
            }
          when 4
            subtable[:coverage].glyphs.each_with_index.flat_map { |glyph_id, i|
              next [] unless glyphs.include?(glyph_id)

              subtable[:ligature_sets][i].filter_map { |ligature|
                if ligature[:components].all? { |component| glyphs.include?(component) }
                  ligature[:ligature]
                end
              }
            }
          when 5, 6
            []
          when 7
            produced_glyphs(subtable[:inner], glyphs)
          end
        end

        # Indices of lookups nested in this subtable (contextual lookups
        # reference other lookups in their substitution records).
        #
        # @param subtable [Hash]
        # @return [Array<Integer>]
        def nested_lookup_indices(subtable)
          case subtable[:type]
          when 5, 6
            records(subtable).map { |record| record[:lookup_index] }
          when 7
            nested_lookup_indices(subtable[:inner])
          else
            []
          end
        end

        # All substitution records in a contextual subtable.
        #
        # @param subtable [Hash]
        # @return [Array<Hash>]
        def records(subtable)
          case subtable[:format]
          when 1, 2
            sets = subtable[:rule_sets] || subtable[:class_sets] || []
            sets.compact.flat_map { |rules|
              rules.flat_map { |rule| rule[:records] }
            }
          when 3
            subtable[:records]
          end
        end

        # Parsing

        def parse_single(data, offset)
          format = BinReader.u16(data, offset)
          coverage = Coverage.parse(data, offset + BinReader.u16(data, offset + 2))

          case format
          when 1
            {
              type: 1,
              format: 1,
              coverage: coverage,
              delta: BinReader.i16(data, offset + 4),
            }
          when 2
            count = BinReader.u16(data, offset + 4)
            {
              type: 1,
              format: 2,
              coverage: coverage,
              substitutes: BinReader.u16s(data, offset + 6, count),
            }
          else
            raise TTFunk::Error, "unsupported single substitution format #{format}"
          end
        end

        def parse_multiple(data, offset)
          parse_set_subtable(data, offset, 2, :sequences)
        end

        def parse_alternate(data, offset)
          parse_set_subtable(data, offset, 3, :alternates)
        end

        def parse_set_subtable(data, offset, type, key)
          format = BinReader.u16(data, offset)
          unless format == 1
            raise TTFunk::Error,
              "unsupported substitution format #{format} for lookup type #{type}"
          end

          coverage = Coverage.parse(data, offset + BinReader.u16(data, offset + 2))
          count = BinReader.u16(data, offset + 4)
          sets = Array.new(count) do |i|
            set_offset = offset + BinReader.u16(data, offset + 6 + (i * 2))
            BinReader.u16s(data, set_offset + 2, BinReader.u16(data, set_offset))
          end

          { type: type, format: 1, coverage: coverage, key => sets }
        end

        def parse_ligature(data, offset)
          format = BinReader.u16(data, offset)
          unless format == 1
            raise TTFunk::Error, "unsupported ligature substitution format #{format}"
          end

          coverage = Coverage.parse(data, offset + BinReader.u16(data, offset + 2))
          count = BinReader.u16(data, offset + 4)
          sets = Array.new(count) do |i|
            set_offset = offset + BinReader.u16(data, offset + 6 + (i * 2))
            ligature_count = BinReader.u16(data, set_offset)
            Array.new(ligature_count) do |j|
              ligature_offset = set_offset + BinReader.u16(data, set_offset + 2 + (j * 2))
              component_count = BinReader.u16(data, ligature_offset + 2)
              {
                ligature: BinReader.u16(data, ligature_offset),
                components: BinReader.u16s(data, ligature_offset + 4, component_count - 1),
              }
            end
          end

          { type: 4, format: 1, coverage: coverage, ligature_sets: sets }
        end

        def parse_context(data, offset)
          format = BinReader.u16(data, offset)

          case format
          when 1
            coverage = Coverage.parse(data, offset + BinReader.u16(data, offset + 2))
            count = BinReader.u16(data, offset + 4)
            rule_sets = Array.new(count) do |i|
              relative = BinReader.u16(data, offset + 6 + (i * 2))
              parse_rule_set(data, offset + relative) unless relative.zero?
            end
            { type: 5, format: 1, coverage: coverage, rule_sets: rule_sets }
          when 2
            coverage = Coverage.parse(data, offset + BinReader.u16(data, offset + 2))
            class_def = ClassDef.parse(data, offset + BinReader.u16(data, offset + 4))
            count = BinReader.u16(data, offset + 6)
            class_sets = Array.new(count) do |i|
              relative = BinReader.u16(data, offset + 8 + (i * 2))
              parse_class_rule_set(data, offset + relative) unless relative.zero?
            end
            {
              type: 5,
              format: 2,
              coverage: coverage,
              class_def: class_def,
              class_sets: class_sets,
            }
          when 3
            glyph_count = BinReader.u16(data, offset + 2)
            record_count = BinReader.u16(data, offset + 4)
            coverages = Array.new(glyph_count) do |i|
              Coverage.parse(data, offset + BinReader.u16(data, offset + 6 + (i * 2)))
            end
            {
              type: 5,
              format: 3,
              coverages: coverages,
              records: parse_records(data, offset + 6 + (glyph_count * 2), record_count),
            }
          else
            raise TTFunk::Error, "unsupported contextual substitution format #{format}"
          end
        end

        def parse_chaining(data, offset)
          format = BinReader.u16(data, offset)

          case format
          when 1
            coverage = Coverage.parse(data, offset + BinReader.u16(data, offset + 2))
            count = BinReader.u16(data, offset + 4)
            rule_sets = Array.new(count) do |i|
              relative = BinReader.u16(data, offset + 6 + (i * 2))
              parse_chain_rule_set(data, offset + relative) unless relative.zero?
            end
            { type: 6, format: 1, coverage: coverage, rule_sets: rule_sets }
          when 2
            coverage = Coverage.parse(data, offset + BinReader.u16(data, offset + 2))
            count = BinReader.u16(data, offset + 10)
            class_sets = Array.new(count) do |i|
              relative = BinReader.u16(data, offset + 12 + (i * 2))
              parse_chain_class_rule_set(data, offset + relative) unless relative.zero?
            end
            {
              type: 6,
              format: 2,
              coverage: coverage,
              backtrack_class_def: ClassDef.parse(data, offset + BinReader.u16(data, offset + 4)),
              input_class_def: ClassDef.parse(data, offset + BinReader.u16(data, offset + 6)),
              lookahead_class_def: ClassDef.parse(data, offset + BinReader.u16(data, offset + 8)),
              class_sets: class_sets,
            }
          when 3
            backtrack_count = BinReader.u16(data, offset + 2)
            backtrack = Array.new(backtrack_count) do |i|
              Coverage.parse(data, offset + BinReader.u16(data, offset + 4 + (i * 2)))
            end
            position = offset + 4 + (backtrack_count * 2)
            input_count = BinReader.u16(data, position)
            input = Array.new(input_count) do |i|
              Coverage.parse(data, offset + BinReader.u16(data, position + 2 + (i * 2)))
            end
            position += 2 + (input_count * 2)
            lookahead_count = BinReader.u16(data, position)
            lookahead = Array.new(lookahead_count) do |i|
              Coverage.parse(data, offset + BinReader.u16(data, position + 2 + (i * 2)))
            end
            position += 2 + (lookahead_count * 2)
            record_count = BinReader.u16(data, position)
            {
              type: 6,
              format: 3,
              backtrack_coverages: backtrack,
              input_coverages: input,
              lookahead_coverages: lookahead,
              records: parse_records(data, position + 2, record_count),
            }
          else
            raise TTFunk::Error,
              "unsupported chaining contextual substitution format #{format}"
          end
        end

        def parse_extension(data, offset)
          format = BinReader.u16(data, offset)
          unless format == 1
            raise TTFunk::Error, "unsupported extension substitution format #{format}"
          end

          extension_type = BinReader.u16(data, offset + 2)
          {
            type: 7,
            format: 1,
            extension_type: extension_type,
            inner: parse(data, offset + BinReader.u32(data, offset + 4), extension_type),
          }
        end

        def parse_rule_set(data, offset)
          count = BinReader.u16(data, offset)
          Array.new(count) do |i|
            rule_offset = offset + BinReader.u16(data, offset + 2 + (i * 2))
            glyph_count = BinReader.u16(data, rule_offset)
            record_count = BinReader.u16(data, rule_offset + 2)
            {
              input: BinReader.u16s(data, rule_offset + 4, glyph_count - 1),
              records: parse_records(data, rule_offset + 4 + ((glyph_count - 1) * 2), record_count),
            }
          end
        end

        def parse_class_rule_set(data, offset)
          count = BinReader.u16(data, offset)
          Array.new(count) do |i|
            rule_offset = offset + BinReader.u16(data, offset + 2 + (i * 2))
            glyph_count = BinReader.u16(data, rule_offset)
            record_count = BinReader.u16(data, rule_offset + 2)
            {
              classes: BinReader.u16s(data, rule_offset + 4, glyph_count - 1),
              records: parse_records(data, rule_offset + 4 + ((glyph_count - 1) * 2), record_count),
            }
          end
        end

        def parse_chain_rule_set(data, offset)
          count = BinReader.u16(data, offset)
          Array.new(count) do |i|
            rule_offset = offset + BinReader.u16(data, offset + 2 + (i * 2))
            parse_chain_rule(data, rule_offset)
          end
        end

        def parse_chain_class_rule_set(data, offset)
          parse_chain_rule_set(data, offset)
        end

        # Chain rules have identical binary layout in glyph-based (format 1)
        # and class-based (format 2) subtables; only the interpretation of
        # the sequence values differs.
        def parse_chain_rule(data, offset)
          backtrack_count = BinReader.u16(data, offset)
          backtrack = BinReader.u16s(data, offset + 2, backtrack_count)
          position = offset + 2 + (backtrack_count * 2)
          input_count = BinReader.u16(data, position)
          input = BinReader.u16s(data, position + 2, input_count - 1)
          position += 2 + ((input_count - 1) * 2)
          lookahead_count = BinReader.u16(data, position)
          lookahead = BinReader.u16s(data, position + 2, lookahead_count)
          position += 2 + (lookahead_count * 2)
          record_count = BinReader.u16(data, position)
          {
            backtrack: backtrack,
            input: input,
            lookahead: lookahead,
            records: parse_records(data, position + 2, record_count),
          }
        end

        def parse_records(data, offset, count)
          Array.new(count) do |i|
            sequence_index, lookup_index = BinReader.u16s(data, offset + (i * 4), 2)
            { sequence_index: sequence_index, lookup_index: lookup_index }
          end
        end

        # Remapping

        # Build a new subtable with glyph IDs translated through the glyph
        # map and nested lookup references translated through the lookup map.
        # Coverage entries and rules that reference glyphs missing from the
        # glyph map are dropped.
        #
        # @param subtable [Hash]
        # @param glyph_map [Hash{Integer => Integer}]
        # @param lookup_map [Hash{Integer => Integer}]
        # @return [Hash, nil] nil if the subtable can't match anything.
        def remap(subtable, glyph_map, lookup_map)
          case subtable[:type]
          when 1 then remap_single(subtable, glyph_map)
          when 2, 3 then remap_multiple_alternate(subtable, glyph_map)
          when 4 then remap_ligature(subtable, glyph_map)
          when 5 then remap_context(subtable, glyph_map, lookup_map)
          when 6 then remap_chaining(subtable, glyph_map, lookup_map)
          when 7
            inner = remap(subtable[:inner], glyph_map, lookup_map)
            if inner
              {
                type: 7,
                format: 1,
                extension_type: subtable[:extension_type],
                inner: inner,
              }
            end
          end
        end

        def remap_single(subtable, glyph_map)
          pairs = {}

          case subtable[:format]
          when 1
            # A constant delta can't be preserved under an arbitrary glyph
            # remapping, so the subtable is rebuilt in format 2.
            subtable[:coverage].glyphs.each do |glyph_id|
              new_glyph = glyph_map[glyph_id]
              new_substitute = glyph_map[(glyph_id + subtable[:delta]) & 0xFFFF]
              pairs[new_glyph] = new_substitute if new_glyph && new_substitute
            end
          when 2
            subtable[:coverage].glyphs.each_with_index do |glyph_id, i|
              new_glyph = glyph_map[glyph_id]
              new_substitute = glyph_map[subtable[:substitutes][i]]
              pairs[new_glyph] = new_substitute if new_glyph && new_substitute
            end
          end

          return nil if pairs.empty?

          glyphs = pairs.keys.sort
          {
            type: 1,
            format: 2,
            coverage: Coverage.new(glyphs),
            substitutes: glyphs.map { |glyph_id| pairs[glyph_id] },
          }
        end

        def remap_multiple_alternate(subtable, glyph_map)
          key = subtable[:type] == 2 ? :sequences : :alternates
          pairs = []

          subtable[:coverage].glyphs.each_with_index do |glyph_id, i|
            new_glyph = glyph_map[glyph_id]
            next unless new_glyph

            new_set = subtable[key][i].filter_map { |substitute| glyph_map[substitute] }
            pairs << [new_glyph, new_set] unless new_set.empty?
          end

          return nil if pairs.empty?

          pairs.sort_by!(&:first)
          {
            type: subtable[:type],
            format: 1,
            coverage: Coverage.new(pairs.map(&:first)),
            key => pairs.map(&:last),
          }
        end

        def remap_ligature(subtable, glyph_map)
          pairs = []

          subtable[:coverage].glyphs.each_with_index do |glyph_id, i|
            new_glyph = glyph_map[glyph_id]
            next unless new_glyph

            ligatures = subtable[:ligature_sets][i].filter_map do |ligature|
              new_ligature = glyph_map[ligature[:ligature]]
              components = ligature[:components].map { |component| glyph_map[component] }
              if new_ligature && components.all?
                { ligature: new_ligature, components: components }
              end
            end
            pairs << [new_glyph, ligatures] unless ligatures.empty?
          end

          return nil if pairs.empty?

          pairs.sort_by!(&:first)
          {
            type: 4,
            format: 1,
            coverage: Coverage.new(pairs.map(&:first)),
            ligature_sets: pairs.map(&:last),
          }
        end

        def remap_context(subtable, glyph_map, lookup_map)
          case subtable[:format]
          when 1
            result = remap_coverage_rule_sets(subtable, glyph_map) { |rule|
              remap_context_rule(rule, glyph_map, lookup_map)
            }
            if result
              { type: 5, format: 1, coverage: result[0], rule_sets: result[1] }
            end
          when 2
            coverage = subtable[:coverage].remap(glyph_map)
            return nil unless coverage

            class_sets = remap_class_sets(subtable[:class_sets]) { |rule|
              remap_class_rule(rule, lookup_map)
            }
            return nil if class_sets.all?(&:nil?)

            {
              type: 5,
              format: 2,
              coverage: coverage,
              class_def: subtable[:class_def].remap(glyph_map),
              class_sets: class_sets,
            }
          when 3
            coverages = subtable[:coverages].map { |coverage| coverage.remap(glyph_map) }
            return nil if coverages.any?(&:nil?)

            records = remap_records(subtable[:records], lookup_map)
            return nil if records.empty? && !subtable[:records].empty?

            { type: 5, format: 3, coverages: coverages, records: records }
          end
        end

        def remap_chaining(subtable, glyph_map, lookup_map)
          case subtable[:format]
          when 1
            result = remap_coverage_rule_sets(subtable, glyph_map) { |rule|
              remap_chain_rule(rule, glyph_map, lookup_map)
            }
            if result
              { type: 6, format: 1, coverage: result[0], rule_sets: result[1] }
            end
          when 2
            coverage = subtable[:coverage].remap(glyph_map)
            return nil unless coverage

            class_sets = remap_class_sets(subtable[:class_sets]) { |rule|
              remap_class_rule(rule, lookup_map)
            }
            return nil if class_sets.all?(&:nil?)

            {
              type: 6,
              format: 2,
              coverage: coverage,
              backtrack_class_def: subtable[:backtrack_class_def].remap(glyph_map),
              input_class_def: subtable[:input_class_def].remap(glyph_map),
              lookahead_class_def: subtable[:lookahead_class_def].remap(glyph_map),
              class_sets: class_sets,
            }
          when 3
            backtrack = subtable[:backtrack_coverages].map { |coverage| coverage.remap(glyph_map) }
            input = subtable[:input_coverages].map { |coverage| coverage.remap(glyph_map) }
            lookahead = subtable[:lookahead_coverages].map { |coverage| coverage.remap(glyph_map) }
            return nil if [backtrack, input, lookahead].any? { |list| list.any?(&:nil?) }

            records = remap_records(subtable[:records], lookup_map)
            return nil if records.empty? && !subtable[:records].empty?

            {
              type: 6,
              format: 3,
              backtrack_coverages: backtrack,
              input_coverages: input,
              lookahead_coverages: lookahead,
              records: records,
            }
          end
        end

        # Remap a format 1 contextual subtable (coverage with a rule set per
        # covered glyph). Yields rules to the block for remapping.
        #
        # @return [Array(TTFunk::Table::Gsub::Coverage, Array), nil]
        def remap_coverage_rule_sets(subtable, glyph_map)
          pairs = []

          subtable[:coverage].glyphs.each_with_index do |glyph_id, i|
            new_glyph = glyph_map[glyph_id]
            next unless new_glyph

            rules = subtable[:rule_sets][i]
            next unless rules

            new_rules = rules.filter_map { |rule| yield(rule) }
            pairs << [new_glyph, new_rules] unless new_rules.empty?
          end

          return nil if pairs.empty?

          pairs.sort_by!(&:first)
          [Coverage.new(pairs.map(&:first)), pairs.map(&:last)]
        end

        # Remap rules in class sets of a format 2 contextual subtable,
        # keeping set positions (they correspond to class values).
        #
        # @return [Array]
        def remap_class_sets(class_sets)
          class_sets.map do |rules|
            next nil unless rules

            new_rules = rules.filter_map { |rule| yield(rule) }
            new_rules.empty? ? nil : new_rules
          end
        end

        def remap_context_rule(rule, glyph_map, lookup_map)
          input = rule[:input].map { |glyph_id| glyph_map[glyph_id] }
          return nil unless input.all?

          records = remap_records(rule[:records], lookup_map)
          return nil if records.empty? && !rule[:records].empty?

          { input: input, records: records }
        end

        def remap_class_rule(rule, lookup_map)
          records = remap_records(rule[:records], lookup_map)
          return nil if records.empty? && !rule[:records].empty?

          rule.merge(records: records)
        end

        def remap_chain_rule(rule, glyph_map, lookup_map)
          backtrack = rule[:backtrack].map { |glyph_id| glyph_map[glyph_id] }
          input = rule[:input].map { |glyph_id| glyph_map[glyph_id] }
          lookahead = rule[:lookahead].map { |glyph_id| glyph_map[glyph_id] }
          return nil unless backtrack.all? && input.all? && lookahead.all?

          records = remap_records(rule[:records], lookup_map)
          return nil if records.empty? && !rule[:records].empty?

          {
            backtrack: backtrack,
            input: input,
            lookahead: lookahead,
            records: records,
          }
        end

        def remap_records(records, lookup_map)
          records.filter_map do |record|
            new_index = lookup_map[record[:lookup_index]]
            if new_index
              { sequence_index: record[:sequence_index], lookup_index: new_index }
            end
          end
        end

        # Encoding

        # Serialize a subtable to binary.
        #
        # @param subtable [Hash]
        # @return [String]
        def encode(subtable)
          case subtable[:type]
          when 1 then encode_single(subtable)
          when 2, 3 then encode_multiple_alternate(subtable)
          when 4 then encode_ligature(subtable)
          when 5 then encode_context(subtable)
          when 6 then encode_chaining(subtable)
          when 7
            [1, subtable[:extension_type], 8].pack('nnN') + encode(subtable[:inner])
          end
        end

        def encode_single(subtable)
          coverage = subtable[:coverage].encode

          case subtable[:format]
          when 1
            [1, 6].pack('nn') + [subtable[:delta]].pack('s>') + coverage
          when 2
            substitutes = subtable[:substitutes]
            coverage_offset = 6 + (substitutes.length * 2)
            (
              [2, coverage_offset, substitutes.length, *substitutes].pack('nnnn*') +
              coverage
            )
          end
        end

        def encode_multiple_alternate(subtable)
          key = subtable[:type] == 2 ? :sequences : :alternates
          sets = subtable[key].map { |set| [set.length, *set].pack('nn*') }
          header_length = 6 + (sets.length * 2)
          offsets, blob = offset_blocks(header_length, sets)
          coverage_offset = header_length + blob.bytesize

          (
            [1, coverage_offset, sets.length, *offsets].pack('nnnn*') +
            blob +
            subtable[:coverage].encode
          )
        end

        def encode_ligature(subtable)
          sets = subtable[:ligature_sets].map do |ligatures|
            entries = ligatures.map do |ligature|
              [
                ligature[:ligature],
                ligature[:components].length + 1,
                *ligature[:components],
              ].pack('nnn*')
            end
            offsets, blob = offset_blocks(2 + (entries.length * 2), entries)
            [entries.length, *offsets].pack('nn*') + blob
          end
          header_length = 6 + (sets.length * 2)
          offsets, blob = offset_blocks(header_length, sets)
          coverage_offset = header_length + blob.bytesize

          (
            [1, coverage_offset, sets.length, *offsets].pack('nnnn*') +
            blob +
            subtable[:coverage].encode
          )
        end

        def encode_context(subtable)
          case subtable[:format]
          when 1
            encode_coverage_rule_sets(subtable[:coverage], subtable[:rule_sets]) { |rule|
              encode_context_rule(rule)
            }
          when 2
            sets = encode_rule_sets(subtable[:class_sets]) { |rule|
              encode_context_class_rule(rule)
            }
            coverage = subtable[:coverage].encode
            class_def = subtable[:class_def].encode
            coverage_offset = 8 + (sets.length * 2)
            class_def_offset = coverage_offset + coverage.bytesize
            offsets, blob = offset_blocks(class_def_offset + class_def.bytesize, sets)

            (
              [2, coverage_offset, class_def_offset, sets.length].pack('nnnn') +
              offsets.pack('n*') +
              coverage +
              class_def +
              blob
            )
          when 3
            records = encode_records(subtable[:records])
            coverages = subtable[:coverages].map(&:encode)
            header_length = 6 + (coverages.length * 2) + (subtable[:records].length * 4)
            offsets, blob = offset_blocks(header_length, coverages)

            (
              [3, coverages.length, subtable[:records].length].pack('nnn') +
              offsets.pack('n*') +
              records +
              blob
            )
          end
        end

        def encode_chaining(subtable)
          case subtable[:format]
          when 1
            encode_coverage_rule_sets(subtable[:coverage], subtable[:rule_sets]) { |rule|
              encode_chain_rule(rule)
            }
          when 2
            sets = encode_rule_sets(subtable[:class_sets]) { |rule|
              encode_chain_rule(rule)
            }
            coverage = subtable[:coverage].encode
            backtrack_def = subtable[:backtrack_class_def].encode
            input_def = subtable[:input_class_def].encode
            lookahead_def = subtable[:lookahead_class_def].encode
            coverage_offset = 12 + (sets.length * 2)
            backtrack_offset = coverage_offset + coverage.bytesize
            input_offset = backtrack_offset + backtrack_def.bytesize
            lookahead_offset = input_offset + input_def.bytesize
            offsets, blob = offset_blocks(lookahead_offset + lookahead_def.bytesize, sets)

            (
              [
                2,
                coverage_offset,
                backtrack_offset,
                input_offset,
                lookahead_offset,
                sets.length,
              ].pack('nnnnnn') +
              offsets.pack('n*') +
              coverage +
              backtrack_def +
              input_def +
              lookahead_def +
              blob
            )
          when 3
            records = encode_records(subtable[:records])
            backtrack = subtable[:backtrack_coverages].map(&:encode)
            input = subtable[:input_coverages].map(&:encode)
            lookahead = subtable[:lookahead_coverages].map(&:encode)
            header_length =
              2 +
              (2 + (backtrack.length * 2)) +
              (2 + (input.length * 2)) +
              (2 + (lookahead.length * 2)) +
              (2 + records.bytesize)
            offsets, blob = offset_blocks(header_length, backtrack + input + lookahead)
            backtrack_offsets = offsets.shift(backtrack.length)
            input_offsets = offsets.shift(input.length)
            lookahead_offsets = offsets

            (
              [3, backtrack.length].pack('nn') +
              backtrack_offsets.pack('n*') +
              [input.length].pack('n') +
              input_offsets.pack('n*') +
              [lookahead.length].pack('n') +
              lookahead_offsets.pack('n*') +
              [subtable[:records].length].pack('n') +
              records +
              blob
            )
          end
        end

        # Encode a format 1 contextual subtable (coverage with a rule set per
        # covered glyph).
        def encode_coverage_rule_sets(coverage, rule_sets)
          sets = encode_rule_sets(rule_sets) { |rule| yield(rule) }
          header_length = 6 + (sets.length * 2)
          offsets, blob = offset_blocks(header_length, sets)
          coverage_offset = header_length + blob.bytesize

          (
            [1, coverage_offset, sets.length, *offsets].pack('nnnn*') +
            blob +
            coverage.encode
          )
        end

        # Encode rule sets keeping NULL offsets for nil sets.
        def encode_rule_sets(rule_sets)
          rule_sets.map do |rules|
            next nil unless rules

            entries = rules.map { |rule| yield(rule) }
            offsets, blob = offset_blocks(2 + (entries.length * 2), entries)
            [entries.length, *offsets].pack('nn*') + blob
          end
        end

        def encode_context_rule(rule)
          (
            [rule[:input].length + 1, rule[:records].length] +
            rule[:input] +
            record_pairs(rule[:records])
          ).pack('n*')
        end

        def encode_context_class_rule(rule)
          (
            [rule[:classes].length + 1, rule[:records].length] +
            rule[:classes] +
            record_pairs(rule[:records])
          ).pack('n*')
        end

        # Chain rules have identical binary layout in glyph-based (format 1)
        # and class-based (format 2) subtables.
        def encode_chain_rule(rule)
          (
            [rule[:backtrack].length] +
            rule[:backtrack] +
            [rule[:input].length + 1] +
            rule[:input] +
            [rule[:lookahead].length] +
            rule[:lookahead] +
            [rule[:records].length] +
            record_pairs(rule[:records])
          ).pack('n*')
        end

        def encode_records(records)
          record_pairs(records).pack('n*')
        end

        def record_pairs(records)
          records.flat_map { |record|
            [record[:sequence_index], record[:lookup_index]]
          }
        end

        # Compute sequential uint16 offsets for blocks appended after a
        # header of +base+ bytes. Nil blocks get a NULL (0) offset.
        #
        # @return [Array(Array<Integer>, String)] offsets and joined blocks.
        def offset_blocks(base, blocks)
          offsets = []
          blob = +''

          blocks.each do |block|
            if block
              offsets << (base + blob.bytesize)
              blob << block
            else
              offsets << 0
            end
          end

          [offsets, blob]
        end
      end
    end
  end
end
