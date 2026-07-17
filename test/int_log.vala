/* int_log.vala
 *
 * Integration tests for log output format (uses $PROJECT/ instead of full paths).
 */

void test_log_uses_project_path () {
    string? server_path = Environment.get_variable ("VLS_SERVER_PATH");
    if (server_path == null || server_path == "")
        server_path = Path.build_filename (Environment.get_current_dir (), "src", "vala-language-server");
    assert (FileUtils.test (server_path, FileTest.EXISTS));

    var root = File.new_for_path (Path.build_filename (
        Environment.get_current_dir (), ".tmp", "int-log-test-" + Random.int_range (0, int.MAX).to_string ()));
    try {
        root.make_directory_with_parents ();
    } catch (Error e) {
        assert_not_reached ();
    }
    var fixture = root.get_child ("sample.vala");
    try {
        FileUtils.set_contents (fixture.get_path (), "public void main () {}");
    } catch (Error e) {
        assert_not_reached ();
    }
    string uri = fixture.get_uri ();

    var launcher = new SubprocessLauncher (
        SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
    Subprocess server;
    try {
        server = launcher.spawnv ({ server_path });
    } catch (Error e) {
        assert_not_reached ();
    }
    var stream = new SimpleIOStream (server.get_stdout_pipe (), server.get_stdin_pipe ());
    var client = new Jsonrpc.Client (stream);
    var h = new Helpers ();

    Variant? init_result = Helpers.sync_call (client, "initialize", h.build_dict (
        processId: new Variant.int32 ((int32) Posix.getpid ()),
        rootUri: new Variant.string (root.get_uri ()),
        capabilities: Helpers.empty_dict ()
    ));
    assert (init_result != null);
    Helpers.notify (client, "initialized", Helpers.empty_dict ());

    var loop = new MainLoop ();
    client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics")
            loop.quit ();
    });
    Helpers.notify (client, "textDocument/didOpen", h.build_dict (
        textDocument: h.build_dict (
            uri: new Variant.string (uri),
            languageId: new Variant.string ("vala"),
            version: new Variant.int32 (1),
            text: new Variant.string ("public void main () {}")
        )
    ));
    var timeout_id = Timeout.add (8000, () => { loop.quit (); return false; });
    loop.run ();
    Source.remove (timeout_id);

    // Shut down the server cleanly so it flushes its logs
    Helpers.notify (client, "exit", Helpers.empty_dict ());
    try {
        server.wait ();
    } catch (Error e) {
        try {
            server.force_exit ();
            server.wait ();
        } catch (Error e2) {}
    }

    // Read the VLS log file (written by vls_log_handler when -Ddebug_logging is set)
    string log_path = Path.build_filename (Environment.get_current_dir (), ".tmp", "vls.log");
    string log_text = "";
    try {
        FileUtils.get_contents (log_path, out log_text);
    } catch (Error e) {
        // Server built without -Ddebug_logging → no log file produced
        stdout.printf ("SKIP: server built without debug logging, log at %s not found\n", log_path);
        try { fixture.@delete (); root.@delete (); } catch (Error e2) {}
        return;
    }

    // Cleanup temp files
    try {
        fixture.@delete ();
        root.@delete ();
    } catch (Error e) {}

    // The didOpen log should contain $PROJECT/ with the fixture path
    assert ("$PROJECT/" in log_text);
}
