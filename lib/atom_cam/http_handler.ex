defmodule AtomCam.HttpHandler do
  @compile {:no_warn_undefined, [:esp32cam]}

  @moduledoc """
  HTTP request handler for AtomCam dynamic endpoints.

  Static HTML (index.html, gallery.html) is served directly from priv/ by
  httpd_file_handler (the catch-all route registered last in atom_cam.ex).
  This handler only covers the dynamic routes that require device access.

  Routes:
    GET  /snapshot          — live JPEG capture (image/jpeg)
    POST /capture           — capture frame to SD card, return JSON
    GET  /api/images        — list saved .jpg files on SD card, return JSON
    GET  /images/<file>     — serve a JPEG from SD card
    DELETE /images/<file>   — delete a JPEG from SD card, return JSON

  Implements the httpd_handler behaviour (init_handler/2, handle_http_req/2).
  """

  # httpd_handler behaviour -- init_handler/2
  def init_handler(_path_suffix, _handler_config) do
    {:ok, %{}}
  end

  # ---------------------------------------------------------------------------
  # Route dispatch -- handle_http_req/2
  # ---------------------------------------------------------------------------

  # GET /snapshot -- live JPEG capture (zero-copy from camera)
  def handle_http_req(%{method: :get, path: ["snapshot" | _]}, state) do
    case capture_jpeg() do
      {:ok, binary} ->
        {:close, %{"Content-Type" => "image/jpeg"}, binary}

      {:error, reason} ->
        :io.format("Snapshot capture failed: ~p~n", [reason])
        {:error, :internal_server_error}
    end
  end

  # POST /capture -- capture frame and save to SD card (retries up to 3 times)
  def handle_http_req(%{method: :post, path: ["capture" | _]}, state) do
    try do
      ts_chars = timestamp_chars()
      # FAT 8.3 filename limit: "P" + up to 7 digits + ".JPG"
      fname = ~c"P" ++ ts_chars ++ ~c".JPG"
      path = AtomCam.Storage.sd_path(fname)

      case capture_to_sd_with_retry(path, 3) do
        :ok ->
          filename_str = :erlang.list_to_binary(fname)
          json = :json.encode(%{ok: true, file: filename_str})

          {:close, %{"Content-Type" => "application/json"}, json}

        {:error, reason} ->
          err = :erlang.iolist_to_binary(:io_lib.format("~p", [reason]))
          json = :json.encode(%{ok: false, error: err})
          {:close, %{"Content-Type" => "application/json"}, json}
      end
    catch
      kind, err ->
        :io.format("Capture crash: ~p:~p~n", [kind, err])
        msg = :erlang.iolist_to_binary(:io_lib.format("~p:~p", [kind, err]))
        json = :json.encode(%{ok: false, error: msg})

        {:close, %{"Content-Type" => "application/json"}, json}
    end
  end

  # GET /api/images -- list saved .jpg files on SD card as JSON
  def handle_http_req(%{method: :get, path: ["api", "images" | _]}, state) do
    files =
      case AtomCam.Storage.list_dir(~c"/sdcard") do
        {:ok, entries} ->
          entries
          |> Enum.filter(&is_jpg?(&1))
          |> :lists.sort()

        {:error, _} ->
          []
      end

    json = build_images_json(files)

    {:close, %{"Content-Type" => "application/json"}, json}
  end

  # GET /images/<filename> -- serve JPEG from SD card
  def handle_http_req(%{method: :get, path: ["images", filename | _]}, state) do
    path =
      filename
      |> :erlang.binary_to_list()
      |> AtomCam.Storage.sd_path()

    case AtomCam.Storage.read_file(path) do
      {:ok, data} ->
        headers = %{
          "Content-Type" => "image/jpeg",
          "Content-Disposition" => "inline; filename=\"" <> filename <> "\""
        }

        {:close, headers, data}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  # DELETE /images/<filename> -- delete JPEG from SD card
  def handle_http_req(%{method: :delete, path: ["images", filename | _]}, state) do
    path =
      filename
      |> :erlang.binary_to_list()
      |> AtomCam.Storage.sd_path()

    case AtomCam.Storage.delete_file(path) do
      :ok ->
        json = :json.encode(%{ok: true})

        {:close, %{"Content-Type" => "application/json"}, json}

      {:error, reason} ->
        err = :erlang.iolist_to_binary(:io_lib.format("~p", [reason]))
        json = :json.encode(%{ok: false, error: err})

        {:close, %{"Content-Type" => "application/json"}, json}
    end
  end

  # All other requests
  def handle_http_req(_request, _state) do
    {:error, :not_found}
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  # Capture a JPEG frame as a regular heap binary.
  # Uses esp32cam:capture/0 which returns a copied binary.
  defp capture_jpeg do
    :esp32cam.capture()
  end

  # defp capture_jpeg_dma do
  #   with {:ok, frame} <- :esp32cam.capture_frame(),
  #        {:ok, binary} <- :esp32cam.frame_binary(frame) do
  #     {:ok, frame, binary}
  #   else
  #     {:error, reason} ->
  #       {:error, reason}
  #   end
  # end

  # Check if a charlist filename ends with .jpg or .jpeg (case insensitive).
  defp is_jpg?(name) do
    lower = :string.to_lower(name)
    ends_with_jpg?(lower)
  end

  defp ends_with_jpg?(name) do
    rev = :lists.reverse(name)

    case rev do
      ~c"gpj." ++ _ -> true
      ~c"gepj." ++ _ -> true
      _ -> false
    end
  end

  # Build a JSON object {"images":["NAME.JPG",...]} as a binary.
  defp build_images_json([]) do
    ~S({"images":[]})
  end

  defp build_images_json(files) do
    :json.encode(%{images: Enum.map(files, &:erlang.list_to_binary(&1))})
  end

  # Retry capture up to max_retries times. Each failed attempt waits
  # briefly to let the camera hardware reset its internal JPEG encoder
  # state before trying again.
  defp capture_to_sd_with_retry(_path, 0), do: {:error, :capture_failed}

  defp capture_to_sd_with_retry(path, retries) do
    case capture_and_save(path) do
      :ok ->
        :ok

      {:error, reason} ->
        :io.format("SD capture retry (~p left): ~p~n", [retries - 1, reason])
        Process.sleep(300)
        capture_to_sd_with_retry(path, retries - 1)
    end
  end

  # Capture a JPEG using the simple copy path (esp32cam:capture/0) and
  # write it to the SD card. Deep-copy ensures the binary is in regular
  # heap memory (not a PSRAM sub-binary or resource reference) so the
  # VFS write() call can access it.
  defp capture_and_save(path) do
    case :esp32cam.capture() do
      {:ok, image} ->
        copied = :binary.copy(image)
        AtomCam.Storage.write_file(path, copied)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Generate a charlist timestamp for unique filenames.
  # Truncated to fit FAT 8.3: "P" + 7 digits + ".JPG"
  # Uses monotonic_time to get a positive counter since boot.
  defp timestamp_chars do
    ts = :erlang.monotonic_time(:second)
    chars = :erlang.integer_to_list(ts)
    # Keep last 7 chars to fit 8.3 (P + 7 digits = 8 char name)
    len = :erlang.length(chars)
    if len > 7, do: :lists.nthtail(len - 7, chars), else: chars
  end
end
