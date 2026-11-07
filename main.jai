#import "Basic";
#import "BuildCpp";
#import "Command_Line";
#import "File";
#import "String";

#insert -> string {
	#import "Process";
	#import "Compiler";

	result := run_command("make", "-j", working_directory = "vendor/concord");
	if result.exit_code != 0 {
		compiler_report("\"make\" failed while building concord.");
	}

	return "discord :: #library,no_dll \"vendor/concord/lib/libdiscord\";";
}

#run {
    build_cpp_static_lib("decoder", "decoder.c");
}

decoder :: #library,no_dll "decoder";
opus :: #library,system "libopus";
_ :: #library,system,link_always "libm";
_ :: #library,system,link_always "libcurl";

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
	if !voice.state_update_received || !voice.server_update_received return false;
	return true;
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

	discord_set_on_ready(client, on_ready);
	discord_set_on_interaction_create(client, on_interaction_create);
	discord_add_intents(client, DISCORD_INTENT_GUILDS | DISCORD_INTENT_GUILD_VOICE_STATES);
	discord_set_on_voice_state_update(client, on_voice_state_update);
	discord_set_on_voice_server_update(client, on_voice_server_update);
	
	err := discord_run(client);
	print("Discord connection stopped: %\n", to_string(discord_strerror(err, client)));
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
		
		voice.channel_id = event.channel_id;

		if event.channel_id == 0 {
			voice.guild_id = 0;
			voice.state_update_received = false;
			voice.server_update_received = false;
			return;
		}
		session_id_len := c_style_strlen(event.session_id);
		assert(session_id_len < 64);
		memcpy(voice.session_id.data, event.session_id, session_id_len + 1);
		voice.state_update_received = true;
		do_we_have_credentials();
	}
}

on_voice_server_update :: (client: *void, event: *Discord_Voice_Server_Update) #c_call {
	new_context: Context;
	push_context new_context {
		if !event.endpoint {
			voice.server_update_received = false;
			return;
		} 
		if event.guild_id != voice.guild_id return;
		token_len := c_style_strlen(event.token);
		assert(token_len < 64);
		memcpy(voice.token.data, event.token, token_len + 1);
		endpoint_len := c_style_strlen(event.endpoint);
		assert(endpoint_len < 64);
		memcpy(voice.endpoint.data, event.endpoint, endpoint_len + 1);
		voice.server_update_received = true;
		do_we_have_credentials();
	}
}

//
// Slash commands
//

// Decides what to answer. Step 4 is where /join and /leave start doing real work.
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

	    voice.guild_id = 0;
	    voice.state_update_received = false;
	    voice.server_update_received = false;
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

//
// Foreign bindings: decoder (decoder.c) and libopus
//

decoder_open :: (path: *u8) -> *void #foreign decoder;
decoder_read :: (decoder: *void, out: *s16, frames: u64) -> s64 #foreign decoder;
decoder_close :: (decoder: *void) -> void #foreign decoder;

opus_encoder_create :: (Fs: s32, channels: s32, application: s32, error: *s32) -> *void #foreign opus;
opus_encoder_destroy :: (st: *void) -> void #foreign opus;
opus_encode :: (st: *void, pcm: *s16, frame_size: s32, data: *u8, max_data_bytes: s32) -> s32 #foreign opus;
opus_decoder_create :: (Fs: s32, channels: s32, error: *s32) -> *void #foreign opus;
opus_decoder_destroy :: (st: *void) -> void #foreign opus;
opus_decode :: (st: *void, data: *u8, len: s32, pcm: *s16, frame_size: s32, decode_fec: s32) -> s32 #foreign opus;
opus_strerror :: (error: s32) -> *u8 #foreign opus;

//
// Foreign bindings: Concord
//

CCORD_OK      :: 0;
CCORD_PENDING :: 1;

DISCORD_INTENT_GUILDS             :: 1 << 0;
DISCORD_INTENT_GUILD_VOICE_STATES :: 1 << 7;

DISCORD_PERMISSION_ADMINISTRATOR :: 1 << 3;
DISCORD_MESSAGE_EPHEMERAL        :: 1 << 6;

DISCORD_CHANNEL_GUILD_VOICE       :: 2;
DISCORD_CHANNEL_GUILD_STAGE_VOICE :: 13;

DISCORD_APPLICATION_CHAT_INPUT     :: 1;
DISCORD_APPLICATION_OPTION_CHANNEL :: 7;

DISCORD_INTERACTION_APPLICATION_COMMAND         :: 2;
DISCORD_INTERACTION_CHANNEL_MESSAGE_WITH_SOURCE :: 4;

// Concord's list structs all share this shape.
Discord_List :: struct (T: Type) {
    size: s32;
    array: *T;
    realsize: s32;
}

// Only the start of this struct. Concord allocates it and we only read `id`.
Discord_Application :: struct {
    id: u64;
}

Discord_Ready :: struct {
    v: s32;
    user: *Discord_User;
    guilds: *void;
    session_id: *u8;
    shard: *void;
    application: *Discord_Application;
}

Discord_Interaction_Option :: struct {
    name: *u8;
    type: s32;
    value: *u8;
    options: *void;
    focused: bool;
}

Discord_Interaction_Data :: struct {
    id: u64;
    name: *u8;
    type: s32;
    resolved: *void;
    options: *Discord_List(Discord_Interaction_Option);
    custom_id: *u8;
    component_type: s32;
    values: *void;
    target_id: u64;
    components: *void;
}

Discord_Interaction :: struct {
    id: u64;
    application_id: u64;
    type: s32;
    data: *Discord_Interaction_Data;
    guild_id: u64;
    channel_id: u64;
    member: *void;
    user: *void;
    token: *u8;
    version: s32;
    message: *void;
    locale: *u8;
    guild_locale: *u8;
}

Discord_Command_Option :: struct {
    type: s32;
    name: *u8;
    description: *u8;
    required: bool;
    choices: *void;
    options: *void;
    channel_types: *Discord_List(s32);
    min_value: *u8;
    max_value: *u8;
    autocomplete: bool;
}

Discord_Command :: struct {
    id: u64;
    type: s32;
    application_id: u64;
    guild_id: u64;
    name: *u8;
    description: *u8;
    options: *Discord_List(Discord_Command_Option);
    default_member_permissions: u64;
    dm_permission: bool;
    // Concord sends this field whenever it isn't true, so always set it to true.
    default_permission: bool;
    version: u64;
}

Discord_Interaction_Callback_Data :: struct {
    components: *void;
    tts: bool;
    content: *u8;
    embeds: *void;
    flags: u64;
    attachments: *void;
    choices: *void;
    custom_id: *u8;
    title: *u8;
}

Discord_Interaction_Response :: struct {
    type: s32;
    data: *Discord_Interaction_Callback_Data;
}

Discord_Response :: struct {
    data: *void;
    keep: *void;
    code: s32;
}

Discord_Ret :: struct {
    data: *void;
    cleanup: *void;
    keep: *void;
    high_priority: bool;
    fail: #type (client: *void, response: *Discord_Response) #c_call;
    done: *void;
    sync: bool;
}

Discord_Voice_State :: struct {
	guild_id: u64;
	channel_id: u64;
	user_id: u64;
	discord_guild_member: *void;
	session_id: *u8;
	deaf: bool;
	mute: bool;
	self_deaf: bool;
	self_mute: bool;
	self_stream: bool;
	self_video: bool;
	suppress: bool;
	request_to_speak_timestamp: u64;
}

Discord_Update_Voice_State :: struct {
	guild_id: u64;
	channel_id: u64;
	self_mute: bool;
	self_deaf: bool;
}

Discord_Voice_Server_Update :: struct {
	token: *u8;
	guild_id: u64;
	endpoint: *u8;
}

Discord_User :: struct {
	id: u64;
	username: *u8;
	discriminator: *u8;
	avatar: *u8;
	bot: bool;
	System: bool;
	mfa_enabled: bool;
	banner: *u8;
	accent_color: s32;
	locale: *u8;
	verified: bool;
	email: *u8;
	flags: u64;
	premium_type: s32;
	public_flags: u64;
}

#assert size_of(Discord_List(s32)) == 24;
#assert size_of(Discord_Ready) == 48;
#assert size_of(Discord_Interaction_Option) == 40;
#assert size_of(Discord_Interaction_Data) == 80;
#assert size_of(Discord_Interaction) == 104;
#assert size_of(Discord_Command_Option) == 80;
#assert size_of(Discord_Command) == 80;
#assert size_of(Discord_Interaction_Callback_Data) == 72;
#assert size_of(Discord_Interaction_Response) == 16;
#assert size_of(Discord_Response) == 24;
#assert size_of(Discord_Ret) == 56;
#assert size_of(Discord_Voice_State) == 56;
#assert size_of(Discord_Update_Voice_State) == 24;
#assert size_of(Discord_Voice_Server_Update) == 24;
#assert size_of(Discord_User) == 104;

discord_init :: (token: *u8) -> *void #foreign discord;
discord_add_intents :: (client: *void, code: u64) -> void #foreign discord;
discord_set_on_ready :: (client: *void, callback: #type (client: *void, event: *Discord_Ready) #c_call) -> void #foreign discord;
discord_set_on_interaction_create :: (client: *void, callback: #type (client: *void, event: *Discord_Interaction) #c_call) -> void #foreign discord;
discord_run :: (client: *void) -> s32 #foreign discord;
discord_shutdown :: (client: *void) -> void #foreign discord;
discord_cleanup :: (client: *void) -> void #foreign discord;
discord_strerror :: (code: s32, client: *void) -> *u8 #foreign discord;

discord_bulk_overwrite_global_application_commands :: (client: *void, application_id: u64, params: *Discord_List(Discord_Command), ret: *Discord_Ret) -> s32 #foreign discord;
discord_create_interaction_response :: (client: *void, interaction_id: u64, interaction_token: *u8, params: *Discord_Interaction_Response, ret: *Discord_Ret) -> s32 #foreign discord;

discord_update_voice_state :: (client: *void, update: *Discord_Update_Voice_State) -> void #foreign discord;
discord_set_on_voice_state_update :: (client: *void, callback: #type (client: *void, event: *Discord_Voice_State) #c_call) -> void #foreign discord;
discord_set_on_voice_server_update :: (client: *void, callback: #type (client: *void, event: *Discord_Voice_Server_Update) #c_call) -> void #foreign discord;
