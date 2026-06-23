#!/usr/bin/env bash
# Claude Code status line: RGB gradient, dynamic emoji, cost, code velocity

input=$(cat)

# ── Colors ──
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
MAGENTA='\033[35m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Truecolor helper ──
rgb() { printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"; }

# ── Parse JSON fields ──
model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
ctx_in=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
ctx_out=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
lines_add=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_del=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
session_id=$(echo "$input" | jq -r '.session_id // empty')

# ── Git info ──
branch=""
repo=""
if [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  repo=$(basename "$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)
fi

# ── Gradient bar renderer: emoji + RGB gradient bar + colored % ──
BAR_WIDTH=10

render_bar() {
  local pct_int filled i pos r g b bar color adj
  pct_int=$(printf '%.0f' "$1")
  filled=$(( (pct_int * BAR_WIDTH + 50) / 100 ))

  bar=""
  for (( i=0; i<BAR_WIDTH; i++ )); do
    pos=$(( i * 100 / (BAR_WIDTH - 1) ))
    if [ "$pos" -le 50 ]; then
      r=$(( 0 + 220 * pos / 50 )); g=200; b=$(( 80 - 80 * pos / 50 ))
    else
      adj=$(( pos - 50 )); r=220; g=$(( 200 - 160 * adj / 50 )); b=$(( 0 + 20 * adj / 50 ))
    fi
    if [ "$i" -lt "$filled" ]; then
      bar="${bar}$(rgb $r $g $b)█"
    else
      bar="${bar}\033[38;2;60;60;60m░"
    fi
  done
  bar="${bar}${RESET}"

  if [ "$pct_int" -ge 90 ]; then color="$RED"
  elif [ "$pct_int" -ge 70 ]; then color="$YELLOW"
  else color="$GREEN"; fi

  local pct_pad=$(( 3 - ${#pct_int} )); [ "$pct_pad" -lt 0 ] && pct_pad=0
  printf '%b %b%s%%%b%*s' "$bar" "$color" "$pct_int" "$RESET" "$pct_pad" ''
}

EMPTY_BAR="\033[38;2;60;60;60m░░░░░░░░░░${RESET}"

# ── Time-until-reset helper: epoch ts -> "2h13m" / "3d4h" ──
fmt_reset() {
  local ts now diff d h m
  ts="$1"
  [ -z "$ts" ] && return
  # ISO 8601 -> epoch if not already numeric
  if ! [[ "$ts" =~ ^[0-9]+$ ]]; then
    ts=$(date -d "$ts" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null)
    [ -z "$ts" ] && return
  fi
  now=$(date +%s)
  diff=$(( ts - now ))
  [ "$diff" -lt 0 ] && diff=0
  d=$(( diff / 86400 ))
  h=$(( (diff % 86400) / 3600 ))
  m=$(( (diff % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then
    printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then
    printf '%dh%dm' "$h" "$m"
  else
    printf '%dm' "$m"
  fi
}

# ── Reset time helper: epoch/ISO ts -> "13:00" (local, 24h) ──
fmt_reset_clock() {
  local ts="$1"
  [ -z "$ts" ] && return
  if ! [[ "$ts" =~ ^[0-9]+$ ]]; then
    if [[ "$ts" == *Z ]]; then
      ts=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null || date -d "$ts" +%s 2>/dev/null)
    else
      ts=$(date -d "$ts" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${ts%%.*}" +%s 2>/dev/null)
    fi
    [ -z "$ts" ] && return
  fi
  date -r "$ts" +%H:%M 2>/dev/null || date -d "@$ts" +%H:%M 2>/dev/null
}

# ── Compact token formatter: 110234 -> "110k", 1500000 -> "1.5M" ──
fmt_tokens() {
  local n="$1"
  if [ "$n" -ge 1000000 ]; then
    printf '%d.%dM' $(( n / 1000000 )) $(( (n % 1000000) / 100000 ))
  elif [ "$n" -ge 1000 ]; then
    printf '%dk' $(( (n + 500) / 1000 ))
  else
    printf '%d' "$n"
  fi
}

# ── Column padders: emit spaces to pad PLAIN text $2 within visible width $1 ──
# Measure on the uncolored string (ANSI escapes would inflate ${#s}). Center =
# pad_left (floor of slack) + text + pad_right (rest); the two together fill
# exactly $1, so the following column still starts at a fixed offset.
pad_left() {
  local w="$1" s="$2" n
  n=$(( (w - ${#s} + 1) / 2 )); [ "$n" -lt 0 ] && n=0   # round half up
  printf '%*s' "$n" ''
}
pad_right() {
  local w="$1" s="$2" l n
  l=$(( (w - ${#s} + 1) / 2 )); [ "$l" -lt 0 ] && l=0   # must match pad_left
  n=$(( w - ${#s} - l )); [ "$n" -lt 0 ] && n=0
  printf '%*s' "$n" ''
}

# ── Context bar ──
# Context-fullness words, clueless -> overloaded, one per 10% tier
CULT_WORDS=("Clueless" "Squinting" "Skimming" "CatchingOn" "InTheLoop" "WellVersed" "Brimming" "Overstuffed" "TooMuch" "BrainFull")
# Column-A width: the centered number/reset field (ctx tokens, 5h clock, 7d
# reset). Sized to the widest of those (~6, e.g. "16d22h") so the trailing
# word/combo column starts at one fixed, tight offset. Longer values just get
# zero pad (slightly less centered) rather than clipping.
COL_A_W=6
if [ -n "$used" ]; then
  ctx_part=$(render_bar "$used")
  tier=$(printf '%.0f' "$used"); tier=$(( tier / 10 )); [ "$tier" -gt 9 ] && tier=9
  ctx_word="${CULT_WORDS[$tier]}"
  ctx_tok=""
  if [ -n "$ctx_size" ]; then
    left=$(( ctx_size - ctx_in - ctx_out )); [ "$left" -lt 0 ] && left=0
    ctx_tok=$(fmt_tokens "$left")
  fi
  # column A = token number (dim, same as the word, centered), column B = the word
  ctx_part="${ctx_part}$(pad_left "$COL_A_W" "$ctx_tok")${DIM}${ctx_tok}${RESET}$(pad_right "$COL_A_W" "$ctx_tok")"
  ctx_part="${ctx_part}   ${DIM}${ctx_word}${RESET}"
else
  ctx_part="${EMPTY_BAR} --%  ${DIM}${CULT_WORDS[0]}${RESET}"
fi

# ── 5-hour rate limit bar ──
five_hour=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_hour_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')

# ── 5h combo streak ──
# Hit >=90% of a 5h block -> +1 combo (x1..x10). Each 5h block is credited
# exactly ONCE, even when several Claude sessions render at the same time: the
# first renderer to atomically create that block's marker file wins the credit,
# every other session sees the marker and skips. No new credit for 24h -> combo
# lost (reset to 0). ~4-5 blocks fit in 24h, so combo climbs up to ~+4/day.
COMBO_DB="$HOME/.claude/statusline-combo.json"
COMBO_MARK_DIR="$HOME/.claude/statusline-combo-blocks"  # one marker per credited 5h block
COMBO_THRESHOLD=90
COMBO_TTL=86400
# Distinct color per multiplier. Cool neon ramp (blue -> indigo -> violet ->
# magenta -> hot pink) chosen to clash with NOTHING else in the line: the bars
# are warm green/gold/red, money is teal/coral. Combo owns the cool spectrum.
COMBO_R=( [1]=70  [2]=90  [3]=120 [4]=150 [5]=180 [6]=205 [7]=230 [8]=250 [9]=255 [10]=255 )
COMBO_G=( [1]=195 [2]=160 [3]=130 [4]=110 [5]=95  [6]=85  [7]=80  [8]=80  [9]=85  [10]=95  )
COMBO_B=( [1]=235 [2]=255 [3]=255 [4]=255 [5]=255 [6]=250 [7]=235 [8]=205 [9]=175 [10]=150 )
# One cheering word per tier, from cult movies.
COMBO_WORD=( [1]=Nice [2]=Groovy [3]=Excellent [4]=Smokin [5]=Tubular [6]=Bonkers \
             [7]=Inconceivable [8]=Wolverines [9]=Freedom [10]=Legendary )

combo_level=0 combo_last=0 combo_block="" combo_dirty=0
if [ -s "$COMBO_DB" ]; then
  read -r combo_level combo_last combo_block < <(jq -r \
    '[(.level // 0), (.last // 0), (.block // "")] | @tsv' "$COMBO_DB" 2>/dev/null)
fi
[ -z "$combo_level" ] && combo_level=0
[ -z "$combo_last" ] && combo_last=0
combo_now=$(date +%s)

# Lose combo if 24h passed with no new credit.
if [ "$combo_level" -gt 0 ] && [ "$combo_last" -gt 0 ] \
   && [ "$(( combo_now - combo_last ))" -gt "$COMBO_TTL" ]; then
  combo_level=0 combo_last=0 combo_block="" combo_dirty=1
fi

# Safety/migration: if a block was already credited (per stored combo_block) but
# has no marker yet — first render after this upgrade, or the marker was pruned —
# seed it, so the already-counted block can't be credited a second time.
if [ -n "$combo_block" ]; then
  mkdir -p "$COMBO_MARK_DIR" 2>/dev/null
  combo_seed="$COMBO_MARK_DIR/$(printf '%s' "$combo_block" | tr -c 'A-Za-z0-9' '_')"
  [ -e "$combo_seed" ] || : > "$combo_seed" 2>/dev/null
fi

# Credit this 5h block once, atomically across concurrent sessions.
# A block's identity is its resets_at. The credit is gated on EXCLUSIVELY
# creating a marker file named after it (set -o noclobber == O_EXCL): only the
# first session to win that create bumps the combo. A second session that loads
# mid-block finds the marker already present and adds no extra multiplier.
if [ -n "$five_hour" ] && [ -n "$five_hour_reset" ]; then
  fh_int=$(printf '%.0f' "$five_hour" 2>/dev/null)
  if [ -n "$fh_int" ] && [ "$fh_int" -ge "$COMBO_THRESHOLD" ]; then
    mkdir -p "$COMBO_MARK_DIR" 2>/dev/null
    combo_mark="$COMBO_MARK_DIR/$(printf '%s' "$five_hour_reset" | tr -c 'A-Za-z0-9' '_')"
    if ( set -o noclobber; : > "$combo_mark" ) 2>/dev/null; then
      combo_level=$(( combo_level + 1 ))
      [ "$combo_level" -gt 10 ] && combo_level=10
      combo_last=$combo_now combo_block="$five_hour_reset" combo_dirty=1
    fi
  fi
fi

if [ "$combo_dirty" = "1" ]; then
  # Atomic write (temp + rename) so a concurrent reader never catches a torn or
  # truncated file — a torn read used to blank combo_block and double-credit.
  combo_tmp="$COMBO_DB.$$.tmp"
  if jq -n --argjson l "$combo_level" --argjson t "$combo_last" --arg b "$combo_block" \
       '{level:$l, last:$t, block:$b}' > "$combo_tmp" 2>/dev/null; then
    mv -f "$combo_tmp" "$COMBO_DB" 2>/dev/null
  else
    rm -f "$combo_tmp" 2>/dev/null
  fi
fi

# Prune markers older than ~11h (a 5h block + slack) so the dir stays small.
[ -d "$COMBO_MARK_DIR" ] && find "$COMBO_MARK_DIR" -type f -mmin +660 -delete 2>/dev/null

# Number sits right after the %, tier-colored. Word is grey (like ctx words)
# and trails after the reset clock.
combo_mult="" combo_word=""
if [ "$combo_level" -ge 1 ]; then
  cc=$(rgb "${COMBO_R[$combo_level]}" "${COMBO_G[$combo_level]}" "${COMBO_B[$combo_level]}")
  combo_word="   ${DIM}${COMBO_WORD[$combo_level]}${RESET}"
  combo_mult=" ${cc}${BOLD}x${combo_level}${RESET}"
fi

if [ -n "$five_hour" ]; then
  usage_part=$(render_bar "$five_hour")
else
  usage_part="${EMPTY_BAR} --% "
fi
fh_reset_txt=""
[ -n "$five_hour_reset" ] && fh_reset_txt=$(fmt_reset_clock "$five_hour_reset")
usage_part="${usage_part}$(pad_left "$COL_A_W" "$fh_reset_txt")${DIM}${fh_reset_txt}${RESET}$(pad_right "$COL_A_W" "$fh_reset_txt")"
usage_part="${usage_part}${combo_word}"
usage_part="${usage_part}${combo_mult}"

# ── 7-day rate limit bar ──
seven_day=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_day_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
if [ -n "$seven_day" ]; then
  week_part=$(render_bar "$seven_day")
else
  week_part="${EMPTY_BAR} --% "
fi
if [ -n "$seven_day_reset" ]; then
  sd_txt=$(fmt_reset "$seven_day_reset")
  week_part="${week_part}$(pad_left "$COL_A_W" "$sd_txt")${DIM}${sd_txt}${RESET}"
fi

# ── Cost ──
cost_part="${YELLOW}$(printf '$%.2f' "$cost")${RESET}"

# ── Cross-session totals (cost + lines) ──
# Per-session stats keyed by session_id; session values are cumulative,
# so overwriting the key each render avoids double-counting. Totals = sums.
COST_DB="$HOME/.claude/statusline-costs.json"
total_cost="" total_add="" total_del=""
if [ -n "$session_id" ]; then
  [ -s "$COST_DB" ] || echo '{}' > "$COST_DB"
  tmp=$(jq --arg sid "$session_id" \
           --argjson c "${cost:-0}" --argjson a "${lines_add:-0}" --argjson d "${lines_del:-0}" '
    map_values(if type == "number" then {cost: ., add: 0, del: 0} else . end)
    | .[$sid] = {
        cost: ([.[$sid].cost // 0, $c] | max),
        add:  ([.[$sid].add  // 0, $a] | max),
        del:  ([.[$sid].del  // 0, $d] | max)
      }' "$COST_DB" 2>/dev/null)
  [ -n "$tmp" ] && printf '%s' "$tmp" > "$COST_DB"
  read -r total_cost total_add total_del < <(jq -r \
    '[([.[].cost] | add // 0), ([.[].add] | add // 0), ([.[].del] | add // 0)] | @tsv' \
    "$COST_DB" 2>/dev/null)
fi
# ── Monthly billing cycle ──
# Totals above are all-time sums. We want to display only the CURRENT month.
# Anchor = the day totals were first collected (cost DB birth). Each calendar
# month from the anchor is one cycle. On rollover: archive the just-finished
# period's delta into history[], set baseline = current all-time totals, and
# advance the anchor. Displayed values = all-time - baseline (this month only).
CYCLE_DB="$HOME/.claude/statusline-cycle.json"
month_cost="$total_cost" month_add="$total_add" month_del="$total_del"
if [ -n "$total_cost" ]; then
  cyc_anchor="" base_cost=0 base_add=0 base_del=0
  if [ -s "$CYCLE_DB" ]; then
    read -r cyc_anchor base_cost base_add base_del < <(jq -r \
      '[(.anchor // 0), (.baseline_cost // 0), (.baseline_add // 0), (.baseline_del // 0)] | @tsv' \
      "$CYCLE_DB" 2>/dev/null)
  fi
  if [ -z "$cyc_anchor" ] || [ "$cyc_anchor" = "0" ]; then
    cyc_anchor=$(stat -f %B "$COST_DB" 2>/dev/null || stat -c %W "$COST_DB" 2>/dev/null)
    { [ -z "$cyc_anchor" ] || [ "$cyc_anchor" -le 0 ]; } 2>/dev/null && cyc_anchor=$(date +%s)
    base_cost=0 base_add=0 base_del=0
    jq -n --argjson a "$cyc_anchor" \
      '{anchor:$a, baseline_cost:0, baseline_add:0, baseline_del:0, history:[]}' \
      > "$CYCLE_DB" 2>/dev/null
  fi

  cyc_now=$(date +%s)
  cyc_end=$(date -v+1m -r "$cyc_anchor" +%s 2>/dev/null || date -d "@$cyc_anchor +1 month" +%s 2>/dev/null)
  if [ -n "$cyc_end" ] && [ "$cyc_now" -ge "$cyc_end" ]; then
    # Cycle ended. Compute this period's delta (clamped at 0).
    period_cost=$(awk -v a="$total_cost" -v b="$base_cost" 'BEGIN{d=a-b; if(d<0)d=0; printf "%.2f", d}')
    period_add=$(( total_add - base_add )); [ "$period_add" -lt 0 ] && period_add=0
    period_del=$(( total_del - base_del )); [ "$period_del" -lt 0 ] && period_del=0
    # Advance anchor month-by-month to the latest boundary <= now (handles gaps).
    new_anchor="$cyc_anchor"
    while : ; do
      ne=$(date -v+1m -r "$new_anchor" +%s 2>/dev/null || date -d "@$new_anchor +1 month" +%s 2>/dev/null)
      { [ -n "$ne" ] && [ "$cyc_now" -ge "$ne" ]; } || break
      new_anchor="$ne"
    done
    # Idempotent: if a concurrent render already archived this boundary
    # (last history .end == $en), don't append a duplicate — just sync state.
    tmp=$(jq --argjson st "$cyc_anchor" --argjson en "$new_anchor" \
             --argjson pc "$period_cost" --argjson pa "$period_add" --argjson pd "$period_del" \
             --argjson bc "${total_cost:-0}" --argjson ba "${total_add:-0}" --argjson bd "${total_del:-0}" '
      .history = (.history // [])
      | (if (.history | last | .end) == $en then .
         else .history += [{start:$st, end:$en, cost:$pc, add:$pa, del:$pd}] end)
      | .anchor = $en
      | .baseline_cost = $bc | .baseline_add = $ba | .baseline_del = $bd' "$CYCLE_DB" 2>/dev/null)
    [ -n "$tmp" ] && printf '%s' "$tmp" > "$CYCLE_DB"
    base_cost="$total_cost" base_add="$total_add" base_del="$total_del"
    cyc_anchor="$new_anchor"   # window start is now the advanced anchor
  fi

  month_cost=$(awk -v a="$total_cost" -v b="$base_cost" 'BEGIN{d=a-b; if(d<0)d=0; printf "%.2f", d}')
  month_add=$(( total_add - base_add )); [ "$month_add" -lt 0 ] && month_add=0
  month_del=$(( total_del - base_del )); [ "$month_del" -lt 0 ] && month_del=0
  # Time until this month's reset (anchor + 1 month), same format as 7d.
  cyc_reset=$(date -v+1m -r "$cyc_anchor" +%s 2>/dev/null || date -d "@$cyc_anchor +1 month" +%s 2>/dev/null)
fi

MONEY_GREEN='\033[38;2;133;187;101m'
TOTAL_ADD_C='\033[38;2;110;200;160m'   # softer teal-green, distinct from session +
TOTAL_DEL_C='\033[38;2;230;140;110m'   # softer coral, distinct from session -
total_part=""
if [ -n "$total_cost" ]; then
  total_part="${MONEY_GREEN}$(printf '$%.2f' "$month_cost")${RESET} ${DIM}|${RESET} ${TOTAL_ADD_C}+${month_add}${RESET} ${TOTAL_DEL_C}-${month_del}${RESET}"
  [ -n "$cyc_reset" ] && total_part="${total_part} ${DIM}|${RESET} ${DIM}$(fmt_reset "$cyc_reset")${RESET}"
fi

# ── Code velocity ──
velocity="${GREEN}+${lines_add}${RESET} ${RED}-${lines_del}${RESET}"

# ── Line 1: repo, branch ──
line1=""
[ -n "$repo" ] && line1="${BOLD}$(rgb 217 119 87)${repo}${RESET}"
[ -n "$branch" ] && line1="${line1:+$line1 }${BOLD}${CYAN}(${branch})${RESET}"

# ── Context + daily usage bars ──
LABEL='\033[1;97m'
bar_ctx="${LABEL}ctx${RESET} ${ctx_part}"
bar_5h="${LABEL}5h ${RESET} ${usage_part}"
bar_7d="${LABEL}7d ${RESET} ${week_part}"

# ── Line 3: cost, velocity, model ──
line3="${cost_part}"
line3="${line3} ${DIM}|${RESET} ${velocity}"
line3="${line3} ${DIM}|${RESET} ${MAGENTA}${model}${RESET}"

out="$line1 $line3"
out="${out}\n\n${bar_ctx}\n${bar_5h}\n${bar_7d}"
[ -n "$total_part" ] && out="${out}\n${total_part}"
printf '%b' "$out"
