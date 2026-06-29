defmodule AtomCam do
  @compile {:no_warn_undefined, [:atomvm, :avm_pubsub]}

  @moduledoc """
  Boot entrypoint for AtomCam.

  Flow:
    1. Connect to WiFi (blocks — captive portal on first boot).
    2. Init camera (PSRAM DMA mode + sensor controls + warm-up).
    3. Start HTTP server on port 80.
       GET /          — HTML viewer (auto-refreshes every 2 s)
       GET /snapshot  — live JPEG capture
    4. Sleep forever; httpd handles requests in its own process.
  """

  @http_port 80

  def start() do
    IO.puts("=== AtomCam starting ===")
    Process.sleep(1000)

    :ok = start_pubsub()

    with {:ok, {ip, _, _}} <- AtomCam.Wifi.connect(),
         :ok <- log_ip(ip),
         :ok <- AtomCam.Camera.init(),
         {:ok, sd_ref} <- mount_sd(),
         {:ok, _httpd} <- start_httpd() do
      :io.format("HTTP server running on port ~p~n", [@http_port])
      # Keep the boot process alive so the httpd supervisor process stays linked.
      # IMPORTANT: sd_ref must stay referenced here — the MountedFS resource has
      # a destructor that unmounts the SD card when garbage collected. Holding
      # the reference in this sleeping process prevents GC from reclaiming it.
      keep_alive(sd_ref)
    else
      {:error, reason} ->
        :io.format("Startup failed: ~p~n", [reason])
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp start_pubsub do
    case :avm_pubsub.start(:pubsub) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp start_httpd do
    handler = %{handler: AtomCam.HttpHandler, handler_config: %{}}

    routes = [
      # Dynamic endpoints handled by AtomCam.HttpHandler
      {["snapshot"], handler},
      {["capture"], handler},
      {["images"], handler},
      {["api"], handler},
      # Catch-all: serve static files from priv/ via httpd_file_handler.
      # / resolves to priv/index.html automatically.
      {[], AtomvmHttpd.file_handler_config(:atom_cam)}
    ]

    AtomvmHttpd.start(@http_port, routes)
  end

  defp mount_sd do
    case AtomCam.Storage.mount_sd() do
      {:ok, mounted} ->
        :io.format("SD card mounted at /sdcard~n", [])
        {:ok, mounted}

      {:error, reason} ->
        :io.format("SD card mount failed (~p), continuing without SD~n", [reason])
        # Return a dummy ref so the with-chain continues without SD
        {:ok, nil}
    end
  end

  # Hold a reference to prevent GC. The MountedFS resource destructor
  # unmounts the SD card, so the reference must stay alive.
  defp keep_alive(ref) do
    Process.sleep(:infinity)
    # Unreachable, but ensures the compiler doesn't optimize away ref
    :io.format("~p~n", [ref])
  end

  defp log_ip(ip) do
    :io.format("WiFi connected. IP: ~p~n", [ip])
    :ok
  end
end
