# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      # CFF2 charstring.
      class Charstring < TTFunk::Table::Cff::Charstring
        # There are not enough operands for a blend operator.
        class InsufficientOperandsError < StandardError; end

        # @param coordinates [Hash{Symbol,Integer => Numeric}]
        def initialize(glyph_id, top_dict, font_dict, raw, coordinates)
          @coordinates = coordinates
          super(glyph_id, top_dict, font_dict, raw, cff2: true)
          @variation_store_index = font_dict&.private_dict&.respond_to?(:vsindex) ?
            font_dict.private_dict.vsindex : 0
        end

        private

        def parse!
          loop do
            if @index >= @data.size
              break unless return_from_subroutine
              next
            end

            code = @data[@index]

            if code == 11
              return_from_subroutine
              next
            elsif code == 28
              @stack << shortint_value
              next
            end

            @index += 1

            if code.between?(0, 31) && (m = code_map[code])
              send(m)
            elsif code.between?(32, 246)
              @stack << (code - 139)
            elsif code.between?(247, 250)
              b1 = @data[@index]
              @index += 1
              @stack << (((code - 247) * 256) + b1 + 108)
            elsif code.between?(251, 254)
              b1 = @data[@index]
              @index += 1
              @stack << ((-(code - 251) * 256) - b1 - 108)
            else
              @stack << read_fixed_operand
            end
          end
        end

        def code_map
          @code_map ||=
            super.merge(
              15 => :vsindex,
              16 => :blend,
            ).freeze
        end

        def vsindex
          @variation_store_index = read_operand
          raise InsufficientOperandsError, 'invalid vsindex operand' unless @variation_store_index.is_a?(Integer)
        end

        def blend
          blend_count = read_operand
          region_count = variation_region_count
          operand_count = blend_count * (region_count + 1)

          if !blend_count.is_a?(Integer) || blend_count <= 0 || @stack.length < operand_count
            raise InsufficientOperandsError,
              "blend requires #{operand_count} operands plus a positive blend count, but #{@stack.length} values were available"
          end

          arguments = @stack.pop(operand_count)
          defaults = arguments.shift(blend_count)

          defaults.each_with_index do |default, index|
            deltas = Array.new(region_count) do |region_index|
              arguments[(region_index * blend_count) + index]
            end

            @stack << default + variation_store.delta(@variation_store_index, deltas, @coordinates)
          end
        end

        def read_operand
          code = @data[@index]
          raise InsufficientOperandsError, 'missing charstring operand' if code.nil?

          @index += 1

          if code.between?(32, 246)
            code - 139
          elsif code.between?(0, 27) && code != 28
            code
          elsif code.between?(247, 250)
            b1 = @data[@index]
            @index += 1
            ((code - 247) * 256) + b1 + 108
          elsif code.between?(251, 254)
            b1 = @data[@index]
            @index += 1
            (-(code - 251) * 256) - b1 - 108
          elsif code == 28
            shortint_value
          else
            read_binary_operand(code)
          end
        end

        def shortint_value
          @index += 1
          value = shortint_value_at(@index)
          @index += 1
          value
        end

        def shortint_value_at(position)
          b1, b2 = read_bytes_at(position, 2)
          (((b1 << 24) | (b2 << 16)) >> 16)
        end

        def read_bytes_at(position, length)
          bytes = @data[position, length]
          bytes
        end

        def read_binary_operand(code)
          if code == 28
            shortint_value
          else
            read_fixed_operand
          end
        end

        def read_fixed_operand
          b1, b2, b3, b4 = read_bytes(4)
          raise InsufficientOperandsError, 'missing charstring operand' if [b1, b2, b3, b4].include?(nil)

          (((b1 << 24) | (b2 << 16) | (b3 << 8) | b4) / 65_536)
        end

        def variation_region_count
          variation_store.region_count(@variation_store_index)
        end

        def variation_store
          @top_dict.variation_store
        end

        def callgsubr
          raise TTFunk::Error, 'CFF2 charstrings do not support global subroutines'
        end

        def stem
          @n_stems += @stack.length >> 1
          @stack.clear
        end

        def vmoveto
          @y += @stack.pop
          add_contour(@x, @y)
        end

        def rmoveto
          @y += @stack.pop
          @x += @stack.pop
          add_contour(@x, @y)
        end

        def hmoveto
          @x += @stack.pop
          add_contour(@x, @y)
        end

        def endchar
          @stack.clear

          if @open
            @path.close_path
            @open = false
          end
        end
      end
    end
  end
end
