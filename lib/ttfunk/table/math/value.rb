# frozen_string_literal: true

module TTFunk
  class Table
    class Math < Table
      # A signed value with an optional ppem-specific device adjustment.
      Value = Struct.new(:value, :device) do
        def value_at(ppem = nil)
          return value if ppem.nil? || device.nil?

          value + device.adjustment_for(ppem)
        end
      end
    end
  end
end
