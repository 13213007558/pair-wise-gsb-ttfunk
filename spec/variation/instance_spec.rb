# frozen_string_literal: true

require 'ttfunk'
require 'ttfunk/variation/instance'
require 'ttfunk/variation/glyph_outline'
require 'ttfunk/table/simple'
require 'stringio'

def test_path(name)
  File.expand_path('../fonts', __dir__) + "/#{name}"
end

RSpec.describe TTFunk::Variation::Instance do
  let(:path) { test_path('VariableTest.ttf') }
  let(:file) { TTFunk::File.open(path) }

  def instantiate(coordinates)
    described_class.generate(file, coordinates)
  end

  def open(result)
    TTFunk::File.open(StringIO.new(result[:font]))
  end

  def glyph_ids(font)
    cmap = font.cmap.unicode.first
    {
      notdef: 0,
      space: cmap.code_map.fetch(0x20),
      base: cmap.code_map.fetch(0x62),
      mark: 2,
      composite: font.maximum_profile.num_glyphs - 1,
    }
  end

  def simple_outline(font, gid)
    raw = font.glyph_outlines.for(gid).raw
    TTFunk::Variation::GlyphOutline::SimpleOutline.decode(raw)
  end

  def composite_outline(font, gid)
    raw = font.glyph_outlines.for(gid).raw
    TTFunk::Variation::GlyphOutline::CompoundOutline.decode(raw)
  end

  describe 'axis normalization and clamping' do
    it 'reports the normalized location' do
      result = instantiate('wght' => 900)
      expect(result[:location]).to eq('wght' => 1.0)
    end

    it 'clamps coordinates above the axis maximum' do
      result = instantiate('wght' => 1500)
      expect(result[:location]).to eq('wght' => 1.0)
    end

    it 'clamps coordinates below the axis minimum' do
      result = instantiate('wght' => 50)
      expect(result[:location]).to eq('wght' => -1.0)
    end

    it 'defaults omitted axes to the default location' do
      result = instantiate({})
      expect(result[:location]).to eq('wght' => 0.0)
    end

    it 'accepts symbol axis tags' do
      result = instantiate(wght: 900)
      expect(result[:location]).to eq('wght' => 1.0)
    end

    it 'applies the avar segment map to the normalized coordinate' do
      # 650 design units normalizes to 0.5, which avar maps to ~0.7
      result = instantiate('wght' => 650)
      # The avar-mapped value is itself quantized to the F2DOT14 grid.
      expect(result[:location]['wght']).to be_within(1e-3).of(0.7)
      expect(result[:location]['wght']).to eq(0.70001220703125)
    end
  end

  describe 'the generated font' do
    let(:result) { instantiate('wght' => 900) }

    it 'no longer advertises variable-font tables' do
      font = open(result)
      %w[fvar avar gvar cvar MVAR HVAR VVAR].each do |tag|
        expect(font.directory_info(tag)).to be_nil
      end
    end

    it 'lists the tables it removed and rewrote' do
      expect(result[:removed_tables]).to match_array(
        %w[fvar avar gvar cvar]
      )
      expect(result[:rewritten_tables]).to match_array(
        ['glyf', 'loca', 'hmtx', 'hhea', 'head', 'maxp', 'cvt ']
      )
      expect(result[:copied_tables]).to include('cmap', 'name', 'post')
    end

    it 'is a parseable TrueType font with the same glyph count' do
      font = open(result)
      expect(font.directory.scaler_type).to eq(0x00010000)
      expect(font.maximum_profile.num_glyphs).to eq(
        file.maximum_profile.num_glyphs
      )
    end

    it 'updates the head index-to-location format and bounding box' do
      font = open(result)
      base_id = glyph_ids(font)[:base]
      raw = font.glyph_outlines.for(base_id)
      expect([raw.x_min, raw.y_min, raw.x_max, raw.y_max]).to eq(
        [0, 0, 610, 710]
      )
    end
  end

  describe 'simple glyph interpolation' do
    it 'applies outline deltas at the heavy location' do
      font = open(instantiate('wght' => 900))
      outline = simple_outline(font, glyph_ids(font)[:base])
      expect(outline.coordinates_x).to eq([0, 610, 610, 0])
      expect(outline.coordinates_y).to eq([0, 0, 710, 710])
    end

    it 'interpolates omitted (IUP) points on a contour' do
      font = open(instantiate('wght' => 900))
      outline = simple_outline(font, glyph_ids(font)[:mark])
      # The middle point had no explicit delta; it follows the two
      # explicitly moved end points of the contour.
      expect(outline.coordinates_y).to eq([720, 720, 820])
      expect(outline.coordinates_x).to eq([200, 400, 300])
    end

    it 'rounds outline coordinates once (OpenType half-up rounding)' do
      # 650 -> normalized/avar 0.7: 700 + 0.7*20 = 714 exactly,
      # while a non-avar 0.5 would give 710. This locks in avar.
      font = open(instantiate('wght' => 650))
      outline = simple_outline(font, glyph_ids(font)[:base])
      expect(outline.coordinates_y).to eq([0, 0, 707, 707])
    end
  end

  describe 'phantom points and horizontal metrics' do
    it 'widens a simple glyph from its right phantom delta' do
      heavy = open(instantiate('wght' => 900))
      base_id = glyph_ids(heavy)[:base]
      expect(heavy.horizontal_metrics.for(base_id)).to have_attributes(
        advance_width: 700,
        left_side_bearing: 0
      )
    end

    it 'widens an empty glyph from a phantom-only delta' do
      heavy = open(instantiate('wght' => 900))
      space_id = glyph_ids(heavy)[:space]
      expect(heavy.horizontal_metrics.for(space_id)).to have_attributes(
        advance_width: 420,
        left_side_bearing: 0
      )
    end

    it 'leaves the default location metrics untouched' do
      default = open(instantiate('wght' => 400))
      space_id = glyph_ids(default)[:space]
      expect(default.horizontal_metrics.for(space_id)).to have_attributes(
        advance_width: 300,
        left_side_bearing: 0
      )
    end
  end

  describe 'composite glyphs' do
    it 'moves a component via its pseudo-point deltas' do
      heavy = open(instantiate('wght' => 900))
      id = glyph_ids(heavy)[:composite]
      outline = composite_outline(heavy, id)
      components = outline.components
      expect(components.map(&:glyph_index)).to eq([id - 1, 2])
      expect(components.map { |c| [c.arg1, c.arg2] }).to eq(
        [[0, 0], [80, -10]]
      )
    end

    it 'recomputes the composite bounding box from moved children' do
      heavy = open(instantiate('wght' => 900))
      id = glyph_ids(heavy)[:composite]
      glyph = heavy.glyph_outlines.for(id)
      expect([glyph.x_min, glyph.y_min, glyph.x_max, glyph.y_max]).to eq(
        [0, 0, 610, 810]
      )
    end

    it 'updates the composite advance width from phantom deltas' do
      heavy = open(instantiate('wght' => 900))
      id = glyph_ids(heavy)[:composite]
      expect(heavy.horizontal_metrics.for(id)).to have_attributes(
        advance_width: 670
      )
    end
  end

  describe 'unsupported variation tables' do
    it 'raises instead of silently dropping an HVAR table' do
      info = { tag: 'HVAR', checksum: 0, offset: 0, length: 1 }
      tables = file.directory.tables
      without_hvar = file.method(:directory_info)
      file.define_singleton_method(:directory_info) do |tag|
        tag == 'HVAR' ? info : without_hvar.call(tag)
      end

      expect { instantiate('wght' => 900) }.to raise_error(
        TTFunk::Error, /HVAR/
      )
    end
  end

  describe 'cvar control values' do
    it 'adds cvar deltas to the cvt table at the heavy location' do
      font = open(instantiate('wght' => 900))
      cvt = TTFunk::Table::Simple.new(font, 'cvt ').raw
      expect(cvt.unpack('s>*')).to eq([107, -43, 7, 207])
    end

    it 'leaves the cvt table untouched at the default location' do
      font = open(instantiate('wght' => 400))
      cvt = TTFunk::Table::Simple.new(font, 'cvt ').raw
      expect(cvt.unpack('s>*')).to eq([100, -50, 0, 200])
    end

    it 'removes cvar but keeps the rebuilt cvt table' do
      result = instantiate('wght' => 900)
      font = open(result)
      expect(result[:removed_tables]).to include('cvar')
      expect(font.directory_info('cvar')).to be_nil
      expect(font.directory_info('cvt ')).not_to be_nil
    end
  end

  describe 'non-variable fonts' do
    it 'raises a clear error when the font has no fvar table' do
      static = TTFunk::File.open(test_path('DejaVuSans.ttf'))
      expect {
        described_class.generate(static, 'wght' => 700)
      }.to raise_error(TTFunk::Error, /no fvar/i)
    end
  end
end
