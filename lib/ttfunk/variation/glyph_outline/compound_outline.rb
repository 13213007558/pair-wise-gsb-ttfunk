# frozen_string_literal: true

module TTFunk
  module Variation
    module GlyphOutline
      # Decoded composite TrueType glyph.
      #
      # Only the component records are decoded (glyph id, arguments and
      # transform), because those are the only composite fields that the
      # `gvar` table can move. Component glyph ids are left untouched by
      # instantiation, and component instructions are copied verbatim.
      class CompoundOutline
        include GlyphOutline

        # One component record.
        #
        # @!attribute flags
        #   @return [Integer] component flags.
        # @!attribute glyph_index
        #   @return [Integer] glyph id of the component.
        # @!attribute arg1
        #   @return [Integer] first argument (x offset when XY offsets are
        #     used, which is the only case `gvar` can displace).
        # @!attribute arg2
        #   @return [Integer] second argument (y offset).
        # @!attribute transform
        #   @return [String] raw fixed-point transform bytes (2/4/8 bytes).
        Component = Struct.new(:flags, :glyph_index, :arg1, :arg2,
                               :transform)

        # @return [Array<Component>] component records, in font order.
        attr_reader :components

        # Decode a composite glyph.
        #
        # @param raw [String] the glyph's bytes as stored in `glyf`.
        # @return [CompoundOutline]
        def self.decode(raw)
          new(raw)
        end

        def initialize(raw)
          io = StringIO.new(raw)
          io.read(2) # numberOfContours, always -1
          @x_min = read_int16(io)
          @y_min = read_int16(io)
          @x_max = read_int16(io)
          @y_max = read_int16(io)

          @components = []
          @header_length = 10
          loop do
            flags, glyph_index = io.read(4).unpack('n2')
            @header_length += 4

            if flags & ARG_1_AND_2_ARE_WORDS != 0
              arg1 = read_int16(io)
              arg2 = read_int16(io)
              @header_length += 4
            else
              # Byte XY offsets are signed; point-number arguments are
              # unsigned.
              format = flags & 0x0002 != 0 ? 'c2' : 'C2'
              arg1, arg2 = io.read(2).unpack(format)
              @header_length += 2
            end

            transform = +''
            if flags & WE_HAVE_A_TWO_BY_TWO != 0
              transform = io.read(8).b
              @header_length += 8
            elsif flags & WE_HAVE_AN_X_AND_Y_SCALE != 0
              transform = io.read(4).b
              @header_length += 4
            elsif flags & WE_HAVE_A_SCALE != 0
              transform = io.read(2).b
              @header_length += 2
            end

            @components << Component.new(
              flags, glyph_index, arg1, arg2, transform
            )
            break if flags & MORE_COMPONENTS == 0
          end

          @trailing_data = raw[@header_length..] || +''
        end

        # Re-encode the composite glyph with the current component arguments
        # and bounding box. Argument sizes are never changed (bytes vs
        # words), keeping the binary layout otherwise identical.
        #
        # @return [String]
        def encode
          body = +''
          body << [-1].pack('s>')
          body << pack_bounds

          components.each do |component|
            flags = component.flags
            word_args = args_require_words?(component)
            flags |= ARG_1_AND_2_ARE_WORDS if word_args

            body << [flags, component.glyph_index].pack('n2')

            if word_args
              body << [component.arg1, component.arg2].pack('s>2')
            elsif component.flags & 0x0002 != 0
              body << [component.arg1, component.arg2].pack('c2')
            else
              body << [component.arg1, component.arg2].pack('C2')
            end

            body << (component.transform || +'')
          end

          body << @trailing_data
          body
        end

        # Whether the component arguments must be encoded as 16-bit words
        # because they no longer fit in signed bytes after instantiation.
        def args_require_words?(component)
          return true if component.flags & ARG_1_AND_2_ARE_WORDS != 0
          return false if component.flags & 0x0002 == 0 # point-number args

          ![component.arg1, component.arg2].all? { |value|
            (-128..127).cover?(value)
          }
        end

        # Number of pseudo-points used by gvar for this glyph: one
        # translation (x, y) pseudo-point per component plus the four phantom
        # points.
        #
        # @return [Integer]
        def variation_point_count
          components.length + 4
        end

        # Affine transform matrix of a component as
        # +[xx, yx, xy, yy]+ 2.14 fixed-point values, or +nil+ for an
        # identity transform.
        #
        # @param component [Component]
        # @return [Array<Float>, nil]
        def self.matrix_for(component)
          bytes = component.transform
          return nil if bytes.nil? || bytes.empty?

          values = bytes.unpack('s>*').map { |value| value / 16_384.0 }
          case values.length
          when 1 then [values[0], 0.0, 0.0, values[0]]
          when 2 then [values[0], 0.0, 0.0, values[1]]
          else values
          end
        end

        private

        def read_int16(io)
          io.read(2).unpack1('s>')
        end

      end
    end
  end
end
