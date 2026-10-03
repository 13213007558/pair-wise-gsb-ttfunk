# frozen_string_literal: true

require_relative '../../reader'

module TTFunk
  class Table
    class Kern
      # Format 2 (class-based) kerning subtable.
      #
      # Glyphs are grouped into classes on each side and kerning values are
      # stored in a two-dimensional matrix addressed by the classes. Glyphs
      # not covered by a class map implicitly belong to class 0.
      class Format2
        include Reader

        # Subtable attributes.
        # @return [Hash{Symbol => any}]
        attr_reader :attributes

        # Kerning pairs.
        #
        # Pairs whose kerning value is zero are omitted, matching the sparse
        # representation of format 0 subtables. Only glyphs explicitly listed
        # in the class maps are enumerated: glyphs outside the maps share
        # class 0 with every other uncovered glyph, so use #kerning_for to
        # query such a specific pair.
        # @return [Hash{Array(Integer, Integer) => Integer}]
        attr_reader :pairs

        # Width of a row in the kerning value array, in words.
        # @return [Integer]
        attr_reader :row_width

        # First glyph covered by the left-hand class map.
        # @return [Integer]
        attr_reader :left_first_glyph

        # First glyph covered by the right-hand class map.
        # @return [Integer]
        attr_reader :right_first_glyph

        # Class indices (word offsets) for the left-hand glyphs.
        # @return [Array<Integer>]
        attr_reader :left_class_offsets

        # Class indices (row offsets) for the right-hand glyphs.
        # @return [Array<Integer>]
        attr_reader :right_class_offsets

        # Kerning value array, as signed font units.
        # @return [Array<Integer>]
        attr_reader :values

        # @param attributes [Hash{Symbol => any}]
        def initialize(attributes = {})
          @attributes = attributes
          data = attributes[:data] || ''

          @row_width, left_offset, right_offset, array_offset =
            data.unpack('x2n4')
          @row_width ||= 0
          @columns = @row_width / 2
          left_offset ||= 0
          right_offset ||= 0
          array_offset ||= 0

          @left_class_offsets, @left_first_glyph, @left_glyphs =
            parse_class_table(data, left_offset) { |offset| offset / 2 }
          @right_class_offsets, @right_first_glyph, @right_glyphs =
            parse_class_table(data, right_offset) do |offset|
              @row_width.zero? ? 0 : offset / @row_width
            end

          @values =
            if array_offset < data.length
              data[array_offset..].unpack('n*').map { |v| to_signed(v) }
            else
              []
            end

          @pairs = build_pairs
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

        # Do values of this subtable replace earlier subtables?
        # @return [Boolean]
        def override?
          @attributes[:override]
        end

        # Kerning value for the given glyph pair, in font units.
        #
        # Glyphs outside the class maps belong to class 0, as specified by
        # the format.
        #
        # @param left_glyph [Integer]
        # @param right_glyph [Integer]
        # @return [Integer]
        def kerning_for(left_glyph, right_glyph)
          left = class_offset(
            @left_first_glyph, @left_class_offsets, left_glyph
          )
          right =
            class_offset(@right_first_glyph, @right_class_offsets, right_glyph)

          index = left + (right * @columns)
          return 0 unless index >= 0 && index < @values.length

          @values[index]
        end

        # Does this subtable provide a value for the given glyph pair?
        #
        # Glyphs outside both class maps are only covered when the default
        # class cell is non-zero.
        #
        # @param left_glyph [Integer]
        # @param right_glyph [Integer]
        # @return [Boolean]
        def covers?(left_glyph, right_glyph)
          !kerning_for(left_glyph, right_glyph).zero?
        end

        # Recode this subtable using the specified mapping.
        #
        # The surviving glyphs are regrouped into compact classes and the
        # kerning value matrix is rebuilt; the original byte offsets are not
        # copied.
        #
        # @param mapping [Hash{Integer => Integer}] keys are old glyph IDs,
        #   values are new glyph IDs
        # @return [String, nil]
        def recode(mapping)
          left_classes = grouped_classes(mapping, @left_first_glyph,
                                         @left_class_offsets)
          right_classes = grouped_classes(mapping, @right_first_glyph,
                                          @right_class_offsets)

          matrix = build_matrix(left_classes, right_classes)
          values = matrix.flatten
          return if values.all?(&:zero?)

          row_width_words = left_classes.length
          left_glyph_offsets =
            glyph_byte_offsets(
              mapping, left_classes, @left_first_glyph,
              @left_class_offsets
            ) { |index| index * 2 }
          right_glyph_offsets =
            glyph_byte_offsets(
              mapping, right_classes, @right_first_glyph,
              @right_class_offsets
            ) do |index|
              index * row_width_words * 2
            end

          left_table = build_class_table(left_glyph_offsets)
          right_table = build_class_table(right_glyph_offsets)
          values_data = values.map { |value| value & 0xFFFF }.pack('n*')

          left_offset = 10
          right_offset = left_offset + left_table.bytesize
          array_offset = right_offset + right_table.bytesize

          payload =
            [
              0x0002,
              row_width_words * 2,
              left_offset,
              right_offset,
              array_offset,
            ].pack('n5') +
            left_table + right_table + values_data

          encode_header(payload.bytesize) + payload
        end

        private

        def missing_class_table?(data, offset)
          offset.nil? || offset.zero? || offset >= data.length
        end

        def parse_class_table(data, offset)
          return [[], 0, {}] if missing_class_table?(data, offset)

          format, first_glyph, glyph_count = data[offset, 6].unpack('n*')
          unless format == 1
            raise(
              Kern::UnsupportedFormatError,
              "unsupported kern class subtable format: #{format}",
            )
          end

          table_data =
            data[offset, 6 + (glyph_count * 2)] || ''
          _format, _first_glyph, _glyph_count, *offsets =
            table_data.unpack('n*')

          offsets.map! { |class_byte_offset| yield(class_byte_offset) }

          glyphs = Hash.new { |hash, key| hash[key] = [] }
          offsets.each_with_index do |class_offset, index|
            glyphs[class_offset] << (first_glyph + index)
          end

          [offsets, first_glyph, glyphs]
        end

        def class_offset(first_glyph, offsets, glyph)
          index = glyph - first_glyph
          return 0 if index.negative? || index >= offsets.length

          offsets[index]
        end

        def build_pairs
          pairs = {}

          @left_glyphs.each do |left_offset, left_glyphs|
            @right_glyphs.each do |right_offset, right_glyphs|
              index = left_offset + (right_offset * @columns)
              next unless index >= 0 && index < @values.length

              value = @values[index]
              next if value.zero?

              left_glyphs.each do |left|
                right_glyphs.each do |right|
                  pairs[[left, right]] = value
                end
              end
            end
          end

          pairs
        end

        def grouped_classes(mapping, first_glyph, offsets)
          classes = [0]
          mapping.each do |old_glyph, new_glyph|
            old_offset = class_offset(first_glyph, offsets, old_glyph)
            classes << old_offset
          end

          classes.uniq.sort
        end

        def build_matrix(left_classes, right_classes)
          right_classes.map do |right_offset|
            left_classes.map do |left_offset|
              index = left_offset + (right_offset * @columns)
              index < @values.length ? @values[index] : 0
            end
          end
        end

        def glyph_byte_offsets(mapping, classes, first_glyph, offsets)
          class_index = classes.each_with_index.to_h
          mapping.each_with_object({}) do |(old_glyph, new_glyph), result|
            old_offset = class_offset(first_glyph, offsets, old_glyph)
            result[new_glyph] = yield(class_index.fetch(old_offset))
          end
        end

        def build_class_table(glyph_offsets)
          glyph_ids = glyph_offsets.keys.sort
          first_glyph = glyph_ids.min
          entries =
            (first_glyph..glyph_ids.max).map do |glyph|
            glyph_offsets[glyph] || 0
          end

          [1, first_glyph, entries.length, *entries].pack('n*')
        end

        def encode_header(payload_length)
          if (@attributes[:header_size] || 6) == 8
            [
              payload_length + 8,
              @attributes[:coverage],
              @attributes.fetch(:tuple_index, 0),
            ].pack('Nnn')
          else
            [
              @attributes[:version],
              payload_length + 6,
              @attributes[:coverage],
            ].pack('n*')
          end
        end
      end
    end
  end
end
