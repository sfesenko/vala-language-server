/* server.vala
 *
 * Copyright 2017-2019 Ben Iofel <ben@iofel.me>
 * Copyright 2017-2020 Princeton Ferro <princetonferro@gmail.com>
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
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

using Lsp;
using Gee;

class Vls.Server : Jsonrpc.Server {
    private static bool received_signal = false;
    MainLoop loop;

    public InitializeParams init_params;

    const uint check_update_context_period_ms = 100;
    const int64 update_context_delay_inc_us = 500 * 1000;
    const int64 update_context_delay_max_us = 1000 * 1000;
    const uint wait_for_context_update_delay_ms = 200;

    /**
     * Contains documentation from found GIR files.
     */
    GirDocumentation documentation;

    HashSet<Request> pending_requests;

    bool shutting_down = false;

    /**
     * The global cancellable object
     */
    public static Cancellable cancellable = new Cancellable ();

    uint[] g_sources = {};
    ulong client_closed_event_id;
    public HashTable<Project, ulong> projects;
    public DefaultProject default_project;

    /**
     * Contains files that have been closed and should no longer be managed
     * by VLS. This is used to clear the errors/warnings for the files on
     * the next context update.
     */
    HashSet<string> discarded_files = new HashSet<string> ();

    /**
     * Files that are currently open in the editor
     */
    HashSet<string> open_files = new HashSet<string> ();

    /**
     * Use this in projects to keep track of target outputs and avoid
     * rebuilding dependent targets.
     */
    FileCache file_cache = new FileCache ();

    static construct {
        Process.@signal (ProcessSignal.INT, () => {
            Server.received_signal = true;
        });
        Process.@signal (ProcessSignal.TERM, () => {
            Server.received_signal = true;
        });
    }

    public Server (MainLoop loop) {
        this.loop = loop;

        // hack to prevent other things from corrupting JSON-RPC pipe:
        // create a new handle to stdout, and close the old one (or move it to stderr)
#if WINDOWS
        var new_stdout_fd = Windows._dup (Posix.STDOUT_FILENO);
        Windows._close (Posix.STDOUT_FILENO);
        Windows._dup2 (Posix.STDERR_FILENO, Posix.STDOUT_FILENO);
        void* new_stdin_handle = Windows._get_osfhandle (Posix.STDIN_FILENO);
        void* new_stdout_handle = Windows._get_osfhandle (new_stdout_fd);

        // we can't use the names 'stdin' or 'stdout' for these variables
        // since it causes build problems for mingw-w64-x86_64-gcc
        var input_stream = new Win32InputStream (new_stdin_handle, false);
        var output_stream = new Win32OutputStream (new_stdout_handle, false);
#else
        var new_stdout_fd = Posix.dup (Posix.STDOUT_FILENO);
        Posix.close (Posix.STDOUT_FILENO);
        Posix.dup2 (Posix.STDERR_FILENO, Posix.STDOUT_FILENO);

        var input_stream = new UnixInputStream (Posix.STDIN_FILENO, false);
        var output_stream = new UnixOutputStream (new_stdout_fd, false);

        // set nonblocking
        try {
            if (!Unix.set_fd_nonblocking (Posix.STDIN_FILENO, true)
             || !Unix.set_fd_nonblocking (new_stdout_fd, true))
             error ("could not set pipes to nonblocking.\n");
        } catch (Error e) {
            warning ("failed to set FDs to nonblocking");
            loop.quit ();
            return;
        }
#endif

        // shutdown if/when we get a signal
        g_sources += Timeout.add (1000, check_signal);

        accept_io_stream (new SimpleIOStream (input_stream, output_stream));

        pending_requests = new HashSet<Request> (Request.hash, Request.equal);

        this.projects = new HashTable<Project, ulong> (GLib.direct_hash, GLib.direct_equal);

        debug ("Finished constructing");
    }

    protected override void notification (Jsonrpc.Client client, string method, Variant parameters) {
        switch (method) {
            case "exit":
                exit ();
                break;

            case "$/cancelRequest":
                cancel_request (client, parameters);
                break;

            case "textDocument/didOpen":
                text_document_did_open (client, parameters);
                break;

            case "textDocument/didSave":
                text_document_did_save (client, parameters);
                break;

            case "textDocument/didClose":
                text_document_did_close (client, parameters);
                break;

            case "textDocument/didChange":
                text_document_did_change (client, parameters);
                break;

            default:
                warning ("unhandled notification `%s'", method);
                break;
        }
    }

    protected override bool handle_call (Jsonrpc.Client client, string method, Variant id, Variant parameters) {
        switch (method) {
            case "initialize":
                initialize (client, method, id, parameters);
                break;

            case "shutdown":
                shutdown ();
                reply_null (id, client, method);
                break;

            case "textDocument/definition":
                Navigation.goto_definition (this, client, method, id, parameters);
                break;

            case "textDocument/documentSymbol":
                DocumentSymbolHandler.document_symbol_outline (this, client, method, id, parameters);
                break;

            case "textDocument/completion":
                show_completion (client, method, id, parameters);
                break;

            case "textDocument/signatureHelp":
                show_signature_help (client, method, id, parameters);
                break;

            case "textDocument/hover":
                HoverHandler.hover (this, client, method, id, parameters);
                break;

            case "textDocument/formatting":
            case "textDocument/rangeFormatting":
                format (client, method, id, parameters);
                break;

            case "textDocument/codeAction":
                code_action (client, method, id, parameters);
                break;

            case "textDocument/references":
            case "textDocument/documentHighlight":
                Navigation.show_references (this, client, method, id, parameters);
                break;
                
            case "textDocument/implementation":
                Navigation.show_implementations (this, client, method, id, parameters);
                break;

            case "workspace/symbol":
                Workspace.search_workspace_symbols (this, client, method, id, parameters);
                break;

            case "textDocument/rename":
                Rename.rename_symbol (this, client, method, id, parameters);
                break;

            case "textDocument/prepareRename":
                Rename.prepare_rename_symbol (this, client, method, id, parameters);
                break;

            case "textDocument/codeLens":
                code_lens (client, method, id, parameters);
                break;

            case "textDocument/prepareCallHierarchy":
                CallHierarchy.prepare_call_hierarchy (this, client, method, id, parameters);
                break;

            case "callHierarchy/incomingCalls":
                CallHierarchy.call_hierarchy_incoming_calls (this, client, method, id, parameters);
                break;

            case "callHierarchy/outgoingCalls":
                CallHierarchy.call_hierarchy_outgoing_calls (this, client, method, id, parameters);
                break;

            case "textDocument/inlayHint":
                InlayHints.show_inlay_hints (this, client, method, id, parameters);
                break;

            case "textDocument/prepareTypeHierarchy":
                TypeHierarchy.prepare_type_hierarchy (this, client, method, id, parameters);
                break;

            case "typeHierarchy/supertypes":
                TypeHierarchy.show_type_hierarchy (this, client, method, id, parameters, true);
                break;

            case "typeHierarchy/subtypes":
                TypeHierarchy.show_type_hierarchy (this, client, method, id, parameters, false);
                break;

            case "textDocument/semanticTokens/full":
                SemanticTokensHandler.full (this, client, method, id, parameters);
                break;

            case "textDocument/semanticTokens/full/delta":
                SemanticTokensHandler.delta (this, client, method, id, parameters);
                break;

            case "textDocument/semanticTokens/range":
                SemanticTokensHandler.range (this, client, method, id, parameters);
                break;

            default:
                warning ("unhandled call `%s'", method);
                return false;
        }
        return true;
    }

#if WITH_JSONRPC_GLIB_3_30
    protected override void client_closed (Jsonrpc.Client client) {
        shutdown ();
        exit ();
    }
#endif

    bool check_signal () {
        if (Server.received_signal) {
            shutdown ();
            exit ();
            return Source.REMOVE;
        }
        return !this.shutting_down;
    }

    // a{sv} only
    public Variant build_dict (...) {
        var builder = new VariantBuilder (new VariantType ("a{sv}"));
        var l = va_list ();
        while (true) {
            string? key = l.arg ();
            if (key == null) {
                break;
            }
            Variant val = l.arg ();
            builder.add ("{sv}", key, val);
        }
        return builder.end ();
    }

    /**
     * Find a file with a URI. Will pick the first match.
     *
     * @param uri the URI of the file. may contain escape characters
     */
    public Vala.SourceFile? find_file (string uri, out Compilation? compilation = null, out Project? project = null) {
        var results = new ArrayList<Pair<Vala.SourceFile, Compilation>> ();
        Project? selected_project = null;
        foreach (var p in projects.get_keys_as_array ()) {
            results = p.lookup_compile_input_source_file (uri);
            if (!results.is_empty) {
                selected_project = p;
                break;
            }
        }
        // fallback to default project
        if (selected_project == null) {
            results = default_project.lookup_compile_input_source_file (uri);
            if (!results.is_empty)
                selected_project = default_project;
        }

        if (selected_project != null) {
            project = selected_project;
            compilation = results[0].second;
            return results[0].first;
        }

        project = null;
        compilation = null;
        return null;
    }

    void show_message (Jsonrpc.Client client, string message, MessageType type) {
        if (type == MessageType.Error)
            warning (message);
        try {
            client.send_notification ("window/showMessage", build_dict (
                type: new Variant.int16 (type),
                message: new Variant.string (message)
            ), cancellable);
        } catch (Error e) {
            debug (@"showMessage: failed to notify client: $(e.message)");
        }
    }

    void initialize (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        init_params = Util.parse_variant<InitializeParams> (@params);

        File root_dir;
        if (init_params.rootUri != null)
            root_dir = File.new_for_uri (init_params.rootUri);
        else if (init_params.rootPath != null)
            root_dir = File.new_for_path (init_params.rootPath);
        else
            root_dir = File.new_for_path (Environment.get_current_dir ());
        if (!root_dir.is_native ()) {
            show_message (client, "Non-native files not supported", MessageType.Error);
            client.reply_error_async.begin (
                id,
                Jsonrpc.ClientError.INVALID_PARAMS,
                "Non-native files not supported",
                cancellable);
            return;
        }
        string root_path = Util.realpath ((!) root_dir.get_path ());
        debug (@"[initialize] root path is $root_path");

        // respond
        try {
            client.reply (id, build_dict (
                capabilities: build_dict (
                    textDocumentSync: new Variant.int16 (TextDocumentSyncKind.Incremental),
                    definitionProvider: new Variant.boolean (true),
                    documentSymbolProvider: new Variant.boolean (true),
                    completionProvider: build_dict(
                        triggerCharacters: new Variant.strv (new string[] {".", ">"})
                    ),
                    signatureHelpProvider: build_dict(
                        triggerCharacters: new Variant.strv (new string[] {"(", "[", ","})
                    ),
                    codeActionProvider: new Variant.boolean (true),
                    hoverProvider: new Variant.boolean (true),
                    referencesProvider: new Variant.boolean (true),
                    documentHighlightProvider: new Variant.boolean (true),
                    documentFormattingProvider: new Variant.boolean (true),
                    documentRangeFormattingProvider: new Variant.boolean (true),
                    implementationProvider: new Variant.boolean (true),
                    workspaceSymbolProvider: new Variant.boolean (true),
                    renameProvider: build_dict (prepareProvider: new Variant.boolean (true)),
                    codeLensProvider: build_dict (resolveProvider: new Variant.boolean (false)),
                    callHierarchyProvider: new Variant.boolean (true),
                    inlayHintProvider: new Variant.boolean (true),
                    typeHierarchyProvider: new Variant.boolean (true),
                    semanticTokensProvider: build_dict (
                        legend: build_dict (
                            tokenTypes: new Variant.strv (new string[] {
                                "namespace", "class", "enum", "interface", "struct",
                                "typeParameter", "type", "parameter", "variable",
                                "property", "enumMember", "event", "function",
                                "method", "keyword", "string", "number", "comment", "operator"
                            }),
                            tokenModifiers: new Variant.strv (new string[] {
                                "declaration", "definition", "readonly", "static",
                                "deprecated", "abstract", "async", "documentation",
                                "defaultLibrary"
                            })
                        ),
                        full: build_dict (delta: new Variant.boolean (true)),
                        range: new Variant.boolean (true)
                    )
                ),
                serverInfo: build_dict (
                    name: new Variant.string ("Vala Language Server"),
                    version: new Variant.string (Config.PROJECT_VERSION)
                )
            ), cancellable);
        } catch (Error e) {
            error (@"[initialize] failed to reply to client: $(e.message)");
        }

        var meson_file = root_dir.get_child ("meson.build");
        ArrayList<File> cc_files = new ArrayList<File> ();
        try {
            cc_files = Util.find_files (root_dir, /compile_commands\.json/, 2);
        } catch (Error e) {
            warning ("could not enumerate root dir - %s", e.message);
        }

        var new_projects = new ArrayList<Project> ();
        Project? backend_project = null;
        // TODO: autotools, make(?), cmake(?)
        if (meson_file.query_exists (cancellable)) {
            try {
                backend_project = new MesonProject (root_path, file_cache, cancellable);
            } catch (Error e) {
                if (!(e is ProjectError.VERSION_UNSUPPORTED)) {
                    show_message (client, @"Failed to initialize Meson project - $(e.message)", MessageType.Error);
                }
            }
        }
        
        // try compile_commands.json if Meson failed
        if (backend_project == null && !cc_files.is_empty) {
            foreach (var cc_file in cc_files) {
                string cc_file_path = Util.realpath (cc_file.get_path ());
                try {
                    backend_project = new CcProject (root_path, cc_file_path, file_cache, cancellable);
                    debug ("[initialize] initialized CcProject with %s", cc_file_path);
                    break;
                } catch (Error e) {
                    debug ("[initialize] CcProject failed with %s - %s", cc_file_path, e.message);
                    continue;
                }
            }
        }

        // show messages if we could not get a backend-specific project
        if (backend_project == null) {
            var cmake_file = root_dir.get_child ("CMakeLists.txt");
            var autogen_sh = root_dir.get_child ("autogen.sh");

            if (cmake_file.query_exists (cancellable))
                show_message (client, @"CMake build system is not currently supported. Only Meson is. See https://github.com/vala-lang/vala-language-server/issues/73", MessageType.Warning);
            if (autogen_sh.query_exists (cancellable))
                show_message (client, @"Autotools build system is not currently supported. Consider switching to Meson.", MessageType.Warning);
        } else {
            new_projects.add (backend_project);
        }

        // always have default project
        default_project = new DefaultProject (root_path, file_cache);

        // build and publish diagnostics
        foreach (var project in new_projects) {
            try {
                debug ("Building project ...");
                project.build_if_stale ();
                debug ("Publishing diagnostics ...");
                foreach (var compilation in project.get_compilations ())
                    publish_diagnostics (project, compilation, client);
            } catch (Error e) {
                show_message (client, @"Failed to build project - $(e.message)", MessageType.Error);
            }
        }

        // create documentation (compiles GIR files too)
        var packages = new HashSet<Vala.SourceFile> ();
        var custom_gir_dirs = new HashSet<File> (Util.file_hash, Util.file_equal);
        foreach (var project in new_projects) {
            packages.add_all (project.get_packages ());
            custom_gir_dirs.add_all (project.get_custom_gir_dirs ());
        }
        documentation = new GirDocumentation (packages, custom_gir_dirs);

        // listen for context update requests
        update_context_client = client;
        g_sources += Timeout.add (check_update_context_period_ms, check_update_context);

        // listen for project changed events
        foreach (Project project in new_projects)
            projects[project] = project.changed.connect (project_changed_event);
    }

    void project_changed_event () {
        request_context_update (update_context_client);
        debug ("requested context update for project change event");
    }

    void cancel_request (Jsonrpc.Client client, Variant @params) {
        Variant? id = @params.lookup_value ("id", null);
        if (id == null)
            return;

        var req = new Request (id);
        // if (pending_requests.remove (req))
        //     debug (@"[cancelRequest] cancelled request $req");
        // else
        //     debug (@"[cancelRequest] request $req not found");
        pending_requests.remove (req);
    }

    public static void reply_null (Variant id, Jsonrpc.Client client, string method) {
        try {
            client.reply (id, new Variant.maybe (VariantType.VARIANT, null), cancellable);
        } catch (Error e) {
            debug (@"[$method] failed to reply to client: $(e.message)");
        }
    }

    void text_document_did_open (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);

        string? uri         = (string) document.lookup_value ("uri",        VariantType.STRING);
        string languageId   = (string) document.lookup_value ("languageId", VariantType.STRING);
        string fileContents = (string) document.lookup_value ("text",       VariantType.STRING);

        if (languageId != "vala" && languageId != "genie") {
            warning (@"[textDocument/didOpen] $languageId file sent to vala language server");
            return;
        }

        if (uri == null) {
            warning (@"[textDocument/didOpen] null URI sent to vala language server");
            return;
        }

        Pair<Vala.SourceFile, Compilation>? doc_w_bt = null;

        foreach (var project in projects.get_keys_as_array ()) {
            try {
                doc_w_bt = project.open (uri, fileContents, cancellable).first ();
                break;
            } catch (Error e) {
                if (!(e is ProjectError.NOT_FOUND))
                    warning ("[textDocument/didOpen] failed to open %s - %s", Uri.unescape_string (uri), e.message);
            }
        }

        // fallback to default project
        if (doc_w_bt == null) {
            try {
                doc_w_bt = default_project.open (uri, fileContents, cancellable).first ();
                // it's possible that we opened a Vala script and have to
                // include additional packages for documentation
                foreach (var pkg in default_project.get_packages ())
                    documentation.add_package_from_source_file (pkg);
                // show diagnostics for the newly-opened file
                request_context_update (client);
            } catch (Error e) {
                warning ("[textDocumnt/didOpen] failed to open %s - %s", Uri.unescape_string (uri), e.message);
            }
        }

        if (doc_w_bt == null) {
            warning ("[textDocument/didOpen] could not open %s", uri);
            return;
        }

        var doc = doc_w_bt.first;
        // We want to load the document unconditionally, to avoid
        // errors later on in textDocument/didChange. However, we
        // only want to edit it if it is an actual TextDocument.
        if (doc.content == null)
            doc.get_mapped_contents ();
        if (doc is TextDocument) {
            var tdoc = (TextDocument) doc;
            debug (@"[textDocument/didOpen] opened $(Uri.unescape_string (uri))"); 
            tdoc.last_saved_content = fileContents;
            bool content_changed = tdoc.content != fileContents;
            debug ("[SEMTOK] didOpen: uri=%s, content_len=%lu, content_changed=%s",
                   Uri.unescape_string (uri), fileContents.length, content_changed.to_string ());
            if (content_changed) {
                tdoc.content = fileContents;
                tdoc.last_updated = new DateTime.now ();
                debug ("[SEMTOK] didOpen: set content, last_updated=%s", tdoc.last_updated.to_string ());
                request_context_update (client);
                debug (@"[textDocument/didOpen] requested context update");
            }
        } else {
            debug (@"[textDocument/didOpen] opened read-only $(Uri.unescape_string (uri))");
        }

        // add document to open list
        open_files.add (uri);
    }

    void text_document_did_save (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);

        string? uri = (string) document.lookup_value ("uri", VariantType.STRING);
        if (uri == null) {
            warning (@"[textDocument/didSave] null URI sent to vala language server");
            return;
        }

        Project[] all_projects = projects.get_keys_as_array ();
        all_projects += default_project;

        foreach (var project in all_projects) {
            foreach (var pair in project.lookup_compile_input_source_file (uri)) {
                var text_document = pair.first as TextDocument;

                if (text_document == null) {
                    warning ("[textDocument/didSave] ignoring save to system file");
                    continue;
                }

                // make checkpoint
                text_document.last_saved_content = text_document.content;
                debug ("[textDocument/didSave] last save of %s is now at version %d", uri, text_document.last_saved_version);
            }
        }
    }

    void text_document_did_close (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        string? uri         = (string) document.lookup_value ("uri",        VariantType.STRING);

        if (uri == null) {
            warning (@"[textDocument/didClose] null URI sent to vala language server");
            return;
        }

        Project[] all_projects = projects.get_keys_as_array ();
        all_projects += default_project;

        foreach (var project in all_projects) {
            try {
                if (project.close (uri)) {
                    discarded_files.add (uri);
                    request_context_update (client);
                    debug (@"[textDocument/didClose] requested context update");
                }
                debug ("[textDocument/didClose] closed %s", uri);
            } catch (Error e) {
                if (!(e is ProjectError.NOT_FOUND))
                    warning ("[textDocument/didClose] failed to close %s - %s", Uri.unescape_string (uri), e.message);
            }
        }
    }

    Jsonrpc.Client? update_context_client = null;
    int64 update_context_requests = 0;
    int64 update_context_time_us = 0;

    void text_document_did_change (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        var changes = @params.lookup_value ("contentChanges", VariantType.ARRAY);

        var uri = (string) document.lookup_value ("uri", VariantType.STRING);
        var version = (int64) document.lookup_value ("version", VariantType.INT64);

        Project[] all_projects = projects.get_keys_as_array ();
        all_projects += default_project;

        foreach (var project in all_projects) {
            foreach (Pair<Vala.SourceFile, Compilation> pair in project.lookup_compile_input_source_file (uri)) {
                var source_file = pair.first;

                if (!(source_file is TextDocument)) {
                    warning (@"[textDocument/didChange] Ignoring change to system file");
                    return;
                }

                var source = (TextDocument) source_file;
                if (source.version >= version) {
                    warning (@"[textDocument/didChange] rejecting outdated version of $(Uri.unescape_string (uri))");
                    return;
                }

                if (source_file.content == null) {
                    error (@"[textDocument/didChange] source content is null!");
                }

                // update the document
                var iter = changes.iterator ();
                Variant? elem = null;
                var sb = new StringBuilder (source.content);
                while ((elem = iter.next_value ()) != null) {
                    var changeEvent = Util.parse_variant<TextDocumentContentChangeEvent> (elem);

                    if (changeEvent.range == null) {
                        sb.assign (changeEvent.text);
                    } else {
                        var start = changeEvent.range.start;
                        var end = changeEvent.range.end;
                        size_t pos_begin = Util.get_string_pos (sb.str, start.line, start.character);
                        size_t pos_end = Util.get_string_pos (sb.str, end.line, end.character);
                        sb.erase ((ssize_t) pos_begin, (ssize_t) (pos_end - pos_begin));
                        sb.insert ((ssize_t) pos_begin, changeEvent.text);
                    }
                }
                source.content = sb.str;
                source.last_updated = new DateTime.now ();
                source.version = (int) version;

                request_context_update (client);
            }
        }
    }

    /** 
     * Indicate to the server that the code context(s) it is tracking may
     * need to be refreshed.
     * 
     * @param client        the client to eventually send a `publishDiagnostics` 
     *                      notification to, if the context is refreshed
     */
    void request_context_update (Jsonrpc.Client client) {
        update_context_client = client;
        update_context_requests += 1;
        int64 delay_us = int64.min (update_context_delay_inc_us * update_context_requests, update_context_delay_max_us);
        update_context_time_us = get_monotonic_time () + delay_us;
        debug ("[SEMTOK] request_context_update: requests=%d, delay=%dms",
               (int) update_context_requests, (int) (delay_us / 1000));
    }

    /** 
     * Reconfigure the project if needed, and check whether we need to rebuild
     * the project and documentation engine if we have context update requests.
     */
    bool check_update_context () {
        if (update_context_requests > 0 && get_monotonic_time () >= update_context_time_us) {
            debug ("[SEMTOK] check_update_context: starting rebuild (requests=%d)", (int) update_context_requests);
            update_context_requests = 0;
            update_context_time_us = 0;

            Project[] all_projects = projects.get_keys_as_array ();
            all_projects += default_project;
            bool reconfigured_projects = false;
            foreach (var project in all_projects) {
                try {
                    bool reconfigured = project.reconfigure_if_stale (cancellable);
                    reconfigured_projects |= reconfigured;
                    debug ("[SEMTOK] check_update_context: build_if_stale for project");
                    project.build_if_stale (cancellable);

                    // remove all newly-added files from the default project
                    if (reconfigured && project != default_project) {
                        var newly_added = new HashSet<string> ();
                        foreach (var compilation in project.get_compilations ())
                            newly_added.add_all_iterator (compilation.get_project_files ().map<string> (f => f.filename));
                        foreach (var compilation in default_project.get_compilations ()) {
                            foreach (var source_file in compilation.get_project_files ()) {
                                if (newly_added.contains (source_file.filename)) {
                                    var uri = File.new_for_path (source_file.filename).get_uri ();
                                    try {
                                        default_project.close (uri);
                                        discarded_files.add (uri);
                                        debug ("discarding %s from DefaultProject", uri);
                                    } catch (Error e) {
                                        // just ignore
                                    }
                                }
                            }
                        }
                    }

                    foreach (var compilation in project.get_compilations ())
                        /* This must come after the resetting of the two variables above,
                        * since it's possible for publishDiagnostics to eventually call
                        * one of our JSON-RPC callbacks through g_main_context_iteration (),
                        * if we get a new message while sending the textDocument/publishDiagnostics
                        * notifications. */
                        publish_diagnostics (project, compilation, update_context_client);
                } catch (Error e) {
                    warning ("Failed to rebuild and/or reconfigure project: %s", e.message);
                    show_message (update_context_client, @"Failed to rebuild/reconfigure project: $(e.message)", MessageType.Error);
                }
            }

            // add open files that do not belong to any project to the default project
            if (reconfigured_projects) {
                var orphaned_files = new HashSet<string> ();
                orphaned_files.add_all (open_files);
                foreach (var project in projects.get_keys ()) {
                    foreach (var compilation in project.get_compilations ()) {
                        foreach (var source_file in compilation.code_context.get_source_files ()) {
                            var uri = File.new_for_path (source_file.filename).get_uri ();
                            orphaned_files.remove (uri);
                        }
                    }
                }
                foreach (var uri in orphaned_files) {
                    try {
                        var opened = default_project.open (uri, null, cancellable).first ();
                        // ensure the file's contents are available
                        var doc = opened.first;
                        if (doc.content == null)
                            doc.get_mapped_contents ();
                        if (doc is TextDocument)
                            ((TextDocument)doc).last_saved_content = doc.content;
                        publish_diagnostics (default_project, opened.second, update_context_client);
                    } catch (Error e) {
                        warning ("Failed to reopen in default project %s - %s", uri, e.message);
                        // clear the diagnostics for the file
                        try {
                            update_context_client.send_notification (
                                "textDocument/publishDiagnostics",
                                build_dict (
                                    uri: new Variant.string (uri),
                                    diagnostics: new Variant.array (VariantType.VARIANT, {})
                                )
                            );
                        } catch (Error e) {
                            warning ("Failed to clear diagnostics for %s - %s", uri, e.message);
                        }
                    }
                }
            }

            // rebuild the documentation
            documentation.rebuild_if_stale ();
        }
        return !this.shutting_down;
    }

    public delegate void OnContextUpdatedFunc (bool request_cancelled);

    /**
     * Rather than satisfying all requests in `check_update_context ()`,
     * to avoid race conditions, we have to spawn a timeout to check for 
     * the right conditions to call `on_context_updated_func ()`.
     */
    public void wait_for_context_update (Variant id, owned OnContextUpdatedFunc on_context_updated_func) {
        debug ("[SEMTOK] wait_for_context_update: requests=%d, pending=%d",
               (int) update_context_requests, pending_requests.size);
        // we've already updated the context
        if (update_context_requests == 0)
            on_context_updated_func (false);
        else {
            var req = new Request (id);
            if (!pending_requests.add (req))
                warning (@"Request ($req): request already in pending requests, this should not happen");
            /* else
                debug (@"Request ($req): added request to pending requests"); */
            wait_for_context_update_aux (req, (owned) on_context_updated_func);
        }
    }

    /**
     * Execute `on_context_updated_func ()` or wait.
     */
    void wait_for_context_update_aux (Request req, owned OnContextUpdatedFunc on_context_updated_func) {
        // we've already updated the context
        if (update_context_requests == 0) {
            if (!pending_requests.remove (req)) {
                // debug (@"Request ($req): context updated but request cancelled");
                on_context_updated_func (true);
            } else {
                // debug (@"Request ($req): context updated");
                on_context_updated_func (false);
            }
        } else {
            Timeout.add (wait_for_context_update_delay_ms, () => {
                if (pending_requests.contains (req))
                    wait_for_context_update_aux (req, (owned) on_context_updated_func);
                else {
                    // debug (@"Request ($req): cancelled before context update");
                    on_context_updated_func (true);
                }
                return Source.REMOVE;
            });
        }
    }

    void publish_diagnostics (Project project, Compilation target, Jsonrpc.Client client) {
        var diags_without_source = new Json.Array ();

        debug ("publishing diagnostics for Compilation target %s", target.id);

        var doc_diags = new HashMap<Vala.SourceFile, Json.Array?> ();
        foreach (var file in target.code_context.get_source_files ())
            doc_diags[file] = null;

        target.reporter.messages.foreach (err => {
            if (err.loc == null) {
                diags_without_source.add_element (Json.gobject_serialize (new Diagnostic () {
                    range = new Range () {
                        start = new Position () {
                            line = 1,
                            character = 1
                        },
                        end = new Position () {
                            line = 1,
                            character = 1
                        }
                    },
                    severity = err.severity,
                    message = err.message
                }));
                return;
            }
            assert (err.loc.file != null);
            if (!(err.loc.file in target.code_context.get_source_files ())) {
                warning (@"diagnostic has source not in compilation! - $(err.message)");
                return;
            }

            var diag = new Diagnostic () {
                range = new Range () {
                    start = new Position () {
                        line = err.loc.begin.line - 1,
                        character = err.loc.begin.column - 1
                    },
                    end = new Position () {
                        line = err.loc.end.line - 1,
                        character = err.loc.end.column
                    }
                },
                severity = err.severity,
                message = err.message
            };

            var node = Json.gobject_serialize (diag);
            if (!doc_diags.has_key (err.loc.file) || doc_diags[err.loc.file] == null)
                doc_diags[err.loc.file] = new Json.Array ();
            doc_diags[err.loc.file].add_element (node);
        });

        // first, publish empty diagnostics for discarded files
        var discarded_files_published = new ArrayList<string> ();
        foreach (string discarded_uri in discarded_files) {
            try {
                client.send_notification (
                    "textDocument/publishDiagnostics",
                    build_dict (
                        uri: new Variant.string (discarded_uri),
                        diagnostics: new Variant.array (VariantType.VARIANT, {})
                    )
                );
                discarded_files_published.add (discarded_uri);
            } catch (Error e) {
                warning ("[publishDiagnostics] failed to publish empty diags for %s: %s", discarded_uri, e.message);
            }
        }
        discarded_files.remove_all (discarded_files_published);

        // report diagnostics for each source file that has diagnostics
        foreach (var entry in doc_diags.entries) {
            Variant diags_variant_array;
            var gfile = File.new_for_commandline_arg_and_cwd (entry.key.filename, target.code_context.directory);

            if (entry.value != null) {
                try {
                    diags_variant_array = Json.gvariant_deserialize (
                        new Json.Node.alloc ().init_array (entry.value),
                        null);
                } catch (Error e) {
                    warning (@"[publishDiagnostics] failed to deserialize diags for `$(gfile.get_uri ())': $(e.message)");
                    continue;
                }
            } else {
                diags_variant_array = new Variant.array (VariantType.VARIANT, new Variant[]{});
            }

            try {
                client.send_notification (
                    "textDocument/publishDiagnostics",
                    build_dict (
                        uri: new Variant.string (gfile.get_uri ()),
                        diagnostics: diags_variant_array
                    ),
                    cancellable);
            } catch (Error e) {
                warning (@"[publishDiagnostics] failed to notify client: $(e.message)");
            }
        }

        try {
            Variant diags_wo_src_variant_array = Json.gvariant_deserialize (
                new Json.Node.alloc ().init_array (diags_without_source),
                null);
            client.send_notification (
                "textDocument/publishDiagnostics",
                build_dict (
                    // use the project root as the URI if the diagnostic is not associated with a file
                    uri: new Variant.string (File.new_for_path(project.root_path).get_uri ()),
                    diagnostics: diags_wo_src_variant_array
                ),
                cancellable);
        } catch (Error e) {
            warning (@"[publishDiagnostics] failed to publish diags without source: $(e.message)");
        }
    }

    public static Vala.CodeNode get_best (NodeSearch fs, Vala.SourceFile file) {
        Vala.CodeNode? best = null;

        foreach (var node in fs.result) {
            if (best == null) {
                best = node;
            } else {
                var best_begin = new Position.from_libvala (best.source_reference.begin);
                var best_end = new Position.from_libvala (best.source_reference.end);
                var node_begin = new Position.from_libvala (node.source_reference.begin);
                var node_end = new Position.from_libvala (node.source_reference.end);

                // it turns out that if multiple CodeNodes share the same range, the first one we
                // encounter will usually be the "right" one
                if (best_begin.compare_to (node_begin) <= 0 && node_end.compare_to (best_end) <= 0 &&
                    (!(best_begin.compare_to (node_begin) == 0 && node_end.compare_to (best_end) == 0) ||
                    // allow exception for local variables (pick the last one) - this helps foreach
                    (best is Vala.LocalVariable && node is Vala.LocalVariable) ||
                    // allow exception for lone properties - their implicit _* fields are declared in the same location
                    (best is Vala.Field && node is Vala.Property) ||
                    // allow exception for null literals which for some reason are created over async methods that are accessed
                    (best is Vala.NullLiteral && node is Vala.Method)
                )) {
                    best = node;
                }
            }
        }

        // var sr = best.source_reference;
        // var from = (long)Util.get_string_pos (file.content, sr.begin.line-1, sr.begin.column-1);
        // var to = (long)Util.get_string_pos (file.content, sr.end.line-1, sr.end.column);
        // string contents = file.content [from:to];
        // debug ("Got best node: %s @ %s = %s", best.type_name, sr.to_string(), contents);

        return (!) best;
    }

    // Search for the most relevant code node at the given position. Returns
    // null when nothing is found there. The caller must have pushed the
    // relevant code context.
    public static Vala.CodeNode? resolve_best_node (Vala.SourceFile file, Position pos,
                                                     bool search_multiline = true) {
        var fs = new NodeSearch (file, pos, search_multiline);
        if (fs.result.size == 0)
            return null;
        return get_best (fs, file);
    }

    // Resolve an expression / data type / using directive to the symbol it
    // refers to, leaving other node kinds untouched.
    public static Vala.CodeNode? unwrap_to_symbol (Vala.CodeNode node) {
        if (node is Vala.Expression && ((Vala.Expression) node).symbol_reference != null)
            return ((Vala.Expression) node).symbol_reference;
        if (node is Vala.DataType)
            return SymbolReferences.get_symbol_data_type_refers_to ((Vala.DataType) node);
        if (node is Vala.UsingDirective && ((Vala.UsingDirective) node).namespace_symbol != null)
            return ((Vala.UsingDirective) node).namespace_symbol;
        return node;
    }


    public DocComment? get_symbol_documentation (Project project, Vala.Symbol sym) {
        Compilation compilation = null;
        Vala.Symbol real_sym = SymbolReferences.find_real_symbol (project, sym);
        sym = real_sym;
        Vala.Symbol root = null;
        for (var node = sym; node != null; node = node.parent_symbol)
            root = node;
        assert (root != null);
        foreach (var project_compilation in project.get_compilations ()) {
            if (project_compilation.code_context.root == root) {
                compilation = project_compilation;
                break;
            }
        }

        if (compilation == null)
            return null;

        Vala.Comment? comment = null;
        DocComment? doc_comment = null;
        var gir_sym = documentation.find_gir_symbol (sym);
        if (gir_sym != null && gir_sym.comment != null)
            comment = gir_sym.comment;
        else
            comment = sym.comment;

        if (comment != null) {
            try {
                if (comment is Vala.GirComment || gir_sym != null && gir_sym.comment == comment)
                    doc_comment = new DocComment.from_gir_comment (comment, documentation, compilation);
                else
                    doc_comment = new DocComment.from_valadoc_comment (comment, sym, compilation);
            } catch (RegexError e) {
                warning ("failed to render comment - %s", e.message);
            }
        }

        if (doc_comment == null && sym is Vala.Parameter) {
            var parent_doc = get_symbol_documentation (project, sym.parent_symbol);
            if (parent_doc != null) {
                string? doc = parent_doc.parameters[sym.name];
                if (doc != null)
                    doc_comment = new DocComment (doc);
            }
        }

        return doc_comment;
    }

    void show_completion (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.CompletionParams>(@params);

        Compilation compilation;
        Project project;
        Vala.SourceFile? file = find_file (p.textDocument.uri, out compilation, out project);
        if (file == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            reply_null (id, client, method);
            return;
        }

        CompletionEngine.begin_response (this, project,
                                         client, id, method,
                                         file, compilation,
                                         p.position, p.context);
    }

    void show_signature_help (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams>(@params);

        Compilation compilation;
        Project project;
        Vala.SourceFile file = find_file (p.textDocument.uri, out compilation, out project);
        if (file == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            reply_null (id, client, method);
            return;
        }

        SignatureHelpEngine.begin_response (this, project,
                                            client, id, method,
                                            file, compilation,
                                            p.position);
    }

    void format (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<DocumentRangeFormattingParams>(@params);

        Compilation compilation;
        Vala.SourceFile? source_file = find_file (p.textDocument.uri, out compilation);
        if (source_file == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            reply_null (id, client, method);
            return;
        }

        var json_array = new Json.Array ();
        TextEdit edited;
        var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (source_file);
        try {
            edited = Formatter.format (p.options, code_style, source_file, p.range, cancellable);
        } catch (Error e) {
            client.reply_error_async.begin (
                id,
                Jsonrpc.ClientError.INTERNAL_ERROR,
                e.message,
            cancellable);
            warning ("Formatting failed: %s", e.message);
            return;
        }
        json_array.add_element (Json.gobject_serialize (edited));
        try {
            Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
            client.reply (id, variant_array, cancellable);
        } catch (Error e) {
            debug (@"[$method] failed to reply to client: $(e.message)");
        }
    }

    void code_action (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<CodeActionParams> (@params);

        Compilation compilation;
        Vala.SourceFile? source_file = find_file (p.textDocument.uri, out compilation);
        if (source_file == null) {
            debug ("[%s] file `%s' not found", method, p.textDocument.uri);
            reply_null (id, client, method);
            return;
        }

        if (!(source_file is TextDocument)) {
            reply_null (id, client, method);
            return;
        }
        var json_array = new Json.Array ();

        Vala.CodeContext.push (compilation.code_context);
        var code_actions = CodeActions.extract (p.context, compilation,
                                                (TextDocument) source_file, p.range, Uri.unescape_string (p.textDocument.uri));
        foreach (var action in code_actions)
            json_array.add_element (Json.gobject_serialize (action));
        Vala.CodeContext.pop ();
        try {
            Variant variant_array = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (json_array), null);
            client.reply (id, variant_array, cancellable);
        } catch (Error e) {
            debug (@"[$method] failed to reply to client: $(e.message)");
        }
    }


    /**
     * handle an incoming `textDocument/codeLens` request
     */
    void code_lens (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        string? uri = document != null ? (string?) document.lookup_value ("uri", VariantType.STRING) : null;

        if (document == null || uri == null) {
            warning ("[%s] `textDocument` or `uri` not provided as expected", method);
            reply_null (id, client, method);
            return;
        }

        Project project;
        Compilation compilation;
        Vala.SourceFile? file = find_file (uri, out compilation, out project);
        if (file == null) {
            debug ("[%s] file `%s' not found", method, uri);
            reply_null (id, client, method);
            return;
        }

        CodeLensEngine.begin_response (this, project, client, id, method, file, compilation);
    }


    void shutdown () {
        debug ("shutting down...");
        this.shutting_down = true;
        cancellable.cancel ();
        if (client_closed_event_id != 0)
            this.disconnect (client_closed_event_id);
        foreach (var project in projects.get_keys_as_array ())
            project.disconnect (projects[project]);
        foreach (uint source_id in g_sources)
            Source.remove (source_id);
    }

    void exit () {
        loop.quit ();
    }
}

/**
 * `--version`
 */
bool opt_version;

const OptionEntry[] entries = {
    { "version", 'v', OptionFlags.NONE, OptionArg.NONE, ref opt_version, "Print the version and commit info", null },
    {}
};

int main (string[] args) {
    Environment.set_prgname ("vala-language-server");
    var ocontext = new OptionContext ("- vala-language-server");
    ocontext.add_main_entries (entries, null);
    ocontext.set_summary ("A language server for Vala");
    ocontext.set_description (@"Report bugs to $(Config.PROJECT_BUGSITE)");
    try {
        ocontext.parse (ref args);
    } catch (Error e) {
        stderr.printf ("%s\n", e.message);
        stderr.printf ("Run '%s --version' to print version, or no arguments to run the language server.\n", args[0]);
        return 1;
    }

    if (opt_version) {
        stdout.printf ("%s %s\n", Config.PROJECT_NAME, Config.PROJECT_VERSION);
        return 0;
    }

    // otherwise

    // Enable all debug output regardless of environment
    Environment.set_variable ("G_MESSAGES_DEBUG", "all", false);

    // Duplicate log output to .tmp/vls-<PID>.log
    var log_dir = File.new_for_path (".tmp");
    try {
        if (!log_dir.query_exists ())
            log_dir.make_directory ();
    } catch (Error e) {
        stderr.printf ("warning: could not create .tmp directory: %s\n", e.message);
    }
    string log_path = ".tmp/vls-%d.log".printf (Posix.getpid ());
    FileStream? log_file = FileStream.open (log_path, "a");
    if (log_file != null) {
        log_file.printf ("=== VLS started at %s ===\n", new DateTime.now ().to_string ());
        Log.set_default_handler ((domain, levels, message) => {
            var timestamp = new DateTime.now ().format ("%Y-%m-%d %H:%M:%S");
            string level_name = ((uint) levels).to_string ();
            var formatted = "%s [%s] %s%s\n".printf (timestamp, level_name,
                                                      domain != null ? domain + ": " : "", message);
            stderr.printf ("%s", formatted);
            log_file.printf ("%s", formatted);
            log_file.flush ();
        });
    }

    var loop = new MainLoop ();
    new Vls.Server (loop);
    loop.run ();
    return 0;
}
