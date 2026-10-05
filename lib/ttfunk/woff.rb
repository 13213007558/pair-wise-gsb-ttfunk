# frozen_string_literal: true

require 'zlib'

module TTFunk
  # Web Open Font Format (WOFF) support. Only WOFF 1.0 containers are
  # supported.
  module WOFF
    # WOFF 1.0 file signature.
    SIGNATURE = 'wOFF'
  end
end

require_relative 'woff/file'
