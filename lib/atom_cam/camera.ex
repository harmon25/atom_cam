defmodule AtomCam.Camera do
  @compile {:no_warn_undefined, [:atomvm, :esp32cam]}

  @moduledoc """
  Camera lifecycle and capture for AtomCam.

  Owns the esp32cam init sequence including the PSRAM-DMA-mode reconfigure
  workaround: set_psram_mode/1 triggers a silent esp_camera_reconfigure which
  resets all sensor-level controls. This module re-applies them afterwards and
  runs a short warm-up burst to let AE/AWB settle.

  This module is the surface the future WiFi/webserver process will call for
  captures — no direct esp32cam calls should be needed outside of here.
  """

  @board Application.compile_env(:atom_cam, :board, :esp32s3_xiao)

  # Hardware config passed through to esp_camera_init (camera_config_t level).
  # These survive a set_psram_mode reconfigure unchanged.
  @hw_opts [
    board: @board,
    frame_size: :xga,
    jpeg_quality: 12
    # fb_count: 2,
    # fb_location: :psram,
    # grab_mode: :latest,
    # warm_up_frames: 3
  ]

  # Sensor-level controls applied by nif_esp32cam_init after esp_camera_init.
  # These are NOT preserved by esp_camera_reconfigure (triggered by set_psram_mode),
  # so apply_sensor_controls/0 must be called after every set_psram_mode call.
  @sensor_opts [
    vflip: true,
    hmirror: false,
    auto_white_balance: true,
    awb_gain: true,
    wb_mode: :auto
  ]

  # Frames to capture-and-release after set_psram_mode resets the sensor,
  # to replace the warm_up_frames cycle that the reconfigure skips and to
  # let AE/AWB settle.
  @post_psram_warmup_frames 3

  @doc """
  Initialise the camera with default hw + sensor options.
  Steps:
    1. esp32cam:init/1  — hardware init + first sensor apply + warm-up.
    2. set_psram_mode(true)  — enables PSRAM DMA mode (triggers silent re-init).
    3. apply_sensor_controls/0  — re-applies sensor opts lost in step 2.
    4. warm_up/0  — 3-frame AE/AWB settle burst.
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
         :ok <- :esp32cam.set_psram_mode(true),
         :ok <- apply_sensor_controls(),
         :ok <- warm_up() do
      :ok
    else
      {:error, reason} ->
        :io.format("Camera init failed: ~p~n", [reason])
        {:error, reason}
    end
  end

  @doc """
  Re-apply the default sensor controls via set_control/2.
  Call this after any operation that triggers esp_camera_reconfigure
  (currently only set_psram_mode/1).
  Individual control failures are logged but do not abort — mirrors upstream
  maybe_set_control/2 from esp32cam_example.erl.
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
  Capture-and-release @post_psram_warmup_frames frames to let AE/AWB settle
  after set_psram_mode has reset the sensor. Per-frame errors are ignored.
  """
  def warm_up, do: warm_up(@post_psram_warmup_frames)

  @doc """
  Capture-and-release n frames. Per-frame errors are ignored.
  """
  def warm_up(n) do
    Enum.each(1..n, fn _ ->
      case :esp32cam.capture_frame() do
        {:ok, frame} -> :esp32cam.release_frame(frame)
        _ -> :ok
      end
    end)

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
