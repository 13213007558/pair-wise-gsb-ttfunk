# frozen_string_literal: true

require_relative 'subset/unicode'
require_relative 'subset/unicode_8bit'
require_relative 'subset/mac_roman'
require_relative 'subset/windows_1252'
require_relative 'subset/shaping'

module TTFunk
  # Namespace for different types of subsets.
  module Subset
    # Create a subset for the font using the specified encoding.
    #
    # @param original [TTFunk::File]
    # @param encoding [:unicode, :unicode_8bit, :mac_roman, :windows_1252, :shaping]
    # @raise [NotImplementedError] for unsupported encodings
    # @return [TTFunk::Subset::Unicode, TTFunk::Subset::Unicode8Bit,
    #   TTFunk::Subset::MacRoman, TTFunk::Subset::Windows1252,
    #   TTFunk::Subset::Shaping]
    def self.for(original, encoding, **options)
      case encoding.to_sym
      when :unicode then Unicode.new(original)
      when :unicode_8bit then Unicode8Bit.new(original)
      when :mac_roman then MacRoman.new(original)
      when :windows_1252 then Windows1252.new(original) # rubocop: disable Naming/VariableNumber
      when :shaping then Shaping.new(original, **options)
      else raise NotImplementedError, "encoding #{encoding} is not supported"
      end
    end
  end
end
