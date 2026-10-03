# frozen_string_literal: true

require_relative '../../reader'

module TTFunk
  class Table
    class Kern
      # Format 2 (class-based) kerning subtable.
      #
      # Kerning values are stored in a two-dimensional matrix indexed by the
      # class of the left and right glyphs. Both Apple class table formats
      # are supported. Glyphs not listed in a class table belong to the
      # default class 0.
      class Format2
        include Reader

        # Subtable attributes.
        # @return [Hash{Symbol => any}]
        attr_reader :attributes

        # Expanded kerning pairs for glyphs explicitly listed in the class
        # tables, plus glyph 0 representing the default class. Use
        # {#kerning_for} to look up arbitrary glyphs.
        # @return [Hash{Array(Integer, Integer) => Integer}]
        attr_reader :pairs

        # Maps glyph ids to left-hand class byte offsets.
        # @return [Hash{Integer => Integer}]
        attr_reader :left_classes

        # Maps glyph ids to right-hand class column indices.
        # @return [Hash{Integer => Integer}]
        attr_reader :right_classes

        # Width, in bytes, of one row of the kerning value matrix.
        # @return [Integer]
        attr_reader :row_width

        # Kerning value matrix, flattened row by row. It is indexed by
        # `leftClass / 2 + rightClass`: left classes are byte offsets and
        # right classes are direct column indices.
        # @return [Array<Integer>]
        attr_reader :values

        # @param attributes [Hash{Symbol => any}]
        def initialize(attributes = {})
          @attributes = attributes
          data = @attributes[:data] || +''

          @row_width, left_offset, right_offset = data.unpack('n3')

          @left_classes = parse_class_table(data, left_offset)
          @right_classes = parse_class_table(data, right_offset)

          values_length = [left_offset, right_offset].min - 12
          values_length = 0 if values_length.negative?
          @values = data[6, values_length]
          @values = (@values || +'').unpack('n*')
                     .map { |value| to_signed(value) }

          build_pairs
        end

        # Is this vertical kerning?
        # @return [Boolean]
        def vertical?
          @attributes[:vertical]
        end

        # Is this horizontal kerning?
        # @return [Boolean]
        def horizontal?
          !vertical?
        end

        # Is this cross-stream kerning?
        # @return [Boolean]
        def cross_stream?
          @attributes[:cross]
        end

        # Do later non-override subtables add to this subtable's values?
        # @return [Boolean]
        def override?
          @attributes[:override]
        end

        # Get the kerning value for the given pair of glyph ids.
        #
        # Glyphs not listed in a class table use the default class 0.
        #
        # @param left_glyph [Integer]
        # @param right_glyph [Integer]
        # @return [Integer]
        def kerning_for(left_glyph, right_glyph)
          return 0 if row_width.zero?

          index =
            (@left_classes.fetch(left_glyph, 0) / 2) +
            @right_classes.fetch(right_glyph, 0)
          @values.fetch(index, 0)
        end

        # Get the overriding kerning value, or nil when this subtable
        # contributes nothing (zero) for the pair.
        #
        # @param left_glyph [Integer]
        # @param right_glyph [Integer]
        # @return [Integer, nil]
        def override_value_for(left_glyph, right_glyph)
          value = kerning_for(left_glyph, right_glyph)
          value.zero? ? nil : value
        end

        # Recode this subtable using the specified mapping.
        #
        # The surviving classes and the value matrix are reorganized, so the
        # new table never references classes used only by glyphs removed
        # during subsetting, and all offsets are recomputed.
        #
        # @param mapping [Hash{Integer => Integer}] keys are old glyph IDs,
        #   values are new glyph IDs
        # @return [String, nil]
        def recode(mapping)
          return if row_width.zero?

          new_to_old = mapping.invert
          new_glyphs = new_to_old.keys.sort
          old_columns = row_width / 2

          right_columns, right_index = remap_classes(
            new_glyphs, new_to_old, @right_classes, 1
          )
          return if right_columns.zero?

          row_count, left_index = remap_classes(
            new_glyphs, new_to_old, @left_classes, old_columns
          )
          return if row_count.zero?

          matrix = Array.new(row_count * right_columns, 0)
          new_glyphs.each do |new_left|
            new_glyphs.each do |new_right|
              value = kerning_for(
                new_to_old[new_left], new_to_old[new_right]
              )
              next if value.zero?

              row = left_index[new_left]
              column = right_index[new_right]
              matrix[(row * right_columns) + column] = value
            end
          end
          return if matrix.all?(&:zero?)

          left_offsets = left_index.transform_values { |row| row * (right_columns * 2) }
          left_table = encode_class_table(new_glyphs, left_offsets)
          right_table = encode_class_table(new_glyphs, right_index)

          values_length = matrix.length * 2
          left_offset = 12 + values_length
          right_offset = left_offset + left_table.length
          length = right_offset + right_table.length

          header = [
            0,
            length,
            attributes[:coverage],
            right_columns * 2,
            left_offset,
            right_offset,
            matrix.map { |value| value & 0xFFFF }
          ].flatten.pack('n*')
          header + left_table + right_table
        end

        private

        # Expand the class table into glyph-pair lookups, mirroring the result
        # shape of a format 0 subtable. Glyph 0 represents glyphs that are not
        # listed in a class table (the default class).
        def build_pairs
          @pairs = {}
          left_glyphs = @left_classes.keys | [0]
          right_glyphs = @right_classes.keys | [0]

          left_glyphs.each do |left_glyph|
            right_glyphs.each do |right_glyph|
              @pairs[[left_glyph, right_glyph]] =
                kerning_for(left_glyph, right_glyph)
            end
          end
        end

        def parse_class_table(data, offset)
          classes = {}
          # The left/right class table offsets are relative to the start of
          # the subtable (including the 6-byte outer header); `data` begins
          # right after that header.
          table_pos = offset - 6
          return classes if offset < 6 || table_pos >= data.length

          format = data.unpack1('n', offset: table_pos)
          pos = table_pos + 2

          if format.zero?
            glyph_count, first_glyph = data.unpack('n2', offset: pos)
            pos += 4
            available = (data.length - pos) / 2
            [glyph_count, available].min.times do |i|
              raw_value = data.unpack1('n', offset: pos + (i * 2))
              class_value = to_signed(raw_value)
              glyph = first_glyph + i
              classes[glyph] = class_value if class_value.positive?
            end
          elsif format == 1
            glyph_count, first_glyph = data.unpack('n2', offset: pos)
            pos += 4
            available = (data.length - pos) / 2
            [glyph_count, available].min.times do |i|
              class_offset = data.unpack1('n', offset: pos + (i * 2))
              glyph = first_glyph + i
              next if class_offset.zero?

              # Format 1 lookup offsets are relative to the class table.
              record_pos = table_pos + class_offset
              next if record_pos.negative? || (record_pos + 2) > data.length

              raw_value = data.unpack1('n', offset: record_pos)
              next if raw_value.nil?

              class_value = raw_value
              classes[glyph] = class_value if class_value.positive?
            end
          else
            raise Kern::UnsupportedFormatError,
                  "kerning class table format #{format} is not supported"
          end

          classes
        end

        # Collect classes referenced by surviving glyphs (always including
        # the default class 0) and renumber them contiguously. New glyph ids
        # are mapped to old ones via `mapping` before looking up the class.
        #
        # Left class values are byte offsets (row * rowWidth) and right class
        # values are direct column indices; `unit` converts a stored value to
        # a class index.
        #
        # @return [Array(Integer, Hash)] number of classes and a map from new
        #   glyph id to renumbered class index
        def remap_classes(new_glyphs, mapping, old_classes, unit)
          glyph_classes = new_glyphs.to_h do |glyph|
            old_value = old_classes[mapping[glyph]]
            [glyph, old_value.nil? ? 0 : old_value.div(unit)]
          end

          used = ([0] + glyph_classes.values).uniq.sort
          remapped = used.each_with_index.to_h { |old_index, index| [old_index, index] }

          [used.length, glyph_classes.transform_values { |index| remapped[index] }]
        end

        # Encode an Apple class table format 0.
        def encode_class_table(glyphs, glyph_offsets)
          entries = glyphs.filter_map do |glyph|
            offset = glyph_offsets[glyph]
            offset.zero? ? nil : [glyph, offset]
          end.sort_by(&:first)

          return [0, 0, 0].pack('n*') if entries.empty?

          first_glyph = entries.first.first
          glyph_count = (entries.last.first - first_glyph) + 1
          by_glyph = entries.to_h

          values = glyph_count.times.map do |i|
            by_glyph.fetch(first_glyph + i, 0)
          end

          [0, glyph_count, first_glyph, values].flatten.pack('n*')
        end
      end
    end
  end
end
