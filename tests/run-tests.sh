#!/usr/bin/env bash
# Tests for temp-watch.sh. They feed it made-up data.json files through file:// URLs, so they need no
# LibreHardwareMonitor, no admin rights and no particular hardware. Takes about 20 seconds.
# usage: bash tests/run-tests.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TOOL="$HERE/../temp-watch.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

url() { if command -v cygpath >/dev/null 2>&1; then echo "file:///$(cygpath -m "$1")"; else echo "file://$1"; fi; }
ok() { pass=$((pass + 1)); echo "ok    $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }
has() { # NAME OUTPUT TEXT...: every TEXT appears in OUTPUT
  local name=$1 out=$2; shift 2
  for t in "$@"; do
    case $out in *"$t"*) ;; *) bad "$name (missing: $t)" "$out"; return ;; esac
  done
  ok "$name"
}
code() { # NAME WANT GOT OUTPUT
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (exit $3, wanted $2)" "$4"; fi
}

sensor() { # ID TEXT VALUE SENSORID TYPE
  printf '{"id":%s,"Text":"%s","Min":"%s","Value":"%s","Max":"%s","SensorId":"%s","Type":"%s","RawMin":"x","RawValue":"x","RawMax":"x","ImageURL":"images/transparent.png","Children":[]}' \
    "$1" "$2" "$3" "$3" "$3" "$4" "$5"
}
intel() { # CPU-TEMP CORE-MAX WATTS LOAD GPU-TEMP -> a data.json shaped like LibreHardwareMonitor's
  printf '{"id":0,"Text":"Sensor","Min":"Min","Value":"Value","Max":"Max","ImageURL":"","Children":[{"id":1,"Text":"TEST-PC","Min":"","Value":"","Max":"","ImageURL":"images_icon/computer.png","Children":['
  sensor 10 "CPU Package" "$3 W" /intelcpu/0/power/0 Power; printf ','
  sensor 11 "Core Max" "$2 \\u00B0C" /intelcpu/0/temperature/0 Temperature; printf ','
  sensor 12 "CPU Package" "$1 \\u00B0C" /intelcpu/0/temperature/14 Temperature; printf ','
  sensor 13 "CPU Total" "$4 %%" /intelcpu/0/load/0 Load; printf ','
  sensor 14 "GPU Core" "$5 %%" /gpu-nvidia/0/load/0 Load; printf ','
  sensor 15 "GPU Core" "$5 \\u00B0C" /gpu-nvidia/0/temperature/0 Temperature
  printf ']}]}'
}

intel 36.0 38.0 81.5 100.0 40.0 >"$TMP/intel.json"
intel 36,5 38,0 81,5 100,0 40,0 >"$TMP/comma.json"
{
  printf '{"id":0,"Text":"Sensor","Min":"Min","Value":"Value","Max":"Max","ImageURL":"","Children":['
  sensor 1 "Core (Tctl/Tdie)" "52.3 \\u00B0C" /amdcpu/0/temperature/2 Temperature; printf ','
  sensor 2 "Package" "65.0 W" /amdcpu/0/power/0 Power
  printf ']}'
} >"$TMP/amd.json"
I=$(url "$TMP/intel.json")

out=$(bash "$TOOL" --list --url "$I" 2>&1); rc=$?
has "--list prints id, type, name and value" "$out" \
  $'/intelcpu/0/temperature/14\tTemperature\tCPU Package\t36.0 deg C' $'/intelcpu/0/power/0\tPower\tCPU Package\t81.5 W'
code "--list exits 0" 0 "$rc" "$out"

out=$(bash "$TOOL" --url "$I" --for 2 --sample 1 --every 1 --csv "$TMP/a.csv" 2>&1); rc=$?
has "a watch reads every default sensor" "$out" "CPU 36.0 C" "hottest core 38.0 C" "81.5 W" "load 100.0 %" "GPU 40.0 C"
has "a watch picks power, not temperature, for the CPU Package watts" "$out" "81.5 W (peak 81.5)"
has "--for ends the watch with a whole-watch line" "$out" "whole watch:" "at 99 % load or more" "finished: --for 2 s passed"
code "a finished watch exits 0" 0 "$rc" "$out"
rows=$(wc -l <"$TMP/a.csv"); hdr=$(head -n 1 "$TMP/a.csv"); row=$(sed -n 2p "$TMP/a.csv")
if [ "$hdr" = "time,cpu_temp_c,core_max_c,cpu_power_w,cpu_load_pct,gpu_temp_c" ] && [ "$rows" -ge 2 ] &&
  [[ $row =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2},36\.0,38\.0,81\.5,100\.0,40\.0$ ]]; then ok "--csv writes a header and one row per sample"
else bad "--csv writes a header and one row per sample" "$(cat "$TMP/a.csv")"; fi

out=$(bash "$TOOL" --url "$I" --for 1 --sample 1 --every 1 --alert 37 --gpu-alert 40 2>&1)
has "--alert and --gpu-alert print ALERT lines" "$out" "ALERT" "CPU at 36.0 C, hottest core 38.0 C (limit 37 C)" "GPU at 40.0 C (limit 40 C)"
out=$(bash "$TOOL" --url "$I" --for 1 --sample 1 --every 1 2>&1)
case $out in *ALERT*) bad "no ALERT below the limits" "$out" ;; *) ok "no ALERT below the limits" ;; esac

printf '   Compiling foo v0.1.0\ntest result: ok. 3 passed; 0 failed\n' >"$TMP/job.log"
( sleep 2; echo "cleanup: done" >>"$TMP/job.log" ) &
out=$(bash "$TOOL" --url "$I" --sample 1 --every 600 --log "$TMP/job.log" --end '^cleanup:' --for 30 2>&1); rc=$?
wait
has "--end stops the watch when the log matches" "$out" "finished: the log matched --end"
has "--log puts the latest status line on the summary" "$out" "| test result: ok. 3 passed; 0 failed"
code "--end exits 0" 0 "$rc" "$out"

if command -v timeout >/dev/null 2>&1; then
  out=$(timeout -s INT 3 bash "$TOOL" --url "$I" --sample 1 --every 600 2>&1)
  has "Ctrl+C ends with the closing lines" "$out" "whole watch:" "finished: stopped"
else
  echo "skip  Ctrl+C ends with the closing lines (no timeout command here)"
fi

out=$(bash "$TOOL" --url "$(url "$TMP/comma.json")" --for 1 --sample 1 2>&1)
has "decimal commas are read as decimal points" "$out" "CPU 36.5 C" "81.5 W"

out=$(bash "$TOOL" --url "$I" --cpu-temp /intelcpu/0/temperature/0 --for 1 --sample 1 2>&1)
has "a SensorId picks that sensor" "$out" "CPU 38.0 C"
out=$(bash "$TOOL" --url "$(url "$TMP/amd.json")" --cpu-temp 'Core (Tctl/Tdie)' --cpu-power Package --for 1 --sample 1 2>&1)
has "names with brackets and slashes are taken literally" "$out" "CPU 52.3 C" "65.0 W"
has "a sensor that isn't there shows as -" "$out" "GPU - C" "hottest core - C"

out=$(bash "$TOOL" --url "$(url "$TMP/missing.json")" --list 2>&1); rc=$?
code "--list without LibreHardwareMonitor exits 3" 3 "$rc" "$out"
out=$(bash "$TOOL" --url "$(url "$TMP/missing.json")" --for 1 --sample 1 2>&1); rc=$?
has "a watch without LibreHardwareMonitor says so" "$out" "temperatures unavailable"
code "... and still finishes normally" 0 "$rc" "$out"

for args in "--bogus" "--every 0" "--every abc" "--sample -5" "--alert hot" "--end x" "--log f --end (" "--every"; do
  # shellcheck disable=SC2086
  out=$(bash "$TOOL" --url "$I" $args 2>&1); rc=$?
  code "bad arguments are refused: $args" 2 "$rc" "$out"
done
out=$(bash "$TOOL" --help 2>&1); rc=$?
has "--help explains the options" "$out" "--every SECONDS" "--list"
code "--help exits 0" 0 "$rc" "$out"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
