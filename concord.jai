// Bindings for the parts of Concord this bot uses.
// The layouts come from vendor/concord/gencodecs/discord_codecs.h. The asserts at
// the bottom catch size mistakes, so update them if you update Concord.

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
