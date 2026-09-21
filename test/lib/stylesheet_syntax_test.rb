require "test_helper"

# The hand-written stylesheet parses.
#
# Written after breaking it twice in one afternoon the same way: extending a
# `/* … */` block by typing the new sentences AFTER its closing marker, so the
# prose landed in the stylesheet as declarations and the rule below it was
# dropped. Neither time did anything complain —
#
#   * `bin/rails tailwindcss:build` exits 0. Tailwind's parser recovers from a
#     stray `*/`, skips to somewhere it can resume, and writes a build that is
#     missing whatever it skipped.
#   * The system suite renders that build, so a dropped rule is only caught if
#     some test happens to assert on the exact geometry it controlled. The
#     first slip dropped `.results-body { display: grid }` — the whole layout
#     of the results feed — and every test stayed green.
#
# So the failure mode is a rule silently disappearing, which is worth a test
# that costs a millisecond. Comments only: this is a balance check, not a CSS
# parser, and it is deliberately the smallest thing that would have caught
# both.
class StylesheetSyntaxTest < ActiveSupport::TestCase
  SHEETS = Rails.root.glob("app/assets/tailwind/**/*.css").freeze

  test "there is a stylesheet to check" do
    assert SHEETS.any?, "no hand-written stylesheets found — has app/assets/tailwind moved?"
  end

  test "every comment is opened and closed, and nothing closes one that is not open" do
    SHEETS.each do |path|
      depth = 0
      opened_at = nil

      path.read.each_line.with_index(1) do |line, number|
        # Scan markers in the order they appear, so `/* … */ /*` on one line
        # is read as close-then-open rather than as two of each.
        line.scan(%r{/\*|\*/}) do |marker|
          if marker == "/*"
            next if depth.positive? # CSS comments do not nest; an inner /* is text
            depth = 1
            opened_at = number
          else
            assert depth.positive?,
              "#{path.relative_path_from(Rails.root)}:#{number} closes a comment that was never " \
              "opened — everything after it is being read as CSS, and the next rule is likely gone"
            depth = 0
          end
        end
      end

      assert_equal 0, depth,
        "#{path.relative_path_from(Rails.root)}:#{opened_at} opens a comment that is never closed — " \
        "the rest of the file is inside it"
    end
  end

  # The other half of the same slip, which balance alone does NOT catch: drop a
  # `*/` in the middle of the file and the comment simply runs on until the
  # next one, swallowing every rule in between — and the file still balances.
  #
  # A line that is nothing but `}` is the tell. Prose does not contain one;
  # a swallowed rule always does.
  test "no comment has swallowed a rule" do
    SHEETS.each do |path|
      inside = false
      opened_at = nil

      path.read.each_line.with_index(1) do |line, number|
        was_inside = inside
        line.scan(%r{/\*|\*/}) do |marker|
          if marker == "/*"
            next if inside
            inside = true
            opened_at = number
          else
            inside = false
          end
        end

        next unless was_inside && inside && line.strip == "}"

        flunk "#{path.relative_path_from(Rails.root)}:#{number} is a closing brace inside the " \
              "comment opened at line #{opened_at} — that comment is missing its `*/` and has " \
              "swallowed the rules between the two"
      end
    end
  end
end
