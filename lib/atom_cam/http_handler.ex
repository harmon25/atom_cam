defmodule AtomCam.HttpHandler do
  @compile {:no_warn_undefined, [:esp32cam]}

  @moduledoc """
  HTTP request handler for AtomCam.

  Routes:
    GET  /                 — live viewer + capture button + gallery link
    GET  /snapshot         — live JPEG capture (image/jpeg)
    POST /capture          — capture frame to SD card, return JSON
    GET  /gallery          — list saved images on SD card
    GET  /images/<file>    — serve a JPEG from SD card
    DELETE /images/<file>  — delete a JPEG from SD card
    *                      — 404

  Implements the httpd_handler behaviour (init_handler/2, handle_http_req/2).
  """

  # ---------------------------------------------------------------------------
  # Inline HTML pages
  # ---------------------------------------------------------------------------

  # Index page: live view + capture button + gallery link.
  # Uses onload/onerror chaining for the live stream (same pattern as before).
  # Capture button uses fetch() and shows feedback inline.
  @index_html """
  <!DOCTYPE html>
  <html>
  <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AtomCam</title>
  <style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:#111;color:#eee;font-family:system-ui,sans-serif;display:flex;flex-direction:column;align-items:center;min-height:100vh;padding:1rem}
  #stream{max-width:100%;max-height:70vh;border-radius:4px;margin-bottom:1rem}
  .bar{display:flex;gap:0.75rem;align-items:center;flex-wrap:wrap;justify-content:center}
  button,a.btn{background:#2563eb;color:#fff;border:none;padding:0.5rem 1.25rem;border-radius:4px;font-size:1rem;cursor:pointer;text-decoration:none;display:inline-block}
  button:active{background:#1d4ed8}
  button:disabled{background:#555;cursor:not-allowed}
  #status{font-size:0.875rem;min-height:1.25rem;color:#86efac}
  #status.err{color:#fca5a5}
  </style>
  </head>
  <body>
  <img id="stream">
  <div class="bar">
    <button id="cap" onclick="capture()">Capture to SD</button>
    <a class="btn" href="/gallery">Gallery</a>
    <span id="status"></span>
  </div>
  <script>
  var img=document.getElementById('stream');
  function refresh(){
    var n=new Image();
    n.onload=n.onerror=function(){img.src=n.src;setTimeout(refresh,200);};
    n.src='/snapshot?t='+Date.now();
  }
  refresh();

  function capture(){
    var btn=document.getElementById('cap'),st=document.getElementById('status');
    btn.disabled=true;st.textContent='Capturing...';st.className='';
    fetch('/capture',{method:'POST'}).then(function(r){return r.json();}).then(function(d){
      if(d.ok){st.textContent='Saved: '+d.file;st.className='';}
      else{st.textContent='Error: '+d.error;st.className='err';}
      btn.disabled=false;
    }).catch(function(e){st.textContent='Network error';st.className='err';btn.disabled=false;});
  }
  </script>
  </body>
  </html>
  """

  # Gallery page: lists saved images with download links and delete buttons.
  # The file list is injected server-side as a JS array. Delete uses fetch DELETE.
  @gallery_html_head """
  <!DOCTYPE html>
  <html>
  <head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AtomCam Gallery</title>
  <style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:#111;color:#eee;font-family:system-ui,sans-serif;padding:1.5rem;max-width:40rem;margin:0 auto}
  h1{font-size:1.25rem;margin-bottom:0.5rem}
  .top{margin-bottom:1rem}
  a{color:#60a5fa;text-decoration:none}
  a:hover{text-decoration:underline}
  ul{list-style:none;padding:0}
  li{display:flex;align-items:center;gap:0.75rem;padding:0.5rem 0;border-bottom:1px solid #333}
  li a.fname{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  button.del{background:#dc2626;color:#fff;border:none;padding:0.25rem 0.75rem;border-radius:4px;font-size:0.8rem;cursor:pointer}
  button.del:active{background:#b91c1c}
  .empty{color:#888;font-style:italic}
  </style>
  </head>
  <body>
  <div class="top"><a href="/">&larr; Live View</a></div>
  <h1>Saved Photos</h1>
  """

  @gallery_html_tail """
  <script>
  function del(name,li){
    if(!confirm('Delete '+name+'?'))return;
    fetch('/images/'+encodeURIComponent(name),{method:'DELETE'}).then(function(r){return r.json();}).then(function(d){
      if(d.ok){li.remove();checkEmpty();}
      else{alert('Delete failed: '+d.error);}
    }).catch(function(){alert('Network error');});
  }
  function checkEmpty(){
    var ul=document.getElementById('files');
    if(ul&&ul.children.length===0){ul.innerHTML='<li class="empty">No photos on SD card.</li>';}
  }
  </script>
  </body>
  </html>
  """

  # httpd_handler behaviour -- init_handler/2
  def init_handler(_path_suffix, _handler_config) do
    {:ok, %{}}
  end

  # ---------------------------------------------------------------------------
  # Route dispatch -- handle_http_req/2
  # ---------------------------------------------------------------------------

  # GET / -- serve the live viewer page
  def handle_http_req(%{method: :get, path: []}, state) do
    {:close, %{"Content-Type" => "text/html"}, @index_html}
    |> with_state(state)
  end

  # GET /favicon.ico -- suppress browser 404 noise
  def handle_http_req(%{method: :get, path: [<<"favicon.ico">> | _]}, _state) do
    {:close, %{"Content-Type" => "image/x-icon"}, ""}
  end

  # GET /snapshot -- live JPEG capture (zero-copy from camera)
  def handle_http_req(%{method: :get, path: [<<"snapshot">> | _]}, state) do
    case capture_jpeg() do
      {:ok, binary} ->
        {:close, %{"Content-Type" => "image/jpeg"}, binary}
        |> with_state(state)

      {:error, reason} ->
        :io.format("Snapshot capture failed: ~p~n", [reason])
        {:error, :internal_server_error}
    end
  end

  # POST /capture -- capture frame and save to SD card (retries up to 3 times)
  def handle_http_req(%{method: :post, path: [<<"capture">> | _]}, state) do
    try do
      ts_chars = timestamp_chars()
      # FAT 8.3 filename limit: "P" + up to 7 digits + ".JPG"
      fname = ~c"P" ++ ts_chars ++ ~c".JPG"
      path = AtomCam.Storage.sd_path(fname)

      case capture_to_sd_with_retry(path, 3) do
        :ok ->
          filename_str = :erlang.list_to_binary(fname)
          json = "{\"ok\":true,\"file\":\"" <> filename_str <> "\"}"

          {:close, %{"Content-Type" => "application/json"}, json}
          |> with_state(state)

        {:error, reason} ->
          err = :erlang.iolist_to_binary(:io_lib.format("~p", [reason]))
          json = "{\"ok\":false,\"error\":\"" <> err <> "\"}"

          {:close, %{"Content-Type" => "application/json"}, json}
          |> with_state(state)
      end
    catch
      kind, err ->
        :io.format("Capture crash: ~p:~p~n", [kind, err])
        msg = :erlang.iolist_to_binary(:io_lib.format("~p:~p", [kind, err]))
        json = "{\"ok\":false,\"error\":\"" <> msg <> "\"}"

        {:close, %{"Content-Type" => "application/json"}, json}
        |> with_state(state)
    end
  end

  # GET /gallery -- list saved images on SD card
  def handle_http_req(%{method: :get, path: [<<"gallery">> | _]}, state) do
    files =
      case AtomCam.Storage.list_dir(~c"/sdcard") do
        {:ok, entries} ->
          entries
          |> Enum.filter(fn name -> is_jpg?(name) end)
          |> :lists.sort()

        {:error, _} ->
          []
      end

    html = build_gallery_html(files)

    {:close, %{"Content-Type" => "text/html"}, html}
    |> with_state(state)
  end

  # GET /images/<filename> -- serve JPEG from SD card
  def handle_http_req(%{method: :get, path: [<<"images">>, filename | _]}, state) do
    path = AtomCam.Storage.sd_path(:erlang.binary_to_list(filename))

    case AtomCam.Storage.read_file(path) do
      {:ok, data} ->
        headers = %{
          "Content-Type" => "image/jpeg",
          "Content-Disposition" => "inline; filename=\"" <> filename <> "\""
        }

        {:close, headers, data}
        |> with_state(state)

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  # DELETE /images/<filename> -- delete JPEG from SD card
  def handle_http_req(%{method: :delete, path: [<<"images">>, filename | _]}, state) do
    path = AtomCam.Storage.sd_path(:erlang.binary_to_list(filename))

    case AtomCam.Storage.delete_file(path) do
      :ok ->
        json = "{\"ok\":true}"

        {:close, %{"Content-Type" => "application/json"}, json}
        |> with_state(state)

      {:error, reason} ->
        err = :erlang.iolist_to_binary(:io_lib.format("~p", [reason]))
        json = "{\"ok\":false,\"error\":\"" <> err <> "\"}"

        {:close, %{"Content-Type" => "application/json"}, json}
        |> with_state(state)
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
  # Uses esp32cam:capture/0 which returns a copied binary, then does an
  # additional binary.copy/1 to ensure the data is in a contiguous heap
  # region that atomvm_httpd can send over TCP without issues. Without
  # this copy, responses can stall or send partial/corrupted data.
  defp capture_jpeg do
    case :esp32cam.capture() do
      {:ok, binary} ->
        {:ok, :binary.copy(binary)}

      {:error, reason} ->
        {:error, reason}
    end
  end

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

  # Build the gallery HTML with a list of files.
  defp build_gallery_html([]) do
    :erlang.iolist_to_binary([
      @gallery_html_head,
      "<p class=\"empty\">No photos on SD card.</p>\n",
      @gallery_html_tail
    ])
  end

  defp build_gallery_html(files) do
    items =
      Enum.map(files, fn name ->
        bin_name = :erlang.list_to_binary(name)

        [
          "<li><a class=\"fname\" href=\"/images/",
          bin_name,
          "\" download>",
          bin_name,
          "</a><button class=\"del\" onclick=\"del('",
          bin_name,
          "',this.parentNode)\">Delete</button></li>\n"
        ]
      end)

    :erlang.iolist_to_binary([
      @gallery_html_head,
      "<ul id=\"files\">\n",
      items,
      "</ul>\n",
      @gallery_html_tail
    ])
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

  # Passthrough helper for consistent return format.
  defp with_state(reply, _state), do: reply
end
