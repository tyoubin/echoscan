# EchoScan

EchoScan is a lightweight, read-only macOS CLI that detects software updates by comparing locally installed apps against the Homebrew Cask catalog. It never installs or upgrades anything.

## Features

- Uses `mdfind` (Spotlight) to list apps in `/Applications` quickly.
- Excludes App Store apps (including iOS/iPad apps on macOS) and Apple-bundled apps.
- Fetches Homebrew Cask metadata with ETag/Last-Modified caching.
- Compares versions using numeric segment logic.
- Falls back to Sparkle feeds (`SUFeedURL`) when no cask match exists.
- Color-coded table output and a compact summary.
- Detailed progress logs to stderr by default.

## Install / Build

```bash
swift build
```

Binary location (debug build):

```
.build/debug/echoscan
```

GitHub Actions builds a universal macOS binary on every push. You can download the latest from the workflow run artifacts.

## Usage

```bash
echoscan
```

Options (accepted for future compatibility):

- `--no-color` disable ANSI color output
- `--quiet` reduce stderr output
- `--verbose` extra diagnostics to stderr
- `-h`, `--help` show help

## Output

EchoScan shows only apps that are not up-to-date. Results are ordered by status:

1. `Update` — exact cask bundle-id match shows a newer version.
2. `Possible` — name-based match (non-verbatim) shows a newer version.
3. `Check` — could not confidently compare (missing version or feed).

A summary line is printed at the end:

```
X update(s) available, Y possible update(s), Z check(s) required, N shown.
```

## Logging (stderr)

EchoScan emits timestamped progress events to stderr, for example:

```
2026-03-16T10:21:03Z EchoScan starting
2026-03-16T10:21:04Z Fetching Homebrew cask index
2026-03-16T10:21:05Z Searching /Applications via mdfind
```

Per-app scan logs (stderr) use this format:

```
TIMESTAMP Scanning <App>, current version <Version>, remote found in cask|sparkle
```

## Cache

The Homebrew cask JSON and metadata are cached at:

```
~/.echoscan/
  cask.json
  cask.meta.json
```

## Notes

- Cask versions containing build numbers (e.g., `4.1.20,778`) are trimmed to the first segment (`4.1.20`) for comparison.
- App Store apps are detected via receipt/metadata files and skipped.
- Apple-bundled apps are skipped by bundle identifier (`com.apple.*`).
