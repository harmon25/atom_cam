# AGENTS.md

Elixir app targeting **AtomVM on ESP32-S3** (XIAO ESP32-S3 Sense, with camera + SD). This is *not* a normal BEAM project — it is cross-compiled to AtomVM bytecode and flashed to a device.

## Toolchain quirks

- Requires **Elixir 1.19 / OTP 28**, **ESP-IDF v5.5.4** (sourced via `get_idf`), and an AtomVM firmware tree at `~/Dev/AtomVM` already built with `ATOMVM_ELIXIR_SUPPORT=on` for `esp32s3`. See `README.md` for the one-time firmware build.
- Only the AtomVM-supported subset of Elixir/OTP is available at runtime. Do **not** add code that pulls in `:crypto`, `File`, `Path`, `Logger` backends, GenServer-heavy supervision trees, or other modules not present in AtomVM. File I/O goes through `:atomvm.posix_*` (see `lib/atom_cam/storage.ex`).
- Strings passed to AtomVM POSIX calls must be **flat charlists**, not binaries or iolists. Use `Storage.sd_path/1` to build SD card paths.
- `@compile {:no_warn_undefined, [:atomvm]}` is used because `:atomvm`, `:esp32cam`, and `:camera_scanner` only exist on-device.

## Build / flash

```bash
get_idf                 # must be sourced in every shell
mix deps.get            # one-time
mix atomvm.packbeam     # build .avm bundle (atom_cam.avm, deps.avm, priv.avm at repo root)
mix atomvm.esp32.flash --port /dev/ttyACM0 --baud 460800   # flash to 0x250000 (set in mix.exs)
idf.py -p /dev/ttyACM0 monitor    # serial console (USB Serial/JTAG, same port as flash)
```

`mix atomvm.*` tasks come from the `:exatomvm` dep. There is no `mix compile` → device cycle other than `packbeam` + `flash`.

## Entry point

`AtomCam.start/0` (`lib/atom_cam.ex`) is the boot function (`atomvm: [start: AtomCam, ...]` in `mix.exs`). Board is hard-coded to `:esp32s3_xiao`.

Boot flow: start pubsub → WiFi connect → camera init → mount SD card → start HTTP server on port 80 → sleep forever.

The boot process holds the SD card mount resource in `keep_alive/1` — this is critical because the AtomVM `MountedFS` NIF resource has a destructor that unmounts the filesystem when garbage collected. Discarding the reference silently unmounts SD.

## Web interface

HTTP server runs on port 80 (single-threaded, `atomvm_httpd`). Dynamic routes are handled by `AtomCam.HttpHandler`; static HTML is served by `httpd_file_handler` from the `priv/` directory.

| Method | Path | Handler | Description |
|--------|------|---------|-------------|
| GET | `/` | `httpd_file_handler` | Serves `priv/index.html` — live camera view + "Capture to SD" button + Gallery link |
| GET | `/gallery.html` | `httpd_file_handler` | Serves `priv/gallery.html` — client-side gallery (fetches `/api/images`) |
| GET | `/snapshot` | `AtomCam.HttpHandler` | Live JPEG capture (image/jpeg, zero-copy with `:binary.copy`) |
| POST | `/capture` | `AtomCam.HttpHandler` | Capture frame to SD card, returns JSON `{ok, file}` (retries up to 3x) |
| GET | `/api/images` | `AtomCam.HttpHandler` | List saved `.jpg` files on SD card, returns JSON `{images: [...]}` |
| GET | `/images/<file>` | `AtomCam.HttpHandler` | Serve a JPEG file from SD card |
| DELETE | `/images/<file>` | `AtomCam.HttpHandler` | Delete a file from SD card, returns JSON |

### Static HTML in `priv/`

HTML pages live in `priv/` and are bundled into `priv.avm` by `mix atomvm.packbeam` (see `deps/exatomvm/lib/mix/tasks/packbeam.ex`). At runtime, `httpd_file_handler` reads them via `atomvm:read_priv(:atom_cam, path)`.

The routing in `atom_cam.ex` registers prefix routes for all dynamic endpoints first, then falls through to the file handler catch-all:

```elixir
routes = [
  {[<<"snapshot">>], handler},
  {[<<"capture">>],  handler},
  {[<<"images">>],   handler},
  {[<<"api">>],      handler},
  {[], AtomvmHttpd.file_handler_config(:atom_cam)}   # catch-all → priv/
]
```

The file handler automatically resolves `GET /` to `priv/index.html` (documented in `deps/atomvm_httpd/README.md`).

## Module overview

| Module | File | Purpose |
|--------|------|---------|
| `AtomCam` | `lib/atom_cam.ex` | Boot entrypoint, orchestrates startup |
| `AtomCam.Camera` | `lib/atom_cam/camera.ex` | Camera init (PSRAM DMA, sensor controls, warm-up) and capture |
| `AtomCam.Storage` | `lib/atom_cam/storage.ex` | SD card mount/unmount, file read/write/list/delete via POSIX |
| `AtomCam.HttpHandler` | `lib/atom_cam/http_handler.ex` | Dynamic HTTP routes: snapshot, capture-to-SD with retry, `/api/images` JSON list, image serve/delete |
| `AtomCam.Wifi` | `lib/atom_cam/wifi.ex` | WiFi provisioning (captive portal AP on first boot) |

## Pitfalls learned the hard way

### SD card mount resource GC
AtomVM's `esp:mount` returns a NIF resource with a destructor that calls `esp_vfs_fat_sdcard_unmount`. If the Erlang term holding the resource is GC'd, the SD card silently unmounts. The mount reference **must** be held alive for the lifetime of the app (see `keep_alive/1` in `atom_cam.ex`).

### FAT 8.3 filenames
The SD card uses FAT without long filename support. File and directory names must fit the **8.3 format** (8 chars + 3 char extension). Filenames like `photo-12345.jpg` (>8 chars) cause `EINVAL` from `posix_open`/`posix_write`. Use short names like `P12345.JPG`.

### posix_readdir return format
`:atomvm.posix_readdir/1` returns `{:ok, {:dirent, inode, name_binary}}` (not `{:ok, name}`). The name is a **binary**, not a charlist. Convert with `:erlang.binary_to_list/1`.

### Zero-copy frame binaries
`esp32cam:frame_binary/1` returns a binary backed by the PSRAM framebuffer. After `release_frame/1`, the PSRAM region can be reused, corrupting the binary mid-transfer. Always call `:binary.copy/1` before releasing the frame if the binary will be used after release (e.g., HTTP response sent in chunks).

For SD card writes, prefer `esp32cam:capture/0` (returns a regular copied binary) over the `capture_frame` + `frame_binary` + `release_frame` lifecycle.

### Camera reliability (OV3660 / PSRAM DMA / XGA)
The OV3660 sensor in PSRAM DMA mode at XGA (1024x768) frequently fails with `NO-EOI - JPEG end marker missing` errors, especially in the first 30-60s after boot. The camera warm-up frames often all fail. The capture endpoint retries up to 3 times to work around this. The live stream's onload/onerror chain pattern naturally retries.

## Tests

`test/atom_cam_test.exs` is a placeholder. There are no host-runnable tests for on-device behavior; `mix test` only exercises pure helpers if any exist. Don't assume `mix test` validates device code.

## Conventions

- Keep new modules AtomVM-safe: prefer `:erlang`, `:io`, `:lists`, `:atomvm` calls over Elixir stdlib wrappers that may not be implemented.
- Charlist literals use `~c"..."`.
- SD card filenames must fit FAT 8.3 format.
- Format with `mix format` (`.formatter.exs` covers `lib`, `test`, `config`).
