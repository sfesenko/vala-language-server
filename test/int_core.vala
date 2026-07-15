/* int_core.vala
 *
 * Core integration tests: diagnostics, init, non-native root.
 *
 * Copyright 2026 Sergii Fesenko
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not see <http://www.gnu.org/licenses/>.
 */

using GLib;
using Jsonrpc;

void test_publish_diagnostics () {
    string? server_path = Environment.get_variable ("VLS_SERVER_PATH");
    if (server_path == null || server_path == "")
        server_path = Path.build_filename (Environment.get_current_dir (), "src", "vala-language-server");
    assert (FileUtils.test (server_path, FileTest.EXISTS));

    var root = File.new_for_path (Path.build_filename (
        Environment.get_tmp_dir (), "vls-integration-" + Random.int_range (0, int.MAX).to_string ()));
    try {
        root.make_directory_with_parents ();
    } catch (Error e) {
        assert_not_reached ();
    }
    var fixture = root.get_child ("sample.vala");
    try {
        FileUtils.set_contents (fixture.get_path (), FIXTURE);
    } catch (Error e) {
        assert_not_reached ();
    }
    string uri = fixture.get_uri ();

    var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
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

    Variant? diag_params = null;
    var loop = new MainLoop ();
    client.notification.connect ((c, method, @params) => {
        if (method == "textDocument/publishDiagnostics") {
            Variant? diags = @params.lookup_value ("diagnostics", VariantType.ARRAY);
            if (diags != null && diags.n_children () > 0) {
                diag_params = @params;
                loop.quit ();
            }
        }
    });

    Helpers.notify (client, "textDocument/didOpen", h.build_dict (
        textDocument: h.build_dict (
            uri: new Variant.string (uri),
            languageId: new Variant.string ("vala"),
            version: new Variant.int32 (1),
            text: new Variant.string (FIXTURE)
        )
    ));

    var timeout_id = Timeout.add (8000, () => { loop.quit (); return false; });
    loop.run ();
    Source.remove (timeout_id);

    Helpers.notify (client, "exit", Helpers.empty_dict ());
    server.force_exit ();

    assert (diag_params != null);
    Variant? diagnostics = diag_params.lookup_value ("diagnostics", VariantType.ARRAY);
    assert (diagnostics != null);
    assert (diagnostics.n_children () > 0);

    try {
        fixture.@delete ();
        root.@delete ();
    } catch (Error e) {}
}

void test_non_native_root_survives () {
    string? server_path = Environment.get_variable ("VLS_SERVER_PATH");
    if (server_path == null || server_path == "")
        server_path = Path.build_filename (Environment.get_current_dir (), "src", "vala-language-server");
    assert (FileUtils.test (server_path, FileTest.EXISTS));

    var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
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
        rootUri: new Variant.string ("http://example.com/"),
        capabilities: Helpers.empty_dict ()
    ));
    assert (init_result == null);

    var root = File.new_for_path (Path.build_filename (
        Environment.get_tmp_dir (), "vls-nonnative-" + Random.int_range (0, int.MAX).to_string ()));
    try {
        root.make_directory_with_parents ();
    } catch (Error e) {
        assert_not_reached ();
    }
    Variant? init_result2 = Helpers.sync_call (client, "initialize", h.build_dict (
        processId: new Variant.int32 ((int32) Posix.getpid ()),
        rootUri: new Variant.string (root.get_uri ()),
        capabilities: Helpers.empty_dict ()
    ));
    assert (init_result2 != null);
    try {
        root.@delete ();
    } catch (Error e) {}

    Helpers.notify (client, "exit", Helpers.empty_dict ());
    server.force_exit ();
}

void test_initialize_capabilities () {
    string? server_path = Environment.get_variable ("VLS_SERVER_PATH");
    if (server_path == null || server_path == "")
        server_path = Path.build_filename (Environment.get_current_dir (), "src", "vala-language-server");
    assert (FileUtils.test (server_path, FileTest.EXISTS));

    var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE);
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
        rootUri: new Variant.string (File.new_for_path (Environment.get_tmp_dir ()).get_uri ()),
        capabilities: Helpers.empty_dict ()
    ));
    assert (init_result != null);
    Variant? capabilities = init_result.lookup_value ("capabilities", VariantType.VARDICT);
    assert (capabilities != null);
    assert (capabilities.lookup_value ("completionProvider", null) != null);
    assert (capabilities.lookup_value ("definitionProvider", null) != null);
    assert (capabilities.lookup_value ("documentSymbolProvider", null) != null);

    Helpers.notify (client, "exit", Helpers.empty_dict ());
    server.force_exit ();
}
