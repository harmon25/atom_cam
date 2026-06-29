# AtomCam

WiFi camera with web interface, running on **AtomVM** on the **XIAO ESP32-S3 Sense** (OV3660 camera + microSD card slot).

## Features

- **Live camera stream** at `http://<device-ip>/` with auto-refreshing JPEG viewer
- **Capture to SD card** button saves photos to the onboard microSD
- **Gallery browser** at `/gallery.html` lists saved photos with download and delete
- **Image serving** from SD card at `/images/<filename>`
- **WiFi provisioning** via captive portal AP on first boot

## Prerequisites

- **ESP-IDF v5.5.4** (installed to `~/.espressif`, sourced via `get_idf`)
- **AtomVM** source at `~/Dev/AtomVM` built with `ATOMVM_ELIXIR_SUPPORT=on` for `esp32s3`
- **Erlang/OTP 28** + **Elixir 1.19**
- XIAO ESP32-S3 Sense with OV3660 camera module and microSD card (FAT32 formatted)

## Firmware Build (one-time)

The ESP32-S3 must be flashed with AtomVM firmware featuring Elixir support and the `atomvm_esp32cam` driver:

```bash
# Source ESP-IDF
get_idf

# Build host tools and boot libraries
cd ~/Dev/AtomVM
mkdir -p build && cd build
cmake .. && make -j$(nproc)

# Build ESP32-S3 firmware with Elixir support
cd ~/Dev/AtomVM/src/platforms/esp32
idf.py -DATOMVM_ELIXIR_SUPPORT=on set-target esp32s3

# Enable PSRAM in menuconfig
idf.py menuconfig

# Build and flash
idf.py build
idf.py -p /dev/ttyACM0 flash
```

The console is configured for USB Serial/JTAG (not the physical UART pins), so the same `/dev/ttyACM0` port is used for both flashing and serial output.

## Build & Flash the App

```bash
get_idf

# Fetch dependencies (one-time)
mix deps.get

# Compile and pack into .avm
mix atomvm.packbeam

# Flash to the main.avm partition (0x250000)
mix atomvm.esp32.flash --port /dev/ttyACM0 --baud 460800
```

## Usage

After flashing, the device boots, connects to WiFi (or starts a captive portal AP named "AtomCam" on first boot), initializes the camera, mounts the SD card, and starts an HTTP server on port 80.

Open `http://<device-ip>/` in a browser to see the live camera view. Use the **Capture to SD** button to save photos, and click **Gallery** to browse, download, or delete saved images. Static HTML (`index.html`, `gallery.html`) is served from `priv/` via `httpd_file_handler`; dynamic endpoints (snapshot, capture, image list) are handled by `AtomCam.HttpHandler`.

## View Serial Output

```bash
# Requires a TTY (run in a real terminal):
idf.py -p /dev/ttyACM0 monitor

# Or using picocom:
picocom /dev/ttyACM0 -b 115200
```

## Architecture

| Module | File | Purpose |
|--------|------|---------|
| `AtomCam` | `lib/atom_cam.ex` | Boot entrypoint, orchestrates startup sequence |
| `AtomCam.Camera` | `lib/atom_cam/camera.ex` | Camera init (PSRAM DMA, sensor controls, warm-up) and capture |
| `AtomCam.Storage` | `lib/atom_cam/storage.ex` | SD card mount/unmount, file read/write/list/delete via POSIX |
| `AtomCam.HttpHandler` | `lib/atom_cam/http_handler.ex` | Dynamic HTTP routes: snapshot, capture-to-SD, `/api/images` JSON, image serve/delete |
| `AtomCam.Wifi` | `lib/atom_cam/wifi.ex` | WiFi provisioning (captive portal AP on first boot) |

## Known Issues

- The OV3660 sensor in PSRAM DMA mode at XGA resolution can take 30-90 seconds after boot before producing valid JPEG frames. The capture endpoint retries up to 3 times to compensate.
- The SD card uses FAT without long filename support. Filenames must fit the 8.3 format (e.g., `P12345.JPG`).
- The HTTP server is single-threaded. Large image transfers from SD card will briefly block other requests.

