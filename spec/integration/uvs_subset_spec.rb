# frozen_string_literal: true

require 'spec_helper'
require 'ttfunk/subset'

RSpec.describe 'UVS subsetting' do # rubocop: disable RSpec/DescribeClass
  let(:font) { TTFunk::File.new(UVSTestFont.build) }
  let(:subset) { TTFunk::Subset.for(font, :unicode) }

  it 'preserves requested variation sequences and remaps glyph IDs' do
    subset.use(UVSTestFont::BASE_CHAR, UVSTestFont::DEFAULT_SELECTOR)
    subset.use(UVSTestFont::BASE_CHAR, UVSTestFont::VARIANT_SELECTOR)

    new_font = TTFunk::File.new(subset.encode)
    uvs = new_font.cmap.uvs

    expect(uvs).not_to be_nil
    expect(uvs.selectors).to eq(
      [UVSTestFont::DEFAULT_SELECTOR, UVSTestFont::VARIANT_SELECTOR],
    )

    base_glyph_id = new_font.cmap.unicode.first[UVSTestFont::BASE_CHAR]
    expect(base_glyph_id).to be_positive

    # default UVS: the glyph comes from the regular Unicode cmap
    expect(uvs[UVSTestFont::BASE_CHAR, UVSTestFont::DEFAULT_SELECTOR])
      .to eq(:default)

    # non-default UVS: a dedicated variant glyph
    variant_glyph_id = uvs[UVSTestFont::BASE_CHAR, UVSTestFont::VARIANT_SELECTOR]
    expect(variant_glyph_id).to be_an(Integer)
    expect(variant_glyph_id).not_to eq(base_glyph_id)

    # the compound variant glyph still references the renumbered base glyph
    expect(new_font.glyph_outlines.for(variant_glyph_id).glyph_ids)
      .to eq([base_glyph_id])
  end

  it 'drops variation selectors that were not requested' do
    subset.use(UVSTestFont::BASE_CHAR, UVSTestFont::DEFAULT_SELECTOR)

    new_font = TTFunk::File.new(subset.encode)

    expect(new_font.cmap.uvs.selectors).to eq([UVSTestFont::DEFAULT_SELECTOR])
    expect(new_font.cmap.uvs[UVSTestFont::BASE_CHAR, UVSTestFont::VARIANT_SELECTOR])
      .to be_nil
  end

  it 'works with codepoint-only usage as before' do
    subset.use(UVSTestFont::BASE_CHAR)

    new_font = TTFunk::File.new(subset.encode)

    expect(new_font.cmap.uvs).to be_nil
    expect(new_font.cmap.unicode.first[UVSTestFont::BASE_CHAR]).to be_positive
  end

  it 'tracks included variation sequences' do
    subset.use(UVSTestFont::BASE_CHAR, UVSTestFont::DEFAULT_SELECTOR)

    expect(subset.includes?(UVSTestFont::BASE_CHAR)).to be(true)
    expect(subset.includes?(UVSTestFont::BASE_CHAR, UVSTestFont::DEFAULT_SELECTOR))
      .to be(true)
    expect(subset.includes?(UVSTestFont::BASE_CHAR, UVSTestFont::VARIANT_SELECTOR))
      .to be(false)
  end

  it 'raises a locatable error for unsupported variation sequences' do
    expect { subset.use(0x4E01, UVSTestFont::DEFAULT_SELECTOR) }
      .to raise_error(
        TTFunk::Error,
        /unsupported variation sequence: U\+4E01 U\+FE00/,
      )

    expect { subset.use(UVSTestFont::BASE_CHAR, 0xFE03) }
      .to raise_error(TTFunk::Error, /unsupported variation sequence/)
  end

  it 'raises when the font has no UVS table' do
    dejavu = TTFunk::File.open(test_font('DejaVuSans'))
    dejavu_subset = TTFunk::Subset.for(dejavu, :unicode)

    expect { dejavu_subset.use(0x61, 0xFE00) }
      .to raise_error(TTFunk::Error, /format 14/)
  end
end
