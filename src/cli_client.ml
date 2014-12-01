
open Lwt

open LTerm_style
open LTerm_text
open LTerm_geom
open CamomileLibraryDyn.Camomile
open React

let rec take_rev x l acc =
  match x, l with
  | 0, _ -> acc
  | n, [] -> acc
  | n, x :: xs -> take_rev (pred n) xs (x :: acc)

let rec take_fill neutral x l acc =
  match x, l with
  | 0, _     -> List.rev acc
  | n, x::xs -> take_fill neutral (pred n) xs (x::acc)
  | n, []    -> take_fill neutral (pred n) [] (neutral::acc)

let rec pad_l neutral x l =
  match x - (List.length l) with
  | 0 -> l
  | d when d > 0 ->  pad_l neutral x (neutral :: l)
  | d -> assert false

let pad x s =
  match x - (String.length s) with
  | 0 -> s
  | d when d > 0 -> s ^ (String.make d ' ')
  | d (* when d < 0 *) -> String.sub s 0 x

let rec find_index id i = function
  | [] -> assert false
  | x::xs when x = id -> i
  | _::xs -> find_index id (succ i) xs

type ui_state = {
  user : User.user ; (* set initially *)
  session : User.session ; (* set initially *)
  mutable log : (Unix.tm * string * string) list ; (* set by xmpp callbacks -- should be time * string list *)
  mutable active_chat : User.user ; (* modified by user (scrolling through buddies) *)
  users : User.users ; (* extended by xmpp callbacks *)
  notifications : User.user list ; (* or a set? adjusted once messages drop in, reset when chat becomes active *)
  (* events : ?? list ; (* primarily subscription requests - anything else? *) *)
}

let empty_ui_state user session users = {
  user ;
  session ;
  log = [] ;
  active_chat = user ;
  users ;
  notifications = []
}

let make_prompt size time network state redraw =
  let tm = Unix.localtime time in

  (* network should be an event, then I wouldn't need a check here *)
  (if List.length state.log = 0 || List.hd state.log <> network then
     state.log <- (network :: state.log)) ;

  let print (lt, from, msg) =
    let time = Printf.sprintf "[%02d:%02d:%02d] " lt.Unix.tm_hour lt.Unix.tm_min lt.Unix.tm_sec in
    time ^ from ^ ": " ^ msg
  in
  let logs =
    let entries = take_rev 6 state.log [] in
    let ent = List.map print entries in
    let msgs = pad_l "" 6 ent in
    String.concat "\n" msgs
  in

  let session = state.session in
  let status = User.presence_to_string session.User.presence in
  let jid = state.user.User.jid ^ "/" ^ session.User.resource in

  let main_size = size.rows - 6 (* log *) - 3 (* status + readline *) in
  assert (main_size > 0) ;

  let buddy_width = 24 in

  let buddies =
    let us = User.keys state.users in
    List.map (fun id ->
        let u = User.Users.find state.users id in
        let session = User.good_session u in
        let s = match session with
          | None -> `Offline
          | Some s -> s.User.presence
        in
        let fg = match session with
          | None -> black
          | Some x -> match Otr.State.(x.User.otr.state.message_state) with
            | `MSGSTATE_ENCRYPTED _ -> lgreen
            | _ -> black
        in
        let f, t =
          if u = state.user then
            ("{", "}")
          else
            User.subscription_to_chars u.User.subscription
        in
        let bg = if state.active_chat = u then lcyan else white in
        let item =
          let data = Printf.sprintf " %s%s%s %s" f (User.presence_to_char s) t id in
          pad buddy_width data
        in
        [B_fg fg ; B_bg bg ; S item ; E_bg ; E_fg ])
      us
  in
  (* handle overflowings: text might be too long for one row *)

  let buddylist =
    let lst = take_fill [ S (String.make buddy_width ' ') ] main_size buddies [] in
    List.map (fun x -> x @ [ B_fg lcyan ; S (Zed_utf8.singleton (UChar.of_int 0x2502)) ; E_fg ; S "\n" ]) lst
  in
  let hline =
    (Zed_utf8.make buddy_width (UChar.of_int 0x2500)) ^
    (Zed_utf8.singleton (UChar.of_int 0x2534)) ^
    (Zed_utf8.make (size.cols - (succ buddy_width)) (UChar.of_int 0x2500))
  in

  eval (
    List.flatten buddylist @ [

    B_fg lcyan;
    S hline ;
    E_fg;
    S "\n" ;

    S logs ;
    S "\n" ;

    B_bold true;

    B_fg lcyan;
    S"─( ";
    B_fg lmagenta; S(Printf.sprintf "%02d:%02d" tm.Unix.tm_hour tm.Unix.tm_min); E_fg;
    S" )─< ";
    B_fg lblue; S jid; E_fg;
    S" >─";
    S redraw ;
    S(Zed_utf8.make
        (size.cols - 22 - String.length jid - String.length status - String.length redraw)
        (UChar.of_int 0x2500));
    S"[ ";
    B_fg (if session.User.presence = `Offline then lred else lgreen); S status; E_fg;
    S" ]─";
    E_fg;
    S"\n";

    E_bold;
  ])

let commands =
  [ "/connect" ; "/add" ; "/status" ; "/quit" ]

let time =
  let time, set_time = S.create (Unix.time ()) in
  (* Update the time every 60 seconds. *)
  ignore (Lwt_engine.on_timer 60.0 true (fun _ -> set_time (Unix.time ())));
  time

let up = UChar.of_int 0x2500
let down = UChar.of_int 0x2501

let redraw, force_redraw = S.create ""

class read_line ~term ~network ~history ~state ~completions = object(self)
  inherit LTerm_read_line.read_line ~history () as super
  inherit [Zed_utf8.t] LTerm_read_line.term term as t

  method completion =
    let prefix  = Zed_rope.to_string self#input_prev in
    let completions = List.filter (fun f -> Zed_utf8.starts_with f prefix) completions in
    self#set_completion 0 (List.map (fun f -> (f, " ")) completions)

  method show_box = false

  method send_action = function
    | LTerm_read_line.Edit (LTerm_edit.Zed (Zed_edit.Insert k)) when k = down ->
      let userlist = User.keys state.users in
      let active_idx = find_index state.active_chat.User.jid 0 userlist in
      if List.length userlist > (succ active_idx) then
        state.active_chat <- User.Users.find state.users (List.nth userlist (succ active_idx)) ;
      force_redraw ("bla" ^ (string_of_int (Random.int 100)))
    | LTerm_read_line.Edit (LTerm_edit.Zed (Zed_edit.Insert k)) when k = up ->
      let userlist = User.keys state.users in
      let active_idx = find_index state.active_chat.User.jid 0 userlist in
      if pred active_idx >= 0 then
        state.active_chat <- User.Users.find state.users (List.nth userlist (pred active_idx)) ;
      force_redraw ("bla" ^ (string_of_int (Random.int 100)))
    | action ->
      super#send_action action

  initializer
    LTerm_read_line.bind [LTerm_key.({ control = false; meta = false; shift = false; code = Prev_page })] [LTerm_read_line.Edit (LTerm_edit.Zed (Zed_edit.Insert up))];
    LTerm_read_line.bind [LTerm_key.({ control = false; meta = false; shift = false; code = Next_page })] [LTerm_read_line.Edit (LTerm_edit.Zed (Zed_edit.Insert down))];
    self#set_prompt (S.l4 (fun size time network redraw -> make_prompt size time network state redraw)
                       self#size time network redraw)
end

let rec loop (config : Config.t) term hist state session_data network s_n =
  let completions = commands in
  let history = LTerm_history.contents hist in
  match_lwt
    try_lwt
      lwt command = (new read_line ~term ~history ~completions ~state ~network)#run in
      return (Some command)
    with
      | Sys.Break -> return None
      | LTerm_read_line.Interrupt -> return (Some "/quit")
  with
   | Some command when (String.length command > 0) && String.get command 0 = '/' ->
       LTerm_history.add hist command;
       let cmd =
         let ws = try String.index command ' ' with Not_found -> String.length command in
         String.sub command 1 (pred ws)
       in
       (match String.trim cmd with
        | "quit" -> return (false, session_data)
        | "connect" ->
          match session_data with
          | None ->
            let otr_config = config.Config.otr_config in
            let cb jid msg =
              let now = Unix.localtime (Unix.time ()) in
              s_n (now, jid, msg)
            in
            let (user_data : Xmpp_callbacks.user_data) = Xmpp_callbacks.({
                otr_config ;
                users = state.users ;
                received = cb
              }) in
            Xmpp_callbacks.connect config user_data () >>= fun session_data ->
            Lwt.async (fun () -> Xmpp_callbacks.parse_loop session_data) ;
            return (true, Some session_data)
          | Some _ -> Printf.printf "already connected\n"; return (true, session_data)
        | _ -> Printf.printf "NYI" ; return (true, session_data)) >>= fun (cont, session_data) ->
       if cont then
         loop config term hist state session_data network s_n
       else
         (* close! *)
         return state
     | Some message ->
       LTerm_history.add hist message;
       let session = match User.good_session state.active_chat with
         | None -> assert false
         | Some x -> x
       in
       let ctx, out, warn = Otr.Handshake.send_otr session.User.otr message in
       session.User.otr <- ctx ;
       (match session_data with
        | None -> Printf.printf "not connected, cannot send\n" ; return_unit
        | Some x -> Xmpp_callbacks.XMPPClient.send_message x
                      ~jid_to:(JID.of_string state.active_chat.User.jid)
                      ?body:out () ) >>= fun () ->
       loop config term hist state session_data network s_n
   | None -> loop config term hist state session_data network s_n


class read_inputline ~term ~prompt () = object(self)
  inherit LTerm_read_line.read_line ()
  inherit [Zed_utf8.t] LTerm_read_line.term term

  method show_box = false

  initializer
    self#set_prompt (S.const (LTerm_text.of_string prompt))
end

class read_password term = object(self)
  inherit LTerm_read_line.read_password () as super
  inherit [Zed_utf8.t] LTerm_read_line.term term

  method send_action = function
    | LTerm_read_line.Break ->
        (* Ignore Ctrl+C *)
        ()
    | action ->
        super#send_action action

  initializer
    self#set_prompt (S.const (LTerm_text.of_string "password: "))
end

let rec read_char term =
  LTerm.read_event term >>= function
    | LTerm_event.Key { LTerm_key.code = LTerm_key.Char ch } ->
        return ch
    | _ ->
        read_char term

let rec read_yes_no term msg =
  LTerm.fprint term (msg ^ " [answer 'y' or 'n']: ") >>= fun () ->
  read_char term >|= Zed_utf8.singleton >>= fun ch ->
  match ch with
    | "y" ->
        return true
    | "n" ->
        return false
    | _ ->
        LTerm.fprintl term "Please enter 'y' or 'n'!" >>= fun () ->
        read_yes_no term msg

let exactly_one char s =
  String.contains s char &&
  try String.index_from s (succ (String.index s char)) char = 0 with Not_found -> true

let configure term () =
  (new read_inputline ~term ~prompt:"enter jabber id (user@host/resource): " ())#run >>= fun jid ->
  (if not (exactly_one '@' jid) then
     fail (Invalid_argument "not a valid jabber ID (exactly one @ character)")
   else return_unit) >>= fun () ->
  (if not (exactly_one '/' jid) then
     fail (Invalid_argument "not a valid jabber ID (exactly one / character)")
   else return_unit ) >>= fun () ->
  let jid = try Some (JID.of_string (String.lowercase jid)) with _ -> None in
  (match jid with
   | None -> fail (Invalid_argument "bad jabber ID")
   | Some x -> return x) >>= fun jid ->
  let { JID.ldomain } = jid in
  Lwt_unix.getprotobyname "tcp" >>= fun tcp ->
  Lwt_unix.getaddrinfo ldomain "xmpp-client" [Lwt_unix.AI_PROTOCOL tcp.Lwt_unix.p_proto] >>= fun r ->
  (match r with
   | []    -> fail (Invalid_argument ("no address for " ^ ldomain))
   | ai::_ -> return ai.Lwt_unix.ai_addr ) >>= fun _addr ->
  (new read_inputline ~term ~prompt:"enter port [5222]: " ())#run >>= fun port ->
  let port = if port = "" then 5222 else int_of_string port in
  (if port <= 0 || port > 65535 then
     fail (Invalid_argument "invalid port number")
   else return_unit ) >>= fun () ->
  (new read_password term)#run >>= fun password ->
  (* trust anchor *)
  (new read_inputline ~term ~prompt:"enter path to trust anchor: " ())#run >>= fun trust_anchor ->
  Lwt_unix.access trust_anchor [ Unix.F_OK ; Unix.R_OK ] >>= fun () ->
  (* otr config *)
  LTerm.fprintl term "OTR config" >>= fun () ->
  read_yes_no term "Protocol version 2 support (recommended)" >>= fun v2 ->
  read_yes_no term "Protocol version 3 support (recommended)" >>= fun v3 ->
  read_yes_no term "Require OTR encryption (recommended)" >>= fun require ->
  read_yes_no term "Send whitespace tag (recommended)" >>= fun send_whitespace ->
  read_yes_no term "Whitespaces starts key exchange (recommended)" >>= fun whitespace_starts ->
  read_yes_no term "Error starts key exchange (recommended)" >>= fun error_starts ->
  let dsa = Nocrypto.Dsa.generate `Fips1024 in
  (match v2, v3 with
   | true, true -> return [`V3 ; `V2 ]
   | true, false -> return [ `V2 ]
   | false, true -> return [ `V3 ]
   | false, false -> fail (Invalid_argument "no OTR version selected") ) >>= fun versions ->
  let policies = List.flatten [
      if require then [`REQUIRE_ENCRYPTION] else [] ;
      if send_whitespace then [`SEND_WHITESPACE_TAG] else [] ;
      if whitespace_starts then [`WHITESPACE_START_AKE] else [] ;
      if error_starts then [`ERROR_START_AKE] else [] ]
  in
  let otr_config = { Otr.State.versions = versions ; Otr.State.policies = policies ; Otr.State.dsa = dsa } in
  let config = Config.({ version = 0 ; jid ; port ; password ; trust_anchor ; otr_config }) in
  return config


let () =
  Lwt_main.run (
    ignore (LTerm_inputrc.load ());
    Tls_lwt.rng_init () >>= fun () ->

    Lazy.force LTerm.stdout >>= fun term ->

    (* look for -f command line flag *)
    Lwt_unix.getlogin () >>= fun user ->
    Lwt_unix.getpwnam user >>= fun pw_ent ->
    let cfgdir =
      let home = pw_ent.Lwt_unix.pw_dir in
      Filename.concat home ".config"
    in
    Xmpp_callbacks.load_config cfgdir >>= fun (config) ->
    (match config with
     | None ->
       configure term () >>= fun config ->
       Xmpp_callbacks.dump_config cfgdir config >>= fun () ->
       return config
     | Some cfg -> return cfg ) >>= fun config ->
    print_endline ("config is now " ^ (Config.store_config config)) ;

    Xmpp_callbacks.load_users cfgdir >>= fun (users) ->

    let history = LTerm_history.create [] in
    let user = User.find_or_add config.Config.jid users in
    let session = User.ensure_session config.Config.jid config.Config.otr_config user in
    let state = empty_ui_state user session users in
    let n, s_n = S.create (Unix.localtime (Unix.time ()), "nobody", "nothing") in
    loop config term history state None n s_n >>= fun state ->
    Printf.printf "now dumping state %d\n%!" (User.Users.length state.users) ;
    print_newline () ;
    (* dump_users cfgdir x.users *)
    return ()
  )
