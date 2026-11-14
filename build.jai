#import "BuildCpp";
#import "Compiler";
#import "Process";


#insert -> string {
    for patch: string.["../patches/concord-null-channel.patch"] {
        applied := run_command("git", "apply", "--reverse", "--check", patch, working_directory = "vendor/concord", capture_and_return_output = true);
        if applied.exit_code == 0  continue;

        apply := run_command("git", "apply", patch, working_directory = "vendor/concord");
        if apply.exit_code != 0 {
            compiler_report(tprint("Failed to apply % to concord.", patch));
        }
    }

    result := run_command("make", "-j", working_directory = "vendor/concord");
    if result.exit_code != 0 {
        compiler_report("\"make\" failed while building concord.");
    }

    return "discord :: #library,no_dll \"vendor/concord/lib/libdiscord\";";
}

#insert -> string {
    #import "String";
    #import "File_Utilities";
    #import "System";

    bootstrap_result := run_command("./vcpkg/bootstrap-vcpkg.sh", working_directory = "vendor/libdave/cpp");
    if bootstrap_result.exit_code != 0 {
        compiler_report("dave vcpkg bootstrap failed.");
    }

    make_result := run_command("make", "-j", working_directory = "vendor/libdave/cpp");
    if make_result.exit_code != 0 {
        compiler_report("\"make\" failed while building dave.");
    }

    gcc_result, gcc_output := run_command("c++", "-print-file-name=libstdc++.a", capture_and_return_output = true);
    stdcpp_archive := trim(gcc_output);
    if gcc_result.exit_code != 0 || !file_exists(stdcpp_archive) {
        compiler_report("Couldn't find libstdc++.a with \"c++ -print-file-name\".");
    }
    gcc_dir := path_strip_filename(stdcpp_archive);

    up: String_Builder;
    for split(get_working_directory(), "/")  if it  append(*up, "../");
    gcc_dir = tprint("%1%2", builder_to_string(*up), gcc_dir);

    return tprint(#string DONE
dave :: #library,no_dll "vendor/libdave/cpp/build/libdave";
_ :: #library,no_dll,link_always "vendor/libdave/cpp/build/vcpkg_installed/x64-linux/lib/libmlspp";
_ :: #library,no_dll,link_always "vendor/libdave/cpp/build/vcpkg_installed/x64-linux/lib/libhpke";
_ :: #library,no_dll,link_always "vendor/libdave/cpp/build/vcpkg_installed/x64-linux/lib/libtls_syntax";
_ :: #library,no_dll,link_always "vendor/libdave/cpp/build/vcpkg_installed/x64-linux/lib/libbytes";
_ :: #library,system,link_always "libcrypto";
_ :: #library,no_dll,link_always "%1libstdc++";
_ :: #library,no_dll,link_always "%1libgcc_eh";
DONE, gcc_dir);
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
