(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2010 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

open Gstreamer

module I = Image.RGBA32
module G = Image.Generic

(* TODO.... *)
let () =
  Gstreamer.init ()

class v4l2_input ~kind dev =
  let width = Lazy.force Frame.video_width in
  let height = Lazy.force Frame.video_height in
  let vfps = 10 in
  let poller_img_m = Mutex.create () in
  let poller_m =
    let m = Mutex.create () in
    Mutex.lock m;
    m
  in
  let poller_c = Condition.create () in
object (self)
  inherit Source.active_source kind

  method stype = Source.Infallible
  method remaining = -1
  method is_ready = true

  method abort_track = ()

  method output = if VFrame.is_partial memo then self#get_frame memo

  val mutable sink = None

  val mutable image = None

  initializer
    ignore (
      Thread.create
        (fun () ->
          while true do
            Condition.wait poller_c poller_m;
            let sink = Utils.get_some sink in
            let b = App_sink.pull_buffer (App_sink.of_element sink) in
            let vimg = G.make_rgb G.Pixel.RGB24 width height b in
            let img = I.create width height in
            G.convert ~copy:true ~proportional:true vimg (G.of_RGBA32 img);
            Mutex.lock poller_img_m;
            image <- Some img;
            Mutex.unlock poller_img_m
          done
        ) ()
    )

  method output_get_ready =
    let pipeline =
      Printf.sprintf
        "v4l2src device=%s ! ffmpegcolorspace ! videoscale ! \
         appsink max-buffers=2 drop=true name=sink \
           caps=\"video/x-raw-rgb,width=%d,height=%d,\
                  pixel-aspect-ratio=1/1,bpp=(int)24,depth=(int)24,\
                  endianness=(int)4321,red_mask=(int)0xff0000,\
                  green_mask=(int)0x00ff00,blue_mask=(int)0x0000ff,\
                  framerate=(fraction)%d/1\""
        dev width height vfps
    in
    let bin = Pipeline.parse_launch pipeline in
    let s = Bin.get_by_name (Bin.of_element bin) "sink" in
    sink <- Some s;
    Element.set_state bin State_playing;
    Condition.signal poller_c

  method output_reset = ()
  method is_active = true

  method get_frame frame =
    assert (0 = Frame.position frame);
    let buf = VFrame.content_of_type ~channels:1 frame in
    let buf = buf.(0) in
    (
      match image with
        | Some img ->
          Mutex.lock poller_img_m;
          for i = 0 to VFrame.size frame - 1 do
            I.Scale.onto ~proportional:true img buf.(i)
          done;
          Mutex.unlock poller_img_m
        | None -> ()
    );
    VFrame.add_break frame (VFrame.size ());
    Condition.signal poller_c
end

let () =
  let k =
    Lang.kind_type_of_kind_format ~fresh:1
      (Lang.Constrained
         { Frame. audio = Lang.Any_fixed 0 ;
                  video = Lang.Fixed 1 ;
                  midi = Lang.Fixed 0 })
  in
  Lang.add_operator "input.gstreamer.v4l2"
    [
      "device", Lang.string_t, Some (Lang.string "/dev/video0"),
      Some "V4L device to use.";
    ]
    ~kind:(Lang.Unconstrained k)
    ~category:Lang.Input
    ~flags:[Lang.Experimental;Lang.Hidden]
    ~descr:"Stream from a gstreamer input device, such as a webcam."
    (fun p kind ->
       let e f v = f (List.assoc v p) in
       let device = e Lang.to_string "device" in
         ((new v4l2_input ~kind device):>Source.source))