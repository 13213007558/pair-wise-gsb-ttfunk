# frozen_string_literal: true

module TTFunk
  class Table
    class Cff2 < TTFunk::Table
      class Charstring < Cff::Charstring
        class InsufficientOperandsError < StandardError; end

        CODE_MAP = Cff::Charstring::CODE_MAP.merge(
          15 => :vsindex,
          16 => :blend,
        ).freeze

        def initialize(glyph_id, top_dict, font_dict, raw)
          super

          @have_width = true
          @dict = (@font_dict || @top_dict).private_dict
          @variation_store = @top_dict.variation_store
          @vsindex = @dict&.vsindex || 0
          @coordinates = {}
        end

        def path(coordinates: nil)
          @path = nil
          @coordinates = normalized_coordinates(coordinates || {})
          @path = Cff::Path.new
          @stack = []
          @data = raw.bytes
          @index = 0
          @n_stems = 0
          @open = false
          @x = 0
          @y = 0
          @vsindex = @dict&.vsindex || 0
          @call_frames = []

          parse!
          @path
        end

        private

        def vsindex
          if @stack.empty?
            raise InsufficientOperandsError, 'vsindex requires one operand'
          end

          index = @stack.pop
          unless index.is_a?(Integer) && index >= 0
            raise ArgumentError, "invalid variation store index #{index.inspect}"
          end

          @vsindex = index
        end

        def blend
          if @stack.empty? || !@stack.last.is_a?(Integer) || @stack.last < 1
            raise InsufficientOperandsError, 'blend requires an operand count'
          end

          raise Error, 'no CFF2 variation store is available' unless @variation_store

          operand_count = @stack.last
          deltas = @variation_store.deltas(@vsindex, @coordinates)
          required_stack_size = operand_count * (1 + deltas.length)

          if @stack.length < required_stack_size
            raise InsufficientOperandsError,
              "blend requires #{required_stack_size} operands but #{@stack.length} are available"
          end
          @stack.pop

          arguments = @stack.pop(operand_count * (1 + deltas.length))

          operand_count.times do
            base = arguments.shift
            deltas_for_operand = arguments.shift(deltas.length)
            increment = deltas_for_operand.each_with_index.inject(0.0) do |sum, (delta, region_index)|
              sum + (delta.to_f * deltas[region_index])
            end

            @stack << base + increment
          end
        end

        def callsubr
          invoke_subroutine(@stack.pop + @subrs_bias, @subrs)
        end

        def callgsubr
          invoke_subroutine(@stack.pop + @gsubrs_bias, @gsubrs)
        end

        def invoke_subroutine(code_index, subroutines)
          raise InsufficientOperandsError, "subroutine #{code_index} not found" unless subroutines

          subr_code = subroutines[code_index]
          raise InsufficientOperandsError, "subroutine #{code_index} not found" unless subr_code

          @call_frames << [@data, @index - 1]
          @data = subr_code.bytes
          @index = 0
        end

        def return_from_charstring_subroutine
          return false if @call_frames.nil? || @call_frames.empty?

          @data, @index = @call_frames.pop
          @index += 1
          true
        end

        def endchar
          return false if return_from_charstring_subroutine

          super
          true
        end

        def normalized_coordinates(coordinates)
          return coordinates.map(&:to_f) if coordinates.is_a?(Array)

          @top_dict.file.fvar.axes.each_with_object({}) do |axis, normalized|
            normalized[axis.tag] =
              if coordinates.key?(axis.tag)
                axis.normalized_position(coordinates[axis.tag])
              else
                0.0
              end
          end
        end
      end
    end
  end
end
