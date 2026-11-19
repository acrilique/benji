//
// Libraries
//

decoder :: #library,no_dll "decoder";
json    :: #library,no_dll "json";
#if OS != .WINDOWS  _ :: #library,system,link_always "libm";
// `libcurl`, `opus`, `dave` (libdave) and `libcrypto` (OpenSSL) are declared in
// build.jai, which builds them.

//
// Foreign bindings: decoder (decoder.c) and libopus
//

decoder_open :: (path: *u8) -> *void #foreign decoder;
decoder_read :: (decoder: *void, out: *s16, frames: u64) -> s64 #foreign decoder;
decoder_close :: (decoder: *void) -> void #foreign decoder;

opus_encoder_create :: (Fs: s32, channels: s32, application: s32, error: *s32) -> *void #foreign opus;
opus_encoder_destroy :: (st: *void) -> void #foreign opus;
opus_encode :: (st: *void, pcm: *s16, frame_size: s32, data: *u8, max_data_bytes: s32) -> s32 #foreign opus;
opus_strerror :: (error: s32) -> *u8 #foreign opus;

//
// Foreign bindings: libdave (vendor/libdave/cpp/includes/dave/dave.h)
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
// Foreign bindings: libcurl, for the WebSockets and Discord's REST API
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
// Foreign bindings: jsmn + jsmn-find (vendor/jsmn, compiled by json.c)
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
