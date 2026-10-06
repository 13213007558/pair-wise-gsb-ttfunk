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

        # Flags bit 1: arg1 and arg2 are XY offsets instead of anchor points.
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
        Component = Struct.new(
          :flags, :glyph_index, :arg1, :arg2, :transform,
          :arg1_offset, :arg2_offset,
        )

        # Parsed component records.
        # @return [Array<Component>]
        attr_reader :components

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
          offset = 10 # 2 bytes for each of num-contours, min x/y, max x/y

          @components = []

          loop do
            flags, glyph_id = @raw[offset, 4].unpack('n*')
            @glyph_ids << glyph_id
            @glyph_id_offsets << (offset + 2)
            offset += 4

            if flags.allbits?(ARG_1_AND_2_ARE_WORDS)
              arg1 = read_signed_short(@raw[offset, 2].unpack1('n'))
              arg2 = read_signed_short(@raw[offset + 2, 2].unpack1('n'))
              offset += 4
            else
              arg1 = signed_byte(@raw.getbyte(offset))
              arg2 = signed_byte(@raw.getbyte(offset + 1))
              offset += 2
            end

            arg1_offset = offset - (flags.allbits?(ARG_1_AND_2_ARE_WORDS) ? 4 : 2)
            arg2_offset = arg1_offset +
              (flags.allbits?(ARG_1_AND_2_ARE_WORDS) ? 2 : 1)
            transform_offset = offset
            transform = read_transform(flags, transform_offset)
            @components << Component.new(
              flags, glyph_id, arg1, arg2, transform,
              arg1_offset, arg2_offset
            )
            offset = transform_offset + transform_size(flags)

            break if flags.nobits?(MORE_COMPONENTS)

            if flags.allbits?(WE_HAVE_A_TWO_BY_TWO)
              offset += 8
            elsif flags.allbits?(WE_HAVE_AN_X_AND_Y_SCALE)
              offset += 4
            elsif flags.allbits?(WE_HAVE_A_SCALE)
              offset += 2
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

        # Recalculate this compound's bounding box from its transformed children.
        #
        # @param glyf [TTFunk::Table::Glyf]
        # @param seen [Array<Integer>]
        # @return [Array<Integer>]
        def recalculate_bounds(glyf, seen = [])
          return [x_min, y_min, x_max, y_max] if seen.include?(id)

          points = flatten(glyf, seen + [id])
          if points.any?
            xs = points.map { |x, _y| x }
            ys = points.map { |_x, y| y }
            @x_min = xs.min.floor
            @x_max = xs.max.ceil
            @y_min = ys.min.floor
            @y_max = ys.max.ceil
          end

          raw[2, 8] = [x_min, y_min, x_max, y_max].pack('s>*')
          [x_min, y_min, x_max, y_max]
        end

        # Move a component whose arguments are XY offsets.
        #
        # @param index [Integer]
        # @param x_delta [Integer]
        # @param y_delta [Integer]
        # @return [void]
        def translate_component(index, x_delta, y_delta)
          component = components[index]
          component.arg1 += x_delta
          component.arg2 += y_delta

          if component.flags.allbits?(ARG_1_AND_2_ARE_WORDS)
            raw[component.arg1_offset, 2] = [component.arg1].pack('s>')
            raw[component.arg2_offset, 2] = [component.arg2].pack('s>')
          else
            raw.setbyte(component.arg1_offset, signed_byte_to_unsigned(component.arg1))
            raw.setbyte(component.arg2_offset, signed_byte_to_unsigned(component.arg2))
          end
        end

        # Flatten transformed component coordinates.
        #
        # @param glyf [TTFunk::Table::Glyf]
        # @param seen [Array<Integer>]
        # @return [Array<Array(Integer, Float)>]
        def flatten(glyf, seen = [])
          assembled = []

          components.each do |component|
            child = glyf.for(component.glyph_index)
            child_points =
              if child.nil?
                []
              elsif child.compound?
                child.flatten(glyf, seen + [id])
              else
                child.coordinates
              end

            transformed = child_points.map { |point| transform_point(component, point) }

            if component.flags.nobits?(ARGS_ARE_XY_VALUES)
              base_point = assembled[component.arg1] || [0, 0]
              child_point = transformed[component.arg2] || [0, 0]
              translation = [
                base_point[0] - child_point[0],
                base_point[1] - child_point[1],
              ]
              transformed.map! { |x, y| [x + translation[0], y + translation[1]] }
            end

            assembled.concat(transformed)
          end

          assembled
        end

        private

        def read_transform(flags, offset)
          identity = [1, 0, 0, 1]
          read_f2dot14 = ->(position) {
            read_signed_short(@raw[position, 2].unpack1('n')) / 16_384.0
          }

          if flags.allbits?(WE_HAVE_A_TWO_BY_TWO)
            [
              read_f2dot14.call(offset),
              read_f2dot14.call(offset + 2),
              read_f2dot14.call(offset + 4),
              read_f2dot14.call(offset + 6),
            ]
          elsif flags.allbits?(WE_HAVE_AN_X_AND_Y_SCALE)
            [read_f2dot14.call(offset), 0, 0, read_f2dot14.call(offset + 2)]
          elsif flags.allbits?(WE_HAVE_A_SCALE)
            scale = read_f2dot14.call(offset)
            [scale, 0, 0, scale]
          else
            identity
          end
        end

        def transform_size(flags)
          if flags.allbits?(WE_HAVE_A_TWO_BY_TWO)
            8
          elsif flags.allbits?(WE_HAVE_AN_X_AND_Y_SCALE)
            4
          elsif flags.allbits?(WE_HAVE_A_SCALE)
            2
          else
            0
          end
        end

        def transform_point(component, point)
          a, b, c, d = component.transform
          x, y = point
          translated = component.flags.allbits?(ARGS_ARE_XY_VALUES)

          [
            (a * x) + (b * y) + (translated ? component.arg1 : 0),
            (c * x) + (d * y) + (translated ? component.arg2 : 0),
          ]
        end

        def signed_byte(value)
          value >= 0x80 ? value - 0x100 : value
        end

        def read_signed_short(value)
          BinUtils.twos_comp_to_int(value, bit_width: 16)
        end

        def signed_byte_to_unsigned(value)
          value.negative? ? value + 0x100 : value
        end
      end
    end
  end
end
