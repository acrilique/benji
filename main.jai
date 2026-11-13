#import "Atomics";
#import "Basic";
#import "Command_Line";
#import "File";
#import "POSIX";
#import "String";
#import "Thread";

#load "build.jai";
#load "ffi.jai";

//
// Globals
//

Context :: #Context;

TESTFILE :: "testfile.flac";
TOKENFILE :: "bot-key";
OPUS_APPLICATION_AUDIO :: 2049;
FRAME_SIZE :: 960;

Args :: struct {
    music_folder: string;
}

bot_user_id: u64;
voice_ws_running: bool;

Voice_Ws :: struct {
    endpoint, session_id, token: string;
    guild_id: u64;

    stop_requested: bool;

    curl: *CURL;
    socket: curl_socket_t;
    rx: [65536]u8;  rx_len: s64;
    heartbeat_interval_ms: float64;
    next_heartbeat: Apollo_Time;
    last_seq: s64 = -1;
    last_nonce: s64;  waiting_for_ack: bool;

    ssrc: u32;  ip: string;  port: u16;
}

voice_ws: Voice_Ws;
voice_thread: Thread;

Voice_Connection :: struct {
    session_id: [64]u8;
    token: [64]u8;
    endpoint: [64]u8;
    guild_id: u64;
    channel_id: u64;

    state_update_received: bool;
    server_update_received: bool;
}

voice: Voice_Connection;

do_we_have_credentials :: () -> bool {
    return voice.state_update_received && voice.server_update_received;
}

start_voice_ws :: () {
    stop_voice_ws();    

    voice_ws.endpoint = copy_string(to_string(voice.endpoint.data));
    voice_ws.session_id = copy_string(to_string(voice.session_id.data));
    voice_ws.token = copy_string(to_string(voice.token.data));
    voice_ws.guild_id = voice.guild_id;

    if !thread_init(*voice_thread, voice_ws_thread) {
        print("Failed to create the voice WS thread\n");
        free(voice_ws.endpoint);
        free(voice_ws.session_id);
        free(voice_ws.token);
        voice_ws = .{};
        return;
    }
    voice_thread.data = *voice_ws;
    thread_start(*voice_thread);
    voice_ws_running = true;
}

main :: () {
    success, args, is_set := parse_arguments(Args);
    if !success return;

    token, result := read_entire_file(TOKENFILE);
    if !result {
        print("Failed to read token file\n");
        return;
    }

    print("Music folder: %\n", args.music_folder);
    client := discord_init(to_c_string(token));
    if !client {
        print("Failed to initialize discord client\n");
        return;
    }
    defer discord_cleanup(client);

    discord_add_intents(client, DISCORD_INTENT_GUILDS | DISCORD_INTENT_GUILD_VOICE_STATES);
    discord_set_on_ready(client, on_ready);
    discord_set_on_interaction_create(client, on_interaction_create);
    discord_set_on_voice_state_update(client, on_voice_state_update);
    discord_set_on_voice_server_update(client, on_voice_server_update);

    err := discord_run(client);
    print("Discord connection stopped: %\n", to_string(discord_strerror(err, client)));
}

voice_ws_thread :: (thread: *Thread) -> s64 {
    ws := cast(*Voice_Ws) thread.data;
    if !ws_connect(ws) return 1;
    defer curl_easy_cleanup(ws.curl);

    gotta_stop: bool;

    while !gotta_stop {
        reset_temporary_storage();
        pfd := pollfd.{fd = ws.socket, events = POLLIN};
        poll(*pfd, 1, ws_ms_until_next_wakeup(ws));       // at most ~250 ms, so stop_requested is noticed
        if !ws_drain(ws) break;
        if ws.heartbeat_interval_ms > 0 && current_time_monotonic() >= ws.next_heartbeat
            if !ws_send_heartbeat(ws)  break;

        gotta_stop = atomic_read(*ws.stop_requested);
    }

    if gotta_stop print("Voice WS closed by us\n");

    return 0;
}

ws_drain :: (ws: *Voice_Ws) -> bool {
    got: u64;
    meta: *Curl_Ws_Frame;
    
    while (true) {
        ret := curl_ws_recv(ws.curl, ws.rx.data + ws.rx_len, xx (ws.rx.count - ws.rx_len), *got, *meta);
        if ret == {
            case CURLE_AGAIN; return true;
            case CURLE_OK;
                ws.rx_len += xx got;                
                if meta.bytesleft > 0 {
                    if ws.rx_len == ws.rx.count {
                        print("Message too big: rx_len = %, rx.count = %\n", ws.rx_len, ws.rx.count);
                        return false;
                    }
                    continue;
                }
                msg := string.{ws.rx_len, ws.rx.data};
                ws.rx_len = 0;
                if meta.flags & CURLWS_CLOSE {
                    code := ifx msg.count >= 2 then ((cast(u16) msg[0]) << 8) | msg[1] else 0;
                    reason := ifx msg.count > 2 then slice(msg, 2, msg.count - 2) else "";
                    print("Voice WS closed by Discord: "); 
                    if code != 0 print("% '%'\n", code, reason);
                    else print("no code\n");
                    return false;
                }
                if meta.flags & CURLWS_TEXT {
                    print("<- %\n", msg);
                    handle_text(ws, msg);
                }
                if meta.flags & CURLWS_BINARY {
                    if msg.count < 3 {
                        print("<- binary message too short (%)\n", msg.count);
                        continue;
                    }

                    ws.last_seq = ((cast(s64) msg[0]) << 8) | msg[1];
                    op := msg[2];
                    print("<- binary op=% seq=% len=%\n", op, ws.last_seq, msg.count);
                }
            case;
                print("Connection lost: %\n", to_string(curl_easy_strerror(ret)));
                return false;
        }
    }
    return false;
}

ws_ms_until_next_wakeup :: (ws: *Voice_Ws) -> s32 {
    if ws.heartbeat_interval_ms <= 0  return 250;
    ms := to_milliseconds(ws.next_heartbeat - current_time_monotonic());
    return xx clamp(ms, 0, 250);
}

ws_connect :: (ws: *Voice_Ws) -> bool {
    url := to_c_string(tprint("wss://%/?v=8", ws.endpoint));
    defer free(url);
    ws.curl = curl_easy_init();
    if !ws.curl {
        print("curl_easy_init failed\n");
        return false; 
    }
    curl_easy_setopt_ptr(ws.curl, CURLOPT_URL, url);
    curl_easy_setopt_long(ws.curl, CURLOPT_CONNECT_ONLY, 2);
    curl_easy_setopt_long(ws.curl, CURLOPT_CONNECTTIMEOUT_MS, 10000);
    ret: s32;
    ret = curl_easy_perform(ws.curl);
    if ret != CURLE_OK {
        print("Error during websocket establish: %\n", to_string(curl_easy_strerror(ret)));
        curl_easy_cleanup(ws.curl);
        ws.curl = null;
        return false;
    }

    curl_easy_getinfo_socket(ws.curl, CURLINFO_ACTIVESOCKET, *ws.socket);

    print("Voice WS connected: %\n", ws.endpoint);
    return true;
}

json_text :: (p: *Jsmnf_Pair, js: string) -> string {
    return string.{xx p.v.len, js.data + p.v.pos};
}

json_find :: (obj: *Jsmnf_Pair, js: string, key: string) -> *Jsmnf_Pair {
    if !obj return null;
    return jsmnf_find(obj, js.data, key.data, xx key.count);
}

handle_text :: (ws: *Voice_Ws, msg: string) {
    parser: Jsmn_Parser;
    tokens: [128]Jsmn_Token;
    jsmn_init(*parser);
    num_tokens := jsmn_parse(*parser, msg.data, xx msg.count, tokens.data, tokens.count); 
    if num_tokens < 0 {
        print("Bad JSON (%)\n", num_tokens);
        return;
    }

    loader: Jsmnf_Loader;
    pairs: [128]Jsmnf_Pair;
    jsmnf_init(*loader);
    if jsmnf_load(*loader, msg.data, tokens.data, xx num_tokens, pairs.data, pairs.count) < 0 {
        print("Couldn't load JSON\n");
        return;
    }

    root := *pairs[0];
    op_pair := json_find(root, msg, "op");
    if !op_pair {
        print("Message without \"op\"\n");
        return;
    }
    op := string_to_int(json_text(op_pair, msg));

    seq_pair := json_find(root, msg, "seq");
    if seq_pair  ws.last_seq = string_to_int(json_text(seq_pair, msg));

    d := json_find(root, msg, "d");

    if op == {
        case 8; // Hello
            interval := json_find(d, msg, "heartbeat_interval");
            if !interval {
                print("Message without \"heartbeat_interval\"\n");
                return;
            }

            ws.heartbeat_interval_ms = string_to_float64(json_text(interval, msg));
            ws.next_heartbeat = current_time_monotonic() + milliseconds_to_apollo(xx ws.heartbeat_interval_ms);
            print("Heartbeat every % ms\n", ws.heartbeat_interval_ms);
            ws_send_identify(ws);
        case 6; // ACK
            t := json_find(d, msg, "t");
            if t && string_to_int(json_text(t, msg)) == ws.last_nonce {
                rtt := to_milliseconds(current_time_monotonic()) - ws.last_nonce;
                print("Heartbeat ACK (% ms)\n", rtt);
                ws.waiting_for_ack = false;
            } else print("Unexpected nonce in ACK\n");
        case 2; // Ready
            ssrc  := json_find(d, msg, "ssrc");
            ip    := json_find(d, msg, "ip");
            port  := json_find(d, msg, "port");
            modes := json_find(d, msg, "modes");
            if !ssrc || !ip || !port || !modes {
                print("Ready is missing fields\n");
                return; 
            }

            free(ws.ip);        

            ws.ssrc = xx string_to_int(json_text(ssrc, msg));
            ws.ip   = copy_string(json_text(ip, msg));
            ws.port = xx string_to_int(json_text(port, msg));
        
            has_xchacha := false;
            for 0..modes.size-1 {
                mode := json_text(*modes.fields[it], msg);
                if mode == "aead_xchacha20_poly1305_rtpsize"  has_xchacha = true;
            }
            print("Ready: ssrc=% udp=%:% xchacha=%\n", ws.ssrc, ws.ip, ws.port, has_xchacha);
        case;
            print("Unhandled \"op\" (%)\n", op);
    }
}

Json_Writer :: struct {
    b: Jsonb;
    buf: [2048]u8;
    failed: bool;
}

jw_init :: (w: *Json_Writer) { jsonb_init(*w.b); w.failed = false; }
jw_check :: (w: *Json_Writer, code: s32) { if code < 0  w.failed = true; }

jw_object :: (w: *Json_Writer) { jw_check(w, jsonb_object(*w.b, w.buf.data, w.buf.count)); }
jw_pop    :: (w: *Json_Writer) { jw_check(w, jsonb_object_pop(*w.b, w.buf.data, w.buf.count)); }
jw_key    :: (w: *Json_Writer, key: string) { jw_check(w, jsonb_key(*w.b, w.buf.data, w.buf.count, key.data, xx key.count)); }
jw_string :: (w: *Json_Writer, s: string)   { jw_check(w, jsonb_string(*w.b, w.buf.data, w.buf.count, s.data, xx s.count)); }
jw_int :: (w: *Json_Writer, n: s64) {
    s := tprint("%", n);
    jw_check(w, jsonb_token(*w.b, w.buf.data, w.buf.count, s.data, xx s.count));
}

jw_result :: (w: *Json_Writer) -> string { return string.{xx w.b.pos, w.buf.data}; }

ws_send_identify :: (ws: *Voice_Ws) {
    w: Json_Writer;
    jw_init(*w);
    jw_object(*w);
        jw_key(*w, "op"); jw_int(*w, 0);
        jw_key(*w, "d");
        jw_object(*w);
            jw_key(*w, "server_id");  jw_string(*w, tprint("%", ws.guild_id));
            jw_key(*w, "user_id");    jw_string(*w, tprint("%", bot_user_id));
            jw_key(*w, "session_id"); jw_string(*w, ws.session_id);
            jw_key(*w, "token");      jw_string(*w, ws.token);
            jw_key(*w, "max_dave_protocol_version"); jw_int(*w, 1);
        jw_pop(*w);
    jw_pop(*w);

    if w.failed { print("Couldn't build Identify\n"); return; }
    print("-> Identify (server_id=%, session_id=%, token=***)\n", ws.guild_id, ws.session_id);
    ws_send_text(ws, jw_result(*w));
}

ws_send_text :: (ws: *Voice_Ws, text: string) -> bool {
    sent: u64;
    ret := curl_ws_send(ws.curl, text.data, xx text.count, *sent, 0, CURLWS_TEXT);
    if ret != CURLE_OK || sent != xx text.count {
        print("Voice WS send failed: % (sent % of %)\n", to_string(curl_easy_strerror(ret)), sent, text.count);
        return false;
    }
    return true;
}

ws_send_heartbeat :: (ws: *Voice_Ws) -> bool {
    if ws.waiting_for_ack  print("Voice WS: no ACK for the previous heartbeat\n");

    ws.last_nonce = to_milliseconds(current_time_monotonic());
    
    w: Json_Writer;
    jw_init(*w);
    jw_object(*w);
        jw_key(*w, "op"); jw_int(*w, 3);
        jw_key(*w, "d");
        jw_object(*w);
            jw_key(*w, "t");       jw_int(*w, ws.last_nonce);
            jw_key(*w, "seq_ack"); jw_int(*w, ws.last_seq);
        jw_pop(*w);
    jw_pop(*w);
    if w.failed || !ws_send_text(ws, jw_result(*w))  return false;

    ws.waiting_for_ack = true;
    interval := milliseconds_to_apollo(xx ws.heartbeat_interval_ms);
    ws.next_heartbeat += interval;
    now := current_time_monotonic();
    if ws.next_heartbeat < now  ws.next_heartbeat = now + interval;
    return true;
}

stop_voice_ws :: () {
    if !voice_ws_running return;
    atomic_write(*voice_ws.stop_requested, true);
    thread_is_done(*voice_thread, -1);
    thread_deinit(*voice_thread);
    free(voice_ws.endpoint);
    free(voice_ws.session_id);
    free(voice_ws.token);
    free(voice_ws.ip);
    voice_ws = .{};
    voice_ws_running = false;
}

reset_voice :: () {
    stop_voice_ws();
    voice = .{};
}

//
// Discord event handlers
//

on_ready :: (client: *void, event: *Discord_Ready) #c_call {
    new_context: Context;
    push_context new_context {
        print("Discord is ready\n");
        print("User id is: %\n", event.user.id);
        bot_user_id = event.user.id;
        register_commands(client, event.application.id);
    }
}

on_interaction_create :: (client: *void, event: *Discord_Interaction) #c_call {
    new_context: Context;
    push_context new_context {
        if event.type != DISCORD_INTERACTION_APPLICATION_COMMAND || !event.data return;

        text := command_handle(client, event);
        defer free(text);
        send_reply(client, event, text);
    }
}

on_voice_state_update :: (client: *void, event: *Discord_Voice_State) #c_call {
    new_context: Context;
    push_context new_context {
        if event.user_id != bot_user_id ||
            event.guild_id != voice.guild_id return;

        if event.channel_id == 0 {
            reset_voice();
            return;
        }

        voice.channel_id = event.channel_id;
        session_id_len := c_style_strlen(event.session_id);
        assert(session_id_len < 64);
        memcpy(voice.session_id.data, event.session_id, session_id_len + 1);
        voice.state_update_received = true;
        if do_we_have_credentials() && !voice_ws_running start_voice_ws();
    }
}

on_voice_server_update :: (client: *void, event: *Discord_Voice_Server_Update) #c_call {
    new_context: Context;
    push_context new_context {
        if event.guild_id != voice.guild_id return;
        if !event.endpoint {
            voice.server_update_received = false;
            return;
        }
        token_len := c_style_strlen(event.token);
        assert(token_len < 64);
        memcpy(voice.token.data, event.token, token_len + 1);
        endpoint_len := c_style_strlen(event.endpoint);
        assert(endpoint_len < 64);
        memcpy(voice.endpoint.data, event.endpoint, endpoint_len + 1);
        voice.server_update_received = true;
        if voice.state_update_received  start_voice_ws();
    }
}

//
// Slash commands
//

command_handle :: (client: *void, event: *Discord_Interaction) -> string {
    if !event.guild_id return copy_string("This command only works in a server.");

    name := to_string(event.data.name);

    if name == "join" {
        channel_id, found := channel_option(event.data, "channel");
        if !found return copy_string("Pick an audio channel.");

        if voice.guild_id != 0 && voice.guild_id != event.guild_id
            return copy_string("Already connected in another server, doing nothing.");

        if do_we_have_credentials() && channel_id == voice.channel_id
            return copy_string("Already here.");

        stop_voice_ws();

        voice.guild_id = event.guild_id;
        voice.state_update_received = false;
        voice.server_update_received = false;
        update := Discord_Update_Voice_State.{ guild_id = event.guild_id, channel_id = channel_id, self_mute = false, self_deaf = true };
        discord_update_voice_state(client, *update);
        return sprint("Joining <#%>.", channel_id);
    }

    if name == "leave" {
        if event.guild_id != voice.guild_id
            return copy_string("Not connected to any channel in this server.");

        update := Discord_Update_Voice_State.{ guild_id = event.guild_id, channel_id = 0 };
        discord_update_voice_state(client, *update);

        reset_voice();
        return copy_string("Leaving the audio channel.");
    }

    return sprint("Unrecognized command: `%`.", name);
}

channel_option :: (data: *Discord_Interaction_Data, name: string) -> id: u64, found: bool {
    if !data.options return 0, false;

    for 0..data.options.size - 1 {
        option := *data.options.array[it];
        if to_string(option.name) != name continue;

        // IDs arrive as text, and Discord's JSON quotes them.
        value := trim(to_string(option.value), "\"");
        id, success := string_to_int(value, 10, u64);
        return id, success;
    }

    return 0, false;
}

send_reply :: (client: *void, event: *Discord_Interaction, text: string) {
    content := to_c_string(text);
    defer free(content);

    data: Discord_Interaction_Callback_Data;
    response: Discord_Interaction_Response;
    build_reply(*response, *data, content);

    ret := Discord_Ret.{fail = on_request_failed};
    code := discord_create_interaction_response(client, event.id, event.token, *response, *ret);
    report_if_failed("Couldn't reply", client, code);
}

build_reply :: (response: *Discord_Interaction_Response, data: *Discord_Interaction_Callback_Data, content: *u8) {
    data.content = content;
    data.flags = DISCORD_MESSAGE_EPHEMERAL;

    response.type = DISCORD_INTERACTION_CHANNEL_MESSAGE_WITH_SOURCE;
    response.data = data;
}

register_commands :: (client: *void, application_id: u64) {
    commands: Command_List;
    build_commands(*commands);

    ret := Discord_Ret.{fail = on_request_failed};
    code := discord_bulk_overwrite_global_application_commands(client, application_id, *commands.list, *ret);
    report_if_failed("Couldn't register commands", client, code);
}

Command_List :: struct {
    audio_channel_types: [2]s32;
    channel_types: Discord_List(s32);
    join_options: [1]Discord_Command_Option;
    join_option_list: Discord_List(Discord_Command_Option);
    commands: [2]Discord_Command;
    list: Discord_List(Discord_Command);
}

// These point at each other, so `out` has to stay in place until Concord has used them.
build_commands :: (out: *Command_List) {
    out.audio_channel_types = .[DISCORD_CHANNEL_GUILD_VOICE, DISCORD_CHANNEL_GUILD_STAGE_VOICE];
    out.channel_types.size = xx out.audio_channel_types.count;
    out.channel_types.array = out.audio_channel_types.data;

    channel := *out.join_options[0];
    channel.type = DISCORD_APPLICATION_OPTION_CHANNEL;
    channel.name = "channel";
    channel.description = "Audio channel to join";
    channel.required = true;
    channel.channel_types = *out.channel_types;

    out.join_option_list.size = xx out.join_options.count;
    out.join_option_list.array = out.join_options.data;

    join := *out.commands[0];
    join.type = DISCORD_APPLICATION_CHAT_INPUT;
    join.name = "join";
    join.description = "Join an audio channel";
    join.options = *out.join_option_list;
    join.default_member_permissions = DISCORD_PERMISSION_ADMINISTRATOR;
    join.default_permission = true;

    leave := *out.commands[1];
    leave.type = DISCORD_APPLICATION_CHAT_INPUT;
    leave.name = "leave";
    leave.description = "Leave the audio channel";
    leave.default_member_permissions = DISCORD_PERMISSION_ADMINISTRATOR;
    leave.default_permission = true;

    out.list.size = xx out.commands.count;
    out.list.array = out.commands.data;
}

// Concord's logs are off by default, so without this a failed request is invisible.
on_request_failed :: (client: *void, response: *Discord_Response) #c_call {
    new_context: Context;
    push_context new_context {
        print("Discord request failed: %\n", to_string(discord_strerror(response.code, client)));
    }
}

report_if_failed :: (action: string, client: *void, code: s32) {
    if code == CCORD_OK || code == CCORD_PENDING return;
    print("%: %\n", action, to_string(discord_strerror(code, client)));
}

//
// Audio
//

decode_and_opus_encode :: () {
    buffer: [2 * FRAME_SIZE]s16;
    encoded_buf: [4000]u8;
    opus_err: s32;

    outfile, s := file_open("output",
        for_writing = true,
        keep_existing_content = false);
    if !s {
        print("Failed to open file for writing.\n");
        return;
    }
    defer file_close(*outfile);

    path := to_c_string(TESTFILE);
    defer free(path);

    dec := decoder_open(path);
    if !dec {
        print("Failed to create miniaudio decoder.\n");
        return;
    }
    defer decoder_close(dec);

    opus_enc := opus_encoder_create(48000, 2, OPUS_APPLICATION_AUDIO, *opus_err);
    if !opus_enc {
        print("Failed to create opus encoder: %\n", to_string(opus_strerror(opus_err)));
        return;
    }
    defer opus_encoder_destroy(opus_enc);

    opus_dec := opus_decoder_create(48000, 2, *opus_err);
    if !opus_dec {
        print("Failed to create opus decoder: %\n", to_string(opus_strerror(opus_err)));
        return;
    }
    defer opus_decoder_destroy(opus_dec);

    while (true) {
        frames_read := decoder_read(dec, buffer.data, FRAME_SIZE);
        if frames_read < FRAME_SIZE {
            if frames_read == -1 {
                print("Failed to decode test file\n");
                break;
            }
            memset(buffer.data + 2 * frames_read, 0,
                (2 * FRAME_SIZE - 2 * frames_read) * size_of(s16));
        }

        bytes_encoded := opus_encode(opus_enc, buffer.data,
            FRAME_SIZE, encoded_buf.data, encoded_buf.count);
        if bytes_encoded < 0 {
            print("Failed to encode opus frame: %\n", to_string(opus_strerror(bytes_encoded)));
            break;
        }

        frames_decoded := opus_decode(opus_dec, encoded_buf.data,
            bytes_encoded, buffer.data, FRAME_SIZE, 0);
        if frames_decoded < 0 {
            print("Failed to decode opus frame: %\n", to_string(opus_strerror(frames_decoded)));
            break;
        }

        if !file_write(*outfile, buffer.data, frames_decoded * 2 * size_of(s16)) {
            print("Failed to write to disk\n");
            break;
        }

        if frames_read < FRAME_SIZE break;
    }
}
