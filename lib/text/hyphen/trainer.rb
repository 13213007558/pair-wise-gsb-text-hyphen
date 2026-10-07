# -*- ruby encoding: utf-8 -*-

require "text/hyphen"
require "text/hyphen/language"

# An offline trainer that learns TeX-style hyphenation patterns from an
# annotated domain word list. The learned patterns can be loaded directly
# into Text::Hyphen (through a Text::Hyphen::Language instance) instead of
# adding one exception per word.
#
# The trainer works entirely offline: it never touches the network and it
# never modifies the language pattern data shipped with the library. The
# learned patterns live in a fresh Text::Hyphen::Language instance.
#
# Training follows the layered idea of Frank Liang's patgen: candidate
# patterns are character fragments (optionally anchored to word boundaries)
# carrying a level (weight). Odd levels vote for a break, even levels vote
# against one, and higher levels override lower ones. Candidates are added
# layer by layer; for every candidate the trainer counts how many errors it
# corrects and how many it introduces, where false breaks and missed breaks
# carry independently configurable costs.
#
# The final report is always produced by re-evaluating the learned patterns
# with the real Text::Hyphen matcher, not with the trainer's internal
# counters. With a fixed word list and fixed configuration the output is
# fully reproducible. When the pattern budget runs out before all words are
# hyphenated correctly, the result contains the patterns learned so far
# plus the unresolved counterexamples; it never claims zero errors.
#
#   trainer = Text::Hyphen::Trainer.new(left: 1, right: 1, budget: 50)
#   result = trainer.train(%w[go-ing leav-ing play-ing re-play un-do])
#   puts result.summary
#   hh = result.hyphenator
#   hh.visualize("leaving") #=> "leav-ing"
class Text::Hyphen::Trainer
  # The default number of pattern levels (weights) trained, as in TeX.
  DEFAULT_LEVELS = 5
  # The default training budget: the maximum number of patterns learned.
  DEFAULT_BUDGET = 100
  # The default maximum number of letters in a candidate pattern.
  DEFAULT_MAX_PATTERN_LENGTH = 6
  # The default fraction of words held out for validation.
  DEFAULT_VALIDATION_FRACTION = 0.25

  # A word with its allowed break positions.
  AnnotatedWord = Struct.new(:word, :breaks)

  # The evaluation of a pattern set against a word list, always computed
  # with the real Text::Hyphen matcher.
  Evaluation = Struct.new(:word_count, :perfect, :false_breaks, :missed_breaks, :unresolved) do
    # The total number of wrong break positions.
    def error_count
      false_breaks + missed_breaks
    end

    # True when every word was hyphenated exactly as annotated.
    def perfect?
      false_breaks.zero? && missed_breaks.zero?
    end
  end

  # The outcome of a training run. Contains the learned patterns, the
  # train/validation split, the matcher-verified evaluations, and the
  # unresolved counterexamples (if any).
  class Result
    # The learned patterns, in selection order, in the same textual
    # format used by Text::Hyphen::Language#patterns (for example
    # "re3p", ".un1", "ing2.").
    attr_reader :patterns

    # The AnnotatedWord entries used for training.
    attr_reader :train_words

    # The AnnotatedWord entries held out for validation.
    attr_reader :validation_words

    # Evaluation of the learned patterns on the training words, computed
    # with the real Text::Hyphen matcher.
    attr_reader :train_evaluation


    # Evaluation of the learned patterns on the held-out words, computed
    # with the real Text::Hyphen matcher. Nil when no words were
    # held out.
    attr_reader :validation_evaluation

    # The configuration the trainer ran with.
    attr_reader :left, :right, :budget

    def initialize(options) # :nodoc:
      @patterns = options.fetch(:patterns)
      @train_words = options.fetch(:train_words)
      @validation_words = options.fetch(:validation_words)
      @train_evaluation = options.fetch(:train_evaluation)
      @validation_evaluation = options[:validation_evaluation]
      @left = options.fetch(:left)
      @right = options.fetch(:right)
      @budget = options.fetch(:budget)
    end

    # True when the learned patterns reproduce every training word
    # exactly. When false, the training budget (or the pattern levels)
    # was exhausted before all counterexamples could be resolved; see
    # #train_evaluation for the remaining errors.
    def complete?
      train_evaluation.perfect?
    end

    # The learned patterns as pattern text that can be fed directly to
    # Text::Hyphen::Language#patterns.
    def pattern_text
      lines = [+""]
      @patterns.each do |pattern|
        if lines[-1].size + pattern.size + 1 > 72
          lines << pattern
        else
          lines[-1] << " " unless lines[-1].empty?
          lines[-1] << pattern
        end
      end
      lines.join("\n")
    end

    # A Text::Hyphen::Language instance holding only the learned
    # patterns. It is independent of the language data shipped with the
    # library, which is never modified.
    def language
      @language ||= Text::Hyphen::Language.new do |lang|
        lang.left = @left
        lang.right = @right
        lang.patterns(pattern_text)
      end
    end

    # A Text::Hyphen matcher ready to hyphenate with the learned
    # patterns.
    def hyphenator
      @hyphenator ||= Text::Hyphen.new(left: @left, right: @right) do |h|
        h.language = language
      end
    end

    # Compares the size of the compact pattern set with the size of the
    # equivalent per-word exception list (one exception per training
    # word).
    def size_comparison
      exceptions = @train_words.map { |entry| self.class.annotate(entry) }
      {
        patterns: @patterns.size,
        exceptions: exceptions.size,
        pattern_bytes: pattern_text.bytesize,
        exception_bytes: exceptions.join(" ").bytesize
      }
    end

    # Rebuilds the annotated form of an AnnotatedWord, for example
    # "rep-re-sen-ta-tion".
    def self.annotate(entry)
      return entry.word if entry.breaks.empty?
      parts = []
      cursor = 0
      entry.breaks.each do |point|
        parts << entry.word[cursor...point]
        cursor = point
      end
      parts << entry.word[cursor..-1]
      parts.join("-")
    end

    # A human-readable summary of the training run.
    def summary
      out = []
      out << "Text::Hyphen::Trainer training summary"
      out << "  words: #{@train_words.size + @validation_words.size} " \
        "(train: #{@train_words.size}, validation: #{@validation_words.size})"
      out << "  left/right: #{@left}/#{@right}, budget: #{@budget} " \
        "(patterns learned: #{@patterns.size})"
      out << "  train: #{evaluation_line(@train_evaluation)}"
      if @validation_evaluation
        out << "  validation: #{evaluation_line(@validation_evaluation)}"
      end
      comparison = size_comparison
      out << "  size: #{comparison[:patterns]} patterns " \
        "(#{comparison[:pattern_bytes]} bytes) vs " \
        "#{comparison[:exceptions]} word exceptions " \
        "(#{comparison[:exception_bytes]} bytes)"
      unless complete?
        out << "  incomplete: #{@train_evaluation.unresolved.size} unresolved " \
          "counterexample(s) remain (budget or levels exhausted)"
        @train_evaluation.unresolved.each do |word, miss|
          out << "    #{word}: expected #{miss[:expected].inspect}, " \
            "got #{miss[:actual].inspect}"
        end
      end
      out.join("\n")
    end

    private

    def evaluation_line(evaluation)
      "#{evaluation.perfect}/#{evaluation.word_count} words perfect, " \
        "#{evaluation.false_breaks} false break(s), " \
        "#{evaluation.missed_breaks} missed break(s) " \
        "(verified with Text::Hyphen)"
    end
  end

  # No fewer than this number of letters will show up to the left of a
  # learned hyphenation point.
  attr_reader :left
  # No fewer than this number of letters will show up to the right of a
  # learned hyphenation point.
  attr_reader :right
  # The maximum number of patterns to learn.
  attr_reader :budget
  # The number of pattern levels (weights) trained.
  attr_reader :levels
  # The cost of a false break (a break the annotation forbids).
  attr_reader :false_break_cost
  # The cost of a missed break (an allowed break not found).
  attr_reader :missed_break_cost
  # The fraction of words held out for validation.
  attr_reader :validation_fraction
  # The seed used for the validation split.
  attr_reader :seed
  # The maximum number of letters in a candidate pattern.
  attr_reader :max_pattern_length

  # Creates a trainer. The options are:
  #
  # left::                  Minimum letters left of a break. Defaults to
  #                         Text::Hyphen::DEFAULT_MIN_LEFT.
  # right::                 Minimum letters right of a break. Defaults to
  #                         Text::Hyphen::DEFAULT_MIN_RIGHT.
  # budget::                Maximum number of patterns learned. Defaults
  #                         to DEFAULT_BUDGET.
  # levels::                Number of pattern levels (weights). Defaults
  #                         to DEFAULT_LEVELS.
  # false_break_cost::      Cost of a break the annotation forbids.
  #                         Defaults to 1.
  # missed_break_cost::     Cost of an allowed break not found. Defaults
  #                         to 1.
  # validation_fraction::   Fraction of words held out for validation.
  #                         Defaults to DEFAULT_VALIDATION_FRACTION.
  # seed::                  Seed for the validation split. Defaults to 0.
  # max_pattern_length::    Maximum letters per candidate pattern.
  #                         Defaults to DEFAULT_MAX_PATTERN_LENGTH.
  def initialize(options = {})
    @left = options.fetch(:left, Text::Hyphen::DEFAULT_MIN_LEFT)
    @right = options.fetch(:right, Text::Hyphen::DEFAULT_MIN_RIGHT)
    @budget = options.fetch(:budget, DEFAULT_BUDGET)
    @levels = options.fetch(:levels, DEFAULT_LEVELS)
    @false_break_cost = options.fetch(:false_break_cost, 1)
    @missed_break_cost = options.fetch(:missed_break_cost, 1)
    @validation_fraction = options.fetch(:validation_fraction, DEFAULT_VALIDATION_FRACTION)
    @seed = options.fetch(:seed, 0)
    @max_pattern_length = options.fetch(:max_pattern_length, DEFAULT_MAX_PATTERN_LENGTH)

    raise ArgumentError, "left must be >= 0" if @left < 0
    raise ArgumentError, "right must be >= 0" if @right < 0
    raise ArgumentError, "budget must be >= 0" if @budget < 0
    raise ArgumentError, "levels must be >= 1" if @levels < 1
    if @false_break_cost <= 0 || @missed_break_cost <= 0
      raise ArgumentError, "costs must be positive"
    end
    unless (0..1).cover?(@validation_fraction)
      raise ArgumentError, "validation_fraction must be between 0 and 1"
    end
    raise ArgumentError, "max_pattern_length must be >= 1" if @max_pattern_length < 1
  end

  # Trains hyphenation patterns from +annotations+, an array of words
  # with allowed break positions marked with "-" (for example
  # "rep-re-sen-ta-tion"). Words without a dash must not be hyphenated
  # at all. Returns a Result.
  #
  # Break positions that violate the left/right minima are rejected with
  # an ArgumentError, since the matcher could never produce them.
  def train(annotations)
    entries = parse_all(annotations)
    train_entries, validation_entries = split(entries)
    patterns = learn(train_entries)

    result = Result.new(
      patterns: patterns,
      train_words: train_entries,
      validation_words: validation_entries,
      train_evaluation: nil,
      validation_evaluation: nil,
      left: @left,
      right: @right,
      budget: @budget
    )

    # The final numbers always come from the real matcher, never from
    # the trainer's internal bookkeeping.
    hyphenator = result.hyphenator
    train_evaluation = evaluate(hyphenator, train_entries)
    if validation_entries.empty?
      validation_evaluation = nil
    else
      validation_evaluation = evaluate(hyphenator, validation_entries)
    end

    Result.new(
      patterns: patterns,
      train_words: train_entries,
      validation_words: validation_entries,
      train_evaluation: train_evaluation,
      validation_evaluation: validation_evaluation,
      left: @left,
      right: @right,
      budget: @budget
    )
  end

  private

  Candidate = Struct.new(:text, :dot, :level, :anchor_start, :anchor_end, :string, :matches)

  def parse_all(annotations)
    raise ArgumentError, "no training words given" if annotations.empty?

    seen = {}
    annotations.map do |annotation|
      entry = parse(annotation)
      if seen.key?(entry.word)
        if seen[entry.word] != entry.breaks
          raise ArgumentError, "conflicting annotations for #{entry.word.inspect}"
        end
        next nil
      end
      seen[entry.word] = entry.breaks
      entry
    end.compact
  end

  def parse(annotation)
    text = annotation.to_s.strip.downcase
    parts = text.split("-", -1)
    if parts.any?(&:empty?)
      raise ArgumentError, "invalid annotation #{annotation.inspect}: " \
        "leading, trailing, or repeated '-'"
    end

    word = parts.join
    breaks = []
    position = 0
    parts[0..-2].each do |part|
      position += part.length
      breaks << position
    end

    breaks.each do |point|
      if masked?(point, word.length)
        raise ArgumentError, "break at #{point} in #{annotation.inspect} violates " \
          "the left/right minima (#{@left}/#{@right})"
      end
    end

    AnnotatedWord.new(word, breaks)
  end

  def split(entries)
    return [entries, []] if @validation_fraction <= 0 || entries.size < 2

    count = (entries.size * @validation_fraction).floor
    count = [count, entries.size - 1].min
    return [entries, []] if count.zero?

    shuffled = (0...entries.size).to_a.shuffle(random: Random.new(@seed))
    held_out = shuffled.first(count)
    train_entries = []
    validation_entries = []
    entries.each_with_index do |entry, index|
      if held_out.include?(index)
        validation_entries << entry
      else
        train_entries << entry
      end
    end
    [train_entries, validation_entries]
  end

  # Learns patterns layer by layer. Odd levels vote for a break, even
  # levels vote against one; higher levels override lower ones, matching
  # the TeX (and Text::Hyphen) maximum-level rule.
  def learn(entries)
    gold = entries.map do |entry|
      flags = Array.new(entry.word.length + 1, false)
      entry.breaks.each { |point| flags[point] = true }
      flags
    end
    state = entries.map { |entry| [0] * (entry.word.length + 1) }
    index = build_index(entries)
    patterns = []

    1.upto(@levels) do |level|
      allow = level.odd?
      candidates = generate_candidates(entries, gold, state, level, allow, index)

      loop do
        break if patterns.size >= @budget

        best = nil
        best_gain = 0
        candidates.each do |candidate|
          gain = candidate_gain(candidate, entries, gold, state)
          next if gain <= 0
          if best.nil? || gain > best_gain ||
              (gain == best_gain && candidate.string < best.string)
            best = candidate
            best_gain = gain
          end
        end
        break if best.nil?

        apply(best, state)
        patterns << best.string
        candidates.delete(best)
      end
    end

    patterns
  end

  # Maps every substring of every training word (up to
  # max_pattern_length letters) to the positions where it occurs, so
  # candidate matches are simple hash lookups.
  def build_index(entries)
    index = Hash.new { |hash, key| hash[key] = [] }
    entries.each_with_index do |entry, word_index|
      letters = entry.word.chars
      0.upto(letters.size - 1) do |offset|
        1.upto([@max_pattern_length, letters.size - offset].min) do |length|
          index[letters[offset, length].join] << [word_index, offset]
        end
      end
    end
    index
  end

  # Generates every candidate that could fix a currently-wrong position
  # with this level's parity: all context windows around the position,
  # with word-boundary anchors where the window touches an edge.
  def generate_candidates(entries, gold, state, level, allow, index)
    seen = {}
    candidates = []

    entries.each_with_index do |entry, word_index|
      letters = entry.word.chars
      size = letters.size
      1.upto(size - 1) do |position|
        next if masked?(position, size)
        next unless gold[word_index][position] == allow
        next if (state[word_index][position] % 2 == 1) == allow

        0.upto([position, @max_pattern_length - 1].min) do |left_context|
          max_right = [@max_pattern_length - 1 - left_context, size - position].min
          0.upto(max_right) do |right_context|
            length = left_context + right_context
            next if length.zero?

            text = letters[position - left_context, length].join
            at_start = (position - left_context).zero?
            at_end = (position + right_context == size)

            variants = [[false, false]]
            variants << [true, false] if at_start
            variants << [false, true] if at_end
            variants << [true, true] if at_start && at_end

            variants.each do |(anchor_start, anchor_end)|
              key = [text, left_context, anchor_start, anchor_end]
              next if seen[key]
              seen[key] = true
              candidates << build_candidate(
                text, left_context, level, anchor_start, anchor_end, entries, index
              )
            end
          end
        end
      end
    end

    candidates
  end

  def build_candidate(text, dot, level, anchor_start, anchor_end, entries, index)
    matches = []
    index[text].each do |(word_index, offset)|
      next if anchor_start && offset != 0
      next if anchor_end && offset + text.length != entries[word_index].word.length
      matches << [word_index, offset + dot]
    end

    Candidate.new(
      text, dot, level, anchor_start, anchor_end,
      pattern_string(text, dot, level, anchor_start, anchor_end),
      matches
    )
  end

  # Counts the errors a candidate corrects and introduces. Because the
  # candidate's level is higher than every level applied so far, it wins
  # every position it touches, exactly as in the matcher.
  def candidate_gain(candidate, entries, gold, state)
    allow = candidate.level.odd?
    fixed = 0
    introduced = 0

    candidate.matches.each do |(word_index, position)|
      size = entries[word_index].word.length
      next if masked?(position, size)
      current = state[word_index][position]
      next if current >= candidate.level

      desired = gold[word_index][position]
      correct_now = (current % 2 == 1) == desired

      if desired
        fixed += @missed_break_cost if !correct_now && allow
        introduced += @missed_break_cost if correct_now && !allow
      else
        fixed += @false_break_cost if !correct_now && !allow
        introduced += @false_break_cost if correct_now && allow
      end
    end

    fixed - introduced
  end

  def apply(candidate, state)
    candidate.matches.each do |(word_index, position)|
      if state[word_index][position] < candidate.level
        state[word_index][position] = candidate.level
      end
    end
  end

  # A position is masked when the left/right minima forbid a break
  # there; the matcher zeroes these positions, so the trainer ignores
  # them too.
  def masked?(position, size)
    position <= @left || position >= size - @right
  end

  # Renders a candidate in the Text::Hyphen pattern format: the level
  # digit sits at the break position, "." marks word boundaries.
  def pattern_string(text, dot, level, anchor_start, anchor_end)
    string = +""
    string << "." if anchor_start
    text.chars.each_with_index do |char, index|
      string << level.to_s if index == dot
      string << char
    end
    string << level.to_s if dot == text.length
    string << "." if anchor_end
    string
  end

  # Evaluates the learned patterns with the real Text::Hyphen matcher.
  def evaluate(hyphenator, entries)
    perfect = 0
    false_breaks = 0
    missed_breaks = 0
    unresolved = {}

    entries.each do |entry|
      actual = hyphenator.hyphenate(entry.word)
      false_positions = actual - entry.breaks
      missed_positions = entry.breaks - actual
      false_breaks += false_positions.size
      missed_breaks += missed_positions.size

      if false_positions.empty? && missed_positions.empty?
        perfect += 1
      else
        unresolved[entry.word] = {expected: entry.breaks, actual: actual}
      end
    end

    Evaluation.new(entries.size, perfect, false_breaks, missed_breaks, unresolved)
  end
end

# vim: syntax=ruby

