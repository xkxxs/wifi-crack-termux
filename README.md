# WiFi Crack Termux

WiFi dictionary brute-force tool for Android (Termux + Root)

## Features

- Scan nearby WiFi networks
- Brute-force passwords from dictionary file
- Auto-detect encryption type (WPA2/WPA3/WEP)
- Fast connection check via `cmd wifi`
- Progress display with speed & ETA

## Requirements

- Android phone with root access
- Termux installed
- `cmd wifi` command available (requires root)

## Usage

```bash
# Interactive mode
wifi-crack

# Quick mode - specify target
wifi-crack -t <SSID> [BSSID] [encryption] [dictionary]
```

### Interactive Mode

1. Run `wifi-crack`
2. Select option `1` to scan
3. Choose target network from list
4. Wait for password to be found

### Quick Mode

```bash
wifi-crack -t MINI 50:88:11:7b:b5:3c wpa2 ~/dict.txt
```

## Dictionary

Place your dictionary file at `~/dict.txt` or specify a custom path.

Supports any text file with one password per line.

## Installation

```bash
# Clone the repo
git clone https://github.com/xkxxs/wifi-crack-termux.git
cd wifi-crack-termux

# Make executable
chmod +x wifi-crack.sh

# Create shortcut (optional)
cp wifi-crack.sh ~/wifi-crack.sh
```

## Notes

- Each password attempt takes ~5 seconds
- Use a good dictionary for faster results
- Script automatically disconnects after finding password
- Results saved in `~/wifi-results/`
