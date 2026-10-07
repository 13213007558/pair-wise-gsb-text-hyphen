# coding: utf-8

require "test/unit"
require "text/hyphen/trainer"

class TestTrainer < Test::Unit::TestCase
  WORDS = %w[
    re-play-ing re-play-ed re-play-ful play-ing play-ful play-ed
    un-play-ing un-play-able re-do-ing un-do-ing do-ing go-ing re-make
    un-made re-order makes bakes
  ]

  def trainer(options = {})
    Text::Hyphen::Trainer.new({left: 1, right: 1, validation: 0}.merge(options))
  end

  def reload_matcher(result)
    language = Text::Hyphen::Language.new
    language.patterns(result.pattern_text)
    Text::Hyphen.new(left: 1, right: 1) { |hyphen| hyphen.language = language }
  end

  def test_trains_compact_patterns_loadable_by_the_matcher
    result = trainer.train(WORDS)
    assert_equal(WORDS.length, result.train_evaluation.total)
    assert(result.train_evaluation.error_free?)
    assert(result.patterns.length < WORDS.length)

    reloaded = reload_matcher(result)
    WORDS.each do |annotated|
      word = annotated.delete("-")
      assert_equal(result.hyphenator.hyphenate(word), reloaded.hyphenate(word), word)
    end
  end

  def test_evaluation_comes_from_the_real_matcher
    result = trainer(budget: 1).train(WORDS)
    assert_kind_of(Text::Hyphen, result.hyphenator)
    assert(!result.unresolved.empty?)
    result.unresolved.each do |error|
      assert_equal(error[:actual], result.hyphenator.hyphenate(error[:word]))
    end
  end

  def test_output_is_reproducible
    first = trainer(validation: 0.25).train(WORDS)
    second = trainer(validation: 0.25).train(WORDS)
    assert_equal(first.pattern_text, second.pattern_text)
    assert_equal(first.report, second.report)
  end

  def test_budget_exhaustion_returns_partial_patterns_and_counterexamples
    result = trainer(budget: 1).train(WORDS)
    assert(result.budget_exhausted?)
    assert_equal(1, result.patterns.length)
    assert(!result.train_evaluation.error_free?)
    assert(!result.unresolved.empty?)
    assert_no_match(/All evaluated words hyphenate as annotated/, result.report)
  end

  def test_pattern_stats_record_fixed_and_broken_counts
    result = trainer.train(WORDS)
    assert_equal(result.patterns.length, result.pattern_stats.length)
    result.pattern_stats.each do |stat|
      assert(stat[:fixed] > 0)
      assert(stat[:broken] >= 0)
      assert(stat[:gain] > 0)
      assert(stat[:level] >= 1)
    end
  end

  def test_allow_and_forbid_levels
    words = ["ta-pa", "ta-pe", "ta-pi", "ta-po", "ta-pu", "tapir"]
    result = trainer(max_pattern_length: 3).train(words)
    assert_equal(2, result.levels_used)
    assert(result.pattern_stats.any? { |stat| stat[:level].odd? })
    assert(result.pattern_stats.any? { |stat| stat[:level].even? })
    assert(result.pattern_stats.any? { |stat| stat[:broken] > 0 })
    assert(result.train_evaluation.error_free?)
    assert_equal([], result.hyphenator.hyphenate("tapir"))
  end

  def test_miss_and_false_costs_steer_candidate_choice
    words = ["ta-per", "tape-rs"]
    options = {max_pattern_length: 3}
    miss_expensive = trainer(options.merge(miss_cost: 10, false_cost: 1)).train(words)
    false_expensive = trainer(options.merge(miss_cost: 1, false_cost: 10)).train(words)

    assert_not_equal(miss_expensive.pattern_text, false_expensive.pattern_text)
    assert_equal(0, false_expensive.train_evaluation.false_breaks)
    assert(false_expensive.train_evaluation.missed_breaks > 0)
    assert_equal(0, miss_expensive.train_evaluation.missed_breaks)
    assert(miss_expensive.train_evaluation.false_breaks > 0)
  end

  def test_validation_holdout
    result = trainer(validation: 0.25).train(WORDS)
    total = result.train_evaluation.total + result.validation_evaluation.total
    assert_equal(WORDS.length, total)
    assert(result.validation_evaluation.total > 0)
    assert(result.validation_evaluation.total < WORDS.length)
  end

  def test_size_comparison_against_exceptions
    result = trainer.train(WORDS)
    size = result.size_comparison
    assert_equal(result.patterns.length, size[:patterns][:count])
    assert_equal(WORDS.length, size[:exceptions][:count])
    assert(size[:patterns][:characters] < size[:exceptions][:characters])
    assert_equal(result.unresolved.length, size[:remaining_exceptions][:count])
  end

  def test_points_outside_left_right_are_dropped
    result = Text::Hyphen::Trainer.new(left: 2, right: 2, validation: 0).train(["re-make"])
    assert_equal([], result.hyphenator.hyphenate("remake"))
    assert_equal(1, result.train_evaluation.total)
  end

  def test_bundled_language_data_is_untouched
    before = Text::Hyphen::Language.constants.sort
    result = trainer.train(WORDS)
    assert_equal(before, Text::Hyphen::Language.constants.sort)
    assert_kind_of(Text::Hyphen::Language, result.language)
  end

  def test_invalid_options_raise
    assert_raise(ArgumentError) { Text::Hyphen::Trainer.new(budget: -1) }
    assert_raise(ArgumentError) { Text::Hyphen::Trainer.new(max_levels: 10) }
    assert_raise(ArgumentError) { Text::Hyphen::Trainer.new(miss_cost: 0) }
    assert_raise(ArgumentError) { Text::Hyphen::Trainer.new(false_cost: 0) }
    assert_raise(ArgumentError) { Text::Hyphen::Trainer.new(validation: 1.5) }
  end
end

