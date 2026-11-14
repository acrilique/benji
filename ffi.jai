//
// Libraries
//

decoder :: #library,no_dll "decoder";
_ :: #library,system,link_always "libm";
// `libcurl`, `opus`, `discord` (Concord), `dave` (libdave) and `libcrypto`
// (OpenSSL) are declared in build.jai, which builds them.

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

//
// Foreign bindings: libdave (vendor/libdave/cpp/includes/dave/dave.h)
//

DAVE_Session        :: *void;
DAVE_Commit_Result  :: *void;
DAVE_Welcome_Result :: *void;
DAVE_Key_Ratchet    :: *void;
DAVE_Encryptor      :: *void;
DAVE_Decryptor      :: *void;

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

DAVE_Decryptor_Result :: enum s32 {
    SUCCESS             :: 0;
    DECRYPTION_FAILURE  :: 1;
    MISSING_KEY_RATCHET :: 2;
    INVALID_NONCE       :: 3;
    MISSING_CRYPTOR     :: 4;
}

DAVE_Logging_Severity :: enum s32 {
    VERBOSE :: 0;
    INFO    :: 1;
    WARNING :: 2;
    ERROR   :: 3;
    NONE    :: 4;
}

DAVE_Encryptor_Stats :: struct {
    passthrough_count:         u64;
    encrypt_success_count:     u64;
    encrypt_failure_count:     u64;
    encrypt_duration:          u64;
    encrypt_attempts:          u64;
    encrypt_max_attempts:      u64;
    encrypt_missing_key_count: u64;
}

DAVE_Decryptor_Stats :: struct {
    passthrough_count:           u64;
    decrypt_success_count:       u64;
    decrypt_failure_count:       u64;
    decrypt_duration:            u64;
    decrypt_attempts:            u64;
    decrypt_missing_key_count:   u64;
    decrypt_invalid_nonce_count: u64;
}

#assert size_of(DAVE_Encryptor_Stats) == 56;
#assert size_of(DAVE_Decryptor_Stats) == 56;

DAVE_MLS_Failure_Callback :: #type (source: *u8, reason: *u8, user_data: *void) #c_call;
DAVE_Pairwise_Fingerprint_Callback :: #type (fingerprint: *u8, length: u64, user_data: *void) #c_call;
DAVE_Protocol_Version_Changed_Callback :: #type (user_data: *void) #c_call;
DAVE_Log_Sink_Callback :: #type (severity: DAVE_Logging_Severity, file: *u8, line: s32, message: *u8) #c_call;

daveMaxSupportedProtocolVersion :: () -> u16 #foreign dave;
daveFree :: (ptr: *void) -> void #foreign dave;
daveSetLogSinkCallback :: (callback: DAVE_Log_Sink_Callback) -> void #foreign dave;

daveSessionCreate :: (ctx: *void, auth_session_id: *u8, callback: DAVE_MLS_Failure_Callback, user_data: *void) -> DAVE_Session #foreign dave;
daveSessionDestroy :: (session: DAVE_Session) -> void #foreign dave;
daveSessionInit :: (session: DAVE_Session, version: u16, group_id: u64, self_user_id: *u8) -> void #foreign dave;
daveSessionReset :: (session: DAVE_Session) -> void #foreign dave;
daveSessionSetProtocolVersion :: (session: DAVE_Session, version: u16) -> void #foreign dave;
daveSessionGetProtocolVersion :: (session: DAVE_Session) -> u16 #foreign dave;
daveSessionGetLastEpochAuthenticator :: (session: DAVE_Session, authenticator: **u8, length: *u64) -> void #foreign dave;
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
daveSessionGetPairwiseFingerprint :: (session: DAVE_Session, version: u16, user_id: *u8, callback: DAVE_Pairwise_Fingerprint_Callback, user_data: *void) -> void #foreign dave;

daveKeyRatchetDestroy :: (key_ratchet: DAVE_Key_Ratchet) -> void #foreign dave;

daveCommitResultIsFailed :: (result: DAVE_Commit_Result) -> bool #foreign dave;
daveCommitResultIsIgnored :: (result: DAVE_Commit_Result) -> bool #foreign dave;
daveCommitResultGetRosterMemberIds :: (result: DAVE_Commit_Result, roster_ids: **u64, roster_ids_length: *u64) -> void #foreign dave;
daveCommitResultGetRosterMemberSignature :: (result: DAVE_Commit_Result, roster_id: u64, signature: **u8, signature_length: *u64) -> void #foreign dave;
daveCommitResultDestroy :: (result: DAVE_Commit_Result) -> void #foreign dave;

daveWelcomeResultGetRosterMemberIds :: (result: DAVE_Welcome_Result, roster_ids: **u64, roster_ids_length: *u64) -> void #foreign dave;
daveWelcomeResultGetRosterMemberSignature :: (result: DAVE_Welcome_Result, roster_id: u64, signature: **u8, signature_length: *u64) -> void #foreign dave;
daveWelcomeResultDestroy :: (result: DAVE_Welcome_Result) -> void #foreign dave;

daveEncryptorCreate :: () -> DAVE_Encryptor #foreign dave;
daveEncryptorDestroy :: (encryptor: DAVE_Encryptor) -> void #foreign dave;
// Doesn't take ownership: the key ratchet must outlive its use by the encryptor.
daveEncryptorSetKeyRatchet :: (encryptor: DAVE_Encryptor, key_ratchet: DAVE_Key_Ratchet) -> void #foreign dave;
daveEncryptorSetPassthroughMode :: (encryptor: DAVE_Encryptor, passthrough: bool) -> void #foreign dave;
daveEncryptorAssignSsrcToCodec :: (encryptor: DAVE_Encryptor, ssrc: u32, codec: DAVE_Codec) -> void #foreign dave;
daveEncryptorGetProtocolVersion :: (encryptor: DAVE_Encryptor) -> u16 #foreign dave;
daveEncryptorGetMaxCiphertextByteSize :: (encryptor: DAVE_Encryptor, media_type: DAVE_Media_Type, frame_size: u64) -> u64 #foreign dave;
daveEncryptorHasKeyRatchet :: (encryptor: DAVE_Encryptor) -> bool #foreign dave;
daveEncryptorIsPassthroughMode :: (encryptor: DAVE_Encryptor) -> bool #foreign dave;
daveEncryptorEncrypt :: (encryptor: DAVE_Encryptor, media_type: DAVE_Media_Type, ssrc: u32, frame: *u8, frame_length: u64, encrypted_frame: *u8, encrypted_frame_capacity: u64, bytes_written: *u64) -> DAVE_Encryptor_Result #foreign dave;
daveEncryptorSetProtocolVersionChangedCallback :: (encryptor: DAVE_Encryptor, callback: DAVE_Protocol_Version_Changed_Callback, user_data: *void) -> void #foreign dave;
daveEncryptorGetStats :: (encryptor: DAVE_Encryptor, media_type: DAVE_Media_Type, stats: *DAVE_Encryptor_Stats) -> void #foreign dave;

daveDecryptorCreate :: () -> DAVE_Decryptor #foreign dave;
daveDecryptorDestroy :: (decryptor: DAVE_Decryptor) -> void #foreign dave;
daveDecryptorTransitionToKeyRatchet :: (decryptor: DAVE_Decryptor, key_ratchet: DAVE_Key_Ratchet) -> void #foreign dave;
daveDecryptorTransitionToPassthroughMode :: (decryptor: DAVE_Decryptor, passthrough: bool) -> void #foreign dave;
daveDecryptorDecrypt :: (decryptor: DAVE_Decryptor, media_type: DAVE_Media_Type, encrypted_frame: *u8, encrypted_frame_length: u64, frame: *u8, frame_capacity: u64, bytes_written: *u64) -> DAVE_Decryptor_Result #foreign dave;
daveDecryptorGetMaxPlaintextByteSize :: (decryptor: DAVE_Decryptor, media_type: DAVE_Media_Type, encrypted_frame_size: u64) -> u64 #foreign dave;
daveDecryptorGetStats :: (decryptor: DAVE_Decryptor, media_type: DAVE_Media_Type, stats: *DAVE_Decryptor_Stats) -> void #foreign dave;

//
// Foreign bindings: OpenSSL's libcrypto, for the AES-256-GCM transport encryption
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
// Foreign bindings: libcurl, for the voice WebSocket
//

CURL :: void;
curl_off_t :: s64;
curl_socket_t :: s32;

CURL_GLOBAL_DEFAULT :: 3;

CURLE_OK          :: 0;
CURLE_GOT_NOTHING :: 52;  // the server closed the connection
CURLE_SEND_ERROR  :: 55;
CURLE_RECV_ERROR  :: 56;
CURLE_AGAIN       :: 81;  // nothing to read, or the socket can't take more yet

CURLOPT_VERBOSE           :: 41;
CURLOPT_CONNECT_ONLY      :: 141;  // set to 2 for WebSocket: stop after the upgrade
CURLOPT_CONNECTTIMEOUT_MS :: 156;
CURLOPT_WS_OPTIONS        :: 320;
CURLOPT_URL               :: 10002;

CURLINFO_ACTIVESOCKET :: 0x500000 + 44;

CURLWS_TEXT   :: 1 << 0;
CURLWS_BINARY :: 1 << 1;
CURLWS_CONT   :: 1 << 2;
CURLWS_CLOSE  :: 1 << 3;
CURLWS_PING   :: 1 << 4;
CURLWS_OFFSET :: 1 << 5;
CURLWS_PONG   :: 1 << 6;

// For CURLOPT_WS_OPTIONS.
CURLWS_RAW_MODE   :: 1 << 0;
CURLWS_NOAUTOPONG :: 1 << 1;

Curl_Ws_Frame :: struct {
    age: s32;
    flags: s32;          // CURLWS_* bits
    offset: curl_off_t;  // where this chunk starts inside the whole message
    bytesleft: curl_off_t;  // bytes of this message still to come
    len: u64;            // size of this chunk
}

#assert size_of(Curl_Ws_Frame) == 32;

curl_global_init :: (flags: s64) -> s32 #foreign libcurl;
curl_global_cleanup :: () -> void #foreign libcurl;
curl_easy_init :: () -> *CURL #foreign libcurl;
curl_easy_cleanup :: (curl: *CURL) -> void #foreign libcurl;
curl_easy_perform :: (curl: *CURL) -> s32 #foreign libcurl;
curl_easy_strerror :: (code: s32) -> *u8 #foreign libcurl;

// curl_easy_setopt and curl_easy_getinfo are variadic in C. These fixed versions
// cover the three argument kinds we need, and are ABI-compatible on x86-64 Linux.
curl_easy_setopt_long :: (curl: *CURL, option: s32, value: s64) -> s32 #foreign libcurl "curl_easy_setopt";
curl_easy_setopt_ptr  :: (curl: *CURL, option: s32, value: *void) -> s32 #foreign libcurl "curl_easy_setopt";
curl_easy_getinfo_socket :: (curl: *CURL, info: s32, out: *curl_socket_t) -> s32 #foreign libcurl "curl_easy_getinfo";

curl_ws_recv :: (curl: *CURL, buffer: *void, buflen: u64, recv: *u64, meta: **Curl_Ws_Frame) -> s32 #foreign libcurl;
curl_ws_send :: (curl: *CURL, buffer: *void, buflen: u64, sent: *u64, fragsize: curl_off_t, flags: u32) -> s32 #foreign libcurl;
curl_ws_meta :: (curl: *CURL) -> *Curl_Ws_Frame #foreign libcurl;

//
// Foreign bindings: Concord's JSON libraries (jsmn + jsmn-find to parse, json-build to build)
//

JSMN_UNDEFINED :: 0;
JSMN_OBJECT    :: 1;
JSMN_ARRAY     :: 2;
JSMN_STRING    :: 3;
JSMN_PRIMITIVE :: 4;  // numbers, true, false, null

JSMN_ERROR_NOMEM :: -1;  // not enough tokens or pairs
JSMN_ERROR_INVAL :: -2;  // invalid character
JSMN_ERROR_PART  :: -3;  // incomplete JSON

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

JSONB_OK          :: 0;
JSONB_END         :: 1;
JSONB_ERROR_NOMEM :: -1;  // the output buffer is too small
JSONB_ERROR_INPUT :: -2;
JSONB_ERROR_STACK :: -3;

JSONB_MAX_DEPTH :: 128;

Jsonb :: struct {
    stack: [JSONB_MAX_DEPTH + 1]s32;
    top: *s32;
    pos: u64;  // bytes written to the buffer so far
}

#assert size_of(Jsmn_Token) == 16;
#assert size_of(Jsmn_Parser) == 12;
#assert size_of(Jsmnf_Tok) == 16;
#assert size_of(Jsmnf_Pair) == 64;
#assert size_of(Jsmnf_Loader) == 4;
#assert size_of(Jsonb) == 536;

jsmn_init :: (parser: *Jsmn_Parser) -> void #foreign discord;
jsmn_parse :: (parser: *Jsmn_Parser, js: *u8, len: u64, tokens: *Jsmn_Token, num_tokens: u32) -> s32 #foreign discord;
jsmn_parse_auto :: (parser: *Jsmn_Parser, js: *u8, length: u64, p_tokens: **Jsmn_Token, num_tokens: *u32) -> s32 #foreign discord;
jsmnf_init :: (loader: *Jsmnf_Loader) -> void #foreign discord;
jsmnf_load :: (loader: *Jsmnf_Loader, js: *u8, tokens: *Jsmn_Token, num_tokens: u32, pairs: *Jsmnf_Pair, num_pairs: u32) -> s32 #foreign discord;
jsmnf_load_auto :: (loader: *Jsmnf_Loader, js: *u8, tokens: *Jsmn_Token, num_tokens: u32, p_pairs: **Jsmnf_Pair, num_pairs: *u32) -> s32 #foreign discord;
jsmnf_find :: (head: *Jsmnf_Pair, js: *u8, key: *u8, length: s32) -> *Jsmnf_Pair #foreign discord;
jsmnf_find_path :: (head: *Jsmnf_Pair, js: *u8, path: **u8, depth: u32) -> *Jsmnf_Pair #foreign discord;
jsmnf_unescape :: (buf: *u8, bufsize: u64, src: *u8, length: u64) -> s64 #foreign discord;

jsonb_init :: (b: *Jsonb) -> void #foreign discord;
jsonb_object :: (b: *Jsonb, buf: *u8, bufsize: u64) -> s32 #foreign discord;
jsonb_object_pop :: (b: *Jsonb, buf: *u8, bufsize: u64) -> s32 #foreign discord;
jsonb_key :: (b: *Jsonb, buf: *u8, bufsize: u64, key: *u8, len: u64) -> s32 #foreign discord;
jsonb_array :: (b: *Jsonb, buf: *u8, bufsize: u64) -> s32 #foreign discord;
jsonb_array_pop :: (b: *Jsonb, buf: *u8, bufsize: u64) -> s32 #foreign discord;
jsonb_token :: (b: *Jsonb, buf: *u8, bufsize: u64, token: *u8, len: u64) -> s32 #foreign discord;
jsonb_bool :: (b: *Jsonb, buf: *u8, bufsize: u64, boolean: s32) -> s32 #foreign discord;
jsonb_null :: (b: *Jsonb, buf: *u8, bufsize: u64) -> s32 #foreign discord;
jsonb_string :: (b: *Jsonb, buf: *u8, bufsize: u64, str: *u8, len: u64) -> s32 #foreign discord;
jsonb_number :: (b: *Jsonb, buf: *u8, bufsize: u64, number: float64) -> s32 #foreign discord;
