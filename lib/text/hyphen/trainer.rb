# -*- ruby encoding: utf-8 -*-
require "text/hyphen"
require "text/hyphen/language"

class Text::Hyphen
  # Trains TeX-style hyphenation patterns offline from an annotated word
  # list, producing pattern text that can be loaded directly by
  # Text::Hyphen::Language#patterns instead of maintaining one exception
  # per word.
  #
  # The input is a list of words with their allowed hyphenation points
  # marked with a hyphen:
  #
  #   words = %w[re-play-ing re-play-ed play-ful un-do-ing makes]
  #   trainer = Text::Hyphen::Trainer.new(left: 1, right: 1, budget: 50)
  #   result = trainer.train(words)
  #   puts result.pattern_text
  #
  # Training proceeds in levels, following Liang's algorithm as used by
  # patgen: odd levels add patterns that *allow* breaks, even levels add
  # patterns that *forbid* breaks. Each candidate is a character fragment
  # (optionally anchored to a word edge with ".") plus the position of its
  # weight. For every candidate the trainer counts how many currently
  # wrong decisions it would fix and how many currently right decisions
  # it would break; the cost of a missed break (annotation not produced)
  # and of a false break (break not annotated) are configured
  # independently with +:miss_cost+ and +:false_cost+.
  #
  # Training is fully offline: it never touches the network and never
  # modifies the language data shipped with the library. The trained
  # patterns are evaluated through a real Text::Hyphen matcher, not
  # through the trainer's internal bookkeeping, and with a fixed input
  # and configuration the output is reproducible. When the pattern
  # budget is exhausted the result still contains everything learned so
  # far plus the list of unresolved counterexamples.
  #
  # Note that Text::Hyphen can only produce a break at position +p+ of a
  # word of length +n+ when <tt>left < p < n - right</tt>; annotated
  # points outside that range are dropped from the gold standard.
  class Trainer
    DEFAULT_LEFT = 2
    DEFAULT_RIGHT = 2
    DEFAULT_BUDGET = 100
    DEFAULT_MAX_LEVELS = 5
    DEFAULT_MAX_PATTERN_LENGTH = 6
    DEFAULT_VALIDATION_FRACTION = 0.2
    DEFAULT_SEED = 4157

    # The minimum number of letters that must appear to the left of a
    # hyphenation point, as understood by Text::Hyphen.
    attr_reader :left

    # The minimum number of letters that must appear to the right of a
    # hyphenation point, as understood by Text::Hyphen.
    attr_reader :right

    # The maximum number of patterns the trainer may select.
    attr_reader :budget

    # The maximum pattern level (weight) used during training. Odd levels
    # allow breaks, even levels forbid them. At most 9, because pattern
    # weights are single digits.
    attr_reader :max_levels

    # The maximum length (in characters, including word-edge dots) of a
    # candidate pattern.
    attr_reader :max_pattern_length

    # The cost of a missed break (an annotated point the patterns fail to
    # produce).
    attr_reader :miss_cost

    # The cost of a false break (a produced point that is not annotated).
    attr_reader :false_cost

    # The fraction of the word list held out for validation (0 disables
    # the holdout).
    attr_reader :validation_fraction

    # The seed for the deterministic holdout shuffle.
    attr_reader :seed

    def initialize(options = {})
      @left = options.fetch(:left, DEFAULT_LEFT)
      @right = options.fetch(:right, DEFAULT_RIGHT)
      @budget = options.fetch(:budget, DEFAULT_BUDGET)
      @max_levels = options.fetch(:max_levels, DEFAULT_MAX_LEVELS)
      @max_pattern_length = options.fetch(:max_pattern_length, DEFAULT_MAX_PATTERN_LENGTH)
      @miss_cost = options.fetch(:miss_cost, 1)
      @false_cost = options.fetch(:false_cost, 1)
      @validation_fraction = options.fetch(:validation, DEFAULT_VALIDATION_FRACTION)
      @seed = options.fetch(:seed, DEFAULT_SEED)
      validate_options!
    end

    # Trains patterns from +annotated_words+ (strings such as
    # "rep-re-sen-ta-tion") and returns a Trainer::Result.
    def train(annotated_words)
      words = parse_words(annotated_words)
      train_words, validation_words = split_holdout(words)
      selected = select_patterns(train_words)
      build_result(selected, train_words, validation_words)
    end

    # A word with its gold hyphenation points and the running weight
    # vector used during training.
    class Word
      attr_reader :text, :points, :padded
      attr_accessor :weights

      def initialize(text, points)
        @text = text
        @points = points
        @padded = ".#{text}."
        @weights = [0] * (text.length + 1)
      end
    end

    # A selected pattern: a tag (letters plus optional word-edge dots),
    # the gap at which its weight sits, and the counts of errors it fixed
    # and introduced when it was selected.
    class Candidate
      attr_reader :tag, :gap, :level, :fixed, :broken, :gain

      def initialize(tag, gap, level, fixed, broken, gain)
        @tag = tag
        @gap = gap
        @level = level
        @fixed = fixed
        @broken = broken
        @gain = gain
      end

      # The TeX pattern form, e.g. ".re1" or "1ing.".
      def text
        @text ||= @tag.dup.insert(@gap, @level.to_s)
      end
    end

    # The evaluation of a pattern set against a word list, computed with
    # a real Text::Hyphen matcher.
    class Evaluation
      attr_reader :total, :errors, :missed_breaks, :false_breaks

      def initialize(total, errors, missed_breaks, false_breaks)
        @total = total
        @errors = errors
        @missed_breaks = missed_breaks
        @false_breaks = false_breaks
      end

      def correct
        @total - @errors.length
      end

      def error_free?
        @errors.empty?
      end
    end

    # The outcome of a training run.
    class Result
      attr_reader :patterns, :pattern_text, :language, :hyphenator,
        :train_evaluation, :validation_evaluation, :unresolved,
        :pattern_stats, :size_comparison, :levels_used, :budget

      def initialize(attributes)
        @patterns = attributes[:patterns]
        @pattern_text = attributes[:pattern_text]
        @language = attributes[:language]
        @hyphenator = attributes[:hyphenator]
        @train_evaluation = attributes[:train_evaluation]
        @validation_evaluation = attributes[:validation_evaluation]
        @unresolved = attributes[:unresolved]
        @pattern_stats = attributes[:pattern_stats]
        @size_comparison = attributes[:size_comparison]
        @levels_used = attributes[:levels_used]
        @budget = attributes[:budget]
      end

      def budget_exhausted?
        @patterns.length >= @budget
      end

      def report
        lines = []
        lines << format("Trained %d pattern(s) over %d level(s); budget %d %s.",
          patterns.length, levels_used, budget,
          budget_exhausted? ? "exhausted" : "not exhausted")
        lines << evaluation_line("Train", train_evaluation)
        if validation_evaluation.total > 0
          lines << evaluation_line("Validation", validation_evaluation)
        end
        if unresolved.empty?
          lines << "All evaluated words hyphenate as annotated."
        else
          lines << format("%d unresolved counterexample(s):", unresolved.length)
          unresolved.each do |error|
            lines << format("  %s (%s): expected %s, got %s",
              error[:word], error[:set],
              error[:expected].inspect, error[:actual].inspect)
          end
        end
        size = size_comparison
        lines << format(
          "Size: %d pattern(s) / %d char(s) vs %d exception(s) / %d char(s); " \
          "%d remaining exception(s) / %d char(s).",
          size[:patterns][:count], size[:patterns][:characters],
          size[:exceptions][:count], size[:exceptions][:characters],
          size[:remaining_exceptions][:count],
          size[:remaining_exceptions][:characters]
        )
        lines.join("\n")
      end

      private

      def evaluation_line(label, evaluation)
        format("%s: %d/%d word(s) correct, %d missed break(s), %d false break(s).",
          label, evaluation.correct, evaluation.total,
          evaluation.missed_breaks, evaluation.false_breaks)
      end
    end

    private

    def validate_options!
      raise ArgumentError, "left must be >= 0" if left < 0
      raise ArgumentError, "right must be >= 0" if right < 0
      raise ArgumentError, "budget must be >= 0" if budget < 0
      unless (1..9).cover?(max_levels)
        raise ArgumentError, "max_levels must be between 1 and 9"
      end
      if max_pattern_length < 2
        raise ArgumentError, "max_pattern_length must be >= 2"
      end
      raise ArgumentError, "miss_cost must be > 0" if miss_cost <= 0
      raise ArgumentError, "false_cost must be > 0" if false_cost <= 0
      unless (0...1).cover?(validation_fraction)
        raise ArgumentError, "validation must be in [0, 1)"
      end
    end

    def parse_words(annotated_words)
      seen = {}
      annotated_words.map { |entry| parse_word(entry) }
        .compact
        .reject { |word| seen[word.text] ? true : (seen[word.text] = true; false) }
        .sort_by { |word| word.text }
    end

    def parse_word(entry)
      annotated = entry.to_s.downcase.strip
      return nil if annotated.empty?

      text = annotated.delete("-")
      return nil if text.empty?

      points = []
      index = 0
      annotated.each_char do |char|
        if char == "-"
          points << index
        else
          index += 1
        end
      end
      feasible = points.select { |point| feasible_point?(point, text.length) }
      Word.new(text, feasible.sort.uniq)
    end

    # Mirrors the matcher exactly: Text::Hyphen#hyphenate zeroes positions
    # 0..left and the last right + 1 positions, so a break at +point+ of a
    # word of +length+ can only be produced when
    # left < point < length - right.
    def feasible_point?(point, length)
      point > left && point < length - right
    end

    def split_holdout(words)
      return [words, []] if validation_fraction <= 0 || words.length < 2

      shuffled = words.shuffle(random: Random.new(seed))
      count = (words.length * validation_fraction).floor
      count = words.length - 1 if count >= words.length
      validation = shuffled.first(count).sort_by { |word| word.text }
      train = shuffled.drop(count).sort_by { |word| word.text }
      [train, validation]
    end

    def select_patterns(words)
      selected = []
      remaining = budget
      (1..max_levels).each do |level|
        while remaining > 0
          best = best_candidate(words, level)
          break if best.nil?
          apply_candidate(words, best)
          selected << best
          remaining -= 1
        end
        break if remaining <= 0
      end
      selected
    end

    # Counts, for every candidate at this level, how many currently wrong
    # decisions it fixes and how many currently right decisions it breaks,
    # then returns the candidate with the best gain. Ties are resolved by
    # candidate key so the result is reproducible.
    def best_candidate(words, level)
      allow = level.odd?
      fixed = Hash.new(0)
      broken = Hash.new(0)

      words.each do |word|
        each_relevant_point(word, allow) do |point, correct|
          each_candidate_at(word, point) do |tag, gap|
            key = [tag, gap]
            if correct
              broken[key] += 1
            else
              fixed[key] += 1
            end
          end
        end
      end

      fix_cost, break_cost = allow ? [miss_cost, false_cost] : [false_cost, miss_cost]

      best = nil
      best_gain = 0
      fixed.keys.sort.each do |key|
        gain = (fixed[key] * fix_cost) - (broken[key] * break_cost)
        next if gain <= best_gain
        best_gain = gain
        best = key
      end
      return nil if best.nil?

      Candidate.new(best[0], best[1], level, fixed[best], broken[best], best_gain)
    end

    # Yields each point where a pattern of this level's parity would flip
    # the current decision, along with whether the current decision is
    # correct.
    def each_relevant_point(word, allow)
      last = word.text.length - right - 1
      return if last <= left

      ((left + 1)..last).each do |point|
        decision = word.weights[point].odd?
        next if decision == allow
        gold = word.points.include?(point)
        yield point, decision == gold
      end
    end

    # Yields every candidate (tag, gap) whose weight would land on
    # +point+ of +word+. Tags are fragments of the dot-padded word, so
    # they may carry word-edge dots.
    def each_candidate_at(word, point)
      padded = word.padded
      target = point + 1
      2.upto(max_pattern_length) do |size|
        first_offset = target - size
        first_offset = 0 if first_offset < 0
        last_offset = target
        last_offset = padded.length - size if last_offset > padded.length - size
        first_offset.upto(last_offset) do |offset|
          tag = padded[offset, size]
          next unless tag =~ /[^.]/
          yield tag, target - offset
        end
      end
    end

    def apply_candidate(words, candidate)
      words.each do |word|
        offset = 0
        while (found = word.padded.index(candidate.tag, offset))
          point = found + candidate.gap - 1
          if point >= 0 && point <= word.text.length &&
              word.weights[point] < candidate.level
            word.weights[point] = candidate.level
          end
          offset = found + 1
        end
      end
    end

    def build_result(selected, train_words, validation_words)
      pattern_text = selected.map { |candidate| candidate.text }.join(" ")

      language = Text::Hyphen::Language.new
      language.left = left
      language.right = right
      language.patterns(pattern_text)
      hyphenator = Text::Hyphen.new(left: left, right: right) do |hyphen|
        hyphen.language = language
      end

      train_evaluation = evaluate(hyphenator, train_words)
      validation_evaluation = evaluate(hyphenator, validation_words)

      unresolved = []
      train_evaluation.errors.each { |error| unresolved << error.merge(set: :train) }
      validation_evaluation.errors.each { |error| unresolved << error.merge(set: :validation) }

      all_words = train_words + validation_words
      exception_text = all_words.map { |word| annotate(word) }.join(" ")
      remaining_text = unresolved.map { |error| error[:annotated] }.join(" ")

      Result.new(
        patterns: selected.map { |candidate| candidate.text },
        pattern_text: pattern_text,
        language: language,
        hyphenator: hyphenator,
        train_evaluation: train_evaluation,
        validation_evaluation: validation_evaluation,
        unresolved: unresolved,
        pattern_stats: selected.map { |candidate|
          {
            pattern: candidate.text,
            level: candidate.level,
            fixed: candidate.fixed,
            broken: candidate.broken,
            gain: candidate.gain
          }
        },
        size_comparison: {
          patterns: {
            count: selected.length,
            characters: pattern_text.delete(" ").length
          },
          exceptions: {
            count: all_words.length,
            characters: exception_text.delete(" ").length
          },
          remaining_exceptions: {
            count: unresolved.length,
            characters: remaining_text.delete(" ").length
          }
        },
        levels_used: selected.map { |candidate| candidate.level }.max || 0,
        budget: budget
      )
    end

    # Evaluates the trained patterns with a real Text::Hyphen matcher
    # rather than the trainer's internal weight vectors.
    def evaluate(hyphenator, words)
      errors = []
      missed = 0
      false_breaks = 0
      words.each do |word|
        actual = hyphenator.hyphenate(word.text)
        next if actual == word.points
        missed += (word.points - actual).length
        false_breaks += (actual - word.points).length
        errors << {
          word: word.text,
          annotated: annotate(word),
          expected: word.points,
          actual: actual
        }
      end
      Evaluation.new(words.length, errors, missed, false_breaks)
    end

    def annotate(word)
      annotated = word.text.dup
      word.points.reverse_each { |point| annotated.insert(point, "-") }
      annotated
    end
  end
end

