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

class output ~kind
  ~on_start ~on_stop ~infallible ~autostart
  ~hostname ~port ~encoder_factory source =
object (self)

  inherit
    Output.encoded ~output_kind:"udp" ~content_kind:kind
      ~on_start ~on_stop ~infallible ~autostart
      ~name:(Printf.sprintf "udp://%s:%d" hostname port) source

  val mutable socket_send = None
  val mutable encoder = None

  method private output_start =
    let socket =
      Unix.socket Unix.PF_INET Unix.SOCK_DGRAM
        (Unix.getprotobyname "udp").Unix.p_proto
    in
    let ipaddr = (Unix.gethostbyname hostname).Unix.h_addr_list.(0) in
    let portaddr = Unix.ADDR_INET (ipaddr, port) in
      socket_send <-
        Some (fun msg off len -> Unix.sendto socket msg off len [] portaddr) ;
      encoder <-
        Some (encoder_factory self#id Encoder.Meta.empty_metadata)

  method private output_reset = self#output_start ; self#output_stop

  method private output_stop =
    socket_send <- None ;
    encoder <- None

  method private encode frame ofs len =
    (Utils.get_some encoder).Encoder.encode frame ofs len

  method private insert_metadata m =
    (Utils.get_some encoder).Encoder.insert_metadata m

  method private send data =
    let sent = (Utils.get_some socket_send) data 0 (String.length data) in
      ignore sent

end

module Generator = Generator.From_audio_video_plus
module Generated = Generated.Make(Generator)

class input ~kind ~hostname ~port ~decoder_factory ~bufferize =
  let max_ticks = 2 * (Frame.master_of_seconds bufferize) in
  (* A log function for our generator: start with a stub, and replace it
   * when we have a proper logger with our ID on it. *)
  let log_ref = ref (fun _ -> ()) in
  let log = (fun x -> !log_ref x) in
object (self)

  inherit Source.source kind
  inherit
    Generated.source
      (Generator.create ~log ~kind ~overfull:(`Drop_old max_ticks) `Undefined)
      ~empty_on_abort:false ~bufferize as generated
  inherit
    Start_stop.async
      ~source_kind:"udp"
      ~name:(Printf.sprintf "udp://%s:%d" hostname port)
      ~on_start:ignore ~on_stop:ignore
      ~autostart:true

  initializer log_ref := (fun s -> self#log#f 3 "%s" s)

  val mutable kill_feeding = None
  val mutable wait_feeding = None

  method private start =
    begin match wait_feeding with
      | None -> ()
      | Some f -> f () ; wait_feeding <- None
    end ;
    let kill,wait = Tutils.stoppable_thread self#feed "UDP input" in
      kill_feeding <- Some kill ;
      wait_feeding <- Some wait

  method private stop =
    (Utils.get_some kill_feeding) () ;
    kill_feeding <- None

  method private output_reset =
    request_stop <- true ;
    request_start <- true

  method private is_active = true

  method private stype = Source.Fallible

  method private feed (should_stop,has_stopped) =
    let socket =
      Unix.socket Unix.PF_INET Unix.SOCK_DGRAM
        (Unix.getprotobyname "udp").Unix.p_proto
    in
    let ipaddr = (Unix.gethostbyname hostname).Unix.h_addr_list.(0) in
    let addr = Unix.ADDR_INET (ipaddr,port) in
      Unix.bind socket addr ;
      (* Wait until there's something to read or we must stop. *)
      let rec wait () =
        if should_stop () then begin
          failwith "stop"
        end ;
        let l,_,_ = Unix.select [socket] [] [] 1. in
          if l = [] then wait ()
      in
      (* Read data from the network. *)
      let read len =
        wait () ;
        let msg = String.create len in
        let n,_ = Unix.recvfrom socket msg 0 len [] in
          msg,n
      in
        try
          (* Feeding loop. *)
          let Decoder.Decoder decoder = decoder_factory read in
            while true do
              if should_stop () then failwith "stop" ;
              decoder generator
            done
        with
          | e ->
              Generator.add_break ~sync:`Drop generator ;
              (* Closing the socket is slightly overkill but
               * we need to recreate the decoder anyway, which
               * might loose some data too. *)
              Unix.close socket ;
              begin match e with
                | Failure s ->
                    self#log#f 2 "Feeding stopped: %s." s
                | e ->
                    self#log#f 2 "Feeding stopped: %s."
                      (Utils.error_message e)
              end ;
              if should_stop () then
                has_stopped ()
              else
                self#feed (should_stop,has_stopped)

end

let () =
  let k = Lang.univ_t 1 in
    Lang.add_operator "output.udp"
      ~descr:"Output encoded data to UDP, without any control whatsoever."
      ~category:Lang.Output
      ~flags:[Lang.Experimental;Lang.Hidden]
      (Output.proto @
       [ ("port", Lang.int_t, None, None) ;
         ("host", Lang.string_t, None, None) ;
         ("", Lang.format_t k, None, Some "Encoding format.") ;
         ("", Lang.source_t k, None, None) ])
      ~kind:(Lang.Unconstrained k)
      (fun p kind ->
         (* Generic output parameters *)
         let autostart = Lang.to_bool (List.assoc "start" p) in
         let infallible = not (Lang.to_bool (List.assoc "fallible" p)) in
         let on_start =
           let f = List.assoc "on_start" p in
             fun () -> ignore (Lang.apply ~t:Lang.unit_t f [])
         in
         let on_stop =
           let f = List.assoc "on_stop" p in
             fun () -> ignore (Lang.apply ~t:Lang.unit_t f [])
         in
         (* Specific UDP parameters *)
         let port = Lang.to_int (List.assoc "port" p) in
         let hostname = Lang.to_string (List.assoc "host" p) in
         let fmt = Lang.to_format (Lang.assoc "" 1 p) in
         let fmt = Encoder.get_factory fmt in
         let source = Lang.assoc "" 2 p in
           ((new output ~kind ~on_start ~on_stop ~infallible ~autostart
               ~hostname ~port ~encoder_factory:fmt source):>Source.source))

let () =
  let k = Lang.univ_t 1 in
    Lang.add_operator "input.udp"
      ~descr:"Input encoded data from UDP, without any control whatsoever."
      ~category:Lang.Input
      ~flags:[Lang.Experimental;Lang.Hidden]
      [ ("port", Lang.int_t, None, None) ;
        ("host", Lang.string_t, None, None) ;
        ("buffer", Lang.float_t, Some (Lang.float 1.),
         Some "Duration of buffered data before starting playout.") ;
        ("", Lang.string_t, None, Some "Mime type.") ]
      ~kind:(Lang.Unconstrained k)
      (fun p kind ->
         (* Specific UDP parameters *)
         let port = Lang.to_int (List.assoc "port" p) in
         let hostname = Lang.to_string (List.assoc "host" p) in
         let bufferize = Lang.to_float (List.assoc "buffer" p) in
         let mime = Lang.to_string (Lang.assoc "" 1 p) in
           match Decoder.get_stream_decoder mime kind with
             | None ->
                 raise (Lang.Invalid_value
                          ((Lang.assoc "" 1 p),
                           "Cannot get a stream decoder for this MIME"))
             | Some decoder_factory ->
                 ((new input ~kind
                     ~hostname ~port ~bufferize ~decoder_factory)
                    :>Source.source))