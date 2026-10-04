# frozen_string_literal: true

require_relative '../../reader'

module TTFunk
  class Table
    class Glyf
      # Composite TrueType glyph.
      class Compound
        include Reader

        # Flags bit 0: arg1 and arg2 are words.
        ARG_1_AND_2_ARE_WORDS = 0x0001

        # Flags bit 1: arguments are offsets rather than point numbers.
        ARGS_ARE_XY_VALUES = 0x0002

        # Flags bit 3: there is a simple scale for the component.
        WE_HAVE_A_SCALE = 0x0008

        # Flags bit 5: at least one more glyph after this one.
        MORE_COMPONENTS = 0x0020

        # Flags bit 6: the x direction will use a different scale from the
        # y direction.
        WE_HAVE_AN_X_AND_Y_SCALE = 0x0040

        # Flags bit 7: there is a 2 by 2 transformation that will be used to
        # scale the component.
        WE_HAVE_A_TWO_BY_TWO = 0x0080

        # Flags bit 8: following the last component are instructions for the
        # composite character.
        WE_HAVE_INSTRUCTIONS = 0x0100

        # Glyph ID.
        # @return [Integer]
        attr_reader :id

        # Binary serialization of this glyph.
        # @return [String]
        attr_reader :raw

        # Number of contours in this glyph.
        # @return [Integer]
        attr_reader :number_of_contours

        # Minimum x for coordinate.
        # @return [Integer]
        attr_reader :x_min

        # Minimum y for coordinate.
        # @return [Integer]
        attr_reader :y_min

        # Maximum x for coordinate.
        # @return [Integer]
        attr_reader :x_max

        # Maximum y for coordinate.
        # @return [Integer]
        attr_reader :y_max

        # IDs of compound glyphs.
        attr_reader :glyph_ids

        # Parsed components.
        # @return [Array<Component>]
        attr_reader :components

        # Component glyph.
        #
        # @!attribute [rw] flags
        #   Component flag.
        #   @return [Integer]
        # @!attribute [rw] glyph_index
        #   Glyph index of component.
        #   @return [Integer]
        # @!attribute [rw] arg1
        #   x-offset for component or point number.
        #   @return [Integer]
        # @!attribute [rw] arg2
        #   y-offset for component or point number.
        #   @return [Integer]
        # @!attribute [rw] transform
        #   Transformation.
        #   @return []
        Component = Struct.new(:flags, :glyph_index, :arg1, :arg2, :transform)

        # @param id [Integer] glyph ID.
        # @param raw [String]
        def initialize(id, raw)
          @id = id
          @raw = raw
          io = StringIO.new(raw)

          @number_of_contours, @x_min, @y_min, @x_max, @y_max =
            io.read(10).unpack('n*').map { |i|
              BinUtils.twos_comp_to_int(i, bit_width: 16)
            }

          # Because TTFunk only cares about glyphs insofar as they (1) provide
          # a bounding box for each glyph, and (2) can be rewritten into a
          # font subset, we don't really care about the rest of the glyph data
          # except as a whole. Thus, we don't actually decompose the glyph
          # into it's parts--all we really care about are the locations within
          # the raw string where the component glyph ids are stored, so that
          # when we rewrite this glyph into a subset we can rewrite the
          # component glyph-ids so they are correct for the subset.

          @glyph_ids = []
          @glyph_id_offsets = []
          @components = []
          offset = 10 # 2 bytes for each of num-contours, min x/y, max x/y

          loop do
            flags, glyph_id = @raw[offset, 4].unpack('n*')
            @glyph_ids << glyph_id
            @glyph_id_offsets << (offset + 2)
            arg1_offset = offset + 4
            arg2_offset = arg1_offset + (flags.allbits?(ARG_1_AND_2_ARE_WORDS) ? 2 : 1)

            arg1 = read_argument(arg1_offset, flags)
            arg2 = read_argument(arg2_offset, flags)
            transform_offset = arg2_offset + (flags.allbits?(ARG_1_AND_2_ARE_WORDS) ? 2 : 1)
            transform = read_transform(transform_offset, flags)
            @components << Component.new(
              flags, glyph_id, arg1, arg2, transform,
            )

            break if flags.nobits?(MORE_COMPONENTS)

            if flags.allbits?(WE_HAVE_A_TWO_BY_TWO)
              offset = transform_offset + 8
            elsif flags.allbits?(WE_HAVE_AN_X_AND_Y_SCALE)
              offset = transform_offset + 4
            elsif flags.allbits?(WE_HAVE_A_SCALE)
              offset = transform_offset + 2
            else
              offset = transform_offset
            end
          end
        end

        # Is this a composite glyph?
        # @return [true]
        def compound?
          true
        end

        # Recode glyph.
        #
        # @param mapping [Hash{Integer => Integer}] a hash mapping old glyph IDs
        #   to new glyph IDs.
        # @return [String]
        def recode(mapping)
          result = raw.dup
          new_ids = glyph_ids.map { |id| mapping[id] }

          new_ids.zip(@glyph_id_offsets).each do |new_id, offset|
            result[offset, 2] = [new_id].pack('n')
          end

          result
        end

        # Whether component arguments are numeric offsets.
        # @return [Boolean]
        def xy_arguments?
          components.any? { |component| component.flags.allbits?(ARGS_ARE_XY_VALUES) }
        end

        # Encode the compound after applying gvar component translations.
        #
        # @param component_deltas [Hash{Integer => Array(Integer, Integer)}]
        # @return [String]
        def encode_with_component_deltas(component_deltas)
          result = raw.dup

          components.each do |component|
            delta_x, delta_y = component_deltas.fetch(component.glyph_index, [0, 0])
            next if delta_x.zero? && delta_y.zero?
            unless component.flags.allbits?(ARGS_ARE_XY_VALUES)
              raise TTFunk::Error, 'point-number component gvar deltas are not supported'
            end

            replace_argument(result, component, delta_x, delta_y)
          end

          result
        end

        private

        def read_argument(position, flags)
          if flags.allbits?(ARG_1_AND_2_ARE_WORDS)
            BinUtils.twos_comp_to_int(raw[position, 2].unpack1('n'), bit_width: 16)
          else
            value = raw[position].unpack1('C')
            value >= 0x80 ? value - 0x100 : value
          end
        end

        def read_transform(position, flags)
          if flags.allbits?(WE_HAVE_A_TWO_BY_TWO)
            raw[position, 8].unpack('n*').map { |value| fixed2x14(value) }
          elsif flags.allbits?(WE_HAVE_AN_X_AND_Y_SCALE)
            [fixed2x14(raw[position, 2].unpack1('n')), 0, 0,
             fixed2x14(raw[position + 2, 2].unpack1('n'))]
          elsif flags.allbits?(WE_HAVE_A_SCALE)
            scale = fixed2x14(raw[position, 2].unpack1('n'))
            [scale, 0, 0, scale]
          else
            [Rational(1), 0, 0, Rational(1)]
          end
        end

        def fixed2x14(value)
          Rational(BinUtils.twos_comp_to_int(value, bit_width: 16), 0x4000)
        end

        def replace_argument(result, component, delta_x, delta_y)
          flags = component.flags
          flags |= ARG_1_AND_2_ARE_WORDS
          # Replacing variable-width arguments in place is not possible here.
          raise TTFunk::Error, 'byte component deltas are not supported' unless component.flags.allbits?(ARG_1_AND_2_ARE_WORDS)

          component_position = @glyph_id_offsets[components.index(component)] - 2
          result[component_position, 2] = [flags].pack('n')
          arg1_offset = component_position + 4
          result[arg1_offset, 4] = [component.arg1 + delta_x, component.arg2 + delta_y].pack('s>2')
        end
      end
    end
  end
end
