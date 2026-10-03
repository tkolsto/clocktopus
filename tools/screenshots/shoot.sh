#!/bin/zsh
# Shoot the README/blog screenshots from a demo instance with seeded data,
# in light and dark, without touching your real config or database.
#
#   tools/screenshots/shoot.sh            # builds the helpers, seeds, shoots
#
# Output: docs/assets/screenshots/{day-timeline,week-grid,popover,preferences,menubar}-{light,dark}.png
# Needs: a Debug build under App/build/dd, Accessibility permission for your
# terminal (System Settings → Privacy → Accessibility), and about a minute
# during which the system appearance flips to light and back.
set -e
ROOT=${0:A:h:h:h}
HERE=$ROOT/tools/screenshots
OUT=$ROOT/docs/assets/screenshots
WORK=${TMPDIR:-/tmp}/clocktopus-screenshots; mkdir -p $WORK
APP=$ROOT/App/build/dd/Build/Products/Debug/Clocktopus.app
DEMO_CFG=~/.config/clocktopus/demo

# Helpers: pid-precise accessibility driver + window-id lookup.
[[ -x $WORK/axctl ]] || swiftc -O -o $WORK/axctl $HERE/axctl.swift
[[ -x $WORK/winid ]] || swiftc -O -o $WORK/winid $HERE/winid.swift
AX=$WORK/axctl; W=$WORK/winid

# Demo config lives under ~/.config/clocktopus/demo so Preferences shows a tidy path.
mkdir -p $DEMO_CFG && cp $HERE/team.toml $HERE/config.toml $DEMO_CFG/

launch() {  # launch TAG → pid; a second instance beside your real one
  open -n -a $APP --args -clocktopus-db $WORK/demo.sqlite -clocktopus-config $DEMO_CFG/config.toml -clocktopus-open $1
  sleep 6; pgrep -f "clocktopus-db" | head -1
}
dark() { osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $1"; sleep 2 }
was_dark=$(osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode')

# 1. Let the app create the schema, then seed.
rm -f $WORK/demo.sqlite; PID=$(launch review); kill $PID; sleep 2
python3 $HERE/seed.py $WORK/demo.sqlite
PID=$(launch review)

shoot_review() {  # shoot_review SUFFIX
  $AX $PID resize "Clocktopus Review" 900 900; sleep 0.5
  $AX $PID tab "Clocktopus Review" 0; sleep 0.5
  $AX $PID scroll "Clocktopus Review" 0.2; sleep 0.8
  local ID=$($W $PID "Clocktopus Review" | awk '{print $1}')
  screencapture -l $ID -o -x $OUT/day-timeline-$1.png
  $AX $PID tab "Clocktopus Review" 1; sleep 0.3
  $AX $PID resize "Clocktopus Review" 900 690; sleep 0.8
  screencapture -l $ID -o -x $OUT/week-grid-$1.png
  $AX $PID tab "Clocktopus Review" 0
  read X Y MW MH <<< "$($AX $PID statusframe)"
  screencapture -R "$((X-4)),$Y,$((MW+8)),$MH" -x $OUT/menubar-$1.png
  $AX $PID statusitem; sleep 2.5
  local POP=$($W $PID | awk '$2!="Clocktopus"{print $1}' | head -1)
  screencapture -l $POP -o -x $OUT/popover-$1.png
  osascript -e 'tell application "System Events" to key code 53'   # esc closes the popover
}
dark true;  shoot_review dark
dark false; shoot_review light
kill $PID; sleep 2

# 2. Preferences gets its own launch (the popover's buttons aren't scriptable).
PID=$(launch preferences)
$AX $PID resize "Clocktopus Preferences" 460 980; sleep 1
$AX $PID unfocus "Clocktopus Preferences"; sleep 0.5    # the AI-tools field opens focused with its text selected
ID=$($W $PID "Clocktopus Preferences" | awk '{print $1}')
screencapture -l $ID -o -x $OUT/preferences-light.png
dark true; screencapture -l $ID -o -x $OUT/preferences-dark.png
kill $PID
dark $was_dark
echo "done → $OUT"
