#import "BuildCpp";

// Defines `discord`, the Concord library. It comes from #insert so the library exists before the compiler sees it.
#insert -> string {
    #import "Compiler";
    #import "Process";

    result := run_command("make", "-j", working_directory = "vendor/concord");
    if result.exit_code != 0 {
        compiler_report("\"make\" failed while building concord.");
    }

    return "discord :: #library,no_dll \"vendor/concord/lib/libdiscord\";";
}

#run {
    #import "File_Utilities";

    // Compiling miniaudio takes ~11s, so only rebuild decoder.a when its sources changed.
    lib_time, _, lib_exists := file_modtime_and_size("decoder.a");
    needs_rebuild := !lib_exists;
    for source: string.["decoder.c", "vendor/miniaudio/miniaudio.h"] {
        if needs_rebuild break;
        source_time := file_modtime_and_size(source);
        if source_time > lib_time  needs_rebuild = true;
    }

    if needs_rebuild  build_cpp_static_lib("decoder", "decoder.c");
}
