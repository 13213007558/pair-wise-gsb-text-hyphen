# coding: utf-8

require "test/unit"
require "text-hyphen"
require "text/hyphen/trainer"

class TestTextHyphenTrainer < Test::Unit::TestCase
  WORDS = %w[
    go-ing do-ing see-ing be-ing leav-ing play-ing sing-ing read-ing
    walk-ing jump-ing talk-ing stand-ing un-do un-tie un-fold un-lock
    re-play re-fill re-new re-read through
  ].freeze

  OPTIONS = {
    left: 1,
    right: 1,
    budget: 100,
    seed: 42,
    validation_fraction: 0.25
  }.freeze

  def train(overrides = {}, words = WORDS)
    Text::Hyphen::Trainer.new(**OPTIONS, **overrides).train(words)
  end

  def test_training_learns_generalizing_patterns
    result = train
    assert_false result.patterns.empty?
    assert result.complete?, "expected a perfect fit, got:\n" + result.summary
    assert_equal 0, result.train_evaluation.false_breaks
    assert_equal 0, result.train_evaluation.missed_breaks
  end

  def test_evaluation_uses_the_real_matcher
    result = train
    hyphenator = result.hyphenator
    false_breaks = 0
    missed_breaks = 0
    result.train_words.each do |entry|
      actual = hyphenator.hyphenate(entry.word)
      false_breaks += (actual - entry.breaks).size
      missed_breaks += (entry.breaks - actual).size
    end
    assert_equal false_breaks, result.train_evaluation.false_breaks
    assert_equal missed_breaks, result.train_evaluation.missed_breaks
  end

  def test_patterns_load_into_a_plain_language
    result = train
    language = Text::Hyphen::Language.new do |lang|
      lang.patterns(result.pattern_text)
    end
    hyphenator = Text::Hyphen.new(left: 1, right: 1) do |h|
      h.language = language
    end
    result.train_words.each do |entry|
      assert_equal entry.breaks, hyphenator.hyphenate(entry.word), entry.word
    end
  end

  def test_reproducible_with_fixed_input_and_configuration
    first = train
    second = train
    assert_equal first.patterns, second.patterns
    assert_equal first.pattern_text, second.pattern_text
    assert_equal first.train_words, second.train_words
    assert_equal first.validation_words, second.validation_words
    assert_equal first.summary, second.summary
  end

  def test_validation_split_is_deterministic_and_disjoint
    result = train
    assert_equal 5, result.validation_words.size
    assert_equal 16, result.train_words.size
    train_words = result.train_words.map(&:word)
    validation_words = result.validation_words.map(&:word)
    assert_empty train_words & validation_words
    assert_equal validation_words, train.validation_words.map(&:word)
    assert_not_nil result.validation_evaluation
  end

  def test_validation_can_be_disabled
    result = train(validation_fraction: 0)
    assert_equal 21, result.train_words.size
    assert_empty result.validation_words
    assert_nil result.validation_evaluation
  end

  def test_budget_exhaustion_returns_patterns_and_counterexamples
    result = train(budget: 1)
    assert_equal 1, result.patterns.size
    assert_false result.complete?
    unresolved = result.train_evaluation.unresolved
    assert_false unresolved.empty?
    unresolved.each do |word, miss|
      assert miss[:expected].is_a?(Array)
      assert miss[:actual].is_a?(Array)
      assert_false miss[:expected] == miss[:actual]
    end
    assert_match(/unresolved counterexample/, result.summary)
  end

  def test_size_comparison_against_word_exceptions
    result = train
    comparison = result.size_comparison
    assert_equal result.patterns.size, comparison[:patterns]
    assert_equal result.train_words.size, comparison[:exceptions]
    assert_operator comparison[:patterns], :<, comparison[:exceptions]
    assert_equal result.pattern_text.bytesize, comparison[:pattern_bytes]
    assert_operator comparison[:exception_bytes], :>, 0
  end

  def test_false_break_cost_is_respected
    result = train(false_break_cost: 100)
    assert_equal 0, result.train_evaluation.false_breaks
  end

  def test_missed_break_cost_is_respected
    result = train(missed_break_cost: 100)
    assert_equal 0, result.train_evaluation.missed_breaks
  end

  def test_break_violating_minima_is_rejected
    trainer = Text::Hyphen::Trainer.new(left: 2, right: 2)
    assert_raise(ArgumentError) { trainer.train(%w[go-ing]) }
  end

  def test_malformed_annotations_are_rejected
    trainer = Text::Hyphen::Trainer.new(left: 1, right: 1)
    assert_raise(ArgumentError) { trainer.train(["-going"]) }
    assert_raise(ArgumentError) { trainer.train(["going-"]) }
    assert_raise(ArgumentError) { trainer.train(["go--ing"]) }
    assert_raise(ArgumentError) { trainer.train([]) }
    assert_raise(ArgumentError) { trainer.train(%w[go-ing goi-ng]) }
  end

  def test_bundled_language_data_is_not_modified
    require "text/hyphen/language/en_us"
    before = Text::Hyphen::Language::EN_US.hyphen.dup
    train
    assert_equal before, Text::Hyphen::Language::EN_US.hyphen
  end
end

