# frozen_string_literal: true

require_relative '../../reader'
require_relative 'outline'

module TTFunk
  class Table
    class Glyf
      # Composite TrueType glyph.
      class Compound
        include Reader

        # Flags bit 0: arg1 and arg2 are words.
        ARG_1_AND_2_ARE_WORDS = 0x0001

        # Flags bit 1: arg1 and arg2 are x/y-offsets. If not set they are
        # point numbers to be matched.
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

        # Flags bit 9: horizontal metrics of this component glyph are to be
        # used for the compound glyph.
        USE_MY_METRICS = 0x0200

        # Flags bit 11: the component offset is scaled by the component
        # transformation.
        SCALED_COMPONENT_OFFSET = 0x0800

        # Flags bit 12: the component offset is not scaled by the component
        # transformation.
        UNSCALED_COMPONENT_OFFSET = 0x1000

        # Divisor for F2.14 fixed-point numbers used in component
        # transformations.
        F2DOT14_DIVISOR = 0x4000

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

        # Component records of this glyph.
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
        #   @return [Array(Float, Float, Float, Float), nil] 2x2
        #     transformation matrix as [xscale, scale01, scale10, yscale],
        #     or nil for the identity transformation.
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

          # Component records are parsed eagerly: they're small and their
          # glyph ID locations are needed to rewrite this glyph into a font
          # subset. Actual outline expansion is deferred to #decompose so
          # that subsetting doesn't pay for it.

          @glyph_ids = []
          @glyph_id_offsets = []
          @components = []
          offset = 10 # 2 bytes for each of num-contours, min x/y, max x/y

          loop do
            flags, glyph_id = @raw[offset, 4].unpack('n*')
            @glyph_ids << glyph_id
            @glyph_id_offsets << (offset + 2)
            offset += 4

            arg1, arg2 = read_component_args(flags, offset)
            offset += flags.allbits?(ARG_1_AND_2_ARE_WORDS) ? 4 : 2

            transform, transform_size = read_component_transform(flags, offset)
            offset += transform_size

            @components << Component.new(flags, glyph_id, arg1, arg2, transform)

            break if flags.nobits?(MORE_COMPONENTS)
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

        # Expand this glyph into an outline by recursively decomposing its
        # components. Points are numbered in component expansion order.
        #
        # @param glyf_table [TTFunk::Table::Glyf] glyph table to resolve
        #   component glyph IDs.
        # @param hmtx_table [TTFunk::Table::Hmtx] horizontal metrics table.
        # @param chain [Array<Integer>] glyph IDs of the enclosing compound
        #   glyphs, used for cycle detection and error reporting.
        # @return [TTFunk::Table::Glyf::Outline]
        # @raise [TTFunk::Error] if a circular component reference is found
        #   or a component anchor point is out of range.
        def decompose(glyf_table, hmtx_table, chain = [])
          glyph_chain = chain + [id]

          points = []
          end_points = []
          metrics_glyph_id = id

          components.each do |component|
            if glyph_chain.include?(component.glyph_index)
              cycle = (glyph_chain + [component.glyph_index]).join(' -> ')
              raise Error,
                "circular component reference in compound glyph: #{cycle}"
            end

            sub_outline = decompose_component(
              glyf_table,
              hmtx_table,
              component.glyph_index,
              glyph_chain,
            )

            component_points = sub_outline.points.map { |point|
              transform_point(component.transform, point.x, point.y)
            }

            dx, dy =
              component_offset(component, points, component_points, glyph_chain)

            base = points.length
            component_points.each_with_index do |(x, y), i|
              on_curve = sub_outline.points[i].on_curve
              points << OutlinePoint.new(x + dx, y + dy, on_curve)
            end
            sub_outline.end_points_of_contours.each do |end_point|
              end_points << (base + end_point)
            end

            if metrics_glyph_id == id &&
                component.flags.allbits?(USE_MY_METRICS)
              metrics_glyph_id = component.glyph_index
            end
          end

          Outline.new(points, end_points, hmtx_table.for(metrics_glyph_id))
        end

        private

        def read_component_args(flags, offset)
          if flags.allbits?(ARG_1_AND_2_ARE_WORDS)
            @raw[offset, 4].unpack('n*').map { |i|
              BinUtils.twos_comp_to_int(i, bit_width: 16)
            }
          else
            @raw[offset, 2].unpack('c*')
          end
        end

        def read_component_transform(flags, offset)
          if flags.allbits?(WE_HAVE_A_TWO_BY_TWO)
            [read_f2dot14(offset, 4), 8]
          elsif flags.allbits?(WE_HAVE_AN_X_AND_Y_SCALE)
            xscale, yscale = read_f2dot14(offset, 2)
            [[xscale, 0, 0, yscale], 4]
          elsif flags.allbits?(WE_HAVE_A_SCALE)
            scale = read_f2dot14(offset, 1).first
            [[scale, 0, 0, scale], 2]
          else
            [nil, 0]
          end
        end

        def read_f2dot14(offset, count)
          @raw[offset, count * 2].unpack('n*').map { |i|
            BinUtils.twos_comp_to_int(i, bit_width: 16).fdiv(F2DOT14_DIVISOR)
          }
        end

        def decompose_component(glyf_table, hmtx_table, glyph_id, chain)
          glyph = glyf_table.for(glyph_id)

          # blank glyphs (e.g. space) contribute no points
          return Outline.new([], [], nil) if glyph.nil?

          glyph.decompose(glyf_table, hmtx_table, chain)
        end

        def transform_point(transform, x, y)
          return [x, y] if transform.nil?

          xscale, scale01, scale10, yscale = transform
          [
            (xscale * x) + (scale10 * y),
            (scale01 * x) + (yscale * y),
          ]
        end

        def component_offset(component, points, component_points, glyph_chain)
          if component.flags.allbits?(ARGS_ARE_XY_VALUES)
            dx = component.arg1
            dy = component.arg2

            if component.flags.allbits?(SCALED_COMPONENT_OFFSET) &&
                component.flags.nobits?(UNSCALED_COMPONENT_OFFSET)
              dx, dy = transform_point(component.transform, dx, dy)
            end

            [dx, dy]
          else
            anchor_point_offset(
              component, points, component_points, glyph_chain,
            )
          end
        end

        def anchor_point_offset(
          component, points, component_points, glyph_chain
        )
          parent_point = points[component.arg1] if component.arg1 >= 0
          if parent_point.nil?
            chain_string = glyph_chain.join(' -> ')
            raise Error,
              "anchor point #{component.arg1} not found in compound glyph " \
              "#{id} (glyph chain: #{chain_string})"
          end

          if component.arg2 >= 0
            component_point = component_points[component.arg2]
          end
          if component_point.nil?
            chain = (glyph_chain + [component.glyph_index]).join(' -> ')
            raise Error,
              "anchor point #{component.arg2} not found in component glyph " \
              "#{component.glyph_index} (glyph chain: #{chain})"
          end

          [
            parent_point.x - component_point[0],
            parent_point.y - component_point[1],
          ]
        end
      end
    end
  end
end
