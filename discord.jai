//
// Discord's gateway and REST API, on libcurl. Everything here runs on the main thread.
//
// The session rules (when to resume, when to start over, when to give up) are the ones
// Concord had in src/discord-gateway.c. Two things differ: consecutive failed attempts
// wait before the next one, and a heartbeat that Discord asks for (op 1) gets sent.
//

DISCORD_API_URL       :: "https://discord.com/api/v10";
DISCORD_GATEWAY_QUERY :: "?v=10&encoding=json";
DISCORD_USER_AGENT    :: "DiscordBot (custom, 1.0)";

DISCORD_INTENT_GUILDS             :: 1 << 0;
DISCORD_INTENT_GUILD_VOICE_STATES :: 1 << 7;

DISCORD_PERMISSION_ADMINISTRATOR :: 1 << 3;
DISCORD_MESSAGE_EPHEMERAL        :: 1 << 6;

DISCORD_CHANNEL_GUILD_VOICE       :: 2;
DISCORD_CHANNEL_GUILD_STAGE_VOICE :: 13;

DISCORD_APPLICATION_CHAT_INPUT     :: 1;
DISCORD_APPLICATION_OPTION_STRING  :: 3;
DISCORD_APPLICATION_OPTION_CHANNEL :: 7;

DISCORD_INTERACTION_APPLICATION_COMMAND              :: 2;
DISCORD_INTERACTION_APPLICATION_COMMAND_AUTOCOMPLETE :: 4;

DISCORD_INTERACTION_CHANNEL_MESSAGE_WITH_SOURCE             :: 4;
DISCORD_INTERACTION_APPLICATION_COMMAND_AUTOCOMPLETE_RESULT :: 8;

DISCORD_MAX_AUTOCOMPLETE_CHOICES :: 25;
DISCORD_MAX_CHOICE_LENGTH        :: 100;

GATEWAY_DISPATCH           :: 0;
GATEWAY_HEARTBEAT          :: 1;
GATEWAY_IDENTIFY           :: 2;
GATEWAY_VOICE_STATE_UPDATE :: 4;
GATEWAY_RESUME             :: 6;
GATEWAY_RECONNECT          :: 7;
GATEWAY_INVALID_SESSION    :: 9;
GATEWAY_HELLO              :: 10;
GATEWAY_HEARTBEAT_ACK      :: 11;

// A close with 1000 or 1001 ends the session on Discord's side. Any other code keeps it resumable.
WS_CLOSE_NORMAL         :: 1000;
WS_CLOSE_ABNORMAL       :: 1006;  // never on the wire: the connection dropped without a close frame
GATEWAY_CLOSE_RECONNECT :: 4900;

GATEWAY_MAX_RECONNECT_DELAY_S :: 30;
REST_TIMEOUT_MS               :: 10000;
REST_MAX_RATE_LIMIT_WAIT_MS   :: 5000;

#if OS == .WINDOWS  DISCORD_OS_NAME :: "windows";
else #if OS == .MACOS  DISCORD_OS_NAME :: "macos";
else  DISCORD_OS_NAME :: "linux";

Gateway :: struct {
    token: string;
    intents: u64;

    curl: *CURL;
    socket: curl_socket_t;
    rx: [..]u8;

    // Grown by jsmn as needed and reused for every message.
    tokens: *Jsmn_Token;  num_tokens: u32;
    pairs: *Jsmnf_Pair;   num_pairs: u32;

    session_id: string;
    resume_url: string;
    seq: s64;  // 0 until the first dispatch

    ready: bool;      // READY or RESUMED arrived on this connection
    closing: bool;    // this connection is over, whoever ended it
    resumable: bool;  // the next connection resumes the session instead of starting one
    retry := true;    // false once Discord closed with a code that reconnecting can't fix
    stop_reason: string;
    attempt: s64;     // connections since the last one that got to READY or RESUMED

    heartbeat_interval: Apollo_Time;
    last_heartbeat: Apollo_Time;
    heartbeat_acknowledged: bool;
}

gateway: Gateway;

Rest :: struct {
    curl: *CURL;
    headers: *void;
    response: [..]u8;
}

rest: Rest;

Interaction :: struct {
    id: u64;
    token: string;
    type: s64;
    guild_id: u64;
    user_id: u64;  // 0 outside of a server
    command: string;
    options: []Interaction_Option;
}

Interaction_Option :: struct {
    name: string;
    value: string;  // strings unescaped, anything else as it is in the JSON
}

//
// Gateway
//

// Returns once the connection can't go on, with the reason.
discord_run :: (token: string, intents: u64) -> string {
    gw := *gateway;
    gw.token = token;
    gw.intents = intents;
    if !rest_init(token)  return "couldn't set up libcurl";

    while true {
        if gw.attempt > 1 {
            delay := min(1 << min(gw.attempt - 2, 5), GATEWAY_MAX_RECONNECT_DELAY_S);
            print("Gateway: waiting % s before trying again\n", delay);
            sleep_milliseconds(xx (delay * 1000));
        }

        result, reason := gateway_connect(gw);
        if result == .FATAL  return reason;
        if result == .CONNECTED {
            gateway_loop(gw);
            gateway_disconnect(gw);
            if !gw.retry  return gw.stop_reason;
        }

        gw.attempt += 1;
        print("Gateway: reconnect attempt #%\n", gw.attempt);
    }
    return "";
}

Gateway_Connect_Result :: enum {
    CONNECTED;
    FAILED;  // worth another attempt
    FATAL;
}

gateway_connect :: (gw: *Gateway) -> Gateway_Connect_Result, reason: string {
    reset_temporary_storage();

    status, response := rest_request("GET", "/gateway/bot");
    if status == 401  return .FATAL, "Discord rejected the bot token";
    if status != 200 {
        if status  print("Gateway: couldn't get the gateway URL (HTTP %): %\n", status, response);
        return .FAILED, "";
    }

    tokens: [128]Jsmn_Token;
    pairs: [128]Jsmnf_Pair;
    root := json_load(response, tokens, pairs);
    base_url := json_string(root, response, "url");
    if !base_url {
        print("Gateway: no URL in Discord's answer: %\n", response);
        return .FAILED, "";
    }

    limit := json_find(root, response, "session_start_limit");
    remaining, has_remaining := json_int(limit, response, "remaining");
    if has_remaining && remaining == 0 {
        reset_after := json_int(limit, response, "reset_after");
        return .FATAL, sprint("no session starts left, Discord allows more in % seconds", reset_after / 1000);
    }

    url: string;
    if gw.resumable && gw.resume_url {
        // Used once: if resuming there fails, the next attempt goes back to the regular URL.
        url = copy_temporary_string(gw.resume_url);
        free(gw.resume_url);
        gw.resume_url = "";
    } else {
        url = gateway_url(base_url);
    }

    gw.curl = curl_easy_init();
    if !gw.curl {
        print("Gateway: curl_easy_init failed\n");
        return .FAILED, "";
    }
    curl_easy_setopt_ptr(gw.curl, CURLOPT_URL, temp_c_string(url));
    curl_easy_setopt_long(gw.curl, CURLOPT_CONNECT_ONLY, 2);
    curl_easy_setopt_long(gw.curl, CURLOPT_CONNECTTIMEOUT_MS, 10000);
    ret := curl_easy_perform(gw.curl);
    if ret != CURLE_OK {
        print("Gateway: couldn't connect to %: %\n", url, to_string(curl_easy_strerror(ret)));
        gateway_disconnect(gw);
        return .FAILED, "";
    }
    curl_easy_getinfo_socket(gw.curl, CURLINFO_ACTIVESOCKET, *gw.socket);

    gw.rx.count = 0;
    gw.ready = false;
    gw.closing = false;
    gw.heartbeat_acknowledged = true;
    print("Gateway: connected to %\n", url);
    return .CONNECTED, "";
}

gateway_url :: (base: string) -> string {
    return tprint("%1%2%3", base, ifx ends_with(base, "/") then "" else "/", DISCORD_GATEWAY_QUERY);
}

gateway_disconnect :: (gw: *Gateway) {
    if gw.curl  curl_easy_cleanup(gw.curl);
    gw.curl = null;
    gw.ready = false;
}

gateway_loop :: (gw: *Gateway) {
    while true {
        gateway_drain(gw);
        if gw.closing  return;

        // Heartbeats start with READY or RESUMED, which send the first one.
        timeout: s64 = 1000;
        if gw.ready {
            remaining := to_milliseconds(gw.last_heartbeat + gw.heartbeat_interval - current_time_monotonic());
            if remaining <= 0 {
                gateway_send_heartbeat(gw);
                continue;
            }
            timeout = min(remaining, timeout);
        }
        wait_readable(gw.socket, xx timeout);
    }
}

// Handles every message libcurl has. Sets gw.closing when the connection is over.
gateway_drain :: (gw: *Gateway) {
    while !gw.closing {
        if gw.rx.allocated - gw.rx.count < 4096  array_reserve(*gw.rx, max(65536, gw.rx.allocated * 2));

        got: u64;
        meta: *Curl_Ws_Frame;
        ret := curl_ws_recv(gw.curl, gw.rx.data + gw.rx.count, xx (gw.rx.allocated - gw.rx.count), *got, *meta);
        if ret == CURLE_AGAIN  return;
        if ret != CURLE_OK {
            gateway_on_close(gw, WS_CLOSE_ABNORMAL, to_string(curl_easy_strerror(ret)));
            return;
        }

        if meta.flags & (CURLWS_PING | CURLWS_PONG)  continue;  // libcurl answers pings itself

        gw.rx.count += xx got;
        if meta.bytesleft > 0 || (meta.flags & CURLWS_CONT)  continue;

        msg := string.{gw.rx.count, gw.rx.data};
        gw.rx.count = 0;

        if meta.flags & CURLWS_CLOSE {
            code := ifx msg.count >= 2 then cast(s64) get_u16_be(msg.data) else WS_CLOSE_ABNORMAL;
            reason := ifx msg.count > 2 then slice(msg, 2, msg.count - 2) else "";
            gateway_on_close(gw, code, reason);
            return;
        }
        if meta.flags & CURLWS_TEXT {
            reset_temporary_storage();
            gateway_on_text(gw, msg);
        }
    }
}

gateway_on_text :: (gw: *Gateway, msg: string) {
    parser: Jsmn_Parser;
    jsmn_init(*parser);
    num_tokens := jsmn_parse_auto(*parser, msg.data, xx msg.count, *gw.tokens, *gw.num_tokens);
    if num_tokens <= 0 {
        print("Gateway: bad JSON (%)\n", num_tokens);
        return;
    }

    loader: Jsmnf_Loader;
    jsmnf_init(*loader);
    if jsmnf_load_auto(*loader, msg.data, gw.tokens, parser.toknext, *gw.pairs, *gw.num_pairs) <= 0 {
        print("Gateway: couldn't load JSON\n");
        return;
    }

    root := gw.pairs;
    seq := json_int(root, msg, "s");
    if seq  gw.seq = seq;
    d := json_find(root, msg, "d");

    op, has_op := json_int(root, msg, "op");
    if !has_op {
        print("Gateway: message without \"op\"\n");
        return;
    }

    if op == {
        case GATEWAY_DISPATCH;
            gateway_on_dispatch(gw, json_string(root, msg, "t"), d, msg);
        case GATEWAY_HEARTBEAT;
            gateway_send_heartbeat(gw, check_ack = false);
        case GATEWAY_RECONNECT;
            gw.resumable = true;
            gateway_close(gw, GATEWAY_CLOSE_RECONNECT, "Discord expects client to reconnect");
        case GATEWAY_INVALID_SESSION;
            gw.resumable = !d || json_text(d, msg) != "false";
            if gw.resumable  gateway_close(gw, GATEWAY_CLOSE_RECONNECT, "Invalid session, will attempt to resume");
            else             gateway_close(gw, WS_CLOSE_NORMAL, "Invalid session, can't resume");
        case GATEWAY_HELLO;
            interval, has_interval := json_int(d, msg, "heartbeat_interval");
            if !has_interval || interval <= 0 {
                print("Gateway: Hello without \"heartbeat_interval\"\n");
                return;
            }
            gw.heartbeat_interval = milliseconds_to_apollo(interval);

            if gw.resumable && gw.session_id  gateway_send_resume(gw);
            else                              gateway_send_identify(gw);
            gw.resumable = false;
        case GATEWAY_HEARTBEAT_ACK;
            gw.heartbeat_acknowledged = true;
        case;
            print("Gateway: unhandled op %\n", op);
    }
}

gateway_on_dispatch :: (gw: *Gateway, name: string, d: *Jsmnf_Pair, msg: string) {
    if name == "READY" {
        free(gw.session_id);
        gw.session_id = copy_string(json_string(d, msg, "session_id"));

        resume_url := json_string(d, msg, "resume_gateway_url");
        free(gw.resume_url);
        gw.resume_url = ifx resume_url then copy_string(gateway_url(resume_url)) else "";

        print("Gateway: started a session\n");
    } else if name == "RESUMED" {
        print("Gateway: resumed the session\n");
    }

    if name == "READY" || name == "RESUMED" {
        gw.ready = true;
        gw.attempt = 0;
        gateway_send_heartbeat(gw);
    }

    on_discord_event(name, d, msg);
}

// Discord closed the connection, or it dropped.
gateway_on_close :: (gw: *Gateway, code: s64, reason: string) {
    if gw.closing  return;  // the answer to our own close
    gw.closing = true;

    outcome: string;
    if code == {
        case WS_CLOSE_NORMAL; #through;
        case 4000; #through;  // unknown error
        case 4001; #through;  // unknown opcode
        case 4002; #through;  // decode error
        case 4003; #through;  // not authenticated
        case 4005; #through;  // already authenticated
        case 4008;            // rate limited
            gw.resumable = true;
            outcome = "reconnecting to resume the session";
        case 4004; #through;  // authentication failed
        case 4010; #through;  // invalid shard
        case 4011; #through;  // sharding required
        case 4012; #through;  // invalid API version
        case 4013; #through;  // invalid intents
        case 4014;            // disallowed intents
            gw.resumable = false;
            gw.retry = false;
            gw.stop_reason = sprint("Discord closed the gateway with % '%'", code, reason);
            outcome = "not reconnecting";
        case;  // 4007 invalid sequence, 4009 session timed out, and anything that isn't Discord's
            gw.resumable = false;
            outcome = "reconnecting to start a new session";
    }
    print("Gateway: closed with % '%', %\n", code, reason, outcome);
}

// We end the connection. gw.resumable says what the next one does.
gateway_close :: (gw: *Gateway, code: u16, reason: string) {
    print("Gateway: closing with % '%'\n", code, reason);

    payload := cast(*u8) talloc(2 + reason.count);
    put_u16_be(payload, code);
    memcpy(payload + 2, reason.data, reason.count);
    sent: u64;
    curl_ws_send(gw.curl, payload, xx (2 + reason.count), *sent, 0, CURLWS_CLOSE);

    gw.closing = true;
}

gateway_send :: (gw: *Gateway, text: string) -> bool {
    if gw.closing  return false;

    sent: u64;
    ret := curl_ws_send(gw.curl, text.data, xx text.count, *sent, 0, CURLWS_TEXT);
    if ret != CURLE_OK || sent != xx text.count {
        gateway_on_close(gw, WS_CLOSE_ABNORMAL, tprint("send failed: %", to_string(curl_easy_strerror(ret))));
        return false;
    }
    return true;
}

gateway_send_identify :: (gw: *Gateway) {
    gw.seq = 0;
    gateway_send(gw, tprint("{\"op\":%,\"d\":{\"token\":%,\"intents\":%,\"properties\":{\"os\":\"%\",\"browser\":\"libcurl\",\"device\":\"libcurl\"}}}",
        GATEWAY_IDENTIFY, json_quote(gw.token), gw.intents, DISCORD_OS_NAME));
}

gateway_send_resume :: (gw: *Gateway) {
    gateway_send(gw, tprint("{\"op\":%,\"d\":{\"token\":%,\"session_id\":%,\"seq\":%}}",
        GATEWAY_RESUME, json_quote(gw.token), json_quote(gw.session_id), gw.seq));
}

gateway_send_heartbeat :: (gw: *Gateway, check_ack := true) {
    if check_ack && !gw.heartbeat_acknowledged {
        // A zombie connection: drop it and start a new session.
        print("Gateway: no ACK for the previous heartbeat\n");
        gw.heartbeat_acknowledged = true;
        gw.resumable = false;
        gateway_close(gw, WS_CLOSE_NORMAL, "Heartbeat ACK not received");
        return;
    }

    seq := ifx gw.seq then tprint("%", gw.seq) else "null";
    if !gateway_send(gw, tprint("{\"op\":%,\"d\":%}", GATEWAY_HEARTBEAT, seq))  return;
    gw.heartbeat_acknowledged = false;
    gw.last_heartbeat = current_time_monotonic();
}

// A channel_id of 0 leaves the voice channel.
discord_update_voice_state :: (guild_id: u64, channel_id: u64, self_deaf := false) {
    channel := ifx channel_id then tprint("\"%\"", channel_id) else "null";
    gateway_send(*gateway, tprint("{\"op\":%,\"d\":{\"guild_id\":\"%\",\"channel_id\":%,\"self_mute\":false,\"self_deaf\":%}}",
        GATEWAY_VOICE_STATE_UPDATE, guild_id, channel, self_deaf));
}

decode_interaction :: (d: *Jsmnf_Pair, js: string) -> Interaction, ok: bool {
    data := json_find(d, js, "data");
    if !data  return .{}, false;

    interaction: Interaction;
    interaction.id       = json_id(d, js, "id");
    interaction.token    = json_string(d, js, "token");
    interaction.type     = json_int(d, js, "type");
    interaction.guild_id = json_id(d, js, "guild_id");
    interaction.user_id  = json_id(json_find(json_find(d, js, "member"), js, "user"), js, "id");
    interaction.command  = json_string(data, js, "name");

    options := json_find(data, js, "options");
    if options && options.type == JSMN_ARRAY {
        list: [..]Interaction_Option;
        list.allocator = temp;
        for 0..options.size - 1 {
            option := *options.fields[it];
            value := json_find(option, js, "value");
            array_add(*list, .{json_string(option, js, "name"), ifx value then json_value(value, js) else ""});
        }
        interaction.options = list;
    }
    return interaction, true;
}

//
// REST
//

rest_init :: (token: string) -> bool {
    rest.curl = curl_easy_init();
    if !rest.curl  return false;

    rest.headers = curl_slist_append(null, temp_c_string(tprint("Authorization: Bot %", token)));
    rest.headers = curl_slist_append(rest.headers, "Content-Type: application/json");
    curl_easy_setopt_ptr(rest.curl, CURLOPT_HTTPHEADER, rest.headers);
    curl_easy_setopt_ptr(rest.curl, CURLOPT_USERAGENT, DISCORD_USER_AGENT.data);
    curl_easy_setopt_ptr(rest.curl, CURLOPT_WRITEFUNCTION, cast(*void) rest_on_data);
    curl_easy_setopt_long(rest.curl, CURLOPT_TIMEOUT_MS, REST_TIMEOUT_MS);
    return true;
}

// Blocks until Discord answers. The status is 0 when there was no answer at all.
// The response is only good until the next request.
rest_request :: (method: string, path: string, body := "") -> status: s64, response: string {
    curl_easy_setopt_ptr(rest.curl, CURLOPT_URL, temp_c_string(tprint("%1%2", DISCORD_API_URL, path)));
    if body {
        curl_easy_setopt_long(rest.curl, CURLOPT_POSTFIELDSIZE, body.count);
        curl_easy_setopt_ptr(rest.curl, CURLOPT_POSTFIELDS, body.data);
        curl_easy_setopt_ptr(rest.curl, CURLOPT_CUSTOMREQUEST, temp_c_string(method));
    } else {
        curl_easy_setopt_long(rest.curl, CURLOPT_HTTPGET, 1);
        curl_easy_setopt_ptr(rest.curl, CURLOPT_CUSTOMREQUEST, null);
    }

    for attempt: 1..3 {
        rest.response.count = 0;
        ret := curl_easy_perform(rest.curl);
        response := string.{rest.response.count, rest.response.data};
        if ret != CURLE_OK {
            print("Discord request failed: % %: %\n", method, path, to_string(curl_easy_strerror(ret)));
            return 0, "";
        }

        status: C_Long;
        curl_easy_getinfo_long(rest.curl, CURLINFO_RESPONSE_CODE, *status);
        if status != 429 || attempt == 3  return status, response;

        tokens: [32]Jsmn_Token;
        pairs: [32]Jsmnf_Pair;
        retry_after := json_find(json_load(response, tokens, pairs), response, "retry_after");
        wait_ms := ifx retry_after then cast(s64) (string_to_float64(json_text(retry_after, response)) * 1000) + 1 else 1000;
        if wait_ms > REST_MAX_RATE_LIMIT_WAIT_MS  return status, response;
        print("Discord rate limit on % %, waiting % ms\n", method, path, wait_ms);
        sleep_milliseconds(xx wait_ms);
    }
    return 0, "";
}

rest_on_data :: (data: *u8, size: u64, count: u64, user_data: *void) -> u64 #c_call {
    new_context: Context;
    push_context new_context {
        bytes := cast(s64) (size * count);
        array_reserve(*rest.response, rest.response.count + bytes);
        memcpy(rest.response.data + rest.response.count, data, bytes);
        rest.response.count += bytes;
    }
    return size * count;
}

discord_report_if_failed :: (action: string, status: s64, response: string) {
    if status >= 200 && status < 300  return;
    if status  print("%: HTTP % %\n", action, status, response);
    else       print("%: no answer from Discord\n", action);
}

discord_respond :: (interaction: *Interaction, action: string, body: string) {
    status, response := rest_request("POST", tprint("/interactions/%/%/callback", interaction.id, interaction.token), body);
    discord_report_if_failed(action, status, response);
}
