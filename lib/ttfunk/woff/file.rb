# frozen_string_literal: true

module TTFunk
  module WOFF
    # WOFF 1.0 container.
    #
    # Decodes a WOFF 1.0 file and reassembles the wrapped font into a plain
    # SFNT so it can be read and subset like any other font. The optional
    # WOFF metadata and private data blocks are kept aside for the caller and
    # don't end up in the font tables.
    class File < TTFunk::File
      # WOFF header format.
      HEADER_FORMAT = 'a4N2n2Nn2N5'

      # WOFF header length in bytes.
      HEADER_LENGTH = 44

      # WOFF table directory entry format.
      DIRECTORY_ENTRY_FORMAT = 'a4N4'

      # WOFF table directory entry length in bytes.
      DIRECTORY_ENTRY_LENGTH = 20

      # Scaler type of the wrapped font.
      # @return [Integer]
      attr_reader :flavor

      # WOFF major version.
      # @return [Integer]
      attr_reader :major_version

      # WOFF minor version.
      # @return [Integer]
      attr_reader :minor_version

      # Decompressed WOFF metadata block (usually an XML document).
      # @return [String, nil]
      attr_reader :metadata

      # Raw WOFF private data block.
      # @return [String, nil]
      attr_reader :private_data

      # @param contents [String] binary string containing the WOFF data
      # @param offset [Integer] offset at which the WOFF data starts
      def initialize(contents, offset = 0)
        tables, attributes = parse(contents, offset)

        @flavor = attributes[:flavor]
        @major_version = attributes[:major_version]
        @minor_version = attributes[:minor_version]
        @metadata = attributes[:metadata]
        @private_data = attributes[:private_data]

        super(build_sfnt(attributes[:flavor], tables))
      end

      private

      def parse(contents, offset)
        io = StringIO.new(contents)
        io.seek(offset)

        header = io.read(HEADER_LENGTH)
        unless header && header.bytesize == HEADER_LENGTH
          raise TTFunk::Error, 'not a WOFF file'
        end

        (signature, flavor, _length, num_tables, _reserved, _total_sfnt_size,
          major_version, minor_version, meta_offset, meta_length,
          _meta_orig_length, priv_offset, priv_length) =
          header.unpack(HEADER_FORMAT)

        unless signature == WOFF::SIGNATURE
          raise TTFunk::Error, 'not a WOFF file'
        end

        entries = read_directory(io, num_tables)
        verify_no_overlaps(entries, contents.bytesize - offset)

        tables = {}
        entries.each do |entry|
          tables[entry[:tag]] = extract_table(contents, offset, entry)
        end

        attributes = {
          flavor: flavor,
          major_version: major_version,
          minor_version: minor_version,
          metadata: extract_metadata(contents, offset, meta_offset, meta_length),
          private_data: extract_private_data(
            contents, offset, priv_offset, priv_length
          ),
        }

        [tables, attributes]
      end

      def read_directory(io, num_tables)
        Array.new(num_tables) do
          data = io.read(DIRECTORY_ENTRY_LENGTH)
          unless data && data.bytesize == DIRECTORY_ENTRY_LENGTH
            raise TTFunk::Error, 'truncated WOFF table directory'
          end

          tag, table_offset, comp_length, orig_length, orig_checksum =
            data.unpack(DIRECTORY_ENTRY_FORMAT)

          {
            tag: tag,
            offset: table_offset,
            comp_length: comp_length,
            orig_length: orig_length,
            orig_checksum: orig_checksum,
          }
        end
      end

      def verify_no_overlaps(entries, file_size)
        data_start = HEADER_LENGTH + (entries.length * DIRECTORY_ENTRY_LENGTH)
        sorted = entries.sort_by { |entry| entry[:offset] }

        sorted.each do |entry|
          # zero-length tables occupy no space and can't overlap anything
          next if entry[:comp_length].zero?

          if entry[:offset] < data_start
            raise TTFunk::Error,
              "WOFF table #{entry[:tag].inspect} overlaps the table directory"
          end

          if entry[:offset] + entry[:comp_length] > file_size
            raise TTFunk::Error,
              "WOFF table #{entry[:tag].inspect} extends past the end of the file"
          end
        end

        sorted.each_cons(2) do |previous, current|
          if previous[:offset] + previous[:comp_length] > current[:offset]
            raise TTFunk::Error,
              "WOFF table #{previous[:tag].inspect} " \
                "overlaps table #{current[:tag].inspect}"
          end
        end
      end

      def extract_table(contents, base_offset, entry)
        tag = entry[:tag]
        data = contents[(base_offset + entry[:offset]), entry[:comp_length]]
        data ||= +''.b

        table =
          if entry[:comp_length] == entry[:orig_length]
            data
          else
            begin
              Zlib::Inflate.inflate(data)
            rescue Zlib::Error => e
              raise TTFunk::Error,
                "WOFF table #{tag.inspect} could not be decompressed: #{e.message}"
            end
          end

        if table.bytesize != entry[:orig_length]
          raise TTFunk::Error,
            "WOFF table #{tag.inspect} decompressed to #{table.bytesize} " \
              "bytes, expected #{entry[:orig_length]}"
        end

        actual_checksum = table_checksum(table)
        if actual_checksum != entry[:orig_checksum]
          raise TTFunk::Error,
            format(
              'WOFF table %<tag>s checksum mismatch: ' \
                'expected 0x%<expected>08X, got 0x%<actual>08X',
              tag: tag.inspect,
              expected: entry[:orig_checksum],
              actual: actual_checksum,
            )
        end

        table
      end

      def extract_metadata(contents, base_offset, meta_offset, meta_length)
        return if meta_offset.zero? || meta_length.zero?

        compressed = contents[(base_offset + meta_offset), meta_length]
        Zlib::Inflate.inflate(compressed || +''.b)
      rescue Zlib::Error => e
        raise TTFunk::Error,
          "WOFF metadata could not be decompressed: #{e.message}"
      end

      def extract_private_data(contents, base_offset, priv_offset, priv_length)
        return if priv_offset.zero? || priv_length.zero?

        contents[(base_offset + priv_offset), priv_length]
      end

      # Reassemble the wrapped font into a plain SFNT. Directory offsets,
      # padding, table checksums, and the whole-font checksum adjustment are
      # all recomputed.
      def build_sfnt(flavor, tables)
        tags = tables.keys.sort
        table_count = tags.length

        max_power = 2**Math.log2(table_count).floor
        search_range = max_power * 16
        entry_selector = Integer(Math.log2(max_power))
        range_shift = (table_count * 16) - search_range

        # checkSumAdjustment must be zeroed while checksums are computed
        tables = tables.dup
        if tables['head']
          head = tables['head'].dup
          head[8, 4] = [0].pack('N')
          tables['head'] = head
        end

        offsets = {}
        table_offset = 12 + (table_count * 16)
        tags.each do |tag|
          offsets[tag] = table_offset
          table_offset += padded_length(tables[tag])
        end

        sfnt = +''.b
        sfnt << [
          flavor, table_count, search_range, entry_selector, range_shift,
        ].pack('Nn4')

        tags.each do |tag|
          sfnt << [
            tag, table_checksum(tables[tag]), offsets[tag], tables[tag].bytesize,
          ].pack('A4N3')
        end

        tags.each do |tag|
          sfnt << tables[tag]
          sfnt << ("\0" * (padded_length(tables[tag]) - tables[tag].bytesize))
        end

        if offsets['head']
          adjustment = (0xB1B0AFBA - table_checksum(sfnt)) & 0xFFFF_FFFF
          sfnt[(offsets['head'] + 8), 4] = [adjustment].pack('N')
        end

        sfnt
      end

      def table_checksum(data)
        data.ljust(padded_length(data), "\0").unpack('N*').sum & 0xFFFF_FFFF
      end

      def padded_length(data)
        (data.bytesize + 3) & ~3
      end
    end
  end
end
