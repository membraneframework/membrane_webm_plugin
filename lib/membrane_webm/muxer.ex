defmodule Membrane.WebM.Muxer do
  @moduledoc """
  Module for muxing WebM files.


  Muxer guidelines
  https://www.webmproject.org/docs/container/

  Muxers should treat all guidelines marked SHOULD in this section as MUST.
  This will foster consistency across WebM files in the real world.

  - WebM SHOULD contain the SeekHead element.
      - Reason: Allows the client to know if the file contains a Cues element.
  - WebM files SHOULD include a keyframe-only Cues element.
      - The Cues element SHOULD contain only video key frames, to decrease the size of the file header.
      - It is recommended that the Cues element be before any clusters, so that the client can seek to a point
        in the data that has not yet been downloaded in a single seek operation. Ref: a tool that will put the Cues at the front.
  - All absolute (block + cluster) timecodes MUST be monotonically increasing.
      - All timecodes are associated with the start time of the block.
  - The TimecodeScale element SHOULD be set to a default of 1.000.000 nanoseconds.
      - Reason: Allows every cluster to have blocks with positive values up to 32.767 seconds.
  - Key frames SHOULD be placed at the beginning of clusters.
      - Having key frames at the beginning of clusters should make seeking faster and easier for the client.
  - Audio blocks that contain the video key frame's timecode SHOULD be in the same cluster as the video key frame block.
  - Audio blocks that have same absolute timecode as video blocks SHOULD be written before the video blocks.
  - WebM files MUST only support pixels for the DisplayUnit element.
  """
  use Bitwise
  use Bunch

  use Membrane.Filter

  alias Membrane.{Buffer}
  alias Membrane.{Opus, VP8, VP9}
  alias Membrane.WebM.Serializer
  alias Membrane.WebM.Parser.Codecs

  alias Membrane.WebM.Serializer.Elements

  def_input_pad :input,
    availability: :on_request,
    mode: :pull,
    demand_unit: :buffers,
    caps: [Opus, VP8, VP9]

  def_output_pad :output,
    availability: :always,
    mode: :pull,
    caps: :any

  # 5 mb
  @cluster_bytes_limit 5_242_880
  @cluster_time_limit Membrane.Time.seconds(5)
  @timestamp_scale Membrane.Time.millisecond()

  defmodule State do
    defstruct tracks: %{},
              expected_tracks: 0,
              active_tracks: 0,
              cluster: %{
                current_cluster: {[], 999_999_999},
                current_bytes: 0,
              }
  end

  @impl true
  def handle_pad_added(_pad, _context, state) do
    {:ok, %State{state | expected_tracks: state.expected_tracks + 1}}
  end

  @impl true
  def handle_caps(Pad.ref(:input, id), caps, _context, state) do
    # FIXME: id is a source of nondeterminism - makes testing difficult
    # also it shouldn't be assigned via input pad but generated in muxer
    # imho best: leave option to provide input pad but generate random id if none provided
    codec =
      case caps do
        %VP8{} -> :vp8
        %VP9{} -> :vp9
        %Opus{} -> :opus
        _ -> raise "unsupported codec #{inspect(caps)}"
      end

    state = update_in(state.active_tracks, fn t -> t + 1 end)
    is_video = Codecs.is_video(codec)

    track = %{
      track_number: state.active_tracks,
      id: id,
      codec: codec,
      caps: caps,
      is_video: is_video,
      last_timestamp: nil,
      last_block: nil
    }

    state = put_in(state.tracks[id], track)

    if state.active_tracks == state.expected_tracks do
      {{:ok,
        demand: Pad.ref(:input, id),
        buffer: {:output, %Buffer{payload: serialize_webm_header(state)}}}, state}

      # FIXME: i can calculate duration only at the end of the stream so the whole webm_header and it's length should be saved; recalculated at the end of the stream and the file stitched together along with seek and cues
    else
      {{:ok, demand: Pad.ref(:input, id)}, state}
    end
  end

  def serialize_webm_header(state) do
    info = Elements.construct_info()
    tracks = Elements.construct_tracks(state.tracks)
    tags = Elements.construct_tags()
    seek_head = Elements.construct_seek_head([info, tracks, tags])
    void = Elements.construct_void(seek_head)

    ebml_header = Serializer.serialize(Elements.construct_ebml_header())

    segment_beginning =
      Serializer.serialize({:Segment, Enum.reverse([seek_head, void, info, tracks, tags])})

    ebml_header <> segment_beginning
  end

  @impl true
  def handle_init(_) do
    {:ok, %State{}}
  end

  @impl true
  def handle_demand(:output, _size, :buffers, _context, state) do
    # demand all tracks for which the last frame is not cached
    if state.expected_tracks == state.active_tracks do
      demands =
        state.tracks
        |> Enum.filter(fn {_id, info} -> info.last_block == nil end)
        |> Enum.map(fn {id, _info} -> {:demand, Pad.ref(:input, id)} end)

      {{:ok, demands}, state}
    else
      {:ok, state}
    end
  end

  # TODO: ivf sends pts while muxer needs dts
  @impl true
  def handle_process(Pad.ref(:input, id), %Buffer{payload: data, pts: timestamp}, _context, state) do
    timestamp = div(timestamp, @timestamp_scale)

    # IO.inspect(timestamp)

    state = put_in(state.tracks[id].last_timestamp, timestamp)
    block = {timestamp, data, state.tracks[id].track_number, state.tracks[id].codec}
    state = put_in(state.tracks[id].last_block, block)

    if Enum.any?(state.tracks, fn {_id, info} -> info.last_block == nil end) do
      # if there are active tracks without a cached frame then demand it
      {{:ok, redemand: :output}, state}
    else
      consume_block(state)
    end
  end

  def consume_block(state) do
    # sort blocks according to which should be next in the cluster
    youngest_track =
      state.tracks
      |> Enum.sort(&block_sorter/2)
      |> hd()
      |> elem(1)

    {returned_cluster, new_cluster_acc} = step_cluster(youngest_track.last_block, state.cluster)

    state = put_in(state.tracks[youngest_track.id].last_block, nil)

    if returned_cluster == nil do
      {{:ok, redemand: :output}, %State{state | cluster: new_cluster_acc}}
    else
      {{:ok, buffer: {:output, %Buffer{payload: write(returned_cluster)}}, redemand: :output},
       %State{state | cluster: new_cluster_acc}}
    end
  end

  def write({blocks, timecode}) do
    Serializer.serialize({:Cluster, blocks ++ [{:Timecode, timecode}]})
  end

  def step_cluster(
        {absolute_time, data, track_number, type} = block,
        %{
          current_cluster: {current_cluster, cluster_time},
          current_bytes: current_bytes
        } = _cluster_acc
      ) do
    cluster_time = min(cluster_time, absolute_time)
    current_bytes = current_bytes + byte_size(data) + 7
    relative_time = absolute_time - cluster_time

    # 32767 is max valid value of a simpleblock timecode (max signed_int16)
    if relative_time * @timestamp_scale > Membrane.Time.milliseconds(32767) do
      IO.warn("Simpleblock timecode overflow. Still writing but some data will be lost.")
    end

    begin_new_cluster =
      current_bytes >= @cluster_bytes_limit or relative_time * @timestamp_scale >= @cluster_time_limit or
        Codecs.is_video_keyframe(block)

    if begin_new_cluster do
      new_block = {:SimpleBlock, {0, data, track_number, type}}

      new_cluster_acc = %{
        current_cluster: {[new_block], absolute_time},
        current_bytes: 0
      }

      if current_cluster == [] do
        {nil, new_cluster_acc}
      else
        {{current_cluster, cluster_time}, new_cluster_acc}
      end
    else
      new_block = {:SimpleBlock, {absolute_time - cluster_time, data, track_number, type}}

      new_cluster_acc = %{
        current_cluster: {[new_block | current_cluster], cluster_time},
        current_bytes: current_bytes
      }

      {nil, new_cluster_acc}
    end
  end

  defp block_sorter({_id1, track1}, {_id2, track2}) do
    {time1, _data1, _track_number1, codec1} = track1.last_block
    {time2, _data2, _track_number2, codec2} = track2.last_block

    if time1 < time2 do
      true
    else
      Codecs.is_audio(codec1) and Codecs.is_video(codec2)
    end
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, id), _context, state) do
    new_block = state.tracks[id].last_block
    {blocks, _timecode} = state.cluster.current_cluster
    put_in(state.cluster.current_cluster, [new_block | blocks])

    if state.active_tracks == 1 do
      {blocks, timecode} = state.cluster.current_cluster
      cluster = Serializer.serialize({:Cluster, blocks ++ [{:Timecode, timecode}]})
      {{:ok, buffer: {:output, %Buffer{payload: cluster}}, end_of_stream: :output}, state}
    else
      {_track, state} = pop_in(state.tracks[id])
      {actions, state} = consume_block(state)
      {actions, %State{state | active_tracks: state.active_tracks - 1, expected_tracks: state.expected_tracks - 1}}
    end
  end

  @doc """
  Pack accumulated frames into Blocks and group them into Clusters.

  A Matroska file SHOULD contain at least one Cluster Element.
  Cluster Elements contain frames of every track sorted by timestamp in monotonically increasing order.
  It is RECOMMENDED that the size of each individual Cluster Element be limited to store no more than 5 seconds or 5 megabytes (but 32.767 seconds is possible).

  Every Cluster Element MUST contain a Timestamp Element - occuring once per cluster placed at the very beginning.
  All Block timestamps inside the Cluster are relative to that Cluster's Timestamp:
  Absolute Timestamp = Block+Cluster
  Relative Timestamp = Block
  Raw Timestamp = (Block+Cluster)*TimestampScale
  Matroska RFC https://www.ietf.org/archive/id/draft-ietf-cellar-matroska-08.html#section-7-18

  Clusters MUST begin with a keyframe.
  Audio blocks that contain the video key frame's timecode MUST be in the same cluster as the video key frame block.
  Audio blocks that have the same absolute timecode as video blocks SHOULD be written before the video blocks.
  This implementation simply splits the stream on every video keyframe if a video track is present. Otherwise the 5mb/5s limits are used.

  WebM Muxer Guidelines https://www.webmproject.org/docs/container/
  """
end
