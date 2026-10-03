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

        # Flags bit 1: arg1 and arg2 are x/y offsets. Otherwise they are
        # point numbers for anchor-point alignment.
        ARGS_ARE_XY_VALUES = 0x0002

        # Flags bit 2: round the x/y offset to the nearest grid line.
        ROUND_XY_TO_GRID = 0x0004

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

        # Flags bit 9: use the horizontal metrics of this component for the
        # compound glyph.
        USE_MY_METRICS = 0x0200

        # Flags bit 11: the component offset is scaled by the component
        # transformation.
        SCALED_COMPONENT_OFFSET = 0x0800

        # Flags bit 12: the component offset is not scaled by the component
        # transformation.
        UNSCALED_COMPONENT_OFFSET = 0x1000

        # Divisor for F2DOT14 fixed-point transformation values.
        F2DOT14_DIVISOR = 2**14
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
        #   Transformation matrix [xx, xy, yx, yy] where
        #   x' = xx*x + xy*y and y' = yx*x + yy*y.
        #   @return [Array(Numeric, Numeric, Numeric, Numeric)]
        Component = Struct.new(:flags, :glyph_index, :arg1, :arg2, :transform) do
          # Are arg1 and arg2 x/y offsets (as opposed to anchor point
          # numbers)?
          # @return [Boolean]
          def xy_values?
            flags.allbits?(ARGS_ARE_XY_VALUES)
          end

          # Should the x/y offset be rounded to the grid?
          # @return [Boolean]
          def round_to_grid?
            flags.allbits?(ROUND_XY_TO_GRID)
          end

          # Do the compound glyph metrics come from this component?
          # @return [Boolean]
          def use_my_metrics?
            flags.allbits?(USE_MY_METRICS)
          end

          # Is the x/y offset scaled by the component transformation?
          # @return [Boolean]
          def scaled_offset?
            flags.allbits?(SCALED_COMPONENT_OFFSET) &&
              flags.nobits?(UNSCALED_COMPONENT_OFFSET)
          end
        end

        # Components of this glyph.
        # @return [Array<Component>]
        attr_reader :components

        # @param id [Integer] glyph ID.
        # @param raw [String]
        # @param file [TTFunk::File, nil] font file this glyph belongs to.
        #   Needed for outline expansion.
        def initialize(id, raw, file = nil)
          @id = id
          @raw = raw
          @file = file
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

          @components = []
          @glyph_ids = []
          @glyph_id_offsets = []
          offset = 10 # 2 bytes for each of num-contours, min x/y, max x/y

          loop do
            flags, glyph_id = @raw[offset, 4].unpack('n*')
            @glyph_ids << glyph_id
            @glyph_id_offsets << (offset + 2)
            offset += 4

            arg1, arg2 = read_component_args(flags, offset)
            offset += flags.allbits?(ARG_1_AND_2_ARE_WORDS) ? 4 : 2

            transform = read_component_transform(flags, offset)
            offset += component_transform_size(flags)

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

        # Expand this glyph into a full outline. All components (including
        # nested ones) are resolved with their transformations applied. Point
        # numbering follows the order in which components are expanded.
        #
        # Effective horizontal metrics come from the first component with the
        # USE_MY_METRICS flag, or from this glyph itself if there is none.
        #
        # @return [TTFunk::Table::Glyf::Outline]
        # @raise [TTFunk::Error] if the glyph was loaded without a font file,
        #   if components recursively reference each other, or if an anchor
        #   point number is out of range
        def expand
          if @file.nil?
            raise TTFunk::Error,
              'cannot expand a glyph without its font file'
          end

          points, end_points, on_curve = expanded_geometry([id])

          metrics_component = @components.find(&:use_my_metrics?)
          metrics_glyph_id = metrics_component ? metrics_component.glyph_index : id
          metric = @file.horizontal_metrics.for(metrics_glyph_id)

          Outline.new(
            points: points,
            end_points_of_contours: end_points,
            on_curve: on_curve,
            advance_width: metric.advance_width,
            left_side_bearing: metric.left_side_bearing,
          )
        end

        # Geometry of the fully expanded glyph for use in compound glyph
        # expansion.
        #
        # @api private
        # @param chain [Array<Integer>] IDs of the glyphs being expanded, for
        #   recursion detection and error reporting
        # @return [Array(Array<Array(Numeric, Numeric)>, Array<Integer>,
        #   Array<Boolean>)] points, contour end points, and on-curve flags
        def expanded_geometry(chain)
          points = []
          end_points = []
          on_curve = []

          @components.each do |component|
            if chain.include?(component.glyph_index)
              raise TTFunk::Error,
                'recursive component reference in glyph chain ' +                  "#{(chain + [component.glyph_index]).join(' -> ')}"
            end

            glyph = @file.glyph_outlines.for(component.glyph_index)
            next if glyph.nil? # blank glyph, e.g. space character

            comp_points, comp_end_points, comp_on_curve =
              glyph.expanded_geometry(chain + [component.glyph_index])

            xx, xy, yx, yy = component.transform
            comp_points = comp_points.map { |x, y|
              [(xx * x) + (xy * y), (yx * x) + (yy * y)]
            }

            dx, dy = component_offset(component, points, comp_points, chain)

            base = points.length
            comp_points.each { |x, y| points << [x + dx, y + dy] }
            comp_end_points.each { |end_point| end_points << end_point + base }
            on_curve.concat(comp_on_curve)
          end

          [points, end_points, on_curve]
        end

        private

        def component_offset(component, points, comp_points, chain)
          if component.xy_values?
            dx = component.arg1
            dy = component.arg2

            if component.scaled_offset?
              xx, xy, yx, yy = component.transform
              dx, dy = (xx * dx) + (xy * dy), (yx * dx) + (yy * dy)
            end

            if component.round_to_grid?
              dx = dx.round
              dy = dy.round
            end

            [dx, dy]
          else
            anchor = points[component.arg1]
            target = comp_points[component.arg2]

            if anchor.nil? || target.nil?
              raise TTFunk::Error,
                'component anchor point out of range in glyph chain ' +                  "#{chain.join(' -> ')}"
            end

            [anchor[0] - target[0], anchor[1] - target[1]]
          end
        end

        def read_component_args(flags, offset)
          words = flags.allbits?(ARG_1_AND_2_ARE_WORDS)
          xy_values = flags.allbits?(ARGS_ARE_XY_VALUES)

          if words
            args = @raw[offset, 4].unpack('n*')
            if xy_values
              args.map { |arg| BinUtils.twos_comp_to_int(arg, bit_width: 16) }
            else
              args
            end
          else
            @raw[offset, 2].unpack(xy_values ? 'c*' : 'C*')
          end
        end

        def read_component_transform(flags, offset)
          if flags.allbits?(WE_HAVE_A_TWO_BY_TWO)
            xx, xy, yx, yy = read_f2dot14(offset, 4)
            [xx, xy, yx, yy]
          elsif flags.allbits?(WE_HAVE_AN_X_AND_Y_SCALE)
            xx, yy = read_f2dot14(offset, 2)
            [xx, 0, 0, yy]
          elsif flags.allbits?(WE_HAVE_A_SCALE)
            scale = read_f2dot14(offset, 1).first
            [scale, 0, 0, scale]
          else
            [1, 0, 0, 1]
          end
        end

        def component_transform_size(flags)
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

        def read_f2dot14(offset, count)
          @raw[offset, count * 2].unpack('n*').map { |value|
            BinUtils.twos_comp_to_int(value, bit_width: 16).to_f / F2DOT14_DIVISOR
          }
        end
      end
    end
  end
end
