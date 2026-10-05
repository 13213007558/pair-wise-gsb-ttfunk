# frozen_string_literal: true

module TTFunk
  class Table
    class Cbdt < Table
      # Composite bitmap glyph (image formats 8 and 9). The glyph is
      # assembled from other glyphs' bitmaps placed at given offsets.
      class CompositeGlyph < Glyph
        # A single component of a composite glyph.
        #
        # @!attribute [rw] glyph_id
        #   ID of the component glyph.
        #   @return [Integer]
        # @!attribute [rw] x_offset
        #   Horizontal offset of the component's origin relative to the
        #   parent glyph's origin. Can be negative.
        #   @return [Integer]
        # @!attribute [rw] y_offset
        #   Vertical offset of the component's origin relative to the parent
        #   glyph's origin. Can be negative.
        #   @return [Integer]
        Component = Struct.new(:glyph_id, :x_offset, :y_offset)

        # Glyph components.
        # @return [Array<Component>]
        attr_reader :components

        # @param image_format [Integer]
        # @param data [String] raw glyph data
        # @param glyph_id [Integer, nil]
        def initialize(image_format, data, glyph_id: nil)
          super(image_format, glyph_id: glyph_id)

          metrics_length =
            if image_format == 8
              @metrics = SmallMetrics.from_bytes(data)
              # 1 byte of padding after small metrics
              SmallMetrics::BYTE_LENGTH + 1
            else
              @metrics = BigMetrics.from_bytes(data)
              BigMetrics::BYTE_LENGTH
            end

          if data.bytesize < metrics_length + 2
            raise TTFunk::Error, 'truncated composite glyph data'
          end

          num_components = data.byteslice(metrics_length, 2).unpack1('n')
          components_offset = metrics_length + 2

          if data.bytesize < components_offset + (num_components * 4)
            raise TTFunk::Error, 'truncated composite glyph components'
          end

          @components = Array.new(num_components) { |i|
            component_glyph_id, x_offset, y_offset =
              data.byteslice(components_offset + (i * 4), 4).unpack('nc2')
            Component.new(component_glyph_id, x_offset, y_offset)
          }
        end

        # Is this a composite glyph?
        #
        # @return [true]
        def composite?
          true
        end

        # Compose the glyph bitmap from its components.
        #
        # Components are drawn in order. Where components overlap the pixel
        # values are combined with a bitwise OR, as specified for bit-aligned
        # composite glyphs.
        #
        # @param resolver [#call] a callable that maps a component glyph ID
        #   to its glyph (e.g. a block calling +strike.bitmap_for+)
        # @return [TTFunk::Table::Cbdt::ComposedBitmap]
        # @raise [TTFunk::Error] on circular component references, missing
        #   component glyphs, or non-bitmap components
        def compose(resolver, resolution_stack = [])
          unless glyph_id.nil?
            if resolution_stack.include?(glyph_id)
              raise TTFunk::Error,
                "circular component reference to glyph #{glyph_id}"
            end

            resolution_stack = resolution_stack + [glyph_id]
          end

          ComposedBitmap.new.tap { |bitmap|
            components.each do |component|
              component_glyph = resolver.call(component.glyph_id)

              if component_glyph.nil?
                raise TTFunk::Error,
                  "component glyph #{component.glyph_id} not found"
              end

              component_bitmap =
                if component_glyph.composite?
                  component_glyph.compose(resolver, resolution_stack)
                elsif component_glyph.respond_to?(:pixels)
                  ComposedBitmap.from_glyph(component_glyph)
                else
                  raise TTFunk::Error,
                    "component glyph #{component.glyph_id} " +                      'is not a compositable bitmap'
                end

              bitmap.place(
                component_bitmap,
                component.x_offset,
                component.y_offset,
              )
            end
          }
        end
      end

      # A bitmap composed from (possibly multiple) glyph bitmaps.
      class ComposedBitmap
        # Bitmap width in pixels.
        # @return [Integer]
        attr_reader :width

        # Bitmap height in pixels.
        # @return [Integer]
        attr_reader :height

        # Horizontal distance from the glyph origin to the left edge of the
        # bitmap. Can be negative.
        # @return [Integer]
        attr_reader :bearing_x

        # Vertical distance from the glyph origin to the top edge of the
        # bitmap. Can be negative.
        # @return [Integer]
        attr_reader :bearing_y

        # Bitmap pixels. Each row is an array of 0s and 1s. Rows are ordered
        # from top to bottom, pixels in a row from left to right.
        # @return [Array<Array<Integer>>]
        attr_reader :pixels

        # Build a composed bitmap from a single bitmap glyph.
        #
        # @param glyph [TTFunk::Table::Cbdt::BitmapGlyph]
        # @return [TTFunk::Table::Cbdt::ComposedBitmap]
        def self.from_glyph(glyph)
          new(
            width: glyph.width,
            height: glyph.height,
            bearing_x: glyph.metrics.hori_bearing_x,
            bearing_y: glyph.metrics.hori_bearing_y,
            pixels: glyph.pixels,
          )
        end

        def initialize(width: 0, height: 0, bearing_x: 0, bearing_y: 0, pixels: [])
          @width = width
          @height = height
          @bearing_x = bearing_x
          @bearing_y = bearing_y
          @pixels = pixels
        end

        # Is this bitmap empty?
        #
        # @return [Boolean]
        def empty?
          @pixels.empty?
        end

        # Place another bitmap into this one. The other bitmap's origin is
        # placed at the given offset relative to this bitmap's origin.
        # Overlapping pixels are combined with a bitwise OR.
        #
        # @param other [TTFunk::Table::Cbdt::ComposedBitmap]
        # @param offset_x [Integer]
        # @param offset_y [Integer]
        # @return [void]
        def place(other, offset_x, offset_y)
          return if other.empty?

          left = offset_x + other.bearing_x
          top = offset_y + other.bearing_y

          if empty?
            @bearing_x = left
            @bearing_y = top
            @width = other.width
            @height = other.height
            @pixels = other.pixels.map(&:dup)
            return
          end

          new_left = [bearing_x, left].min
          new_top = [bearing_y, top].max
          new_right = [bearing_x + width, left + other.width].max
          new_bottom = [bearing_y - height, top - other.height].min

          new_width = new_right - new_left
          new_height = new_top - new_bottom

          canvas = Array.new(new_height) { Array.new(new_width, 0) }
          blit(canvas, @pixels, bearing_x - new_left, new_top - bearing_y)
          blit(canvas, other.pixels, left - new_left, new_top - top)

          @bearing_x = new_left
          @bearing_y = new_top
          @width = new_width
          @height = new_height
          @pixels = canvas
        end

        private

        def blit(canvas, source_pixels, col_offset, row_offset)
          source_pixels.each_with_index do |row, row_index|
            row.each_with_index do |pixel, col_index|
              next if pixel.zero?

              canvas[row_index + row_offset][col_index + col_offset] |= pixel
            end
          end
        end
      end
    end
  end
end
