#import "BuildCpp";
#import "Compiler";
#import "Process";

// vcpkg builds the static libraries in deps/vcpkg.json (curl, OpenSSL, opus,
// mlspp), then Concord compiles against that curl, then libdave against that OpenSSL and mlspp.
// Build outputs go in .deps/.
#insert -> string {
    #import "String";
    #import "File_Utilities";
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

    for patch: string.["../patches/concord-null-channel.patch"] {
        applied := run_command("git", "apply", "--reverse", "--check", patch, working_directory = "vendor/concord", capture_and_return_output = true);
        if applied.exit_code == 0  continue;
        run(tprint("concord (applying %)", patch), "git", "apply", patch, working_directory = "vendor/concord");
    }

    run("concord", "env", tprint("CFLAGS=-O2 -I%/%/include", installed, TRIPLET), "make", "-j", working_directory = "vendor/concord");

    if !file_exists(".deps/libdave/CMakeCache.txt") {
        run("libdave (configure)", "cmake", "-S", "vendor/libdave/cpp", "-B", ".deps/libdave",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBUILD_SHARED_LIBS=OFF",
            "-DTESTING=OFF",
            tprint("-DCMAKE_TOOLCHAIN_FILE=%/%/scripts/buildsystems/vcpkg.cmake", root, VCPKG_DIR),
            tprint("-DVCPKG_TARGET_TRIPLET=%", TRIPLET),
            tprint("-DVCPKG_MANIFEST_DIR=%/deps", root),
            tprint("-DVCPKG_INSTALLED_DIR=%", installed),
            "-DVCPKG_MANIFEST_INSTALL=OFF");
    }
    run("libdave", "cmake", "--build", ".deps/libdave", "--target", "libdave", "--config", "Release", "-j");

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
discord :: #library,no_dll "vendor/concord/lib/libdiscord";
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
