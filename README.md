# temp-watch

Reports your CPU and GPU temperatures while a long job runs: a line every few minutes with the peaks since the line
before, an alert as soon as something gets hot, and every sample in a CSV if you want one.

I wrote it to watch a PC while a long build or test run was going on, and I was often away from the screen. One line every five
minutes is easy to read from a phone. It also shows the job's latest status (`Compiling …`, `test result: …`) on the
same line, so a single line tells you both how hot the machine is and how far the job has got.

## Thanks to LibreHardwareMonitor

All the readings come from [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor), which,
in its own words:

> Libre Hardware Monitor is free software that can monitor the temperature sensors, fan speeds, voltages, load and
> clock speeds of your computer.

temp-watch only reads the `data.json` page that LibreHardwareMonitor's web server publishes. Reading the sensors is all
their work, so thank you to the LibreHardwareMonitor team and contributors. LibreHardwareMonitor is under the Mozilla
Public License 2.0, and no part of it is copied here.

## What it needs

- **LibreHardwareMonitor, running, with its web server on:** *Options → Remote Web Server → Run* (port 8085 by
  default). Run it as administrator, or the CPU temperatures stay empty.
- **bash with `curl`, `grep`, `sed` and `awk`:** Git Bash on Windows has all of them.

A word on that web server: LibreHardwareMonitor serves `data.json` to any machine that can reach port 8085, with no
password. If you don't want your network to see your sensors, block the port in the firewall for anything but this
PC. temp-watch only reads from it and never changes a setting.

## Run it

Watch for an hour, a line every 5 minutes:

```bash
./temp-watch.sh --for 3600
```

Watch a job until it ends. Have the job write a last line you can wait for, and point temp-watch at its log:

```bash
( cargo test --workspace > job.log 2>&1; echo "JOB DONE $?" >> job.log ) &
./temp-watch.sh --log job.log --end '^JOB DONE' --csv temps.csv
```

Ctrl+C stops it at any time, with the same closing lines as a normal finish.

## Reading the output

```text
21:00 CPU 35.0 C (peak 35.0), hottest core 36.0 C (peak 36.0), 79.2 W (peak 79.2), load 58.3 %, GPU 36.0 C (peak 36.0) | Compiling foo v0.1.0
21:05 CPU 40.0 C (peak 42.0), hottest core 41.0 C (peak 42.0), 91.0 W (peak 93.6), load 100.0 %, GPU 37.0 C (peak 38.0) | test result: ok. 1776 passed; 0 failed
whole watch: 21 samples over 320 s, 18 at 99 % load or more; CPU peak 42.0 C, hottest core 42.0 C, 93.6 W, GPU peak 38.0 C
finished: the log matched --end
```

Each line has the current reading and, in brackets, the highest one since the line before. CPU is the package
temperature, hottest core is the hottest single core, then come the CPU's power and load and the GPU temperature. A
`-` means that sensor wasn't found. The first line comes right away, so you know it's working. An `ALERT` line comes
the moment the CPU reaches `--alert` (80 °C by default) or the GPU reaches `--gpu-alert` (85 °C). It comes at most once per
summary period, so a long hot spell doesn't flood the output.

The CSV has one row per sample: `time,cpu_temp_c,core_max_c,cpu_power_w,cpu_load_pct,gpu_temp_c`.

## Options

| Option | What it does |
|---|---|
| `--every SECONDS` | a summary line this often (300) |
| `--sample SECONDS` | pause between sensor reads (15) |
| `--for SECONDS` | stop after this long |
| `--log FILE` | the job's log: its latest status line ends each summary |
| `--end REGEX` | stop when a line of `--log` matches |
| `--status REGEX` | which log lines count as status (default: cargo's `Compiling`, `Running`, `test result:` …) |
| `--csv FILE` | append every sample, with a header when the file is new |
| `--alert C`, `--gpu-alert C` | when to print an `ALERT` (80, 85) |
| `--cpu-temp`, `--core-max`, `--cpu-power`, `--cpu-load`, `--gpu-temp` | which sensor each column reads |
| `--url URL` | where `data.json` is (`http://127.0.0.1:8085/data.json`) |
| `--list` | print every sensor and exit |

`./temp-watch.sh --help` prints the same list.

## Other machines and sensors

The defaults are the names LibreHardwareMonitor gives on an Intel CPU with an NVIDIA graphics card: *CPU Package*,
*Core Max*, *CPU Total* and *GPU Core*. Other hardware has other names. List yours, then pass a name or a SensorId:

```bash
./temp-watch.sh --list | grep -i temperature
./temp-watch.sh --cpu-temp 'Core (Tctl/Tdie)' --core-max '' --for 600
./temp-watch.sh --gpu-temp /gpu-amd/0/temperature/0 --for 600
```

A name matches the first sensor of that name and the column's type (temperature, power or load). With two CPUs or
two graphics cards, use the SensorId. An empty name (`--core-max ''`) leaves that column out.

## What it can't tell you

- **Anything between samples.** A spike shorter than `--sample` can be missed. The peaks are the highest of the
  samples, not LibreHardwareMonitor's own *Max* column, which counts from when that app started. A read itself
  takes about a second in Git Bash on a busy machine, so a sample comes every `--sample` seconds plus that.
- **Whether the readings are right.** They are what LibreHardwareMonitor reads from your hardware.
- **Fahrenheit.** If LibreHardwareMonitor is set to show °F, the numbers are °F, but the lines still say C and the
  alert limits are compared as they are.
- **Fans, voltages, clocks.** These columns aren't read. `--list` shows them.

## Exit status

`0` when the watch finished (`--end`, `--for` or Ctrl+C), `2` for bad arguments, `3` when `--list` can't reach
LibreHardwareMonitor. While watching, a missing LibreHardwareMonitor gives "temperatures unavailable" lines instead
of stopping, so it can be started after temp-watch.

## Tests

```bash
bash tests/run-tests.sh
```

They feed temp-watch made-up `data.json` files, so they don't need LibreHardwareMonitor or any particular hardware.

## Licence

MIT, see [LICENSE](LICENSE).
