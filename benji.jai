//
// Benji: a Discord bot that plays a folder of audio files in a voice channel.
//
// Copyright (C) 2026 Lluc Simó Margalef <lluc.simo@protonmail.com>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Build:  jai benji.jai   (this also builds the C and C++ dependencies, see "Libraries and build")
// Run:    benji -music_folder <path>   with the bot's token in the file `bot-key`
//
// Three threads:
//   - The main thread runs the Discord gateway and handles the slash commands.
//   - The voice thread, one per voice connection, runs the voice WebSocket and DAVE.
//   - The audio thread, started by the voice thread, decodes, encodes, encrypts and sends audio.
//

#import "Atomics";
#import "Basic";
#import "Command_Line";
#import "File";
#import "File_Utilities";
#import "Socket";
#import "Sort";
#import "String";
#import "Thread";

#if OS != .WINDOWS  #import "POSIX";

// Only used at compile time, by "Libraries and build".
#import "BuildCpp";
#import "Compiler";
#import "Process";

Context :: #Context;

// ============================================================================================
// The bot
// ============================================================================================

//
// Constants
//

TOKENFILE :: "bot-key";
AUDIO_EXTENSIONS :: string.["flac", "mp3", "wav"];

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

//
// Entry point
//

bot_user_id: u64;
music_folder: string;

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

    daveSetLogSinkCallback(on_dave_log);
    if curl_global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK {
        print("Failed to initialize libcurl\n");
        return;
    }

    reason := discord_run(trim(token), DISCORD_INTENT_GUILDS | DISCORD_INTENT_GUILD_VOICE_STATES);
    print("Discord connection stopped: %\n", reason);
}

//
// Discord event handlers
//

// Called on the main thread, inside discord_run, for every gateway dispatch. Temporary storage
// is reset before each one: nothing temporary outlives a handler.
on_discord_event :: (name: string, d: *Jsmnf_Pair, js: string) {
    if name == {
        case "READY";
            bot_user_id = json_id(json_find(d, js, "user"), js, "id");
            print("Discord is ready\n");
            print("User id is: %\n", bot_user_id);
            register_commands(json_id(json_find(d, js, "application"), js, "id"));

        case "INTERACTION_CREATE";
            interaction, ok := decode_interaction(d, js);
            if !ok  return;
            if interaction.type == DISCORD_INTERACTION_APPLICATION_COMMAND_AUTOCOMPLETE {
                send_file_suggestions(*interaction);
            } else if interaction.type == DISCORD_INTERACTION_APPLICATION_COMMAND {
                send_reply(*interaction, command_handle(*interaction));
            }

        case "GUILD_CREATE";
            guild_id := json_id(d, js, "id");
            for voice_states  if it.guild_id == guild_id  remove it;

            // These lack `guild_id`.
            states := json_find(d, js, "voice_states");
            if !states || states.type != JSMN_ARRAY  return;
            for 0..states.size - 1 {
                state := *states.fields[it];
                remember_voice_state(guild_id, json_id(state, js, "user_id"), json_id(state, js, "channel_id"));
            }

        case "VOICE_STATE_UPDATE";
            guild_id   := json_id(d, js, "guild_id");
            user_id    := json_id(d, js, "user_id");
            channel_id := json_id(d, js, "channel_id");
            remember_voice_state(guild_id, user_id, channel_id);

            if user_id != bot_user_id || guild_id != voice.guild_id  return;

            if channel_id == 0 {
                reset_voice();
                return;
            }

            voice.channel_id = channel_id;
            if !copy_c_string(*voice.session_id, json_string(d, js, "session_id"), "session id")  return;
            if voice.token[0] && !voice_ws_running  start_voice_ws();

        case "VOICE_SERVER_UPDATE";
            if json_id(d, js, "guild_id") != voice.guild_id  return;

            // A null endpoint means the voice server went away, and another update follows.
            endpoint := json_string(d, js, "endpoint");
            if !endpoint || !copy_c_string(*voice.endpoint, endpoint, "endpoint")
                         || !copy_c_string(*voice.token, json_string(d, js, "token"), "token") {
                stop_voice_ws();
                voice.token[0] = 0;
                return;
            }
            if voice.session_id[0]  start_voice_ws();
    }
}

// Leaves `to` empty when `from` doesn't fit.
copy_c_string :: (to: *[64]u8, from: string, what: string) -> bool {
    if from.count >= to.count {
        print("Discord sent a % of % bytes, which is more than we can hold. Ignoring it.\n", what, from.count);
        to.*[0] = 0;
        return false;
    }
    memcpy(to.data, from.data, from.count);
    to.*[from.count] = 0;
    return true;
}

//
// Slash commands
//

command_handle :: (interaction: *Interaction) -> string {
    if !interaction.guild_id return "This command only works in a server.";

    name := interaction.command;

    if name == "play" {
        file := string_option(interaction, "file");  // optional: without it, play from the top

        channel_id := voice_channel_of(interaction.guild_id, interaction.user_id);
        if !channel_id  return "Join an audio channel first.";

        return join_and_play(interaction.guild_id, channel_id, file);
    }

    if name == "skip" {
        if interaction.guild_id != voice.guild_id
            return "Not connected to any channel in this server.";

        skipped := player_skip();
        if !skipped  return "Nothing is playing.";
        return tprint("Skipped `%`.", skipped);
    }

    if name == "leave" {
        if interaction.guild_id != voice.guild_id
            return "Not connected to any channel in this server.";

        discord_update_voice_state(interaction.guild_id, 0);

        reset_voice();
        return "Leaving the audio channel.";
    }

    return tprint("Unrecognized command: `%`.", name);
}

join_and_play :: (guild_id: u64, channel_id: u64, file: string) -> string {
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
    discord_update_voice_state(guild_id, channel_id, self_deaf = true);
    return tprint("Joining <#%> to play %.", channel_id, what);
}

//
// Music folder
//

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

//
// Members' voice states
//

Member_Voice_State :: struct {
    guild_id: u64;
    user_id: u64;
    channel_id: u64;
}

voice_states: [..]Member_Voice_State;

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

//
// Replies and command registration
//

string_option :: (interaction: *Interaction, name: string) -> string, found: bool {
    for interaction.options  if it.name == name  return it.value, it.value != "";
    return "", false;
}

send_reply :: (interaction: *Interaction, text: string) {
    discord_respond(interaction, "Couldn't reply", tprint("{\"type\":%,\"data\":{\"content\":%,\"flags\":%}}",
        DISCORD_INTERACTION_CHANNEL_MESSAGE_WITH_SOURCE, json_quote(text), DISCORD_MESSAGE_EPHEMERAL));
}

send_file_suggestions :: (interaction: *Interaction) {
    query := string_option(interaction, "file");
    words := split(to_lower_copy(query,, temp), " ",, temp);

    choices: String_Builder;
    choices.allocator = temp;
    count := 0;
    for scan_music_folder() {
        if count == DISCORD_MAX_AUTOCOMPLETE_CHOICES  break;
        if character_count(it) > DISCORD_MAX_CHOICE_LENGTH  continue;
        if !matches_all(to_lower_copy(it,, temp), words)  continue;

        quoted := json_quote(it);
        print_to_builder(*choices, "%{\"name\":%,\"value\":%}", ifx count then "," else "", quoted, quoted);
        count += 1;
    }

    discord_respond(interaction, "Couldn't send suggestions", tprint("{\"type\":%,\"data\":{\"choices\":[%]}}",
        DISCORD_INTERACTION_APPLICATION_COMMAND_AUTOCOMPLETE_RESULT, builder_to_string(*choices,, temp)));
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

register_commands :: (application_id: u64) {
    FILE_OPTION :: #run tprint("{\"type\":%,\"name\":\"file\",\"description\":\"File to start from, inside the music folder (default: the first one)\",\"autocomplete\":true}",
        DISCORD_APPLICATION_OPTION_STRING);

    command :: (name: string, description: string, options: .. string) -> string {
        return tprint("{\"type\":%,\"name\":%,\"description\":%,\"options\":[%],\"default_member_permissions\":\"%\"}",
            DISCORD_APPLICATION_CHAT_INPUT, json_quote(name), json_quote(description), join(.. options, ",",, temp),
            DISCORD_PERMISSION_ADMINISTRATOR);
    }
    body := tprint("[%,%,%]",
        command("play",  "Join your audio channel and play the music folder", FILE_OPTION),
        command("skip",  "Skip to the next track"),
        command("leave", "Leave the audio channel"));

    status, response := rest_request("PUT", tprint("/applications/%/commands", application_id), body);
    discord_report_if_failed("Couldn't register commands", status, response);
}

//
// Player
//
// The main thread asks, the audio thread plays.

// A playlist is a list of file names relative to the music folder. `pending` is what the main
// thread asked for, and `playing` is what the audio thread took from it.
Player :: struct {
    mutex: Mutex;
    wake: Semaphore;
    pending: [..]string;
    playing: [..]string;
    current := -1;  // index in `playing`, or -1 when nothing is playing
    stop_requested: bool;
    skip_requested: bool;
}

player: Player;

player_play :: (playlist: [..]string) {
    lock(*player.mutex);
    free_playlist(*player.pending);
    player.pending = playlist;
    if player.playing.count  atomic_write(*player.stop_requested, true);
    unlock(*player.mutex);
    signal(*player.wake);
}

player_stop :: () {
    lock(*player.mutex);
    if player.current >= 0  atomic_write(*player.stop_requested, true);
    free_playlist(*player.pending);
    unlock(*player.mutex);
}

// Returns the name of the track it skipped, in temporary storage. Empty when nothing was playing.
player_skip :: () -> string {
    lock(*player.mutex);
    defer unlock(*player.mutex);

    if player.current < 0  return "";
    atomic_write(*player.skip_requested, true);
    return copy_temporary_string(player.playing[player.current]);
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
    atomic_write(*player.skip_requested, false);
    unlock(*player.mutex);
}

player_finish :: () {
    lock(*player.mutex);
    free_playlist(*player.playing);
    player.current = -1;
    atomic_write(*player.skip_requested, false);
    unlock(*player.mutex);
}

free_playlist :: (playlist: *[..]string) {
    for <<playlist  free(it);
    array_free(<<playlist);
    <<playlist = [..]string.{};
}

// ============================================================================================
// Voice
// ============================================================================================

//
// Voice connection
//

// What the gateway told us about our voice session. `voice` is main thread only; the voice
// thread gets its own copy. An empty session_id or token means that update hasn't arrived yet.
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
    // Copied by the main thread before the voice thread starts, then only read.
    using connection: Voice_Connection;

    stop_requested: bool;  // the main thread asks the voice thread to end
    audio_stop: bool;      // the voice thread asks the audio thread to end

    // Voice thread only.
    socket: curl_socket_t;
    rx: [..]u8;
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

start_voice_ws :: () {
    stop_voice_ws();

    voice_ws.connection = voice;
    if !thread_init(*voice_thread, voice_ws_thread) {
        print("Failed to create the voice WS thread\n");
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
    destroy(*voice_ws.dave_mutex);
    destroy(*voice_ws.curl_mutex);
    voice_ws = .{};
    voice_ws_running = false;
}

// The voice thread can end on its own: the connection failed, or Discord closed it.
// When it has, this cleans up after it, so the next /play connects again.
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
// Voice WebSocket
//

voice_ws_thread :: (thread: *Thread) -> s64 {
    ws := cast(*Voice_Ws) thread.data;
    defer { free(ws.ip); free(ws.external_ip); array_free(ws.rx); array_free(ws.dave_pending_transitions); }
    ws.curl, ws.socket = websocket_open(tprint("wss://%/?v=8", to_string(ws.endpoint.data)), "Voice WS");
    if !ws.curl  return 1;
    defer curl_easy_cleanup(ws.curl);
    defer close_and_reset(*ws.udp);
    defer transport_destroy(ws);
    if !dave_create(ws)  return 1;
    defer dave_destroy(ws);
    defer audio_stop_and_join(ws);

    gotta_stop: bool;

    while !gotta_stop {
        reset_temporary_storage();
        wait_readable(ws.socket, ws_ms_until_next_wakeup(ws));       // at most ~250 ms, so stop_requested is noticed
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

ws_drain :: (ws: *Voice_Ws) -> bool {
    while true {
        lock(*ws.curl_mutex);
        event, msg, code := websocket_recv(ws.curl, *ws.rx);
        unlock(*ws.curl_mutex);
        if event == {
            case .NOTHING;  return true;
            case .CLOSED;
                print("Voice WS closed: % '%'\n", code, msg);
                return false;
            case .TEXT;
                if !handle_text(ws, msg)  return false;
            case .BINARY;
                if msg.count < 3 {
                    print("<- binary message too short (%)\n", msg.count);
                    continue;
                }
                ws.last_seq = get_u16_be(msg.data);
                if !handle_binary(ws, msg[2], .{msg.count - 3, msg.data + 3})  return false;
        }
    }
    return false;
}

handle_text :: (ws: *Voice_Ws, msg: string) -> bool {
    // For messages that can't be acted on: logs it and goes on with the next one.
    skip :: (what: string) -> bool { print("% is missing fields, ignoring it\n", what); return true; }

    tokens: [128]Jsmn_Token;
    pairs: [128]Jsmnf_Pair;
    root := json_load(msg, tokens, pairs);
    if !root {
        print("<- %\nBad JSON\n", msg);
        return true;
    }

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
            if !interval  return skip("Hello");

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
            if !has_id || !has_version  return skip("Prepare Transition");
            dave_lock(ws);
            return dave_prepare_transition(ws, xx transition_id, xx version);
        case 22; // DAVE Execute Transition
            transition_id, has_id := json_int(d, msg, "transition_id");
            if !has_id  return skip("Execute Transition");
            dave_lock(ws);
            dave_execute_transition(ws, xx transition_id);
        case 24; // DAVE Prepare Epoch
            epoch, has_epoch     := json_int(d, msg, "epoch");
            version, has_version := json_int(d, msg, "protocol_version");
            if !has_epoch || !has_version  return skip("Prepare Epoch");
            dave_lock(ws);
            return dave_prepare_epoch(ws, epoch, xx version);
        case;
            print("Unhandled \"op\" (%)\n", op);
    }
    return true;
}

handle_binary :: (ws: *Voice_Ws, op: u8, payload: []u8) -> bool {
    dave_lock(ws);

    // Commit (29) and Welcome (30) are [transition_id u16][message].
    transition_id: u16;
    message := payload;
    if op == 29 || op == 30 {
        if payload.count < 2 {
            print("<- DAVE op % too short (% bytes)\n", op, payload.count);
            return true;
        }
        transition_id = get_u16_be(payload.data);
        message = .{payload.count - 2, payload.data + 2};
    }

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
        case 29; // MLS Announce Commit Transition
            print("<- DAVE commit for transition % (% bytes)\n", transition_id, message.count);

            result := daveSessionProcessCommit(ws.dave, message.data, xx message.count);
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
        case 30; // MLS Welcome
            print("<- DAVE welcome for transition % (% bytes)\n", transition_id, message.count);

            result := daveSessionProcessWelcome(ws.dave, message.data, xx message.count);
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
    lock(*ws.curl_mutex);
    error := websocket_send(ws.curl, data, flags);
    unlock(*ws.curl_mutex);
    if error  print("Voice WS send failed: %\n", error);
    return !error;
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
    session_id := to_string(ws.session_id.data);
    print("-> Identify (server_id=%, session_id=%)\n", ws.guild_id, session_id);
    ws_send_text(ws, tprint("{\"op\":0,\"d\":{\"server_id\":\"%\",\"user_id\":\"%\",\"session_id\":%,\"token\":%,\"max_dave_protocol_version\":1}}",
        ws.guild_id, bot_user_id, json_quote(session_id), json_quote(to_string(ws.token.data))), log = false);
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
        print("Couldn't create the UDP socket: %\n", get_last_socket_error());
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
        print("Couldn't connect the UDP socket to %:%: %\n", ws.ip, ws.port, get_last_socket_error());
        return false;
    }

    #if OS == .WINDOWS {
        timeout: u32 = IP_DISCOVERY_TIMEOUT_MS;
    } else {
        timeout: timeval;
        timeout.tv_sec  = IP_DISCOVERY_TIMEOUT_MS / 1000;
        timeout.tv_usec = (IP_DISCOVERY_TIMEOUT_MS % 1000) * 1000;
    }
    if setsockopt(ws.udp, SOL_SOCKET, SO_RCVTIMEO, xx *timeout, size_of(type_of(timeout))) != 0 {
        print("Couldn't set the UDP receive timeout: %\n", get_last_socket_error());
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
            print("IP discovery: send failed (%), attempt %/%\n", get_last_socket_error(), attempt, IP_DISCOVERY_ATTEMPTS);
            continue;
        }

        got := recv(ws.udp, reply.data, reply.count, 0);
        if got < 0 {
            err := get_last_socket_error();
            #if OS == .WINDOWS  timed_out := err == WSAETIMEDOUT;
            else                timed_out := err == EAGAIN || err == EWOULDBLOCK;
            if timed_out
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
        if atomic_read(*player.skip_requested)  return .FINISHED;

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
        if sent != length  error = tprint("UDP send failed (%)", get_last_socket_error());
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

// ============================================================================================
// Discord
// The gateway and REST API, on libcurl. Everything here runs on the main thread,
// except the WebSocket helpers at the end, which the voice thread uses too.
// ============================================================================================

//
// Discord constants
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

//
// Gateway
//

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

    gw.curl, gw.socket = websocket_open(url, "Gateway");
    if !gw.curl  return .FAILED, "";

    gw.rx.count = 0;
    gw.ready = false;
    gw.closing = false;
    gw.heartbeat_acknowledged = true;
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
        event, msg, code := websocket_recv(gw.curl, *gw.rx);
        if event == {
            case .NOTHING;  return;
            case .CLOSED;   gateway_on_close(gw, code, msg);
            case .TEXT;
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
    websocket_send(gw.curl, .{2 + reason.count, payload}, CURLWS_CLOSE);

    gw.closing = true;
}

gateway_send :: (gw: *Gateway, text: string) -> bool {
    if gw.closing  return false;

    error := websocket_send(gw.curl, cast([]u8) text, CURLWS_TEXT);
    if error  gateway_on_close(gw, WS_CLOSE_ABNORMAL, tprint("send failed: %", error));
    return !error;
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

//
// Interactions
//

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

Rest :: struct {
    curl: *CURL;
    headers: *void;
    response: [..]u8;
}

rest: Rest;

rest_init :: (token: string) -> bool {
    rest.curl = curl_handle_create();
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

//
// WebSocket, for the gateway and the voice connection
//

Websocket_Event :: enum {
    NOTHING;  // nothing more to read for now
    TEXT;
    BINARY;
    CLOSED;   // the message is the reason
}

// Returns null when it couldn't connect, after saying why.
websocket_open :: (url: string, who: string) -> *CURL, curl_socket_t {
    curl := curl_handle_create();
    if !curl {
        print("%: curl_easy_init failed\n", who);
        return null, 0;
    }
    curl_easy_setopt_ptr(curl, CURLOPT_URL, temp_c_string(url));
    curl_easy_setopt_long(curl, CURLOPT_CONNECT_ONLY, 2);
    curl_easy_setopt_long(curl, CURLOPT_CONNECTTIMEOUT_MS, 10000);
    ret := curl_easy_perform(curl);
    if ret != CURLE_OK {
        print("%: couldn't connect to %: %\n", who, url, to_string(curl_easy_strerror(ret)));
        curl_easy_cleanup(curl);
        return null, 0;
    }

    socket: curl_socket_t;
    curl_easy_getinfo_socket(curl, CURLINFO_ACTIVESOCKET, *socket);
    print("%: connected to %\n", who, url);
    return curl, socket;
}

// Reads the next whole message, which stays in `rx` until the next call. A connection that
// dropped comes back as CLOSED with WS_CLOSE_ABNORMAL.
websocket_recv :: (curl: *CURL, rx: *[..]u8) -> Websocket_Event, message: string, close_code: s64 {
    while true {
        if rx.allocated - rx.count < 4096  array_reserve(rx, max(65536, rx.allocated * 2));

        got: u64;
        meta: *Curl_Ws_Frame;
        ret := curl_ws_recv(curl, rx.data + rx.count, xx (rx.allocated - rx.count), *got, *meta);
        if ret == CURLE_AGAIN  return .NOTHING, "", 0;
        if ret != CURLE_OK     return .CLOSED, to_string(curl_easy_strerror(ret)), WS_CLOSE_ABNORMAL;
        if meta.flags & (CURLWS_PING | CURLWS_PONG)  continue;  // libcurl answers pings itself

        rx.count += xx got;
        if meta.bytesleft > 0 || (meta.flags & CURLWS_CONT)  continue;

        msg := string.{rx.count, rx.data};
        rx.count = 0;
        if meta.flags & CURLWS_CLOSE {
            code := ifx msg.count >= 2 then cast(s64) get_u16_be(msg.data) else WS_CLOSE_ABNORMAL;
            reason := ifx msg.count > 2 then slice(msg, 2, msg.count - 2) else "";
            return .CLOSED, reason, code;
        }
        if meta.flags & CURLWS_TEXT    return .TEXT, msg, 0;
        if meta.flags & CURLWS_BINARY  return .BINARY, msg, 0;
    }
    return .NOTHING, "", 0;
}

// Sends a whole message. Returns what went wrong, or an empty string.
websocket_send :: (curl: *CURL, data: []u8, flags: u32) -> error: string {
    sent: u64;
    ret := curl_ws_send(curl, data.data, xx data.count, *sent, 0, flags);
    if ret != CURLE_OK        return to_string(curl_easy_strerror(ret));
    if sent != xx data.count  return tprint("sent % of % bytes", sent, data.count);
    return "";
}

// ============================================================================================
// Helpers
// ============================================================================================

//
// JSON
//

json_text :: (p: *Jsmnf_Pair, js: string) -> string {
    return string.{xx p.v.len, js.data + p.v.pos};
}

json_find :: (obj: *Jsmnf_Pair, js: string, key: string) -> *Jsmnf_Pair {
    if !obj return null;
    return jsmnf_find(obj, js.data, key.data, xx key.count);
}

// Parses `text` into `pairs`. Returns the root, or null when it isn't JSON or doesn't fit.
json_load :: (text: string, tokens: []Jsmn_Token, pairs: []Jsmnf_Pair) -> *Jsmnf_Pair {
    parser: Jsmn_Parser;
    jsmn_init(*parser);
    num_tokens := jsmn_parse(*parser, text.data, xx text.count, tokens.data, xx tokens.count);
    if num_tokens <= 0  return null;

    loader: Jsmnf_Loader;
    jsmnf_init(*loader);
    if jsmnf_load(*loader, text.data, tokens.data, xx num_tokens, pairs.data, xx pairs.count) <= 0  return null;
    return pairs.data;
}

// The value as text: strings unescaped, anything else as it is in the JSON.
json_value :: (pair: *Jsmnf_Pair, js: string) -> string {
    text := json_text(pair, js);
    if pair.type != JSMN_STRING || !text  return text;

    buffer := cast(*u8) talloc(text.count + 1);
    length := jsmnf_unescape(buffer, xx (text.count + 1), text.data, xx text.count);
    if length <= 0  return "";
    return .{length, buffer};
}

// Empty when the key is missing or isn't a string.
json_string :: (obj: *Jsmnf_Pair, js: string, key: string) -> string {
    pair := json_find(obj, js, key);
    if !pair || pair.type != JSMN_STRING  return "";
    return json_value(pair, js);
}

// A snowflake. 0 when the key is missing or null.
json_id :: (obj: *Jsmnf_Pair, js: string, key: string) -> u64 {
    pair := json_find(obj, js, key);
    if !pair || pair.type != JSMN_STRING  return 0;
    id, ok := string_to_int(json_text(pair, js), 10, u64);
    return ifx ok then id else 0;
}

json_int :: (obj: *Jsmnf_Pair, js: string, key: string) -> s64, found: bool {
    pair := json_find(obj, js, key);
    if !pair  return 0, false;
    value := string_to_int(json_text(pair, js));
    return value, true;
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

//
// Bytes and waiting
//

put_u16_be :: (p: *u8, v: u16) { p[0] = xx (v >> 8); p[1] = xx (v & 0xFF); }
put_u32_be :: (p: *u8, v: u32) {
    p[0] = xx (v >> 24); p[1] = xx ((v >> 16) & 0xFF); p[2] = xx ((v >> 8) & 0xFF); p[3] = xx (v & 0xFF);
}
get_u16_be :: (p: *u8) -> u16 { return ((cast(u16) p[0]) << 8) | p[1]; }
get_u32_be :: (p: *u8) -> u32 {
    return ((cast(u32) p[0]) << 24) | ((cast(u32) p[1]) << 16) | ((cast(u32) p[2]) << 8) | p[3];
}

// Waits until the socket has something to read, or the timeout passes.
wait_readable :: (socket: curl_socket_t, timeout_ms: s32) {
    pfd := pollfd.{fd = socket, events = POLLIN};
    #if OS == .WINDOWS  WSAPoll(*pfd, 1, timeout_ms);
    else                poll(*pfd, 1, timeout_ms);
}

// ============================================================================================
// Foreign code
// ============================================================================================

//
// Libraries and build
//
// Compiling this file builds the libraries it links: the two small C ones right here,
// and the rest through vcpkg and CMake.

decoder :: #library,no_dll "decoder";
json    :: #library,no_dll "json";
#if OS != .WINDOWS  _ :: #library,system,link_always "libm";

// Compiling miniaudio takes ~11s, so a library is only rebuilt when its sources changed.
#run {
    build_if_changed :: (name: string, sources: .. string) {
        LIB_EXTENSION :: #ifx OS == .WINDOWS then "lib" else "a";
        lib_time, _, lib_exists := file_modtime_and_size(tprint("%.%", name, LIB_EXTENSION));
        needs_rebuild := !lib_exists;
        for sources {
            if needs_rebuild break;
            source_time := file_modtime_and_size(it);
            if source_time > lib_time  needs_rebuild = true;
        }
        if needs_rebuild  build_cpp_static_lib(name, sources[0]);
    }

    build_if_changed("decoder", "decoder.c", "vendor/miniaudio/miniaudio.h");
    build_if_changed("json", "json.c", "vendor/jsmn/jsmn.h", "vendor/jsmn/jsmn-find.h", "vendor/jsmn/chash.h");
}

// `libcurl`, `opus`, `dave` (libdave) and `libcrypto` (OpenSSL) are declared by this #insert.
// vcpkg builds the static libraries in deps/vcpkg.json (curl, OpenSSL, opus,
// mlspp), then libdave compiles against that OpenSSL and mlspp.
// Build outputs go in .deps/.
#insert -> string {
    #import "System";

    root := get_working_directory();

    VCPKG_DIR :: "vendor/libdave/cpp/vcpkg";
    VCPKG_EXE :: #ifx OS == .WINDOWS then "vcpkg.exe" else "vcpkg";

    #if OS == .LINUX && CPU == .X64        TRIPLET :: "x64-linux";
    else #if OS == .MACOS && CPU == .ARM64 TRIPLET :: "arm64-osx";
    else #if OS == .MACOS                  TRIPLET :: "x64-osx";
    else #if OS == .WINDOWS                TRIPLET :: "x64-windows-static";
    else #assert false, "No vcpkg triplet for this platform.";

    installed := tprint("%/.deps/vcpkg_installed", root);
    lib := tprint(".deps/vcpkg_installed/%/lib/", TRIPLET);

    run :: (what: string, args: .. string, working_directory := "") {
        result := run_command(.. args, working_directory = working_directory);
        if result.exit_code != 0  compiler_report(tprint("Building % failed.", what));
    }

    if !file_exists(tprint("%/%", VCPKG_DIR, VCPKG_EXE)) {
        #if OS == .WINDOWS  run("vcpkg", "cmd", "/c", "bootstrap-vcpkg.bat", "-disableMetrics", working_directory = VCPKG_DIR);
        else                run("vcpkg", "./bootstrap-vcpkg.sh", "-disableMetrics", working_directory = VCPKG_DIR);
    }

    run("the vcpkg dependencies", tprint("%/%/%", root, VCPKG_DIR, VCPKG_EXE), "install",
        "--x-manifest-root=deps", tprint("--x-install-root=%", installed), tprint("--triplet=%", TRIPLET), "--disable-metrics");

    if !file_exists(".deps/libdave/CMakeCache.txt") {
        run("libdave (configure)", "cmake", "-S", "vendor/libdave/cpp", "-B", ".deps/libdave",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
            "-DTESTING=OFF",
            tprint("-DCMAKE_TOOLCHAIN_FILE=%/%/scripts/buildsystems/vcpkg.cmake", root, VCPKG_DIR),
            tprint("-DVCPKG_TARGET_TRIPLET=%", TRIPLET),
            tprint("-DVCPKG_MANIFEST_DIR=%/deps", root),
            tprint("-DVCPKG_INSTALLED_DIR=%", installed),
            "-DVCPKG_MANIFEST_INSTALL=OFF");
    }
    run("libdave", "cmake", "--build", ".deps/libdave", "--target", "libdave", "--config", "Release", "-j");

    #if OS == .WINDOWS {
        return tprint(#string DONE
libcurl :: #library,no_dll,link_always "%1libcurl";
opus    :: #library,no_dll "%1opus";
dave    :: #library,no_dll ".deps/libdave/Release/libdave";
_ :: #library,no_dll,link_always "%1mlspp";
_ :: #library,no_dll,link_always "%1hpke";
_ :: #library,no_dll,link_always "%1tls_syntax";
_ :: #library,no_dll,link_always "%1bytes";
_ :: #library,no_dll,link_always "%1libssl";
libcrypto :: #library,no_dll,link_always "%1libcrypto";
_ :: #library,no_dll,link_always "%1zlib";
_ :: #library,system,no_dll,link_always "libcpmt";
_ :: #library,system,no_dll,link_always "oldnames";
_ :: #library,system,link_always "ws2_32";
_ :: #library,system,link_always "bcrypt";
_ :: #library,system,link_always "advapi32";
_ :: #library,system,link_always "crypt32";
_ :: #library,system,link_always "user32";
DONE, lib);
    } else {
        gcc_result, gcc_output := run_command("c++", "-print-file-name=libstdc++.a", capture_and_return_output = true);
        stdcpp_archive := trim(gcc_output);
        if gcc_result.exit_code != 0 || !file_exists(stdcpp_archive) {
            compiler_report("Couldn't find libstdc++.a with \"c++ -print-file-name\".");
        }
        gcc_dir := path_strip_filename(stdcpp_archive);

        up: String_Builder;
        for split(root, "/")  if it  append(*up, "../");
        gcc_dir = tprint("%1%2", builder_to_string(*up), gcc_dir);

        return tprint(#string DONE
libcurl :: #library,no_dll,link_always "%1libcurl";
opus    :: #library,no_dll "%1libopus";
dave    :: #library,no_dll ".deps/libdave/libdave";
_ :: #library,no_dll,link_always "%1libmlspp";
_ :: #library,no_dll,link_always "%1libhpke";
_ :: #library,no_dll,link_always "%1libtls_syntax";
_ :: #library,no_dll,link_always "%1libbytes";
_ :: #library,no_dll,link_always "%1libssl";
libcrypto :: #library,no_dll,link_always "%1libcrypto";
_ :: #library,no_dll,link_always "%1libz";
_ :: #library,no_dll,link_always "%2libstdc++";
_ :: #library,no_dll,link_always "%2libgcc_eh";
_ :: #library,no_dll,link_always "%2libgcc";
DONE, lib, gcc_dir);
    }
}

//
// Bindings: decoder (decoder.c) and libopus
//

decoder_open :: (path: *u8) -> *void #foreign decoder;
decoder_read :: (decoder: *void, out: *s16, frames: u64) -> s64 #foreign decoder;
decoder_close :: (decoder: *void) -> void #foreign decoder;

opus_encoder_create :: (Fs: s32, channels: s32, application: s32, error: *s32) -> *void #foreign opus;
opus_encoder_destroy :: (st: *void) -> void #foreign opus;
opus_encode :: (st: *void, pcm: *s16, frame_size: s32, data: *u8, max_data_bytes: s32) -> s32 #foreign opus;
opus_strerror :: (error: s32) -> *u8 #foreign opus;

//
// Bindings: libdave (vendor/libdave/cpp/includes/dave/dave.h)
//

DAVE_Session        :: *void;
DAVE_Commit_Result  :: *void;
DAVE_Welcome_Result :: *void;
DAVE_Key_Ratchet    :: *void;
DAVE_Encryptor      :: *void;

DAVE_Codec :: enum s32 {
    UNKNOWN :: 0;
    OPUS    :: 1;
    VP8     :: 2;
    VP9     :: 3;
    H264    :: 4;
    H265    :: 5;
    AV1     :: 6;
}

DAVE_Media_Type :: enum s32 {
    AUDIO :: 0;
    VIDEO :: 1;
}

DAVE_Encryptor_Result :: enum s32 {
    SUCCESS             :: 0;
    ENCRYPTION_FAILURE  :: 1;
    MISSING_KEY_RATCHET :: 2;
    MISSING_CRYPTOR     :: 3;
    TOO_MANY_ATTEMPTS   :: 4;
}

DAVE_Logging_Severity :: enum s32 {
    VERBOSE :: 0;
    INFO    :: 1;
    WARNING :: 2;
    ERROR   :: 3;
    NONE    :: 4;
}

DAVE_MLS_Failure_Callback :: #type (source: *u8, reason: *u8, user_data: *void) #c_call;
DAVE_Log_Sink_Callback :: #type (severity: DAVE_Logging_Severity, file: *u8, line: s32, message: *u8) #c_call;

daveFree :: (ptr: *void) -> void #foreign dave;
daveSetLogSinkCallback :: (callback: DAVE_Log_Sink_Callback) -> void #foreign dave;

daveSessionCreate :: (ctx: *void, auth_session_id: *u8, callback: DAVE_MLS_Failure_Callback, user_data: *void) -> DAVE_Session #foreign dave;
daveSessionDestroy :: (session: DAVE_Session) -> void #foreign dave;
daveSessionInit :: (session: DAVE_Session, version: u16, group_id: u64, self_user_id: *u8) -> void #foreign dave;
daveSessionReset :: (session: DAVE_Session) -> void #foreign dave;
daveSessionGetProtocolVersion :: (session: DAVE_Session) -> u16 #foreign dave;
daveSessionSetExternalSender :: (session: DAVE_Session, external_sender: *u8, length: u64) -> void #foreign dave;
daveSessionAddRecognizedUser :: (session: DAVE_Session, user_id: *u8) -> void #foreign dave;
daveSessionRemoveRecognizedUser :: (session: DAVE_Session, user_id: *u8) -> void #foreign dave;
// `proposals` is the op 27 payload as is, operation type byte included. No output means nothing to commit.
daveSessionProcessProposals :: (session: DAVE_Session, proposals: *u8, length: u64, commit_welcome: **u8, commit_welcome_length: *u64) -> void #foreign dave;
daveSessionProcessCommit :: (session: DAVE_Session, commit: *u8, length: u64) -> DAVE_Commit_Result #foreign dave;
// Returns null when joining failed.
daveSessionProcessWelcome :: (session: DAVE_Session, welcome: *u8, length: u64) -> DAVE_Welcome_Result #foreign dave;
daveSessionGetMarshalledKeyPackage :: (session: DAVE_Session, key_package: **u8, length: *u64) -> void #foreign dave;
daveSessionGetKeyRatchet :: (session: DAVE_Session, user_id: *u8) -> DAVE_Key_Ratchet #foreign dave;

daveKeyRatchetDestroy :: (key_ratchet: DAVE_Key_Ratchet) -> void #foreign dave;

daveCommitResultIsFailed :: (result: DAVE_Commit_Result) -> bool #foreign dave;
daveCommitResultIsIgnored :: (result: DAVE_Commit_Result) -> bool #foreign dave;
daveCommitResultDestroy :: (result: DAVE_Commit_Result) -> void #foreign dave;

daveWelcomeResultDestroy :: (result: DAVE_Welcome_Result) -> void #foreign dave;

daveEncryptorCreate :: () -> DAVE_Encryptor #foreign dave;
daveEncryptorDestroy :: (encryptor: DAVE_Encryptor) -> void #foreign dave;
// Doesn't take ownership: the key ratchet must outlive its use by the encryptor.
daveEncryptorSetKeyRatchet :: (encryptor: DAVE_Encryptor, key_ratchet: DAVE_Key_Ratchet) -> void #foreign dave;
daveEncryptorSetPassthroughMode :: (encryptor: DAVE_Encryptor, passthrough: bool) -> void #foreign dave;
daveEncryptorAssignSsrcToCodec :: (encryptor: DAVE_Encryptor, ssrc: u32, codec: DAVE_Codec) -> void #foreign dave;
daveEncryptorGetMaxCiphertextByteSize :: (encryptor: DAVE_Encryptor, media_type: DAVE_Media_Type, frame_size: u64) -> u64 #foreign dave;
daveEncryptorEncrypt :: (encryptor: DAVE_Encryptor, media_type: DAVE_Media_Type, ssrc: u32, frame: *u8, frame_length: u64, encrypted_frame: *u8, encrypted_frame_capacity: u64, bytes_written: *u64) -> DAVE_Encryptor_Result #foreign dave;

//
// Bindings: OpenSSL's libcrypto, for the AES-256-GCM transport encryption
//

EVP_CIPHER_CTX :: void;
EVP_CIPHER     :: void;

EVP_CTRL_GCM_GET_TAG :: 0x10;

EVP_CIPHER_CTX_new  :: () -> *EVP_CIPHER_CTX #foreign libcrypto;
EVP_CIPHER_CTX_free :: (ctx: *EVP_CIPHER_CTX) -> void #foreign libcrypto;
EVP_aes_256_gcm     :: () -> *EVP_CIPHER #foreign libcrypto;
// All of these return 1 on success. `impl` is an ENGINE, always null here.
EVP_EncryptInit_ex  :: (ctx: *EVP_CIPHER_CTX, cipher: *EVP_CIPHER, impl: *void, key: *u8, iv: *u8) -> s32 #foreign libcrypto;
// With `out` null, `in` is additional authenticated data.
EVP_EncryptUpdate   :: (ctx: *EVP_CIPHER_CTX, out: *u8, outl: *s32, in: *u8, inl: s32) -> s32 #foreign libcrypto;
EVP_EncryptFinal_ex :: (ctx: *EVP_CIPHER_CTX, out: *u8, outl: *s32) -> s32 #foreign libcrypto;
EVP_CIPHER_CTX_ctrl :: (ctx: *EVP_CIPHER_CTX, type: s32, arg: s32, ptr: *void) -> s32 #foreign libcrypto;

//
// Bindings: libcurl, for the WebSockets and Discord's REST API
//

CURL :: void;
curl_off_t :: s64;
#if OS == .WINDOWS  C_Long :: s32;
else                C_Long :: s64;
#if OS == .WINDOWS  curl_socket_t :: u64;  // a SOCKET
else                curl_socket_t :: s32;

CURLE_OK    :: 0;
CURLE_AGAIN :: 81;  // nothing to read, or the socket can't take more yet

CURL_GLOBAL_DEFAULT :: 3;

CURLOPT_POSTFIELDSIZE     :: 60;
CURLOPT_HTTPGET           :: 80;
CURLOPT_CONNECT_ONLY      :: 141;  // set to 2 for WebSocket: stop after the upgrade
CURLOPT_TIMEOUT_MS        :: 155;
CURLOPT_CONNECTTIMEOUT_MS :: 156;
CURLOPT_SSL_OPTIONS       :: 216;
CURLOPT_URL               :: 10002;
CURLOPT_POSTFIELDS        :: 10015;  // not copied: the body must stay valid until the request ends
CURLOPT_USERAGENT         :: 10018;
CURLOPT_HTTPHEADER        :: 10023;
CURLOPT_CUSTOMREQUEST     :: 10036;
CURLOPT_WRITEFUNCTION     :: 20011;

CURLINFO_RESPONSE_CODE :: 0x200000 + 2;
CURLINFO_ACTIVESOCKET  :: 0x500000 + 44;

CURLWS_TEXT   :: 1 << 0;
CURLWS_BINARY :: 1 << 1;
CURLWS_CONT   :: 1 << 2;  // more fragments of this message follow
CURLWS_CLOSE  :: 1 << 3;
CURLWS_PING   :: 1 << 4;
CURLWS_PONG   :: 1 << 6;

Curl_Ws_Frame :: struct {
    age: s32;
    flags: s32;          // CURLWS_* bits
    offset: curl_off_t;  // where this chunk starts inside the whole message
    bytesleft: curl_off_t;  // bytes of this message still to come
    len: u64;            // size of this chunk
}

#assert size_of(Curl_Ws_Frame) == 32;

curl_global_init :: (flags: C_Long) -> s32 #foreign libcurl;
curl_easy_init :: () -> *CURL #foreign libcurl;

CURLSSLOPT_NATIVE_CA :: 1 << 4;

curl_handle_create :: () -> *CURL {
    curl := curl_easy_init();
    #if OS == .WINDOWS  if curl  curl_easy_setopt_long(curl, CURLOPT_SSL_OPTIONS, CURLSSLOPT_NATIVE_CA);
    return curl;
}
curl_easy_cleanup :: (curl: *CURL) -> void #foreign libcurl;
curl_easy_perform :: (curl: *CURL) -> s32 #foreign libcurl;
curl_easy_strerror :: (code: s32) -> *u8 #foreign libcurl;

// curl_easy_setopt and curl_easy_getinfo are variadic in C. These fixed versions
// cover the three argument kinds we need, and are ABI-compatible on x86-64 Linux.
curl_easy_setopt_long :: (curl: *CURL, option: s32, value: s64) -> s32 #foreign libcurl "curl_easy_setopt";
curl_easy_setopt_ptr  :: (curl: *CURL, option: s32, value: *void) -> s32 #foreign libcurl "curl_easy_setopt";
curl_easy_getinfo_socket :: (curl: *CURL, info: s32, out: *curl_socket_t) -> s32 #foreign libcurl "curl_easy_getinfo";
curl_easy_getinfo_long   :: (curl: *CURL, info: s32, out: *C_Long) -> s32 #foreign libcurl "curl_easy_getinfo";

curl_slist_append :: (list: *void, text: *u8) -> *void #foreign libcurl;

curl_ws_recv :: (curl: *CURL, buffer: *void, buflen: u64, recv: *u64, meta: **Curl_Ws_Frame) -> s32 #foreign libcurl;
curl_ws_send :: (curl: *CURL, buffer: *void, buflen: u64, sent: *u64, fragsize: curl_off_t, flags: u32) -> s32 #foreign libcurl;

//
// Bindings: jsmn + jsmn-find (vendor/jsmn, compiled by json.c)
//

JSMN_ARRAY  :: 2;
JSMN_STRING :: 3;

Jsmn_Token :: struct {
    type: s32;
    start: s32;
    end: s32;
    size: s32;
}

Jsmn_Parser :: struct {
    pos: u32;
    toknext: u32;
    toksuper: s32;
}

Jsmnf_Tok :: struct {
    pos: s32;
    len: u64;
}

Jsmnf_Pair :: struct {
    type: s32;
    size: s32;
    capacity: s32;
    fields: *Jsmnf_Pair;
    k: Jsmnf_Tok;
    v: Jsmnf_Tok;
    state: s32;
}

Jsmnf_Loader :: struct {
    pairnext: u32;
}

#assert size_of(Jsmn_Token) == 16;
#assert size_of(Jsmn_Parser) == 12;
#assert size_of(Jsmnf_Tok) == 16;
#assert size_of(Jsmnf_Pair) == 64;
#assert size_of(Jsmnf_Loader) == 4;

jsmn_init :: (parser: *Jsmn_Parser) -> void #foreign json;
jsmn_parse :: (parser: *Jsmn_Parser, js: *u8, len: u64, tokens: *Jsmn_Token, num_tokens: u32) -> s32 #foreign json;
// The `auto` versions grow the array (with realloc) until everything fits.
jsmn_parse_auto :: (parser: *Jsmn_Parser, js: *u8, len: u64, p_tokens: **Jsmn_Token, num_tokens: *u32) -> s32 #foreign json;
jsmnf_init :: (loader: *Jsmnf_Loader) -> void #foreign json;
jsmnf_load :: (loader: *Jsmnf_Loader, js: *u8, tokens: *Jsmn_Token, num_tokens: u32, pairs: *Jsmnf_Pair, num_pairs: u32) -> s32 #foreign json;
jsmnf_load_auto :: (loader: *Jsmnf_Loader, js: *u8, tokens: *Jsmn_Token, num_tokens: u32, p_pairs: **Jsmnf_Pair, num_pairs: *u32) -> s32 #foreign json;
jsmnf_find :: (head: *Jsmnf_Pair, js: *u8, key: *u8, length: s32) -> *Jsmnf_Pair #foreign json;
jsmnf_unescape :: (buf: *u8, bufsize: u64, src: *u8, length: u64) -> C_Long #foreign json;
