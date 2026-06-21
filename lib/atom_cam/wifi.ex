defmodule AtomCam.Wifi do
  @moduledoc """
  WiFi connectivity for AtomCam.

  Wraps WifiWiz — on first boot with no saved credentials it launches a
  captive-portal AP ("AtomCam" / "atomcam1"); once credentials are submitted
  the device reboots and connects as STA.

  Blocks until connected (or WifiWiz exhausts its retry budget and reboots).
  Returns {:ok, ip_tuple} on success.
  """

  @ap_ssid "AtomCam"
  @ap_psk "atomcam1"

  @doc """
  Connect to WiFi. Blocks until a STA IP is obtained.
  Returns {:ok, ip} or {:error, reason}.
  """
  def connect do
    :io.format("Starting WiFi (AP: ~s)...~n", [@ap_ssid])

    WifiWiz.start(
      ap: [ssid: @ap_ssid, psk: @ap_psk],
      sta_retry: [on_exhausted: :wipe_and_reboot]
    )
  end
end
