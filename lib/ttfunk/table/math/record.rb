# frozen_string_literal: true

require_relative '../../sub_table'

module TTFunk
  class Table
    class Math < Table
      # Base class for records contained in the `MATH` table.
      class Record < SubTable
        attr_reader :root_start
        attr_reader :root_end

        def initialize(file, table_offset, root_start = table_offset, root_end = nil)
          @root_start = root_start
          @root_end = root_end
          super(file, table_offset, root_end && root_end - table_offset)
        end

        def read_uint16
          read(2, 'n').first
        end

        def read_int16
          read_signed(1).first
        end

        def read_offset
          read_uint16
        end

        def resolve_offset(parent_base, offset, what = 'offset')
          absolute = parent_base + offset

          if offset.negative? || absolute < root_start ||
             (root_end && absolute >= root_end)
            raise Error, "MATH #{what} points outside the table"
          end

          absolute
        end

        def child_record(klass, parent_base, offset, what = klass.name.split('::').last)
          return if offset.zero?

          absolute = resolve_offset(parent_base, offset, what)
          klass.new(file, absolute, root_start, root_end)
        end

        def read_value_record(parent_base, what = 'value record')
          value = read_int16
          device_offset = read_offset
          device =
            if device_offset.nonzero?
              absolute =
                resolve_offset(parent_base, device_offset, "#{what} device table")
              Device.new(file, absolute, root_start, root_end)
            end

          Value.new(value, device)
        end

        def malformed!(message)
          raise Error, "malformed MATH table: #{message}"
        end
      end
    end
  end
end
