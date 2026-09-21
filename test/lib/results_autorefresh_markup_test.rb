require "test_helper"

# results-autorefresh is wiring: a controller wrapping the live-tally block,
# a markDirty listener on the cable stream's replace, and a toggle. Drop any
# one attribute and it silently never refreshes rather than breaking loudly —
# these cheap assertions stand in the fast suite (see
# editor_scroll_sync_markup_test.rb for the same trade-off). The browser
# behaviour itself is covered in test/system.
class ResultsAutorefreshMarkupTest < ActiveSupport::TestCase
  # The wiring moved with the tally when the header left the feed for the top
  # of the page — same attributes, one file along.
  HEADER = Rails.root.join("app/views/surveys/_results_header.html.erb")
  LIVE   = Rails.root.join("app/views/surveys/_results_live.html.erb")

  test "the wrapper mounts the controller with a results URL and the markDirty action" do
    html = File.read(HEADER)
    assert_includes html, 'data-controller="results-autorefresh"'
    assert_includes html, "data-results-autorefresh-url-value="
    assert_includes html, "turbo:before-stream-render->results-autorefresh#markDirty",
      "without this the broadcast that updates the live tally never marks the breakdown dirty"
  end

  test "the toggle names itself as a target and wires the click action" do
    html = File.read(HEADER)
    assert_includes html, 'data-results-autorefresh-target="toggle"'
    assert_includes html, "click->results-autorefresh#toggle"
  end

  test "the toggle lives outside #results-live, which broadcasts replace wholesale" do
    # _results_live.html.erb IS the node ResultsActivity.broadcast replaces —
    # a toggle inside it would lose its on/off state on every incoming answer.
    refute_includes File.read(LIVE), "results-autorefresh",
      "the autorefresh controller/toggle must not live inside the replaced partial"
  end
end
