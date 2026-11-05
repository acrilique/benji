#import "Basic";
#import "BuildCpp";
#import "Command_Line";
#import "File";

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

Context :: #Context;

decoder :: #library,no_dll "decoder";
opus :: #library,system "libopus";
_ :: #library,system,link_always "libm";
_ :: #library,system,link_always "libcurl";

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

discord_init :: (token: *u8) -> *void #foreign discord;
discord_add_intents :: (client: *void, code: u64) -> void #foreign discord;
discord_on_ready_cb :: #type(client: *void, discord_ready: *void) -> void #c_call;
discord_set_on_ready :: (client: *void, cb: discord_on_ready_cb) -> void #foreign discord;
discord_run :: (client: *void) -> s32 #foreign discord;
discord_shutdown :: (client: *void) -> void #foreign discord;
discord_cleanup :: (client: *void) -> void #foreign discord;

TESTFILE :: "testfile.flac";
TOKENFILE :: "bot-key";
OPUS_APPLICATION_AUDIO :: 2049;
FRAME_SIZE :: 960;

Args :: struct {
	music_folder: string;
}

on_ready :: (client: *void, discord_ready: *void) #c_call {
	new_context: Context;

	push_context new_context {
		print("Discord is ready\n");
	}
}

main :: () {
	success, args, is_set := parse_arguments(Args);
	if !success return;

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

	token, result := read_entire_file(TOKENFILE);
	if !result {
		print("Failed to read token file\n");
		return;
	}

	print("Music folder: %\n", args.music_folder);
	client := discord_init(to_c_string(token));

	discord_set_on_ready(client, on_ready);
	discord_add_intents(client, 1 << 0 | 1 << 7);
	
	discord_run(client);

	discord_cleanup(client);
}

