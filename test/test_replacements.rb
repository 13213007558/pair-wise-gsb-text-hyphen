# -*- encoding: utf-8 -*-

require "test/unit"
require "text-hyphen"
require "text/hyphen/language"

class TestTextHyphenReplacements < Test::Unit::TestCase
  def replacement_language
    Text::Hyphen::Language.new do |lang|
      lang.left = 0
      lang.right = 0
      lang.patterns [
        "ab1cx=ab/bx ab1cy=ab/by b1cye=b/y",
        {
          :pattern => "ab3cx0",
          :start => 0,
          :finish => 4,
          :break => 2,
          :left => "ax",
          :right => "bc"
        }
      ]
      lang.exceptions [{
        "abcyx" => {
          :breaks => [2],
          :replacements => {
            2 => { :start => 1, :finish => 3, :left => "X", :right => "Y" }
          }
        }
      }]
    end
  end

  def replacement_hyphen
    Text::Hyphen.new(:left => 0, :right => 0) { |hyphen| hyphen.language = replacement_language }
  end

  def test_higher_weighted_rule_supplies_its_own_replacement
    hyphen = replacement_hyphen

    assert_equal [2], hyphen.hyphenate("abcxe")

    candidate = hyphen.hyphenate_candidates("abcxe").first
    assert_equal 2, candidate.position
    assert_equal 0, candidate.start
    assert_equal 4, candidate.finish
    assert_equal "ax", candidate.left
    assert_equal "bc", candidate.right
    assert_equal ["ax-", "bce"], hyphen.hyphenate_to_with_replacements("abcxe", 10)
  end

  def test_replacement_preserves_original_case_outside_source_interval
    hyphen = replacement_hyphen

    assert_equal ["Ax-", "bce"], hyphen.hyphenate_to_with_replacements("ABcxe", 10)
  end

  def test_exception_replacement_overrides_patterns
    hyphen = Text::Hyphen.new(:left => 3, :right => 3) { |item| item.language = replacement_language }

    candidate = hyphen.hyphenate_candidates("abcyx").first
    assert_equal 2, candidate.position
    assert_equal 1, candidate.start
    assert_equal 3, candidate.finish
    assert_equal "X", candidate.left
    assert_equal "Y", candidate.right
    assert_equal ["aX-", "Yyx"], hyphen.hyphenate_to_with_replacements("abcyx", 10)
  end

  def test_equal_weighted_overlapping_replacements_are_diagnosed
    hyphen = replacement_hyphen
    candidate = hyphen.hyphenate_candidates("abcye").find { |item| item.diagnostic }

    refute candidate.supported?
    assert_match(/overlapping replacement rules/, candidate.diagnostic)
    assert_equal 1, hyphen.hyphenation_diagnostics("abcye").length
    assert_raise(RuntimeError) { candidate.parts("abcye") }
  end

  def test_rules_with_equal_pattern_text_do_not_overwrite_each_other
    language = Text::Hyphen::Language.new do |lang|
      lang.left = 0
      lang.right = 0
      lang.patterns "abc1x=a/z abc1x=y/b"
    end
    hyphen = Text::Hyphen.new(:left => 0, :right => 0) { |item| item.language = language }
    candidate = hyphen.hyphenate_candidates("abcxe").first

    refute candidate.supported?
    assert_match(/overlapping replacement rules/, candidate.diagnostic)
  end

  def test_replacement_crossing_grapheme_cluster_is_diagnosed
    language = Text::Hyphen::Language.new do |lang|
      lang.left = 0
      lang.right = 0
      lang.patterns [{
        :pattern => "i\u03071x",
        :start => 1,
        :finish => 3,
        :break => 2,
        :left => "a",
        :right => "b"
      }]
    end
    hyphen = Text::Hyphen.new(:left => 0, :right => 0) { |item| item.language = language }
    word = "\u0130x"
    candidate = hyphen.hyphenate_candidates(word).first

    refute candidate.supported?
    assert_match(/grapheme cluster/, candidate.diagnostic)
  end

  def test_legacy_interfaces_do_not_apply_replacements
    hyphen = replacement_hyphen

    assert_equal ["ab-", "cxe"], hyphen.hyphenate_to("abcxe", 10)
    assert_equal "ab-cxe", hyphen.visualize("abcxe")
  end
end
