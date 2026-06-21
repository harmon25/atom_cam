defmodule AtomCam.Storage do
  @compile {:no_warn_undefined, [:atomvm, :camera_scanner]}

  @moduledoc """
  SD card mount/unmount and file I/O for AtomCam.

  All path arguments must be flat charlists, not binaries.
  Uses :atomvm.posix_* for file I/O (only AtomVM-safe APIs).
  """

  @board Application.compile_env(:atom_cam, :board, :esp32s3_xiao)

  @default_mount_point ~c"/sdcard"

  @doc """
  Mount the SD card at the default mount point (/sdcard).
  Returns {:ok, mounted} or {:error, reason}.
  """
  def mount_sd, do: mount_sd(@default_mount_point)

  @doc """
  Mount the SD card at the given charlist path.
  Returns {:ok, mounted} or {:error, reason}.
  """
  def mount_sd(path) do
    case :camera_scanner.mount_sdcard(@board, path) do
      {:ok, mounted} ->
        {:ok, mounted}

      {:error, :no_sdcard_support} ->
        :io.format("Board ~p does not support an SD card slot.~n", [@board])
        {:error, :no_sdcard_support}

      {:error, reason} ->
        :io.format("Failed to mount SD card: ~p~n", [reason])
        {:error, reason}
    end
  end

  @doc """
  Unmount a previously mounted SD card reference.
  Returns :ok or {:error, reason}.
  """
  def umount_sd(mounted) do
    :camera_scanner.umount_sdcard(mounted)
  end

  @doc """
  Write binary data to a flat-charlist path on the SD card.
  Opens with O_WRONLY | O_CREAT | O_TRUNC, mode 0644.
  Writes in chunks to avoid SPI SD card driver size limits.
  Returns :ok or {:error, reason}.
  """
  @write_chunk_size 4096

  def write_file(path, data) do
    case :atomvm.posix_open(path, [:o_wronly, :o_creat, :o_trunc], 0o644) do
      {:ok, fd} ->
        result = write_chunks(fd, data)
        :atomvm.posix_close(fd)
        result

      {:error, reason} ->
        :io.format("Failed to open file for write ~p: ~p~n", [path, reason])
        {:error, reason}
    end
  end

  defp write_chunks(_fd, <<>>), do: :ok

  defp write_chunks(fd, data) when byte_size(data) <= @write_chunk_size do
    case :atomvm.posix_write(fd, data) do
      {:ok, _len} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_chunks(fd, data) do
    <<chunk::binary-size(@write_chunk_size), rest::binary>> = data

    case :atomvm.posix_write(fd, chunk) do
      {:ok, _len} -> write_chunks(fd, rest)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List entries in a directory. Returns {:ok, [charlist]} with filenames
  (excluding "." and ".."), or {:error, reason}.
  Path must be a flat charlist.
  """
  def list_dir(path) do
    case :atomvm.posix_opendir(path) do
      {:ok, dir} ->
        entries = read_dir_entries(dir, [])
        :atomvm.posix_closedir(dir)
        {:ok, entries}

      {:error, reason} ->
        :io.format("Failed to opendir ~p: ~p~n", [path, reason])
        {:error, reason}
    end
  end

  # posix_readdir returns {:ok, {:dirent, inode, name_binary}} or :eof
  defp read_dir_entries(dir, acc) do
    case :atomvm.posix_readdir(dir) do
      {:ok, {:dirent, _ino, name_bin}} when is_binary(name_bin) ->
        name = :erlang.binary_to_list(name_bin)

        case name do
          ~c"." -> read_dir_entries(dir, acc)
          ~c".." -> read_dir_entries(dir, acc)
          _ -> read_dir_entries(dir, [name | acc])
        end

      :eof ->
        :lists.reverse(acc)

      {:error, _} ->
        :lists.reverse(acc)
    end
  end

  @doc """
  Read a file into a binary. Path must be a flat charlist.
  Returns {:ok, binary} or {:error, reason}.
  """
  def read_file(path) do
    case :atomvm.posix_open(path, [:o_rdonly]) do
      {:ok, fd} ->
        result = read_chunks(fd, [])
        :atomvm.posix_close(fd)
        result

      {:error, reason} ->
        :io.format("Failed to open file for read ~p: ~p~n", [path, reason])
        {:error, reason}
    end
  end

  @read_chunk_size 4096

  defp read_chunks(fd, acc) do
    case :atomvm.posix_read(fd, @read_chunk_size) do
      {:ok, data} when byte_size(data) > 0 ->
        read_chunks(fd, [data | acc])

      {:ok, _empty} ->
        {:ok, :erlang.iolist_to_binary(:lists.reverse(acc))}

      :eof ->
        {:ok, :erlang.iolist_to_binary(:lists.reverse(acc))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Delete a file. Path must be a flat charlist.
  Returns :ok or {:error, reason}.
  """
  def delete_file(path) do
    case :atomvm.posix_unlink(path) do
      :ok ->
        :ok

      {:error, reason} ->
        :io.format("Failed to delete ~p: ~p~n", [path, reason])
        {:error, reason}
    end
  end

  @doc """
  Build a flat charlist path by joining the mount point and a filename.
  Both arguments should be charlists.
  """
  def sd_path(filename) do
    :lists.flatten(@default_mount_point ++ ~c"/" ++ filename)
  end
end
