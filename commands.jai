#import "String";

session_id: [64]u8;
token: [64]u8;
endpoint: [64]u8;

state_update_received: bool;
server_update_received: bool;

do_we_have_credentials :: () {
	if !state_update_received || !server_update_received return;
	print("We have all credentials for the requested voice channel.\n");
}

on_voice_state_update :: (client: *void, event: *Discord_Voice_State) #c_call {
	new_context: Context;
	push_context new_context {
		if event.user_id != bot_user_id return;
		if event.channel_id == 0 {
			state_update_received = false;
			server_update_received = false;
			return;
		}
		session_id_len := c_style_strlen(event.session_id);
		assert(session_id_len < 64);
		memcpy(session_id.data, event.session_id, session_id_len + 1);
		state_update_received = true;
		do_we_have_credentials();
	}
}

on_voice_server_update :: (client: *void, event: *Discord_Voice_Server_Update) #c_call {
	new_context: Context;
	push_context new_context {
		if !event.endpoint return;
		token_len := c_style_strlen(event.token);
		assert(token_len < 64);
		memcpy(token.data, event.token, token_len + 1);
		endpoint_len := c_style_strlen(event.endpoint);
		assert(endpoint_len < 64);
		memcpy(endpoint.data, event.endpoint, endpoint_len + 1);
		server_update_received = true;
		do_we_have_credentials();
	}
}

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

// Decides what to answer. Step 4 is where /join and /leave start doing real work.
command_handle :: (client: *void, event: *Discord_Interaction) -> string {
    if !event.guild_id return copy_string("This command only works in a server.");

    name := to_string(event.data.name);

    if name == "join" {
        channel_id, found := channel_option(event.data, "channel");
        if !found return copy_string("Pick an audio channel.");
		state_update_received = false;
		server_update_received = false;
		update := Discord_Update_Voice_State.{ guild_id = event.guild_id, channel_id = channel_id, self_mute = false, self_deaf = true };
		discord_update_voice_state(client, *update);
        return sprint("Would join <#%>.", channel_id);
    }

    if name == "leave" {
		update := Discord_Update_Voice_State.{ guild_id = event.guild_id, channel_id = 0 };
		discord_update_voice_state(client, *update);
		return copy_string("Would leave the audio channel.");
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
