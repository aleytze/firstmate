#!/usr/bin/env bash
# Behavior tests for the shipped bearings board renderer
# (.agents/skills/bearings/assets/board-template.html), exercised through a real
# `fm-bearings-board.sh build` and then executed under the minimal DOM shim in
# tests/assets/board-render-harness.mjs. The assertions are on what the page
# renders - row badges, the stat strip, the empty state, and the row text
# disclosure the shim can press - never on the template's source text.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-bearings-board.sh"
HARNESS="$ROOT/tests/assets/board-render-harness.mjs"
TMP_ROOT=$(fm_test_tmproot fm-bearings-board-render)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

# Build the board from the payload already written to <home>/payload.json and
# return what the renderer produced. With measure=off the harness makes every
# text measurement throw, standing for a browser where the pass cannot run.
build_and_render() {  # <home> [measure]
  local home=$1 measure=${2:-on}
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$BOARD" build "$home/payload.json" >/dev/null || fail "the board did not build"
  FM_BOARD_HARNESS_MEASURE="$measure" node "$HARNESS" "$home/.lavish/bearings-board.html" \
    || fail "the built board could not be rendered"
}

# Build the board from <charted-json> and return what the renderer produced.
render() {  # <home> <charted-json> [charted_more] [charted_warning_more]
  local home=$1 charted=$2 more=${3:-0} warning_more=${4:-0}
  jq -n --argjson charted "$charted" --argjson more "$more" --argjson warning_more "$warning_more" '{
    schema:"fm-bearings-board.v1", home:"render-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[],
    charted:$charted, charted_more:$more, charted_warning_more:$warning_more}' > "$home/payload.json"
  build_and_render "$home"
}

# Build the board from a whole payload, for assertions that span every section.
render_payload() {  # <home> <payload-json> [measure]
  local home=$1
  printf '%s' "$2" > "$home/payload.json"
  build_and_render "$home" "${3:-on}"
}

charted_next_count() {  # <render-json>
  printf '%s' "$1" | jq -r '.stats[] | select(.label == "charted next") | .n'
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work() {
  local home out
  home=$(make_home warning-badge)
  out=$(render "$home" '[
    {"id":"real-queued","repo":"sample","title":"Queued work","reason":"queued behind the cutover","dispatchable":true},
    {"id":"main-inventory","repo":"sample","title":"Main inventory integrity","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    (.charted | length) == 2
      and (.charted[0] | .title == "Queued work"
        and [.badges[] | .text] == ["waiting"] and .pickable == true)
      and (.charted[1] | .title == "Main inventory integrity"
        and [.badges[] | .text] == ["needs repair"]
        and [.badges[] | .tone] == ["danger"]
        and .pickable == false)
  ' >/dev/null || fail "a warning row did not read differently from queued work: $out"
  pass "a warning row badges needs repair while queued work keeps waiting"
}

test_warnings_are_excluded_from_the_charted_next_count() {
  local home out
  home=$(make_home warning-count)
  out=$(render "$home" '[
    {"id":"queued-one","repo":"sample","title":"One","reason":"gated","dispatchable":true},
    {"id":"warn-one","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"},
    {"id":"warn-two","repo":"sample","title":"Inventory mismatch","reason":"main inventory","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 1 ] \
    || fail "the charted next tally counted alarms as queued work: $out"
  printf '%s' "$out" | jq -e '(.charted | length) == 3' >/dev/null \
    || fail "excluding warnings from the count also dropped their rows: $out"
  pass "the charted next count counts queued work only, and still renders warnings"
}

test_a_board_of_only_warnings_still_reports_nothing_queued() {
  local home out
  home=$(make_home warning-only)
  out=$(render "$home" '[
    {"id":"warn-only","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]')
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "a warning-only board claimed queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.charted | length) == 1
  ' >/dev/null || fail "a warning-only board hid the warning or the empty state: $out"
  pass "a warning-only board reports nothing queued and still shows the warning"
}

test_omitted_warnings_never_count_as_more_queued() {
  local home out
  home=$(make_home warning-more)
  out=$(render "$home" '[
    {"id":"warn-visible","repo":"sample","title":"Home unreadable","reason":"current home state unavailable","dispatchable":false,"kind":"warning"}
  ]' 0 1)
  [ "$(charted_next_count "$out")" = 0 ] \
    || fail "an omitted warning was counted as queued work: $out"
  printf '%s' "$out" | jq -e '
    (.empty | length) == 1 and (.empty[0] | test("Nothing is queued"))
      and (.more == ["+1 more repair warning - ask firstmate for the full chart"])
      and ([.more[] | select(test("more queued"))] | length) == 0
  ' >/dev/null || fail "an omitted warning was labeled as more queued: $out"
  pass "omitted warnings remain separate from omitted queued work"
}

test_an_omitted_kind_keeps_the_existing_queued_rendering() {
  local home out
  home=$(make_home default-kind)
  out=$(render "$home" '[
    {"id":"with-reason","repo":"sample","title":"With reason","reason":"blocked on prep","dispatchable":true},
    {"id":"no-reason","repo":"sample","title":"No reason","reason":"","dispatchable":true}
  ]' 2)
  [ "$(charted_next_count "$out")" = 4 ] \
    || fail "an omitted kind changed the charted next tally: $out"
  printf '%s' "$out" | jq -e '
    ([.charted[0].badges[] | .text] == ["waiting"])
      and (.charted[1].badges == [])
  ' >/dev/null || fail "an omitted kind changed the existing queued badges: $out"
  pass "an omitted kind renders exactly as queued work always did"
}


# The captain could not read a row's title or its waiting reason because both
# were clipped to one line. What makes the rest reachable is that the row keeps
# the complete strings as ordinary selectable text carrying a tooltip for a
# mouse, and puts a chevron button beside them that a keyboard and a touch tap
# can press to open the row in place. The clamp itself is CSS, so a browser -
# not this shim - is where the visual truncation is checked.
LONG_TITLE="Rework the charted next column so that the reason a task is waiting survives the half-width layout it is rendered into"
LONG_REASON="waiting on the upstream release that carries the presentation-space version floor, because dispatching before it lands would strand the lab"

long_payload() {
  jq -n --arg t "$LONG_TITLE" --arg r "$LONG_REASON" '{
    schema:"fm-bearings-board.v1", home:"disclosure-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[],
    underway:[{id:"u1", repo:"sample", state:"working", kind:"ship", doing:$t}],
    landed:[{id:"l1", repo:"sample", what:$t, owner:"crew"}],
    charted:[{id:"c1", repo:"sample", title:$t, reason:$r, dispatchable:true}]}'
}

test_every_compact_row_reaches_its_full_text_through_one_disclosure() {
  local home out
  home=$(make_home disclosure)
  out=$(render_payload "$home" "$(long_payload)")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e --arg t "$LONG_TITLE" '
    [.underway[0], .landed[0], .charted[0]] | all(
      .textTag == "div"
        and .disclosure.tag == "button" and .disclosure.type == "button"
        and .disclosure.expanded == "false"
        and (.disclosure.label | contains($t))
        and .title == $t
        and (.tooltip | contains($t))
        and (.sub as $s | .tooltip | contains($s)))
  ' >/dev/null || fail "a section's rows are not a disclosure carrying their full text: $out"
  pass "underway, landed and charted rows each expose their full text through one disclosure button"
}

# A disclosure that reports only "expanded" leaves a screen reader announcing a
# state with no subject, so the button must name the text it opens. Every section
# builds its rows through the same helper, so a per-section index would hand two
# sections the same name and point one button at another section's row.
multi_row_payload() {
  jq -n --arg t "$LONG_TITLE" --arg r "$LONG_REASON" '{
    schema:"fm-bearings-board.v1", home:"controls-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[],
    underway:[{id:"u1", repo:"sample", state:"working", kind:"ship", doing:$t},
              {id:"u2", repo:"sample", state:"working", kind:"ship", doing:($t + " two")}],
    landed:[{id:"l1", repo:"sample", what:$t, owner:"crew"},
            {id:"l2", repo:"sample", what:($t + " two"), owner:"crew"}],
    charted:[{id:"c1", repo:"sample", title:$t, reason:$r, dispatchable:true},
             {id:"c2", repo:"sample", title:($t + " two"), reason:$r, dispatchable:true}]}'
}

test_each_disclosure_names_the_text_it_opens_with_a_page_unique_id() {
  local home out
  home=$(make_home disclosure-controls)
  out=$(render_payload "$home" "$(multi_row_payload)")
  printf '%s' "$out" | jq -e '.error == ""' >/dev/null \
    || fail "the board rendered its fail-closed error instead of the fleet: $out"
  printf '%s' "$out" | jq -e '
    [.underway[], .landed[], .charted[]]
      | (length == 6)
        and all(.textIds | all(length > 0))
        and all(.disclosure.controls == (.textIds | join(" ")))
        and ([.[].textIds[]] | length == (unique | length))
  ' >/dev/null || fail "the row disclosures do not name their own text by a page-unique id: $out"
  pass "every row's disclosure names the text it opens, by ids unique across all three sections"
}

# A row that renders a chevron but never opens leaves the clamped text just as
# unreachable as before the fix, so the press itself is exercised.
test_pressing_the_disclosure_opens_and_closes_the_row() {
  local home out
  home=$(make_home disclosure-toggle)
  out=$(render_payload "$home" "$(long_payload)")
  printf '%s' "$out" | jq -e '
    (.presses[0] | .open == true and .expanded == "true")
      and (.presses[1] | .open == false and .expanded == "false")
  ' >/dev/null || fail "pressing the disclosure did not open and then close the row: $out"
  pass "pressing a row's disclosure opens it, and pressing again closes it"
}

# A tooltip repeating text that is already fully on screen is noise, and the
# hover panel can cover the very content it duplicates, so the tooltip belongs
# to a collapsed row only.
test_expanding_a_row_drops_its_now_redundant_tooltip() {
  local home out
  home=$(make_home disclosure-tooltip)
  out=$(render_payload "$home" "$(long_payload)")
  printf '%s' "$out" | jq -e --arg t "$LONG_TITLE" '
    (.charted[0].tooltip | contains($t))
      and (.presses[0] | .open == true and .tooltip == null)
      and (.presses[1] | .open == false and (.tooltip | contains($t)))
  ' >/dev/null || fail "the tooltip did not follow the row open and closed again: $out"
  pass "expanding a row drops its redundant tooltip, and collapsing restores it"
}

# An expand that reveals nothing is noise, so the measurement pass takes the
# rows that fit back out of the tab order - but it must never take out a row
# that really is hiding text, which is the bug this whole change repairs.
mixed_payload() {
  jq -n --arg t "$LONG_TITLE" --arg r "$LONG_REASON" '{
    schema:"fm-bearings-board.v1", home:"clip-home", generated:"2026-08-26T00:00Z",
    prs_live:false, captains_call:[], underway:[], landed:[],
    charted:[{id:"c1", repo:"sample", title:$t, reason:$r, dispatchable:true},
             {id:"c2", repo:"sample", title:"Short", reason:"gated", dispatchable:true}]}'
}

test_only_a_row_that_hides_text_keeps_its_disclosure() {
  local home out
  home=$(make_home clip-measure)
  out=$(render_payload "$home" "$(mixed_payload)")
  printf '%s' "$out" | jq -e '.measured == true' >/dev/null \
    || fail "the board never measured which rows clip: $out"
  printf '%s' "$out" | jq -e --arg t "$LONG_TITLE" '
    (.charted[0] | .clip == true and .disclosure.disabled == false
       and (.tooltip | contains($t)))
      and (.charted[1] | .clip == false and .disclosure.disabled == true
       and .tooltip == null)
  ' >/dev/null || fail "the disclosure did not follow which rows actually hide text: $out"
  pass "a row that hides text keeps an enabled disclosure, and a row that fits loses it"
}

# Where the pass cannot run there is no way to tell which rows hide text, so
# every row must stay reachable rather than every row losing its way in.
test_rows_stay_expandable_where_the_clip_measurement_cannot_run() {
  local home out
  home=$(make_home clip-fail-open)
  out=$(render_payload "$home" "$(mixed_payload)" off)
  printf '%s' "$out" | jq -e '.error == "" and .measured == false' >/dev/null \
    || fail "an unmeasurable board did not fall back cleanly: $out"
  printf '%s' "$out" | jq -e --arg t "$LONG_TITLE" '
    (.charted | length) == 2
      and all(.charted[]; .disclosure.disabled == false and .tooltip != null)
      and (.charted[0].tooltip | contains($t))
  ' >/dev/null || fail "an unmeasurable board took rows out of reach: $out"
  pass "every row stays expandable and keeps its tooltip where the clip measurement cannot run"
}

test_the_charted_reason_survives_the_row_in_full() {
  local home out
  home=$(make_home disclosure-reason)
  out=$(render_payload "$home" "$(long_payload)")
  printf '%s' "$out" | jq -e --arg r "$LONG_REASON" '
    .charted[0]
      | (.sub | startswith($r)) and (.sub | endswith("\u00b7 sample"))
        and (.tooltip | contains($r))
  ' >/dev/null || fail "the waiting reason did not survive the charted row in full: $out"
  pass "the charted waiting reason is carried whole by the row and its tooltip"
}

test_a_warning_row_reads_as_a_repair_not_as_queued_work
test_warnings_are_excluded_from_the_charted_next_count
test_a_board_of_only_warnings_still_reports_nothing_queued
test_omitted_warnings_never_count_as_more_queued
test_an_omitted_kind_keeps_the_existing_queued_rendering
test_every_compact_row_reaches_its_full_text_through_one_disclosure
test_each_disclosure_names_the_text_it_opens_with_a_page_unique_id
test_pressing_the_disclosure_opens_and_closes_the_row
test_expanding_a_row_drops_its_now_redundant_tooltip
test_only_a_row_that_hides_text_keeps_its_disclosure
test_rows_stay_expandable_where_the_clip_measurement_cannot_run
test_the_charted_reason_survives_the_row_in_full
