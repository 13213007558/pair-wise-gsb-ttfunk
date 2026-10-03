# frozen_string_literal: true

require 'zlib'

require_relative 'table/simple'

module TTFunk
  # Encodes a font to a WOFF 1.0 container.
  class WOFFEncoder
    # Original font.
    # @return [TTFunk::File]
    attr_reader :original

    # Encoding options.
    # @return [Hash]
    attr_reader :options

    # @param original [TTFunk::File, String] font to encode, either as a font
    #   object or as a binary string containing an SFNT font
    # @param options [Hash]
    # @option options :metadata [String, nil] WOFF metadata block (XML).
    #   When the option is not given the metadata of the original font is
    #   preserved (if any). Pass +nil+ to explicitly drop it.
    # @option options :private [String, nil] WOFF private data block.
    #   When the option is not given the private data of the original font
    #   is preserved (if any). Pass +nil+ to explicitly drop it.
    # @option options :version [Array(Integer, Integer)] font version
    #   ([major, minor]) to record in the WOFF header. Defaults to the
    #   version of the original font if it came from a WOFF container.
    def initialize(original, options = {})
      @original = original.is_a?(TTFunk::File) ? original : TTFunk::File.new(original)
      @options = options
    end

    # Encode the font to a WOFF container.
    #
    # @return [String]
    def encode
      tables = table_entries
      metadata = options.key?(:metadata) ? options[:metadata] : original.woff_metadata
      private_data = options.key?(:private) ? options[:private] : original.woff_private
      major, minor = options.fetch(:version) { original.woff_version || [1, 0] }

      meta_block = metadata && Zlib::Deflate.deflate(metadata, Zlib::BEST_COMPRESSION)

      directory_length = WOFF::DIRECTORY_ENTRY_LENGTH * tables.length
      body = String.new(encoding: Encoding::BINARY)

      tables.each do |entry|
        align_body(body)
        entry[:offset] = WOFF::HEADER_LENGTH + directory_length + body.bytesize
        body << entry[:data]
      end

      meta_offset = 0
      meta_length = 0
      meta_orig_length = 0
      if meta_block
        align_body(body)
        meta_offset = WOFF::HEADER_LENGTH + directory_length + body.bytesize
        meta_length = meta_block.bytesize
        meta_orig_length = metadata.bytesize
        body << meta_block
      end

      priv_offset = 0
      priv_length = 0
      if private_data
        align_body(body)
        priv_offset = WOFF::HEADER_LENGTH + directory_length + body.bytesize
        priv_length = private_data.bytesize
        body << private_data
      end

      total_sfnt_size = 12 + (16 * tables.length) +
        tables.sum { |entry| align4(entry[:orig_length]) }

      header = [
        WOFF::SIGNATURE,
        original.directory.scaler_type,
        WOFF::HEADER_LENGTH + directory_length + body.bytesize,
        tables.length,
        0,
        total_sfnt_size,
        major,
        minor,
        meta_offset,
        meta_length,
        meta_orig_length,
        priv_offset,
        priv_length,
      ].pack('a4N2n2Nn2N5')

      directory = tables.map { |entry|
        [
          entry[:tag],
          entry[:offset],
          entry[:data].bytesize,
          entry[:orig_length],
          entry[:checksum],
        ].pack('a4N4')
      }.join

      header + directory + body
    end

    private

    def table_entries
      original.directory.tables.keys.sort.map do |tag|
        raw = TTFunk::Table::Simple.new(original, tag).raw
        compressed = Zlib::Deflate.deflate(raw, Zlib::BEST_COMPRESSION)

        {
          tag: tag,
          checksum: table_checksum(tag, raw),
          orig_length: raw.bytesize,
          data: compressed.bytesize < raw.bytesize ? compressed : raw,
        }
      end
    end

    def table_checksum(tag, raw)
      if tag == 'head' && raw.bytesize >= 12
        raw = raw.dup
        raw[8, 4] = "\0\0\0\0"
      end
      WOFF.checksum(raw)
    end

    def align_body(body)
      body << "\0" * ((4 - (body.bytesize % 4)) % 4)
    end

    def align4(length)
      (length + 3) & ~3
    end
  end
end
