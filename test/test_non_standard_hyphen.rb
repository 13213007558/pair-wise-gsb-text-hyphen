# coding: utf-8 -

require "test/unit"
require "text-hyphen"
require "text/hyphen/language"

class TestNonStandardHyphen < Test::Unit::TestCase
  def test_replacement_follow_winning_pattern_at_each_break
    hyphenator = hyphenator("a1b3c1d0e/abc/A/B a0b1c3d1e/bcd/X/Y")
    result = hyphenator.hyphenation("abcde")

    assert_equal [1, 2, 3, 4], result.points
    assert_equal [0, 3], interval(result, 2)
    assert_equal ["A-", "Bde"], result.split(2)
    assert_equal [1, 4], interval(result, 3)
    assert_equal ["aX-", "Ye"], result.split(3)
    assert_equal ["aX-", "Ye"], result.split(4)
    assert_equal [1, 2, 3, 4], hyphenator.hyphenate("abcde")
  end

  def test_exception_replacement_takes_priority
    hyphenator = hyphenator("a1b5c0d3e/abc/A/B", "ab-cde/ABB/zzde")
    result = hyphenator.hyphenation("abcde")

    assert_equal [2], result.points
    assert_equal ["ABB-", "zzde"], result.split(2)
    assert_equal ["ABB-", "zzde"], hyphenator.hyphenate_to("abcde", 5)
  end

  def test_candidate_split_uses_rule_word_form_not_original_substring
    hyphenator = hyphenator("a0b3c0d0e/abc/A/B")
    result = hyphenator.hyphenation("abcee")

    assert_equal [2], result.points
    assert_equal [0, 3], interval(result, 2)
    assert_equal ["A-", "Bee"], result.split(2)
  end

  def test_positions_and_minimum_lengths_use_original_word
    hyphenator = hyphenator("a0b0c0d3e0f0g/abcdefg/a/b", nil, 3, 2)
    result = hyphenator.hyphenation("Abcdefg")

    assert_equal [4], result.points
    assert_equal [0, 7], interval(result, 4)
    assert_equal ["A-", "b"], result.split(4)
  end

  def test_tied_overlapping_replacements_are_diagnosed
    warnings = []
    language = with_warnings(warnings) do
      Text::Hyphen::Language.new do |lang|
        lang.patterns "a0b1c3/abc/A/B 0b1c3/bc/X/Y"
        lang.left = 1
        lang.right = 0
      end
    end
    hyphenator = Text::Hyphen.new do |h|
      h.language = language
      h.left = 1
      h.right = 0
    end
    result = hyphenator.hyphenation("abc")

    assert_equal [2], result.points
    assert_equal ["ab-", "c"], result.split(2)
    assert_match(/overlapping non-standard replacement/, result.diagnostics.join)
  end

  def test_cross_grapheme_replacement_is_diagnosed
    warnings = []
    language = with_warnings(warnings) do
      Text::Hyphen::Language.new do |lang|
        lang.patterns "e1\u03012a/\u00e9/A/B"
        lang.left = 0
        lang.right = 0
      end
    end

    assert_match(/crosses a grapheme boundary/, language.diagnostics.join)
    assert_match(/crosses a grapheme boundary/, warnings.join)
  end

  private

  def interval(result, position)
    candidate = result.candidate_at(position)
    [candidate.replacement_start, candidate.replacement_end]
  end

  def hyphenator(patterns, exceptions = nil, left = 0, right = 0)
    language = Text::Hyphen::Language.new do |lang|
      lang.patterns patterns
      lang.exceptions exceptions if exceptions
      lang.left = left
      lang.right = right
    end

    Text::Hyphen.new do |h|
      h.language = language
      h.left = left
      h.right = right
    end
  end

  def with_warnings(warnings)
    language_class = Text::Hyphen::Language
    language_class.send(:define_method, :warn) { |message| warnings << message }
    yield
  ensure
    language_class.send(:remove_method, :warn)
  end
end
