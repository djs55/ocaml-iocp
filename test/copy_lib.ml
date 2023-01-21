
type req = [ `R | `W ]

type request = {
  buf: Cstruct.buffer;
  off: Optint.Int63.t;
  req: req;
  ts: int64;
}

(* The maximum number of threads that the operating system can allow to concurrently process I/O completion packets for the I/O completion port.
   If this parameter is zero, the system allows as many concurrently running threads as there are processors in the system.
*)
let num_threads = 0

let copy_file ?read_latency ?write_latency block_size queue_depth infile outfile =
  let iocp = Iocp.Safest.create num_threads in
  let fd = Iocp.Safest.openfile iocp 0 infile [ O_RDONLY ] 0 in
  let out =
    Iocp.Safest.openfile iocp 1 outfile [ O_WRONLY; O_CREAT; O_TRUNC ] 0o644
  in
  let st_size = Optint.Int63.of_int (Unix.fstat @@ Iocp.Handle.fd fd).Unix.st_size in
  let in_progress_requests = Iocp.Safest.H.create queue_depth in

  (* Submit initial requests *)
  let rec submit_initial_requests next_read_off num_in_flight =
    if Optint.Int63.compare next_read_off st_size < 0 && num_in_flight < queue_depth then begin
      let buf = Cstruct.(to_bigarray @@ create block_size) in
      (* Printf.fprintf stderr "initial submit off=%d in_flight_requests = %d\n" (Optint.Int63.to_int next_read_off) num_in_flight; *)
      let request = {
        buf = buf;
        off = next_read_off;
        req = `R;
        ts = Mtime_clock.now_ns ();
      } in
      let id = Iocp.Safest.read iocp fd buf ~pos:0 ~off:next_read_off ~len:block_size in
      Iocp.Safest.H.replace in_progress_requests id request;
      submit_initial_requests Optint.Int63.(add next_read_off (of_int block_size)) (num_in_flight + 1)
    end else next_read_off, num_in_flight in
  let next_read_off, num_in_flight = submit_initial_requests Optint.Int63.zero 0 in

  let rec handle_completion next_read_off num_in_flight =
    (* Printf.fprintf stderr "waiting for %d\n" num_in_flight; *)
    if num_in_flight > 0 then begin
      match Iocp.Safest.get_queued_completion_status iocp ~timeout:1000 with
      | None -> assert false (* TODO: should we wait forever? *)
      | Some t ->
        let request = Iocp.Safest.H.find in_progress_requests t.id in
        Iocp.Safest.H.remove in_progress_requests t.id;
        begin match request.req with
        | `R ->
          (* Printf.fprintf stderr "read completed at %d\n" (Optint.Int63.to_int request.off); *)
          begin match read_latency with
          | None -> ()
          | Some l -> Latency.add l (Int64.sub (Mtime_clock.now_ns ()) request.ts)
          end;
          let request = { request with req = `W; ts = Mtime_clock.now_ns () } in
          let id = Iocp.Safest.write iocp out request.buf ~pos:0 ~off:request.off ~len:t.bytes_transferred in
          Iocp.Safest.H.replace in_progress_requests id request;
          handle_completion next_read_off num_in_flight
        | `W ->
          (* Printf.fprintf stderr "write completed at %d\n" (Optint.Int63.to_int request.off); *)
          begin match write_latency with
          | None -> ()
          | Some l -> Latency.add l (Int64.sub (Mtime_clock.now_ns ()) request.ts)
          end;
          if Optint.Int63.compare next_read_off st_size < 0 then begin
            let buf = Cstruct.(to_bigarray @@ create block_size) in
            let request = {
              buf = buf;
              off = next_read_off;
              req = `R;
              ts = Mtime_clock.now_ns ();
            } in
            let id = Iocp.Safest.read iocp fd buf ~pos:0 ~off:next_read_off ~len:block_size in
            Iocp.Safest.H.replace in_progress_requests id request;
            handle_completion Optint.Int63.(add next_read_off (of_int block_size)) num_in_flight
          end else handle_completion next_read_off (num_in_flight - 1)
        end
      end in
  handle_completion next_read_off num_in_flight;

  (* print_endline "All done!"; *)
  Unix.close @@ Iocp.Handle.fd fd;
  Unix.close @@ Iocp.Handle.fd out

let run_cp ?read_latency ?write_latency block_size queue_depth infile outfile () =
  copy_file ?read_latency ?write_latency block_size queue_depth infile outfile