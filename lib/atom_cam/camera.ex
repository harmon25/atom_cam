defmodule AtomCam.Camera do
  @compile {:no_warn_undefined, [:atomvm, :esp32cam]}

  @moduledoc """
  Camera lifecycle and capture for AtomCam.

  Owns the esp32cam init sequence. PSRAM DMA mode is intentionally disabled
  due to a confirmed driver bug (espressif/esp32-camera#775) that breaks
  JPEG EOI validation on OV3660 sensors. Frame buffers are still allocated
  in PSRAM via fb_location (the default), only the DMA transfer path is
  the standard one.

  After init, a warm-up burst lets the OV3660 AE/AWB converge before
  serving live frames.
  """

  @board Application.compile_env(:atom_cam, :board, :esp32s3_xiao)

  # Hardware config passed through to esp_camera_init (camera_config_t level).
  #
  # Key tuning for OV3660 stability:
  #   - SVGA (800x600) instead of XGA — smaller JPEG output avoids the
  #     sensor's internal compression buffer overflow that causes NO-EOI
  #     (JPEG end marker missing) errors.
  #   - jpeg_quality 15 — higher number = more compression = smaller output,
  #     giving the sensor JPEG encoder more headroom.
  #   - fb_count 2 — OV3660 needs dual frame buffers to prevent FB-OVF in
  #     continuous/streaming mode (one receives while the other is read).
  @hw_opts [
    board: @board,
    frame_size: :svga,
    jpeg_quality: 10,
    fb_count: 2,
    grab_mode: :when_empty,
    fb_location: :psram
  ]

  # Sensor-level controls applied via set_control after esp_camera_init.
  @sensor_opts [
    vflip: false,
    hmirror: false,
    auto_white_balance: false,
    awb_gain: false,
    wb_mode: :home
  ]

  # Warm-up frames to let the OV3660 AE/AWB converge after init.
  # The first few frames are often dark or colour-shifted.
  @warmup_frames 5

  # Delay in ms between warm-up capture-and-release cycles.
  # Gives the sensor JPEG encoder pipeline time to reset between frames.
  @warmup_delay_ms 100

  @doc """
  Initialise the camera with default hw + sensor options.
  Steps:
    1. esp32cam:init/1  — hardware init + sensor apply + warm-up.
    2. warm_up/0  — capture-and-discard frames to let AE/AWB settle.
  PSRAM DMA mode is intentionally NOT enabled — it has a confirmed driver
  bug (espressif/esp32-camera#775) that breaks JPEG EOI validation,
  causing persistent NO-EOI errors on the OV3660.
  Returns :ok or {:error, reason} from the first failing step.
  """
  def init, do: init([])

  @doc """
  Initialise with per-call overrides merged into the default hw + sensor opts.
  Overrides take precedence. Useful for the webserver requesting e.g. a
  lower resolution without touching global state.
  """
  def init(overrides) do
    merged = Keyword.merge(@hw_opts ++ @sensor_opts, overrides)

    with :ok <- :esp32cam.init(merged),
         :ok <- warm_up() do
      :io.format("Camera init OK (SVGA, no PSRAM DMA)~n", [])
      :ok
    else
      {:error, reason} ->
        :io.format("Camera init failed: ~p~n", [reason])
        {:error, reason}
    end
  end

  @doc """
  Re-apply the default sensor controls via set_control/2.
  Individual control failures are logged but do not abort.
  """
  def apply_sensor_controls, do: apply_sensor_controls(@sensor_opts)

  @doc """
  Re-apply an explicit list of {control, value} sensor options.
  """
  def apply_sensor_controls(opts) do
    Enum.each(opts, fn {control, value} ->
      case :esp32cam.set_control(control, value) do
        :ok ->
          :ok

        {:error, reason} ->
          :io.format("set_control ~p=~p failed (ignored): ~p~n", [control, value, reason])
      end
    end)

    :ok
  end

  @doc """
  Capture-and-release @warmup_frames frames to let AE/AWB settle.
  Includes a short delay between frames to let the sensor JPEG encoder
  pipeline fully reset. Per-frame errors are logged but not fatal.
  """
  def warm_up, do: warm_up(@warmup_frames)

  @doc """
  Capture-and-release n frames with inter-frame delays.
  """
  def warm_up(n) do
    :io.format("Warm-up: capturing ~p frames...~n", [n])

    ok_count =
      Enum.reduce(1..n, 0, fn i, acc ->
        Process.sleep(@warmup_delay_ms)

        case :esp32cam.capture_frame() do
          {:ok, frame} ->
            :esp32cam.release_frame(frame)
            acc + 1

          {:error, reason} ->
            :io.format("Warm-up frame ~p/~p failed: ~p~n", [i, n, reason])
            acc
        end
      end)

    :io.format("Warm-up done: ~p/~p frames OK~n", [ok_count, n])
    :ok
  end

  @doc """
  Capture a JPEG frame and write it to the given flat-charlist path.
  Releases the framebuffer in all paths (ok and error).
  Returns :ok or {:error, reason}.
  """
  def capture_jpeg_to(path) do
    case :esp32cam.capture_frame() do
      {:ok, frame} ->
        result =
          case :esp32cam.frame_binary(frame) do
            {:ok, binary} ->
              AtomCam.Storage.write_file(path, binary)

            {:error, reason} ->
              :io.format("Failed to get frame binary: ~p~n", [reason])
              {:error, reason}
          end

        :esp32cam.release_frame(frame)
        result

      {:error, reason} ->
        :io.format("Failed to capture frame: ~p~n", [reason])
        {:error, reason}
    end
  end
end
