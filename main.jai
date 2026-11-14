#import "Atomics";
#import "Basic";
#import "Command_Line";
#import "File";
#import "File_Utilities";
#import "POSIX";
#import "Socket";
#import "Sort";
#import "String";
#import "Thread";

#load "build.jai";
#load "ffi.jai";

//
// Constants
//

Context :: #Context;

TOKENFILE :: "bot-key";
OPUS_APPLICATION_AUDIO :: 2049;
FRAME_SIZE :: 960;

VOICE_MODE :: "aead_aes256_gcm_rtpsize";
IP_DISCOVERY_ATTEMPTS   :: 3;
IP_DISCOVERY_TIMEOUT_MS :: 1000;

DAVE_INIT_TRANSITION_ID :: 0;
DAVE_NEW_GROUP_EPOCH    :: 1;

FRAME_MS            :: 20;
OPUS_MAX_PACKET     :: 1500;
DAVE_FRAME_CAPACITY :: 2048;
RTP_HEADER_SIZE     :: 12;
RTP_PAYLOAD_TYPE    :: 0x78;
GCM_TAG_SIZE        :: 16;
NONCE_SUFFIX_SIZE   :: 4;
SILENCE_FRAME       :: u8.[0xF8, 0xFF, 0xFE];
SILENCE_FRAME_COUNT :: 5;
MAX_LAG_MS          :: 200;
PLAYER_IDLE_WAIT_MS :: 100;

Args :: struct {
    music_folder: string;
}

main :: () {
    success, args, is_set := parse_arguments(Args);
    if !success return;

    token, result := read_entire_file(TOKENFILE);
    if !result {
        print("Failed to read token file\n");
        return;
    }

    if !args.music_folder {
        print("Pass the folder to play from: -music_folder <path>\n");
        return;
    }
    folder, folder_ok := get_absolute_path(args.music_folder);
    if !folder_ok || !is_directory(folder) {
        print("Music folder % isn't a folder\n", args.music_folder);
        return;
    }
    music_folder = copy_string(folder);
    print("Music folder: %\n", music_folder);

    init(*player.mutex, "player");
    init(*player.wake);

    discord_context = context;
    daveSetLogSinkCallback(on_dave_log);
    client := discord_init(to_c_string(token));
    if !client {
        print("Failed to initialize discord client\n");
        return;
    }
    defer discord_cleanup(client);

    discord_add_intents(client, DISCORD_INTENT_GUILDS | DISCORD_INTENT_GUILD_VOICE_STATES);
    discord_set_on_ready(client, on_ready);
    discord_set_on_interaction_create(client, on_interaction_create);
    discord_set_on_guild_create(client, on_guild_create);
    discord_set_on_voice_state_update(client, on_voice_state_update);
    discord_set_on_voice_server_update(client, on_voice_server_update);

    err := discord_run(client);
    print("Discord connection stopped: %\n", to_string(discord_strerror(err, client)));
}

//
// State
//

// Discord's callbacks run on the main thread, inside discord_run. They push this to get main's
// temporary storage, and reset it on entry: nothing temporary outlives a callback.
discord_context: Context;

bot_user_id: u64;
music_folder: string;

Member_Voice_State :: struct {
    guild_id: u64;
    user_id: u64;
    channel_id: u64;
}

voice_states: [..]Member_Voice_State;

AUDIO_EXTENSIONS :: string.["flac", "mp3", "wav"];

// A playlist is a list of file names relative to the music folder. `pending` is what the main
// thread asked for, and `playing` is what the audio thread took from it.
Player :: struct {
    mutex: Mutex;
    wake: Semaphore;
    pending: [..]string;
    playing: [..]string;
    current := -1;  // index in `playing`, or -1 when nothing is playing
    stop_requested: bool;
}

player: Player;

// What the gateway told us about our voice session. Main thread only.
// An empty session_id or token means that update hasn't arrived yet.
Voice_Connection :: struct {
    session_id: [64]u8;
    token: [64]u8;
    endpoint: [64]u8;
    guild_id: u64;
    channel_id: u64;
}

voice: Voice_Connection;

// One connection to a voice server, shared by the main, voice and audio threads.
Voice_Ws :: struct {
    // Set by the main thread before the voice thread starts, then only read.
    endpoint, session_id, token: string;
    guild_id: u64;
    channel_id: u64;

    stop_requested: bool;  // the main thread asks the voice thread to end
    audio_stop: bool;      // the voice thread asks the audio thread to end

    // Voice thread only.
    socket: curl_socket_t;
    rx: [65536]u8;  rx_len: s64;
    heartbeat_interval_ms: float64;
    next_heartbeat: Apollo_Time;
    last_seq: s64 = -1;
    last_nonce: s64;  waiting_for_ack: bool;
    ip: string;  port: u16;
    external_ip: string;  external_port: u16;
    dave_protocol_version: s32;
    dave_pending_transitions: [..]Dave_Transition;
    dave_active_version: u16;
    audio_thread: Thread;
    audio_started: bool;

    // Used by the voice and audio threads, each behind its mutex.
    // Never take dave_mutex while holding curl_mutex.
    curl_mutex: Mutex;
    curl: *CURL;
    dave_mutex: Mutex;
    dave: DAVE_Session;
    dave_encryptor: DAVE_Encryptor;

    // Written by the voice thread before it starts the audio thread, which then reads them.
    ssrc: u32;
    udp: Socket = INVALID_SOCKET;
    cipher: *EVP_CIPHER_CTX;

    // Audio thread only.
    rtp_sequence: u16;
    rtp_timestamp: u32;
    transport_nonce: u32;
}

Dave_Transition :: struct {
    id: u16;
    protocol_version: u16;
}

voice_ws: Voice_Ws;
voice_thread: Thread;
voice_ws_running: bool;

//
// Discord event handlers
//

on_ready :: (client: *void, event: *Discord_Ready) #c_call {
    push_context discord_context {
        reset_temporary_storage();
        print("Discord is ready\n");
        print("User id is: %\n", event.user.id);
        bot_user_id = event.user.id;
        register_commands(client, event.application.id);
    }
}

on_interaction_create :: (client: *void, event: *Discord_Interaction) #c_call {
    push_context discord_context {
        reset_temporary_storage();
        if !event.data  return;
        if event.type == DISCORD_INTERACTION_APPLICATION_COMMAND_AUTOCOMPLETE {
            send_file_suggestions(client, event);
            return;
        }
        if event.type != DISCORD_INTERACTION_APPLICATION_COMMAND  return;

        send_reply(client, event, command_handle(client, event));
    }
}

on_guild_create :: (client: *void, event: *Discord_Guild) #c_call {
    push_context discord_context {
        reset_temporary_storage();
        for voice_states  if it.guild_id == event.id  remove it;

        if !event.voice_states  return;
        for 0..event.voice_states.size - 1 {
            state := *event.voice_states.array[it];
            remember_voice_state(event.id, state.user_id, state.channel_id);
        }
    }
}

on_voice_state_update :: (client: *void, event: *Discord_Voice_State) #c_call {
    push_context discord_context {
        reset_temporary_storage();
        remember_voice_state(event.guild_id, event.user_id, event.channel_id);

        if event.user_id != bot_user_id ||
            event.guild_id != voice.guild_id return;

        if event.channel_id == 0 {
            reset_voice();
            return;
        }

        voice.channel_id = event.channel_id;
        if !copy_c_string(*voice.session_id, event.session_id, "session id")  return;
        if voice.token[0] && !voice_ws_running  start_voice_ws();
    }
}

on_voice_server_update :: (client: *void, event: *Discord_Voice_Server_Update) #c_call {
    push_context discord_context {
        reset_temporary_storage();
        if event.guild_id != voice.guild_id return;
        if !event.endpoint || !copy_c_string(*voice.endpoint, event.endpoint, "endpoint")
                           || !copy_c_string(*voice.token, event.token, "token") {
            stop_voice_ws();
            voice.token[0] = 0;
            return;
        }
        if voice.session_id[0]  start_voice_ws();
    }
}

// Leaves `to` empty when `from` doesn't fit.
copy_c_string :: (to: *[64]u8, from: *u8, what: string) -> bool {
    length := c_style_strlen(from);
    if length >= to.count {
        print("Discord sent a % of % bytes, which is more than we can hold. Ignoring it.\n", what, length);
        to.*[0] = 0;
        return false;
    }
    memcpy(to.data, from, length + 1);
    return true;
}

//
// Slash commands
//

command_handle :: (client: *void, event: *Discord_Interaction) -> string {
    if !event.guild_id return "This command only works in a server.";

    name := to_string(event.data.name);

    if name == "play" {
        file := string_option(event.data, "file");  // optional: without it, play from the top

        caller := ifx event.member && event.member.user then event.member.user.id else 0;
        channel_id := voice_channel_of(event.guild_id, caller);
        if !channel_id  return "Join an audio channel first, or use /join to pick one.";

        return join_and_play(client, event.guild_id, channel_id, file);
    }

    if name == "join" {
        channel_id, found := channel_option(event.data, "channel");
        if !found return "Pick an audio channel.";
        file := string_option(event.data, "file");

        return join_and_play(client, event.guild_id, channel_id, file);
    }

    if name == "stop" {
        if event.guild_id != voice.guild_id
            return "Not connected to any channel in this server.";

        stopped := player_stop();
        if !stopped  return "Nothing is playing.";
        return tprint("Stopped `%`.", stopped);
    }

    if name == "leave" {
        if event.guild_id != voice.guild_id
            return "Not connected to any channel in this server.";

        update := Discord_Update_Voice_State.{ guild_id = event.guild_id, channel_id = 0 };
        discord_update_voice_state(client, *update);

        reset_voice();
        return "Leaving the audio channel.";
    }

    return tprint("Unrecognized command: `%`.", name);
}

join_and_play :: (client: *void, guild_id: u64, channel_id: u64, file: string) -> string {
    if voice.guild_id != 0 && voice.guild_id != guild_id
        return "Already connected in another server, doing nothing.";

    playlist, error := build_playlist(file);
    if error  return error;
    what := describe_playlist(playlist, file);

    if voice_ws_alive() && voice.guild_id == guild_id && voice.channel_id == channel_id {
        player_play(playlist);
        return tprint("Playing %.", what);
    }

    stop_voice_ws();
    player_play(playlist);

    voice.guild_id = guild_id;
    voice.channel_id = channel_id;
    voice.token[0] = 0;  // wait for the new server before connecting; the session id stays valid
    update := Discord_Update_Voice_State.{ guild_id = guild_id, channel_id = channel_id, self_mute = false, self_deaf = true };
    discord_update_voice_state(client, *update);
    return tprint("Joining <#%> to play %.", channel_id, what);
}

build_playlist :: (start: string) -> [..]string, error: string {
    playlist: [..]string;
    names := scan_music_folder();
    if !names.count  return playlist, "There are no audio files in the music folder.";

    // The scan is the list of what can be played, so a name that isn't in it is refused.
    first := 0;
    if start {
        found, index := array_find(names, start);
        if !found  return playlist, tprint("There's no audio file `%` in the music folder.", start);
        first = index;
    }

    for first..names.count - 1  array_add(*playlist, copy_string(names[it]));
    return playlist, "";
}

describe_playlist :: (playlist: []string, start: string) -> string {
    plural :: (n: s64) -> string { return ifx n == 1 then "" else "s"; }
    if !start  return tprint("the music folder (% track%)", playlist.count, plural(playlist.count));
    rest := playlist.count - 1;
    if !rest  return tprint("`%`", playlist[0]);
    return tprint("`%`, then % more track% from the folder", playlist[0], rest, plural(rest));
}

// The sorted names of the audio files, relative to the music folder, in temporary storage.
scan_music_folder :: () -> []string {
    names: [..]string;
    names.allocator = temp;

    visit :: (info: *File_Visit_Info, names: *[..]string) {
        if info.had_error  return;  // e.g. a broken symlink

        name := slice(info.full_name, music_folder.count + 1, info.full_name.count - music_folder.count - 1);
        for split(name, "/",, temp)  if begins_with(it, ".")  return;

        extension, has_extension := path_extension(name);
        if !has_extension || !array_find(AUDIO_EXTENSIONS, to_lower_copy(extension,, temp))  return;

        if info.is_symlink {
            real, ok := get_absolute_path(info.full_name);
            if !ok || !begins_with(real, tprint("%/", music_folder))  return;
        }
        array_add(names, copy_temporary_string(name));
    }

    visit_files(music_folder, recursive = true, *names, visit, follow_directory_symlinks = false);
    quick_sort(names, compare_names);
    return names;
}

compare_names :: (a: string, b: string) -> s64 {
    order := compare_nocase(a, b);
    if order  return order;
    return compare(a, b);
}

remember_voice_state :: (guild_id: u64, user_id: u64, channel_id: u64) {
    for * voice_states {
        if it.guild_id != guild_id || it.user_id != user_id  continue;
        if channel_id  it.channel_id = channel_id;
        else           remove it;
        return;
    }
    if channel_id  array_add(*voice_states, .{guild_id, user_id, channel_id});
}

voice_channel_of :: (guild_id: u64, user_id: u64) -> u64 {
    for voice_states  if it.guild_id == guild_id && it.user_id == user_id  return it.channel_id;
    return 0;
}

find_option :: (data: *Discord_Interaction_Data, name: string) -> *Discord_Interaction_Option {
    if !data.options return null;
    for 0..data.options.size - 1 {
        option := *data.options.array[it];
        if to_string(option.name) == name  return option;
    }
    return null;
}

channel_option :: (data: *Discord_Interaction_Data, name: string) -> id: u64, found: bool {
    option := find_option(data, name);
    if !option || !option.value  return 0, false;

    id, success := string_to_int(to_string(option.value), 10, u64);
    return id, success;
}

string_option :: (data: *Discord_Interaction_Data, name: string) -> string, found: bool {
    option := find_option(data, name);
    if !option || !option.value  return "", false;

    json := to_string(option.value);
    if !json  return "", false;

    buffer := cast(*u8) talloc(json.count + 1);
    length := jsmnf_unescape(buffer, xx (json.count + 1), json.data, xx json.count);
    if length <= 0  return "", false;
    return .{length, buffer}, true;
}

send_reply :: (client: *void, event: *Discord_Interaction, text: string) {
    data := Discord_Interaction_Callback_Data.{content = temp_c_string(text), flags = DISCORD_MESSAGE_EPHEMERAL};
    response := Discord_Interaction_Response.{type = DISCORD_INTERACTION_CHANNEL_MESSAGE_WITH_SOURCE, data = *data};

    ret := Discord_Ret.{fail = on_request_failed};
    code := discord_create_interaction_response(client, event.id, event.token, *response, *ret);
    report_if_failed("Couldn't reply", client, code);
}

send_file_suggestions :: (client: *void, event: *Discord_Interaction) {
    query := string_option(event.data, "file");
    words := split(to_lower_copy(query,, temp), " ",, temp);

    choices: [DISCORD_MAX_AUTOCOMPLETE_CHOICES]Discord_Command_Option_Choice;
    count := 0;
    for scan_music_folder() {
        if count == choices.count  break;
        if character_count(it) > DISCORD_MAX_CHOICE_LENGTH  continue;
        if !matches_all(to_lower_copy(it,, temp), words)  continue;

        choices[count] = .{name = temp_c_string(it), value = temp_c_string(json_quote(it))};
        count += 1;
    }

    list := discord_list(array_view(choices, 0, count));
    data := Discord_Interaction_Callback_Data.{choices = *list};
    response := Discord_Interaction_Response.{type = DISCORD_INTERACTION_APPLICATION_COMMAND_AUTOCOMPLETE_RESULT, data = *data};

    ret := Discord_Ret.{fail = on_request_failed};
    code := discord_create_interaction_response(client, event.id, event.token, *response, *ret);
    report_if_failed("Couldn't send suggestions", client, code);
}

matches_all :: (text: string, words: []string) -> bool {
    for words  if it && !contains(text, it)  return false;
    return true;
}

character_count :: (s: string) -> s64 {
    count := 0;
    for 0..s.count - 1  if (s[it] & 0xC0) != 0x80  count += 1;
    return count;
}

json_quote :: (s: string) -> string {
    builder: String_Builder;
    builder.allocator = temp;
    append(*builder, "\"");
    for 0..s.count - 1 {
        c := s[it];
        if c == #char "\"" || c == #char "\\" {
            append(*builder, "\\");
            append(*builder, c);
        } else if c < 0x20 {
            print_to_builder(*builder, "\\u%", formatInt(c, base = 16, minimum_digits = 4));
        } else {
            append(*builder, c);
        }
    }
    append(*builder, "\"");
    return builder_to_string(*builder,, temp);
}

discord_list :: (items: []$T) -> Discord_List(T) {
    return .{size = xx items.count, array = items.data};
}

// The lists point at these locals, which is fine because Concord serializes them during the call.
register_commands :: (client: *void, application_id: u64) {
    audio_channel_types := s32.[DISCORD_CHANNEL_GUILD_VOICE, DISCORD_CHANNEL_GUILD_STAGE_VOICE];
    channel_types := discord_list(audio_channel_types);

    file := Discord_Command_Option.{
        type = DISCORD_APPLICATION_OPTION_STRING,
        name = "file",
        description = "File to start from, inside the music folder (default: the first one)",
        autocomplete = true,
    };
    channel := Discord_Command_Option.{
        type = DISCORD_APPLICATION_OPTION_CHANNEL,
        name = "channel",
        description = "Audio channel to join",
        required = true,
        channel_types = *channel_types,
    };
    play_array := Discord_Command_Option.[file];
    join_array := Discord_Command_Option.[channel, file];
    play_options := discord_list(play_array);
    join_options := discord_list(join_array);

    command :: (name: *u8, description: *u8, options: *Discord_List(Discord_Command_Option) = null) -> Discord_Command {
        return .{
            type = DISCORD_APPLICATION_CHAT_INPUT,
            name = name,
            description = description,
            options = options,
            default_member_permissions = DISCORD_PERMISSION_ADMINISTRATOR,
            default_permission = true,
        };
    }
    command_array := Discord_Command.[
        command("play",  "Join your audio channel and play the music folder", *play_options),
        command("join",  "Join an audio channel and play the music folder", *join_options),
        command("stop",  "Stop playing"),
        command("leave", "Leave the audio channel"),
    ];
    commands := discord_list(command_array);

    ret := Discord_Ret.{fail = on_request_failed};
    code := discord_bulk_overwrite_global_application_commands(client, application_id, *commands, *ret);
    report_if_failed("Couldn't register commands", client, code);
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
// Voice connection lifecycle
//

start_voice_ws :: () {
    stop_voice_ws();    

    voice_ws.endpoint = copy_string(to_string(voice.endpoint.data));
    voice_ws.session_id = copy_string(to_string(voice.session_id.data));
    voice_ws.token = copy_string(to_string(voice.token.data));
    voice_ws.guild_id = voice.guild_id;
    voice_ws.channel_id = voice.channel_id;

    if !thread_init(*voice_thread, voice_ws_thread) {
        print("Failed to create the voice WS thread\n");
        free(voice_ws.endpoint);
        free(voice_ws.session_id);
        free(voice_ws.token);
        voice_ws = .{};
        return;
    }
    init(*voice_ws.dave_mutex, "dave");
    init(*voice_ws.curl_mutex, "curl");
    voice_thread.data = *voice_ws;
    thread_start(*voice_thread);
    voice_ws_running = true;
}

stop_voice_ws :: () {
    if !voice_ws_running return;
    atomic_write(*voice_ws.stop_requested, true);
    thread_is_done(*voice_thread, -1);
    thread_deinit(*voice_thread);
    free(voice_ws.endpoint);
    free(voice_ws.session_id);
    free(voice_ws.token);
    destroy(*voice_ws.dave_mutex);
    destroy(*voice_ws.curl_mutex);
    voice_ws = .{};
    voice_ws_running = false;
}

// The voice thread can end on its own: the connection failed, or Discord closed it.
// When it has, this cleans up after it, so the next /play or /join connects again.
voice_ws_alive :: () -> bool {
    if voice_ws_running && thread_is_done(*voice_thread)  stop_voice_ws();
    return voice_ws_running;
}

reset_voice :: () {
    stop_voice_ws();
    player_stop();
    voice = .{};
}

//
// Voice websocket
//

voice_ws_thread :: (thread: *Thread) -> s64 {
    ws := cast(*Voice_Ws) thread.data;
    defer { free(ws.ip); free(ws.external_ip); array_free(ws.dave_pending_transitions); }
    if !ws_connect(ws) return 1;
    defer curl_easy_cleanup(ws.curl);
    defer close_and_reset(*ws.udp);
    defer transport_destroy(ws);
    if !dave_create(ws)  return 1;
    defer dave_destroy(ws);
    defer audio_stop_and_join(ws);

    gotta_stop: bool;

    while !gotta_stop {
        reset_temporary_storage();
        pfd := pollfd.{fd = ws.socket, events = POLLIN};
        poll(*pfd, 1, ws_ms_until_next_wakeup(ws));       // at most ~250 ms, so stop_requested is noticed
        if !ws_drain(ws) break;
        if ws.heartbeat_interval_ms > 0 && current_time_monotonic() >= ws.next_heartbeat
            if !ws_send_heartbeat(ws)  break;

        if !ws.audio_started && audio_ready(ws)  audio_start(ws);

        gotta_stop = atomic_read(*ws.stop_requested);
    }

    if gotta_stop print("Voice WS closed by us\n");

    return 0;
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
    ret := curl_easy_perform(ws.curl);
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

ws_drain :: (ws: *Voice_Ws) -> bool {
    got: u64;
    meta: *Curl_Ws_Frame;
    
    while (true) {
        lock(*ws.curl_mutex);
        ret := curl_ws_recv(ws.curl, ws.rx.data + ws.rx_len, xx (ws.rx.count - ws.rx_len), *got, *meta);
        unlock(*ws.curl_mutex);
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
                    code := ifx msg.count >= 2 then get_u16_be(msg.data) else 0;
                    reason := ifx msg.count > 2 then slice(msg, 2, msg.count - 2) else "";
                    print("Voice WS closed by Discord: "); 
                    if code != 0 print("% '%'\n", code, reason);
                    else print("no code\n");
                    return false;
                }
                if meta.flags & CURLWS_TEXT {
                    if !handle_text(ws, msg)  return false;
                }
                if meta.flags & CURLWS_BINARY {
                    if msg.count < 3 {
                        print("<- binary message too short (%)\n", msg.count);
                        continue;
                    }

                    ws.last_seq = get_u16_be(msg.data);
                    if !handle_binary(ws, msg[2], .{msg.count - 3, msg.data + 3})  return false;
                }
            case;
                print("Connection lost: %\n", to_string(curl_easy_strerror(ret)));
                return false;
        }
    }
    return false;
}

handle_text :: (ws: *Voice_Ws, msg: string) -> bool {
    parser: Jsmn_Parser;
    tokens: [128]Jsmn_Token;
    jsmn_init(*parser);
    num_tokens := jsmn_parse(*parser, msg.data, xx msg.count, tokens.data, tokens.count);
    if num_tokens < 0 {
        print("<- %\nBad JSON (%)\n", msg, num_tokens);
        return true;
    }

    loader: Jsmnf_Loader;
    pairs: [128]Jsmnf_Pair;
    jsmnf_init(*loader);
    if jsmnf_load(*loader, msg.data, tokens.data, xx num_tokens, pairs.data, pairs.count) < 0 {
        print("<- %\nCouldn't load JSON\n", msg);
        return true;
    }

    root := *pairs[0];
    op, has_op := json_int(root, msg, "op");
    if !has_op {
        print("<- %\nMessage without \"op\"\n", msg);
        return true;
    }

    seq, has_seq := json_int(root, msg, "seq");
    if has_seq  ws.last_seq = seq;

    d := json_find(root, msg, "d");

    // These get a one-line summary. Op 4 holds the secret key, so it must not be logged as is.
    quiet := op == 4 || op == 6 || op == 11 || op == 13 || op == 15 || op == 18 || op == 20;
    if !quiet  print("<- %\n", msg);

    if op == {
        case 8; // Hello
            interval := json_find(d, msg, "heartbeat_interval");
            if !interval {
                print("Message without \"heartbeat_interval\"\n");
                return true;
            }

            ws.heartbeat_interval_ms = string_to_float64(json_text(interval, msg));
            ws.next_heartbeat = current_time_monotonic() + milliseconds_to_apollo(xx ws.heartbeat_interval_ms);
            print("Heartbeat every % ms\n", ws.heartbeat_interval_ms);
            ws_send_identify(ws);
        case 6; // ACK
            t, has_t := json_int(d, msg, "t");
            if has_t && t == ws.last_nonce {
                rtt := to_milliseconds(current_time_monotonic()) - ws.last_nonce;
                print("Heartbeat ACK (% ms)\n", rtt);
                ws.waiting_for_ack = false;
            } else print("Unexpected nonce in ACK: %\n", msg);
        case 2; // Ready
            if ws.audio_started {
                print("Ready again while sending audio, ignoring it\n");
                return true;
            }

            ssrc, has_ssrc := json_int(d, msg, "ssrc");
            port, has_port := json_int(d, msg, "port");
            ip    := json_find(d, msg, "ip");
            modes := json_find(d, msg, "modes");
            if !has_ssrc || !has_port || !ip || !modes {
                print("Ready is missing fields\n");
                return false;
            }

            free(ws.ip);

            ws.ssrc = xx ssrc;
            ws.ip   = copy_string(json_text(ip, msg));
            ws.port = xx port;

            offered := false;
            for 0..modes.size-1 {
                mode := json_text(*modes.fields[it], msg);
                if mode == VOICE_MODE  offered = true;
            }
            print("Ready: ssrc=% udp=%:% %=%\n", ws.ssrc, ws.ip, ws.port, VOICE_MODE, offered);
            if !offered {
                // XChaCha20-Poly1305 is the fallback to add if this ever happens.
                print("The voice server doesn't offer %\n", VOICE_MODE);
                return false;
            }

            {
                dave_lock(ws);
                daveEncryptorAssignSsrcToCodec(ws.dave_encryptor, ws.ssrc, .OPUS);
            }

            if !udp_open(ws)         return false;
            if !udp_discover_ip(ws)  return false;
            if !ws_send_select_protocol(ws)  return false;
        case 4; // Session Description
            if ws.audio_started {
                print("<- Session Description again while sending audio, ignoring it\n");
                return true;
            }

            mode := json_find(d, msg, "mode");
            key  := json_find(d, msg, "secret_key");
            secret_key: [32]u8;
            defer memset(secret_key.data, 0, secret_key.count);
            if !mode || !key || key.size != secret_key.count {
                print("Session Description is missing fields or has a bad secret_key\n");
                return false;
            }

            if json_text(mode, msg) != VOICE_MODE {
                print("Session Description picked mode %, we asked for %\n", json_text(mode, msg), VOICE_MODE);
                return false;
            }

            for 0..key.size-1  secret_key[it] = xx string_to_int(json_text(*key.fields[it], msg));
            ws.dave_protocol_version = xx json_int(d, msg, "dave_protocol_version");  // 0 when it's missing
            print("<- Session Description: mode=% dave_protocol_version=% secret_key=(% bytes)\n",
                json_text(mode, msg), ws.dave_protocol_version, secret_key.count);

            if !transport_init(ws, secret_key.data)  return false;

            dave_lock(ws);
            if !dave_protocol_init(ws, xx ws.dave_protocol_version)  return false;
        case 11; // Clients Connect
            ids := json_find(d, msg, "user_ids");
            if !ids  return true;
            for 0..ids.size-1 {
                dave_lock(ws);
                daveSessionAddRecognizedUser(ws.dave, temp_c_string(json_text(*ids.fields[it], msg)));
            }
            print("<- Clients Connect: % user(s)\n", ids.size);
        case 13; // Client Disconnect
            user := json_find(d, msg, "user_id");
            if !user  return true;
            print("<- Client Disconnect: %\n", json_text(user, msg));
            dave_lock(ws);
            daveSessionRemoveRecognizedUser(ws.dave, temp_c_string(json_text(user, msg)));
        case 15; // Media Sink Wants: only matters for video
        case 18; // Client Flags
        case 20; // Client Platform
        case 21; // DAVE Prepare Transition
            transition_id, has_id := json_int(d, msg, "transition_id");
            version, has_version   := json_int(d, msg, "protocol_version");
            if !has_id || !has_version {
                print("Prepare Transition is missing fields\n");
                return true;
            }
            dave_lock(ws);
            return dave_prepare_transition(ws, xx transition_id, xx version);
        case 22; // DAVE Execute Transition
            transition_id, has_id := json_int(d, msg, "transition_id");
            if !has_id {
                print("Execute Transition is missing transition_id\n");
                return true;
            }
            dave_lock(ws);
            dave_execute_transition(ws, xx transition_id);
        case 24; // DAVE Prepare Epoch
            epoch, has_epoch     := json_int(d, msg, "epoch");
            version, has_version := json_int(d, msg, "protocol_version");
            if !has_epoch || !has_version {
                print("Prepare Epoch is missing fields\n");
                return true;
            }
            dave_lock(ws);
            return dave_prepare_epoch(ws, epoch, xx version);
        case;
            print("Unhandled \"op\" (%)\n", op);
    }
    return true;
}

handle_binary :: (ws: *Voice_Ws, op: u8, payload: []u8) -> bool {
    dave_lock(ws);

    if op == {
        case 25; // MLS External Sender Package
            print("<- DAVE external sender (% bytes)\n", payload.count);
            daveSessionSetExternalSender(ws.dave, payload.data, xx payload.count);
        case 27; // MLS Proposals
            print("<- DAVE proposals (% bytes)\n", payload.count);
            commit_welcome: *u8;
            commit_welcome_length: u64;
            daveSessionProcessProposals(ws.dave, payload.data, xx payload.count, *commit_welcome, *commit_welcome_length);
            if commit_welcome {
                defer daveFree(commit_welcome);
                return ws_send_binary(ws, 28, .{xx commit_welcome_length, commit_welcome});
            }
        case 29; // MLS Announce Commit Transition: [transition_id u16][commit]
            if payload.count < 2 {
                print("<- DAVE commit too short (% bytes)\n", payload.count);
                return true;
            }
            transition_id := get_u16_be(payload.data);
            print("<- DAVE commit for transition % (% bytes)\n", transition_id, payload.count - 2);

            result := daveSessionProcessCommit(ws.dave, payload.data + 2, xx (payload.count - 2));
            defer if result  daveCommitResultDestroy(result);

            if result && daveCommitResultIsIgnored(result) {
                print("DAVE: commit ignored\n");
                return true;
            }

            if !result || daveCommitResultIsFailed(result) {
                print("DAVE: commit failed, flagging it and rejoining\n");
                if !ws_send_transition_op(ws, 31, transition_id)  return false;
                return dave_protocol_init(ws, daveSessionGetProtocolVersion(ws.dave));
            }

            return dave_prepare_transition(ws, transition_id, daveSessionGetProtocolVersion(ws.dave));
        case 30; // MLS Welcome: [transition_id u16][welcome]
            if payload.count < 2 {
                print("<- DAVE welcome too short (% bytes)\n", payload.count);
                return true;
            }
            transition_id := get_u16_be(payload.data);
            print("<- DAVE welcome for transition % (% bytes)\n", transition_id, payload.count - 2);

            result := daveSessionProcessWelcome(ws.dave, payload.data + 2, xx (payload.count - 2));
            if !result {
                print("DAVE: welcome failed, flagging it and sending a new key package\n");
                if !ws_send_transition_op(ws, 31, transition_id)  return false;
                return ws_send_key_package(ws);
            }
            daveWelcomeResultDestroy(result);

            print("DAVE: joined the group\n");
            return dave_prepare_transition(ws, transition_id, daveSessionGetProtocolVersion(ws.dave));
        case;
            print("<- binary op=% seq=% (% bytes), unhandled\n", op, ws.last_seq, payload.count);
    }
    return true;
}

ws_send :: (ws: *Voice_Ws, data: []u8, flags: u32) -> bool {
    sent: u64;
    lock(*ws.curl_mutex);
    ret := curl_ws_send(ws.curl, data.data, xx data.count, *sent, 0, flags);
    unlock(*ws.curl_mutex);
    if ret != CURLE_OK || sent != xx data.count {
        print("Voice WS send failed: % (sent % of %)\n", to_string(curl_easy_strerror(ret)), sent, data.count);
        return false;
    }
    return true;
}

ws_send_text :: (ws: *Voice_Ws, text: string, log := true) -> bool {
    if log  print("-> %\n", text);
    return ws_send(ws, cast([]u8) text, CURLWS_TEXT);
}

// Client binary messages have no sequence number: [op u8][payload].
ws_send_binary :: (ws: *Voice_Ws, op: u8, payload: []u8) -> bool {
    message := cast(*u8) talloc(payload.count + 1);
    message[0] = op;
    memcpy(message + 1, payload.data, payload.count);
    print("-> binary op=% (% bytes)\n", op, payload.count);
    return ws_send(ws, .{payload.count + 1, message}, CURLWS_BINARY);
}

ws_send_key_package :: (ws: *Voice_Ws) -> bool {
    key_package: *u8;
    length: u64;
    daveSessionGetMarshalledKeyPackage(ws.dave, *key_package, *length);
    if !key_package {
        print("DAVE: couldn't make a key package\n");
        return false;
    }
    defer daveFree(key_package);
    return ws_send_binary(ws, 26, .{xx length, key_package});
}

// Ready For Transition (23) and Invalid Commit Welcome (31) only carry the transition ID.
ws_send_transition_op :: (ws: *Voice_Ws, op: s64, transition_id: u16) -> bool {
    return ws_send_text(ws, tprint("{\"op\":%,\"d\":{\"transition_id\":%}}", op, transition_id));
}

ws_send_identify :: (ws: *Voice_Ws) {
    print("-> Identify (server_id=%, session_id=%, token=***)\n", ws.guild_id, ws.session_id);
    ws_send_text(ws, tprint("{\"op\":0,\"d\":{\"server_id\":\"%\",\"user_id\":\"%\",\"session_id\":%,\"token\":%,\"max_dave_protocol_version\":1}}",
        ws.guild_id, bot_user_id, json_quote(ws.session_id), json_quote(ws.token)), log = false);
}

ws_send_select_protocol :: (ws: *Voice_Ws) -> bool {
    return ws_send_text(ws, tprint("{\"op\":1,\"d\":{\"protocol\":\"udp\",\"data\":{\"address\":%,\"port\":%,\"mode\":\"%\"}}}",
        json_quote(ws.external_ip), ws.external_port, VOICE_MODE));
}

ws_send_speaking :: (ws: *Voice_Ws, speaking: s64) -> bool {
    return ws_send_text(ws, tprint("{\"op\":5,\"d\":{\"speaking\":%,\"delay\":0,\"ssrc\":%}}", speaking, ws.ssrc));
}

ws_send_heartbeat :: (ws: *Voice_Ws) -> bool {
    if ws.waiting_for_ack  print("Voice WS: no ACK for the previous heartbeat\n");

    ws.last_nonce = to_milliseconds(current_time_monotonic());
    heartbeat := tprint("{\"op\":3,\"d\":{\"t\":%,\"seq_ack\":%}}", ws.last_nonce, ws.last_seq);
    if !ws_send_text(ws, heartbeat, log = false)  return false;

    ws.waiting_for_ack = true;
    interval := milliseconds_to_apollo(xx ws.heartbeat_interval_ms);
    ws.next_heartbeat += interval;
    now := current_time_monotonic();
    if ws.next_heartbeat < now  ws.next_heartbeat = now + interval;
    return true;
}

//
// DAVE
//
// Everything here expects the caller to hold ws.dave_mutex.

dave_lock :: (ws: *Voice_Ws) #expand {
    lock(*ws.dave_mutex);
    `defer unlock(*ws.dave_mutex);
}

dave_create :: (ws: *Voice_Ws) -> bool {
    dave_lock(ws);
    ws.dave = daveSessionCreate(null, null, on_mls_failure, null);
    ws.dave_encryptor = daveEncryptorCreate();
    if !ws.dave || !ws.dave_encryptor {
        print("DAVE: couldn't create the session or the encryptor\n");
        return false;
    }
    // Until the first transition executes, frames would go out without end-to-end encryption.
    daveEncryptorSetPassthroughMode(ws.dave_encryptor, true);
    return true;
}

dave_destroy :: (ws: *Voice_Ws) {
    dave_lock(ws);
    if ws.dave_encryptor  daveEncryptorDestroy(ws.dave_encryptor);
    if ws.dave            daveSessionDestroy(ws.dave);
    ws.dave_encryptor = null;
    ws.dave = null;
}

self_user_id_c :: () -> *u8 {
    return temp_c_string(tprint("%", bot_user_id));
}

// After Session Description (op 4), and again after a failed commit.
dave_protocol_init :: (ws: *Voice_Ws, version: u16) -> bool {
    if version > 0  return dave_prepare_epoch(ws, DAVE_NEW_GROUP_EPOCH, version);
    return dave_prepare_transition(ws, DAVE_INIT_TRANSITION_ID, 0);
}

// An epoch that starts a new group also sends our key package.
dave_prepare_epoch :: (ws: *Voice_Ws, epoch: s64, version: u16) -> bool {
    print("DAVE: prepare epoch % (protocol version %)\n", epoch, version);
    if epoch != DAVE_NEW_GROUP_EPOCH  return true;
    daveSessionInit(ws.dave, version, ws.channel_id, self_user_id_c());
    return ws_send_key_package(ws);
}

// The init transition takes effect right away. Any other one waits for Execute Transition,
// and Discord is told we're ready for it (op 23).
dave_prepare_transition :: (ws: *Voice_Ws, transition_id: u16, version: u16) -> bool {
    print("DAVE: prepare transition % to protocol version %\n", transition_id, version);

    if transition_id == DAVE_INIT_TRANSITION_ID {
        dave_use_version(ws, version);
        return true;
    }

    for ws.dave_pending_transitions  if it.id == transition_id  remove it;
    array_add(*ws.dave_pending_transitions, .{transition_id, version});
    return ws_send_transition_op(ws, 23, transition_id);
}

dave_execute_transition :: (ws: *Voice_Ws, transition_id: u16) {
    for ws.dave_pending_transitions {
        if it.id != transition_id  continue;
        version := it.protocol_version;
        remove it;

        print("DAVE: execute transition % to protocol version %\n", transition_id, version);
        if version == 0  daveSessionReset(ws.dave);
        dave_use_version(ws, version);
        return;
    }

    print("DAVE: execute for transition %, which wasn't prepared\n", transition_id);
}

dave_use_version :: (ws: *Voice_Ws, version: u16) {
    if version == 0 {
        daveEncryptorSetPassthroughMode(ws.dave_encryptor, true);
        ws.dave_active_version = 0;
        print("DAVE: sending without end-to-end encryption\n");
        return;
    }

    ratchet := daveSessionGetKeyRatchet(ws.dave, self_user_id_c());
    if !ratchet {
        print("DAVE: no key ratchet for us at protocol version %\n", version);
        return;
    }
    daveEncryptorSetKeyRatchet(ws.dave_encryptor, ratchet);  // the encryptor keeps its own copy
    daveKeyRatchetDestroy(ratchet);
    daveEncryptorSetPassthroughMode(ws.dave_encryptor, false);
    ws.dave_active_version = version;
    print("DAVE: sending with end-to-end encryption, protocol version %\n", version);
}

on_mls_failure :: (source: *u8, reason: *u8, user_data: *void) #c_call {
    new_context: Context;
    push_context new_context {
        print("DAVE: MLS failure in %: %\n", to_string(source), to_string(reason));
    }
}

on_dave_log :: (severity: DAVE_Logging_Severity, file: *u8, line: s32, message: *u8) #c_call {
    if severity < .INFO  return;
    new_context: Context;
    push_context new_context {
        print("[libdave %] %:% %\n", severity, path_filename(to_string(file)), line, to_string(message));
    }
}

//
// Voice UDP
//

udp_open :: (ws: *Voice_Ws) -> bool {
    close_and_reset(*ws.udp);

    ws.udp = socket(AF_INET, .SOCK_DGRAM, .IPPROTO_UDP);
    if ws.udp == INVALID_SOCKET {
        print("Couldn't create the UDP socket: %\n", errno());
        return false;
    }

    address: sockaddr_in;
    address.sin_family = AF_INET;
    address.sin_port = htons(ws.port);
    ip := to_c_string(ws.ip);
    defer free(ip);
    if inet_pton(AF_INET, ip, *address.sin_addr) != 1 {
        print("Voice server IP isn't IPv4: %\n", ws.ip);
        return false;
    }

    if connect(ws.udp, cast(*sockaddr) *address, size_of(sockaddr_in)) != 0 {
        print("Couldn't connect the UDP socket to %:%: %\n", ws.ip, ws.port, errno());
        return false;
    }

    timeout: timeval;
    timeout.tv_sec  = IP_DISCOVERY_TIMEOUT_MS / 1000;
    timeout.tv_usec = (IP_DISCOVERY_TIMEOUT_MS % 1000) * 1000;
    if setsockopt(ws.udp, SOL_SOCKET, SO_RCVTIMEO, *timeout, size_of(timeval)) != 0 {
        print("Couldn't set the UDP receive timeout: %\n", errno());
        return false;
    }

    return true;
}

udp_discover_ip :: (ws: *Voice_Ws) -> bool {
    request: [74]u8;
    put_u16_be(request.data,     0x1);
    put_u16_be(request.data + 2, 70);
    put_u32_be(request.data + 4, ws.ssrc);

    reply: [74]u8;

    for attempt: 1..IP_DISCOVERY_ATTEMPTS {
        sent := send(ws.udp, request.data, request.count, 0);
        if sent != request.count {
            print("IP discovery: send failed (%), attempt %/%\n", errno(), attempt, IP_DISCOVERY_ATTEMPTS);
            continue;
        }

        got := recv(ws.udp, reply.data, reply.count, 0);
        if got < 0 {
            err := errno();
            if err == EAGAIN || err == EWOULDBLOCK
                print("IP discovery: no reply within % ms, attempt %/%\n", IP_DISCOVERY_TIMEOUT_MS, attempt, IP_DISCOVERY_ATTEMPTS);
            else
                print("IP discovery: recv failed (%), attempt %/%\n", err, attempt, IP_DISCOVERY_ATTEMPTS);
            continue;
        }

        if got != reply.count || get_u16_be(reply.data) != 0x2 || get_u32_be(reply.data + 4) != ws.ssrc {
            print("IP discovery: unexpected reply (% bytes, type %), attempt %/%\n", got, get_u16_be(reply.data), attempt, IP_DISCOVERY_ATTEMPTS);
            continue;
        }

        address_field := reply.data + 8;
        address_len := 0;
        while address_len < 64 && address_field[address_len] != 0  address_len += 1;

        free(ws.external_ip);
        ws.external_ip   = copy_string(string.{address_len, address_field});
        ws.external_port = get_u16_be(reply.data + 72);
        print("IP discovery: we are %:%\n", ws.external_ip, ws.external_port);
        return true;
    }

    print("IP discovery failed after % attempts\n", IP_DISCOVERY_ATTEMPTS);
    return false;
}

put_u16_be :: (p: *u8, v: u16) { p[0] = xx (v >> 8); p[1] = xx (v & 0xFF); }
put_u32_be :: (p: *u8, v: u32) {
    p[0] = xx (v >> 24); p[1] = xx ((v >> 16) & 0xFF); p[2] = xx ((v >> 8) & 0xFF); p[3] = xx (v & 0xFF);
}
get_u16_be :: (p: *u8) -> u16 { return ((cast(u16) p[0]) << 8) | p[1]; }
get_u32_be :: (p: *u8) -> u32 {
    return ((cast(u32) p[0]) << 24) | ((cast(u32) p[1]) << 16) | ((cast(u32) p[2]) << 8) | p[3];
}

//
// JSON helpers
//

json_text :: (p: *Jsmnf_Pair, js: string) -> string {
    return string.{xx p.v.len, js.data + p.v.pos};
}

json_find :: (obj: *Jsmnf_Pair, js: string, key: string) -> *Jsmnf_Pair {
    if !obj return null;
    return jsmnf_find(obj, js.data, key.data, xx key.count);
}

json_int :: (obj: *Jsmnf_Pair, js: string, key: string) -> s64, found: bool {
    pair := json_find(obj, js, key);
    if !pair  return 0, false;
    value := string_to_int(json_text(pair, js));
    return value, true;
}

//
// Transport encryption (aead_aes256_gcm_rtpsize)
//

transport_init :: (ws: *Voice_Ws, secret_key: *u8) -> bool {
    transport_destroy(ws);
    ws.cipher = EVP_CIPHER_CTX_new();
    if !ws.cipher {
        print("Couldn't create the AES-256-GCM context\n");
        return false;
    }
    if EVP_EncryptInit_ex(ws.cipher, EVP_aes_256_gcm(), null, secret_key, null) != 1 {
        print("Couldn't load the transport key\n");
        transport_destroy(ws);
        return false;
    }
    return true;
}

transport_destroy :: (ws: *Voice_Ws) {
    if ws.cipher  EVP_CIPHER_CTX_free(ws.cipher);
    ws.cipher = null;
}

transport_encrypt :: (ctx: *EVP_CIPHER_CTX, nonce: u32, aad: []u8, plaintext: []u8, out: *u8) -> bool {
    iv: [12]u8;
    put_u32_be(iv.data, nonce);
    if EVP_EncryptInit_ex(ctx, null, null, null, iv.data) != 1  return false;

    length: s32;
    if EVP_EncryptUpdate(ctx, null, *length, aad.data, xx aad.count) != 1  return false;
    if EVP_EncryptUpdate(ctx, out, *length, plaintext.data, xx plaintext.count) != 1  return false;
    written := length;
    if EVP_EncryptFinal_ex(ctx, out + written, *length) != 1  return false;
    written += length;
    if written != plaintext.count  return false;

    return EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, GCM_TAG_SIZE, out + written) == 1;
}

//
// Audio
//

audio_ready :: (ws: *Voice_Ws) -> bool {
    if !ws.cipher  return false;
    return ws.dave_protocol_version == 0 || ws.dave_active_version > 0;
}

audio_start :: (ws: *Voice_Ws) {
    ws.audio_started = true;
    atomic_write(*ws.audio_stop, false);
    if !thread_init(*ws.audio_thread, audio_thread_proc) {
        print("Failed to create the audio thread\n");
        return;
    }
    ws.audio_thread.data = ws;
    thread_start(*ws.audio_thread);
}

audio_stop_and_join :: (ws: *Voice_Ws) {
    if !ws.audio_started || !ws.audio_thread.data  return;
    atomic_write(*ws.audio_stop, true);
    thread_is_done(*ws.audio_thread, -1);
    thread_deinit(*ws.audio_thread);
    ws.audio_thread = .{};
}

// Runs for the whole voice connection: waits for a playlist, plays it, and waits again.
audio_thread_proc :: (thread: *Thread) -> s64 {
    ws := cast(*Voice_Ws) thread.data;

    while !atomic_read(*ws.audio_stop) {
        reset_temporary_storage();
        playlist, found := player_take_pending();
        if !found {
            wait_for(*player.wake, PLAYER_IDLE_WAIT_MS);
            continue;
        }
        play_playlist(ws, playlist);
        player_finish();
    }
    return 0;
}

Audio_Stats :: struct {
    sent: s64;
    failed: s64;
}

Track_End :: enum {
    FINISHED;
    STOPPED;
    CUT_OFF;
}

play_playlist :: (ws: *Voice_Ws, playlist: []string) {
    opus_err: s32;
    opus_enc := opus_encoder_create(48000, 2, OPUS_APPLICATION_AUDIO, *opus_err);
    if !opus_enc {
        print("Audio: couldn't create the Opus encoder: %\n", to_string(opus_strerror(opus_err)));
        return;
    }
    defer opus_encoder_destroy(opus_enc);

    if !ws_send_speaking(ws, 1)  return;

    stats: Audio_Stats;
    next_frame := current_time_monotonic();
    ending := Track_End.FINISHED;

    for playlist {
        player_set_current(it_index);
        print("Audio: playing % (%/%)\n", it, it_index + 1, playlist.count);
        ending = play_track(ws, opus_enc, it, *next_frame, *stats);
        if ending != .FINISHED  break;
    }

    if ending == .CUT_OFF {
        print("Audio: cut off (% frames sent, % failed)\n", stats.sent, stats.failed);
        return;
    }

    for 1..SILENCE_FRAME_COUNT {
        if atomic_read(*ws.audio_stop)  return;
        send_frame_on_schedule(ws, SILENCE_FRAME, *next_frame, milliseconds_to_apollo(FRAME_MS), *stats);
    }
    ws_send_speaking(ws, 0);

    print("Audio: % (% frames sent, % failed)\n", ifx ending == .STOPPED then "stopped" else "playlist finished", stats.sent, stats.failed);
}

play_track :: (ws: *Voice_Ws, opus_enc: *void, name: string, next_frame: *Apollo_Time, stats: *Audio_Stats) -> Track_End {
    dec := decoder_open(temp_c_string(tprint("%/%", music_folder, name)));
    if !dec {
        print("Audio: couldn't open %, skipping it\n", name);
        return .FINISHED;
    }
    defer decoder_close(dec);

    pcm: [2 * FRAME_SIZE]s16;
    opus: [OPUS_MAX_PACKET]u8;
    frame_duration := milliseconds_to_apollo(FRAME_MS);

    while true {
        reset_temporary_storage();
        if atomic_read(*ws.audio_stop)  return .CUT_OFF;
        if atomic_read(*player.stop_requested)  return .STOPPED;

        frames_read := decoder_read(dec, pcm.data, FRAME_SIZE);
        if frames_read < 0 {
            print("Audio: decoding % failed, skipping the rest of it\n", name);
            return .FINISHED;
        }
        // A file that ends exactly on a frame boundary gets here with 0 frames.
        // Stopping now, instead of padding, avoids sending an extra frame of silence.
        if frames_read == 0  return .FINISHED;
        if frames_read < FRAME_SIZE
            memset(pcm.data + 2 * frames_read, 0, (2 * FRAME_SIZE - 2 * frames_read) * size_of(s16));

        bytes := opus_encode(opus_enc, pcm.data, FRAME_SIZE, opus.data, opus.count);
        if bytes < 0 {
            print("Audio: Opus encoding failed in %: %\n", name, to_string(opus_strerror(bytes)));
            return .FINISHED;
        }

        send_frame_on_schedule(ws, .{xx bytes, opus.data}, next_frame, frame_duration, stats);
        if frames_read < FRAME_SIZE  return .FINISHED;
    }
    return .FINISHED;
}

send_frame_on_schedule :: (ws: *Voice_Ws, opus: []u8, next_frame: *Apollo_Time, frame_duration: Apollo_Time, stats: *Audio_Stats) {
    packet: [RTP_HEADER_SIZE + DAVE_FRAME_CAPACITY + GCM_TAG_SIZE + NONCE_SUFFIX_SIZE]u8;
    length, error := build_packet(ws, opus, packet);

    wait_until(<<next_frame);

    if !error {
        sent := send(ws.udp, packet.data, xx length, 0);
        if sent != length  error = tprint("UDP send failed (%)", errno());
    }

    if error {
        // Only every 250th failure (5 s of audio), so a lasting problem doesn't flood the log.
        if stats.failed % 250 == 0  print("Audio: % (% failed so far)\n", error, stats.failed + 1);
        stats.failed += 1;
    } else {
        stats.sent += 1;
    }

    ws.rtp_sequence  += 1;
    ws.rtp_timestamp += FRAME_SIZE;

    <<next_frame += frame_duration;
    now := current_time_monotonic();
    if now - <<next_frame > milliseconds_to_apollo(MAX_LAG_MS) {
        print("Audio: % ms behind, restarting the schedule\n", to_milliseconds(now - <<next_frame));
        <<next_frame = now;
    }
}

build_packet :: (ws: *Voice_Ws, opus: []u8, packet: []u8) -> length: s64, error: string {
    header     := packet.data;
    ciphertext := packet.data + RTP_HEADER_SIZE;

    dave_frame: [DAVE_FRAME_CAPACITY]u8;
    dave_length: u64;
    {
        dave_lock(ws);
        needed := daveEncryptorGetMaxCiphertextByteSize(ws.dave_encryptor, .AUDIO, xx opus.count);
        if needed > dave_frame.count
            return 0, tprint("DAVE needs % bytes for a % byte frame", needed, opus.count);
        result := daveEncryptorEncrypt(ws.dave_encryptor, .AUDIO, ws.ssrc, opus.data, xx opus.count,
            dave_frame.data, dave_frame.count, *dave_length);
        if result != .SUCCESS  return 0, tprint("DAVE encryption failed: %", result);
    }

    header[0] = 0x80;
    header[1] = RTP_PAYLOAD_TYPE;
    put_u16_be(header + 2, ws.rtp_sequence);
    put_u32_be(header + 4, ws.rtp_timestamp);
    put_u32_be(header + 8, ws.ssrc);

    nonce := ws.transport_nonce;
    ws.transport_nonce += 1;

    plaintext := []u8.{xx dave_length, dave_frame.data};
    if !transport_encrypt(ws.cipher, nonce, .{RTP_HEADER_SIZE, header}, plaintext, ciphertext)
        return 0, "transport encryption failed";
    put_u32_be(ciphertext + plaintext.count + GCM_TAG_SIZE, nonce);

    return RTP_HEADER_SIZE + plaintext.count + GCM_TAG_SIZE + NONCE_SUFFIX_SIZE, "";
}

wait_until :: (deadline: Apollo_Time) {
    while true {
        remaining := to_microseconds(deadline - current_time_monotonic());
        if remaining <= 0  return;
        sleep_milliseconds(xx ((remaining + 999) / 1000));
    }
}


//
// Player requests
//

player_play :: (playlist: [..]string) {
    lock(*player.mutex);
    free_playlist(*player.pending);
    player.pending = playlist;
    if player.playing.count  atomic_write(*player.stop_requested, true);
    unlock(*player.mutex);
    signal(*player.wake);
}

// Returns the name of the track it stopped, or of the first one waiting to start, in temporary
// storage. Empty when nothing was playing or waiting.
player_stop :: () -> string {
    lock(*player.mutex);
    defer unlock(*player.mutex);

    stopped: string;
    if player.current >= 0 {
        atomic_write(*player.stop_requested, true);
        stopped = copy_temporary_string(player.playing[player.current]);
    } else if player.pending.count {
        stopped = copy_temporary_string(player.pending[0]);
    }
    free_playlist(*player.pending);
    return stopped;
}

player_take_pending :: () -> []string, found: bool {
    lock(*player.mutex);
    defer unlock(*player.mutex);

    if !player.pending.count  return .[], false;
    player.playing = player.pending;
    player.pending = [..]string.{};
    player.current = 0;
    atomic_write(*player.stop_requested, false);
    return player.playing, true;
}

player_set_current :: (index: s64) {
    lock(*player.mutex);
    player.current = index;
    unlock(*player.mutex);
}

player_finish :: () {
    lock(*player.mutex);
    free_playlist(*player.playing);
    player.current = -1;
    unlock(*player.mutex);
}

free_playlist :: (playlist: *[..]string) {
    for <<playlist  free(it);
    array_free(<<playlist);
    <<playlist = [..]string.{};
}
