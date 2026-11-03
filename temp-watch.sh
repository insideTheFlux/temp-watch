#!/usr/bin/env bash
# temp-watch: CPU and GPU temperatures from LibreHardwareMonitor while a long job runs.
# One summary line every few minutes (with the peaks since the line before), an ALERT line at once when a
# temperature crosses a limit, and every sample in a CSV if you want it. Read-only: it only reads
# LibreHardwareMonitor's data.json. See README.md.
set -u

VERSION=1.0.0
URL=http://127.0.0.1:8085/data.json
EVERY=300
SAMPLE=15
ALERT=80
GPU_ALERT=85
FOR=0
LOG=
END=
CSV=
STATUS='^(test result:|[[:space:]]*(Compiling|Checking|Finished|Running|Building|Testing) )'
CPU_TEMP='CPU Package'
CORE_MAX='Core Max'
CPU_POWER='CPU Package'
CPU_LOAD='CPU Total'
GPU_TEMP='GPU Core'
LIST=0

usage() {
  cat <<'EOF'
temp-watch: CPU and GPU temperatures from LibreHardwareMonitor while a long job runs.

usage: temp-watch.sh [options]
       temp-watch.sh --list [--url URL]

Watching
  --every SECONDS     a summary line this often (default 300)
  --sample SECONDS    pause between sensor reads (default 15); peaks come from these samples
  --for SECONDS       stop after this long (default: until --end matches, or Ctrl+C)
  --log FILE          the job's log: its latest status line goes at the end of each summary
  --end REGEX         stop when a line of --log matches this (extended regex)
  --status REGEX      which --log lines count as status (default: cargo's Compiling/Running/test result lines)
  --csv FILE          append every sample to this CSV (a header is written when the file is new)
  --alert C           print an ALERT line when the CPU reaches this (default 80)
  --gpu-alert C       the same for the GPU (default 85)

Sensors (a name as --list prints it, or a SensorId that starts with /; '' leaves the column out)
  --cpu-temp SENSOR   default "CPU Package" (temperature)
  --core-max SENSOR   default "Core Max" (temperature)
  --cpu-power SENSOR  default "CPU Package" (power)
  --cpu-load SENSOR   default "CPU Total" (load)
  --gpu-temp SENSOR   default "GPU Core" (temperature)

Other
  --url URL           where data.json is (default http://127.0.0.1:8085/data.json)
  --list              print every sensor (id, type, name, value) and exit
  --version, --help

Exit status: 0 finished, 2 bad arguments, 3 LibreHardwareMonitor not reachable (with --list).
EOF
}

die() { echo "temp-watch: $*" >&2; exit 2; }
need_count() { [[ $2 =~ ^[0-9]+$ ]] && [ "$2" -gt 0 ] && [ "$2" -le 86400000 ] || die "$1 needs a whole number of seconds above 0, not '$2'"; }
need_degrees() { [[ $2 =~ ^[0-9]+([.][0-9]+)?$ ]] || die "$1 needs a temperature in degrees, not '$2'"; }
need_regex() { printf '' | grep -E -- "$2" >/dev/null 2>&1; [ $? -ne 2 ] || die "$1: '$2' is not a valid extended regex"; }

while [ $# -gt 0 ]; do
  case $1 in
    -h | --help) usage; exit 0 ;;
    --version) echo "temp-watch $VERSION"; exit 0 ;;
    --list) LIST=1; shift; continue ;;
  esac
  [ $# -ge 2 ] || die "$1 needs a value (see --help)"
  case $1 in
    --every) need_count "$1" "$2"; EVERY=$2 ;;
    --sample) need_count "$1" "$2"; SAMPLE=$2 ;;
    --for) need_count "$1" "$2"; FOR=$2 ;;
    --log) LOG=$2 ;;
    --end) need_regex "$1" "$2"; END=$2 ;;
    --status) need_regex "$1" "$2"; STATUS=$2 ;;
    --csv) CSV=$2 ;;
    --alert) need_degrees "$1" "$2"; ALERT=$2 ;;
    --gpu-alert) need_degrees "$1" "$2"; GPU_ALERT=$2 ;;
    --cpu-temp) CPU_TEMP=$2 ;;
    --core-max) CORE_MAX=$2 ;;
    --cpu-power) CPU_POWER=$2 ;;
    --cpu-load) CPU_LOAD=$2 ;;
    --gpu-temp) GPU_TEMP=$2 ;;
    --url) URL=$2 ;;
    *) die "unknown option '$1' (see --help)" ;;
  esac
  shift 2
done

[ -n "$END" ] && [ -z "$LOG" ] && die "--end needs --log (the file to look for it in)"
for tool in curl grep sed awk; do
  command -v "$tool" >/dev/null 2>&1 || die "needs $tool on the PATH"
done

# R: one line per sensor, "Text":…,"Min":…,"Value":…,"Max":…,"SensorId":…,"Type":… (empty when unreachable)
R=
fetch() {
  local j
  j=$(curl -s -f -m 5 -- "$URL" 2>/dev/null) || j=
  R=$(printf '%s' "$j" | grep -oE '"Text":"[^"]*","Min":"[^"]*","Value":"[^"]*","Max":"[^"]*","SensorId":"[^"]*","Type":"[^"]*"')
}

# The five readings from R, as numbers, "-" for one that isn't there: cpu core-max watts load gpu. A sensor that
# starts with / is a SensorId; anything else is a name, of the column's type. The first match wins. "36.0 °C",
# "80,5 W" and "51.8 %" read as 36.0, 80.5 and 51.8. One awk for all five keeps a sample quick in Git Bash.
read_all() {
  printf '%s\n' "$R" | awk -v s1="$CPU_TEMP" -v s2="$CORE_MAX" -v s3="$CPU_POWER" -v s4="$CPU_LOAD" -v s5="$GPU_TEMP" '
    function field(line, key,    i, rest) {
      i = index(line, "\"" key "\":\""); if (!i) return ""
      rest = substr(line, i + length(key) + 4); return substr(rest, 1, index(rest, "\"") - 1)
    }
    function num(v) {
      if (!match(v, /^-?[0-9]+([.,][0-9]+)?/)) return "-"
      v = substr(v, 1, RLENGTH); gsub(/,/, ".", v); return v
    }
    BEGIN {
      s[1] = s1; s[2] = s2; s[3] = s3; s[4] = s4; s[5] = s5
      t[1] = "Temperature"; t[2] = "Temperature"; t[3] = "Power"; t[4] = "Load"; t[5] = "Temperature"
    }
    {
      text = field($0, "Text"); id = field($0, "SensorId"); type = field($0, "Type")
      for (k = 1; k <= 5; k++) {
        if ((k in got) || s[k] == "") continue
        if (substr(s[k], 1, 1) == "/" ? id == s[k] : (text == s[k] && type == t[k])) got[k] = num(field($0, "Value"))
      }
    }
    END { for (k = 1; k <= 5; k++) printf "%s%s", ((k in got) ? got[k] : "-"), (k < 5 ? " " : "\n") }'
}

list_sensors() {
  fetch
  [ -n "$R" ] || { echo "temp-watch: LibreHardwareMonitor is not reachable at $URL (is its Remote Web Server running?)" >&2; exit 3; }
  printf '%s\n' "$R" |
    sed -E 's/^"Text":"([^"]*)","Min":"[^"]*","Value":"([^"]*)","Max":"[^"]*","SensorId":"([^"]*)","Type":"([^"]*)"$/\3\t\4\t\1\t\2/' |
    sed -e 's/\\u00B0/deg /g; s/\\u00b0/deg /g'
}

[ "$LIST" = 1 ] && { list_sensors; exit 0; }

status() {
  [ -n "$LOG" ] || return 0
  local line
  line=$(grep -E -- "$STATUS" "$LOG" 2>/dev/null | tail -n 1 | sed -E 's/^[[:space:]]+//' | cut -c1-90)
  printf ' | %s' "${line:-(nothing yet)}"
}

if [ -n "$CSV" ] && [ ! -s "$CSV" ]; then
  echo "time,cpu_temp_c,core_max_c,cpu_power_w,cpu_load_pct,gpu_temp_c" >>"$CSV" || die "can't write $CSV"
fi

# current readings, peaks since the last summary line (p_*) and over the whole watch (a_*); "-" = none
cpu=- core=- w=- load=- gpu=-
p_cpu=- p_core=- p_w=- p_gpu=-
a_cpu=- a_core=- a_w=- a_gpu=-
samples=0 since=0 busy=0 cpu_alerted=0 gpu_alerted=0 first=1
start=$SECONDS last=$SECONDS

# new peaks and flags from the current readings, in one awk:
# p_cpu p_core p_w p_gpu a_cpu a_core a_w a_gpu busy cpu-hot gpu-hot
update() {
  awk -v c="$cpu" -v k="$core" -v w="$w" -v l="$load" -v g="$gpu" \
    -v pc="$p_cpu" -v pk="$p_core" -v pw="$p_w" -v pg="$p_gpu" \
    -v ac="$a_cpu" -v ak="$a_core" -v aw="$a_w" -v ag="$a_gpu" -v A="$ALERT" -v GA="$GPU_ALERT" '
    function mx(a, b) { if (a == "-") return b; if (b == "-") return a; return (a + 0 > b + 0) ? a : b }
    function at(a, lim) { return a != "-" && a + 0 >= lim + 0 }
    BEGIN {
      print mx(c, pc), mx(k, pk), mx(w, pw), mx(g, pg), mx(c, ac), mx(k, ak), mx(w, aw), mx(g, ag),
        (at(l, 99) ? 1 : 0), ((at(c, A) || at(k, A)) ? 1 : 0), (at(g, GA) ? 1 : 0)
    }'
}

summary() {
  local now
  now=$(date +%H:%M)
  if [ "$cpu$core$w$load$gpu" = ----- ]; then
    echo "$now temperatures unavailable: LibreHardwareMonitor not reachable at $URL$(status)"
  else
    echo "$now CPU $cpu C (peak $p_cpu), hottest core $core C (peak $p_core), $w W (peak $p_w), load $load %, GPU $gpu C (peak $p_gpu)$(status)"
  fi
  p_cpu=- p_core=- p_w=- p_gpu=-
  since=0
  last=$SECONDS
}

finish() {
  # a closing summary only when a sample came in since the last one
  [ "$since" -gt 0 ] && summary
  echo "whole watch: $samples samples over $((SECONDS - start)) s, $busy at 99 % load or more; CPU peak $a_cpu C, hottest core $a_core C, $a_w W, GPU peak $a_gpu C"
  echo "finished: $1"
  exit 0
}
trap 'finish "stopped"' INT TERM

csv() { [ "$1" = - ] || printf '%s' "$1"; }

while :; do
  fetch
  # all five in one read: an interrupt halfway leaves the last whole sample in place
  read -r cpu core w load gpu <<<"$(read_all)"

  if [ "$cpu$core$w$load$gpu" != ----- ]; then
    read -r p_cpu p_core p_w p_gpu a_cpu a_core a_w a_gpu is_busy cpu_hot gpu_hot <<<"$(update)"
    samples=$((samples + 1)) since=$((since + 1)) busy=$((busy + is_busy))
    [ -n "$CSV" ] && echo "$(date +%H:%M:%S),$(csv "$cpu"),$(csv "$core"),$(csv "$w"),$(csv "$load"),$(csv "$gpu")" >>"$CSV"
    if [ "$cpu_alerted" = 0 ] && [ "$cpu_hot" = 1 ]; then
      cpu_alerted=1
      echo "ALERT $(date +%H:%M:%S) CPU at $cpu C, hottest core $core C (limit $ALERT C)"
    fi
    if [ "$gpu_alerted" = 0 ] && [ "$gpu_hot" = 1 ]; then
      gpu_alerted=1
      echo "ALERT $(date +%H:%M:%S) GPU at $gpu C (limit $GPU_ALERT C)"
    fi
  fi

  if [ "$first" = 1 ] || [ $((SECONDS - last)) -ge "$EVERY" ]; then
    summary
    first=0
    # an alert is said once per summary period, so a long hot spell doesn't flood the output
    cpu_alerted=0 gpu_alerted=0
  fi

  reason=
  [ -n "$END" ] && grep -qE -- "$END" "$LOG" 2>/dev/null && reason="the log matched --end"
  [ -z "$reason" ] && [ "$FOR" -gt 0 ] && [ $((SECONDS - start)) -ge "$FOR" ] && reason="--for $FOR s passed"
  [ -n "$reason" ] && finish "$reason"

  sleep "$SAMPLE"
done
