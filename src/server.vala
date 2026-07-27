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

    public Lsp.TraceValue trace { get; set; default = Lsp.TraceValue.VERBOSE; }
    MainLoop loop;
    internal Scheduler scheduler;

    public InitializeParams init_params;

    internal DocumentationEngine doc_engine;
    internal ServiceProvider services;
    internal ContextManager context_manager;

    internal bool shutting_down = false;

    /**
     * The global cancellable object
     */
    public static Cancellable cancellable = new Cancellable ();

    uint[] g_sources = {};
    ulong client_closed_event_id;

    /**
     * Manages project lifecycle and file lookup.
     */
    internal ProjectManager project_manager = new ProjectManager ();

    /**
     * Manages open/discarded file tracking.
     */
    internal DocumentManager document_manager = new DocumentManager ();

    /**
     * Routes incoming LSP requests and notifications.
     */
    RequestRouter request_router;

    /**
     * Per-request cancellables for fine-grained cancellation.
     */
    internal Gee.HashMap<Request, Cancellable> request_cancellables = new Gee.HashMap<Request, Cancellable> (
        req => req.hash (), (a, b) => a.equal (b));

    static construct {
        Process.@signal (ProcessSignal.INT, () => {
            Server.received_signal = true;
        });
        Process.@signal (ProcessSignal.TERM, () => {
            Server.received_signal = true;
        });
    }

    public Server (MainLoop loop) {
        Vls.Logger.debug ("lsp", "Server constructor started");
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
        if (new_stdout_fd < 0) {
            stderr.printf ("=== VLS: dup stdout failed, exiting ===\n");
            Process.exit (1);
        }
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
            Vls.Logger.warn ("lsp", "failed to set FDs to nonblocking");
            loop.quit ();
            return;
        }
#endif

        // shutdown if/when we get a signal
        g_sources += Timeout.add (1000, check_signal);

        accept_io_stream (new SimpleIOStream (input_stream, output_stream));

        this.context_manager = new ContextManager (this);
        this.services = new ServiceProvider (this);
        this.request_router = new RequestRouter (this);

        Vls.Logger.debug ("lsp", "Finished constructing");
    }

    /**
     * Initialize the scheduler thread pool.  Separate from the constructor so
     * that thread creation (which may trigger GLib type-system registration)
     * happens after the main-loop I/O is fully set up and debug logging is
     * configured.
     */
    internal void init_scheduler () throws ThreadError {
        this.scheduler = new Scheduler ();
    }

    protected override void notification (Jsonrpc.Client client, string method, Variant parameters) {
        request_router.notification (client, method, parameters);
    }

    protected override bool handle_call (Jsonrpc.Client client, string method, Variant id, Variant parameters) {
        return request_router.handle_call (client, method, id, parameters);
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

    internal void show_message (Jsonrpc.Client client, string message, MessageType type) {
        if (type == MessageType.Error)
            Vls.Logger.warn ("lsp", "%s", message);
        try {
            client.send_notification ("window/showMessage", build_dict (
                type: new Variant.int16 (type),
                message: new Variant.string (message)
            ), cancellable);
        } catch (Error e) {
            Vls.Logger.debug ("lsp", "showMessage: failed to notify client: %s", e.message);
        }
    }

    internal void initialize (Jsonrpc.Client client, string method, Variant id, Variant @params) {
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
        Util.set_project_root (root_path);
        Vls.Logger.info ("lsp", "root path is %s", root_path);

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
            Vls.Logger.warn ("lsp", "[initialize] failed to reply to client: %s", e.message);
        }

        var meson_file = root_dir.get_child ("meson.build");
        ArrayList<File> cc_files = new ArrayList<File> ();
        try {
            cc_files = Util.find_files (root_dir, /compile_commands\.json/, 2);
        } catch (Error e) {
            Vls.Logger.warn ("lsp", "could not enumerate root dir - %s", e.message);
        }

        // Bug #290: if meson.build not found in root, walk parent directories
        if (!meson_file.query_exists (cancellable)) {
            var parent = root_dir.get_parent ();
            while (parent != null) {
                var candidate = parent.get_child ("meson.build");
                if (candidate.query_exists (cancellable)) {
                    Vls.Logger.debug ("lsp", "found meson.build in parent: %s", candidate.get_path ());
                    meson_file = candidate;
                    break;
                }
                parent = parent.get_parent ();
            }
        }

        var new_projects = new ArrayList<Project> ();
        Project? backend_project = null;
        // TODO: autotools, make(?), cmake(?)
        if (meson_file.query_exists (cancellable)) {
            try {
                // If meson.build was found in a parent directory, use that
                string project_root = meson_file.get_parent ().get_path ();
                backend_project = new MesonProject (project_root, project_manager.file_cache, cancellable);
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
                    backend_project = new CcProject (root_path, cc_file_path, project_manager.file_cache, cancellable);
                    Vls.Logger.debug ("lsp", "initialized CcProject with %s", cc_file_path);
                    break;
                } catch (Error e) {
                    Vls.Logger.debug ("lsp", "CcProject failed with %s - %s", cc_file_path, e.message);
                    continue;
                }
            }
        }

        // show messages if we could not get a backend-specific project
        if (backend_project == null) {
            var cmake_file = root_dir.get_child ("CMakeLists.txt");
            var autogen_sh = root_dir.get_child ("autogen.sh");

            if (cmake_file.query_exists (cancellable))
                show_message (client,
                    "CMake build system is not currently supported. Only Meson is. "
                    + "See https://github.com/vala-lang/vala-language-server/issues/73",
                    MessageType.Warning);
            if (autogen_sh.query_exists (cancellable))
                show_message (client,
                    "Autotools build system is not currently supported. "
                    + "Consider switching to Meson.", MessageType.Warning);
        } else {
            new_projects.add (backend_project);
        }

        // always have default project
        project_manager.default_project = new DefaultProject (root_path, project_manager.file_cache);

        // build and publish diagnostics
        foreach (var project in new_projects) {
            try {
                Vls.Logger.info ("lsp", "building project");
                project.build_if_stale ();
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
        doc_engine = new DocumentationEngine (new GirDocumentation (packages, custom_gir_dirs));
        // Wire the doc cache clear handler so each Compilation clears the
        // (pointer-keyed) documentation cache after a successful swap.
        // Without this, dangling symbol pointers accumulate and may collide
        // with newly-allocated symbols.
        foreach (var project in new_projects)
            project.set_doc_engine (doc_engine);
        project_manager.default_project.set_doc_engine (doc_engine);

        // listen for context update requests
        context_manager.request_context_update (client);
        g_sources += Timeout.add (ContextManager.check_update_context_period_ms, context_manager.check_update_context);

        // listen for project changed events
        foreach (Project project in new_projects)
            project_manager.projects[project] = project.changed.connect (project_changed_event);
    }

    void project_changed_event () {
        context_manager.request_context_update (context_manager.last_update_client);
    }

    internal void cancel_request (Jsonrpc.Client client, Variant @params) {
        Vls.Logger.debug ("lsp", "cancel_request");
        Variant? id_val = @params.lookup_value ("id", null);
        if (id_val != null) {
            var req = new Request (id_val);
            var canc = request_cancellables[req];
            if (canc != null) {
                canc.cancel ();
                request_cancellables.unset (req);
            }
        }
        context_manager.cancel_request (@params);
    }

    /**
     * Remove the per-request cancellable for the given request id.
     * Called from reply paths that bypass RequestHandler wrappers.
     */
    public static void cleanup_request (Server server, Variant id) {
        server.request_cancellables.unset (new Request (id));
    }

    public static void reply_null (Variant id, Jsonrpc.Client client, string method, Cancellable? cancellable = null) {
        try {
            client.reply (id, new Variant.maybe (VariantType.VARIANT, null), cancellable ?? Server.cancellable);
        } catch (Error e) {
            Vls.Logger.warn ("lsp", "[%s] failed to reply to client: %s", method, e.message);
        }
    }

    /**
     * Reply with a JSON array of GObjects serialized to a JSON-RPC result.
     */
    public static void reply_array (Jsonrpc.Client client, Variant id, Gee.Collection<Object> items, string method = "", Cancellable? cancellable = null) {
        var array = new Json.Array ();
        foreach (var item in items)
            array.add_element (Json.gobject_serialize (item));
        try {
            Variant result = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (array), null);
            client.reply (id, result, cancellable ?? Server.cancellable);
        } catch (Error e) {
            Vls.Logger.warn ("lsp", "[%s] failed to reply to client: %s", method, e.message);
        }
    }

    /**
     * Reply with a JSON-RPC error.
     */
    public static void reply_error (Jsonrpc.Client client, Variant id, int code, string message, string method = "", Cancellable? cancellable = null) {
        client.reply_error_async.begin (id, code, message, cancellable ?? Server.cancellable);
        Vls.Logger.debug ("lsp", "error reply (%d): %s", code, message);
    }

    /**
     * Reply with a JSON array serialized from an already-built {@link Json.Array}.
     */
    public static void reply_json_array (Jsonrpc.Client client, Variant id, Json.Array array, string method = "", Cancellable? cancellable = null) {
        try {
            Variant result = Json.gvariant_deserialize (new Json.Node.alloc ().init_array (array), null);
            client.reply (id, result, cancellable ?? Server.cancellable);
        } catch (Error e) {
            Vls.Logger.warn ("lsp", "[%s] failed to reply to client: %s", method, e.message);
        }
    }

    /**
     * Reply with a single GObject serialized to JSON.
     */
    public static void reply_object (Jsonrpc.Client client, Variant id, Object obj, string method = "", Cancellable? cancellable = null) {
        try {
            client.reply (id, Util.object_to_variant (obj), cancellable ?? Server.cancellable);
        } catch (Error e) {
            Vls.Logger.warn ("lsp", "[%s] failed to reply to client: %s", method, e.message);
        }
    }

    /**
     * Reply with an already-built variant dict.
     */
    public static void reply_dict (Jsonrpc.Client client, Variant id, Variant dict, string method = "", Cancellable? cancellable = null) {
        try {
            client.reply (id, dict, cancellable ?? Server.cancellable);
        } catch (Error e) {
            Vls.Logger.warn ("lsp", "[%s] failed to reply to client: %s", method, e.message);
        }
    }

    /**
     * Callback run inside {@link with_code_context}.
     */
    public delegate void ContextCallback ();

    /**
     * Run [cb] with the given Vala code context pushed, balanced by a
     * guaranteed pop. Kills the push/pop-balance regression class.
     */
    public static void with_code_context (Vala.CodeContext ctx, owned ContextCallback cb) {
        Vala.CodeContext.push (ctx);
        try {
            cb ();
        } finally {
            Vala.CodeContext.pop ();
        }
    }

    /**
     * Thin wrapper around Server instance methods that handlers need,
     * breaking the circular dependency Server ↔ handler files.
     */
    public class ServiceProvider : Object {
        private weak Server _server;

        internal ServiceProvider (Server server) {
            _server = server;
        }

        public void wait_for_context_update (Variant id, owned ContextManager.OnContextUpdatedFunc callback,
                                              Compilation? compilation = null) {
            _server.context_manager.wait_for_context_update (id, (owned) callback, compilation);
        }

        public Server server {
            get { return _server; }
        }

        public Scheduler scheduler {
            get { return _server.scheduler; }
        }

        public DocumentationEngine doc_engine {
            get { return _server.doc_engine; }
        }

        public HashTable<Project, ulong> projects {
            get { return _server.project_manager.projects; }
        }

        public DefaultProject default_project {
            get { return _server.project_manager.default_project; }
        }
    }

    /**
     * Context passed to a {@link RequestHandler}. Carries everything a handler
     * needs so feature functions stop taking 9 positional arguments.
     */
    public class RequestContext {
        public Server server;
        public ServiceProvider services { get; private set; }
        public DocumentationEngine doc_engine { get; private set; }
        public Jsonrpc.Client client;
        public Variant id;
        public string method;
        public Vala.SourceFile? file;
        public Compilation? compilation;
        public Project? project;
        public Lsp.Position? pos;
        public Cancellable? cancellable { get; private set; }
        internal Request _request;

        public RequestContext (Server server, Jsonrpc.Client client, Variant id, string method,
                                Vala.SourceFile? file, Compilation? compilation, Project? project,
                                Lsp.Position? pos = null, Cancellable? cancellable = null) {
            this.server = server;
            this.services = server.services;
            this.doc_engine = server.doc_engine;
            this.client = client;
            this.id = id;
            this._request = new Request (id);
            this.method = method;
            this.file = file;
            this.compilation = compilation;
            this.project = project;
            this.pos = pos;
            this.cancellable = cancellable ?? server.request_cancellables[this._request];
        }
    }

    /**
     * Base class for request handlers (Stage 1 of the handler framework).
     *
     * Not forced on existing handlers — they keep calling the Server reply
     * helpers directly. Subclasses override {@link run}; the default {@link run}
     * replies null. The constructor captures a {@link RequestContext}; the
     * {@link with_code_context} and reply_* helpers are available as protected
     * helpers (more are added as handlers are migrated).
     */
    public abstract class RequestHandler {
        protected RequestContext ctx;

        protected RequestHandler (RequestContext ctx) {
            this.ctx = ctx;
        }

        public virtual void run () {
            reply_null ();
        }

        protected void reply_null () {
            Server.reply_null (ctx.id, ctx.client, ctx.method, ctx.cancellable);
            cleanup_request_cancellable ();
        }

        protected void reply_array (Gee.Collection<Object> items) {
            Server.reply_array (ctx.client, ctx.id, items, ctx.method, ctx.cancellable);
            cleanup_request_cancellable ();
        }

        protected void reply_error (int code, string message) {
            Server.reply_error (ctx.client, ctx.id, code, message, ctx.method, ctx.cancellable);
            cleanup_request_cancellable ();
        }

        private void cleanup_request_cancellable () {
            ctx.server.request_cancellables.unset (ctx._request);
        }

        protected void reply_json_array (Json.Array array) {
            Server.reply_json_array (ctx.client, ctx.id, array, ctx.method, ctx.cancellable);
            cleanup_request_cancellable ();
        }

        protected void reply_object (Object obj) {
            Server.reply_object (ctx.client, ctx.id, obj, ctx.method, ctx.cancellable);
            cleanup_request_cancellable ();
        }

        protected void reply_dict (Variant dict) {
            Server.reply_dict (ctx.client, ctx.id, dict, ctx.method, ctx.cancellable);
            cleanup_request_cancellable ();
        }

        /**
         * Resolve the code node at {@link RequestContext.pos} to a symbol,
         * applying the standard unwrap and filtering rules (expressions →
         * symbol_reference, datatypes → type_symbol, using directives →
         * namespace_symbol). Returns null if no symbol is found, if the node
         * is a non-symbol (literal, statement, block, etc.), or if it's a
         * closure lambda.
         */
        protected Vala.Symbol? resolve_symbol () {
            if (ctx.pos == null)
                return null;
            var resolved = Server.resolve_best_node (ctx.file, (!) ctx.pos);
            if (resolved == null)
                return null;
            var node = (!) Server.unwrap_to_symbol (resolved);
            if (!(node is Vala.Symbol))
                return null;
            var sym = (Vala.Symbol) node;
            if (sym is Vala.Method && ((Vala.Method)sym).closure)
                return null;
            return sym;
        }
    }

    internal void text_document_did_open (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        string? uri = (string) document.lookup_value ("uri", VariantType.STRING);
        string languageId = (string) document.lookup_value ("languageId", VariantType.STRING);
        string fileContents = (string) document.lookup_value ("text", VariantType.STRING);

        if (languageId != "vala" && languageId != "genie") {
            Vls.Logger.warn ("lsp", "%s file sent to vala language server", languageId);
            return;
        }

        if (uri == null) {
            Vls.Logger.warn ("lsp", "null URI sent to vala language server");
            return;
        }

        Pair<Vala.SourceFile, Compilation>? doc_w_bt = null;

        foreach (var project in project_manager.projects.get_keys_as_array ()) {
            try {
                doc_w_bt = project.open (uri, fileContents, cancellable).first ();
                break;
            } catch (Error e) {
                if (!(e is ProjectError.NOT_FOUND))
                    Vls.Logger.warn ("lsp", "failed to open %s - %s", uri, e.message);
            }
        }

        // fallback to default project
        if (doc_w_bt == null) {
            try {
                doc_w_bt = project_manager.default_project.open (uri, fileContents, cancellable).first ();
                // it's possible that we opened a Vala script and have to
                // include additional packages for documentation
                foreach (var pkg in project_manager.default_project.get_packages ())
                    doc_engine.gir.add_package_from_source_file (pkg);
                // show diagnostics for the newly-opened file
                context_manager.request_context_update (client);
                // Bug #154: warn when a .vala/.gs file falls to default project
                // but real project targets exist (file should be tracked).
                if ((uri.has_suffix (".vala") || uri.has_suffix (".gs"))
                    && project_manager.projects.size () > 0) {
                    show_message (client,
                        "File is not listed in any build target. Add it to meson.build for full code intelligence.",
                        MessageType.Warning);
                }
            } catch (Error e) {
                Vls.Logger.warn ("lsp", "failed to open %s - %s", uri, e.message);
            }
        }

        if (doc_w_bt == null) {
            Vls.Logger.warn ("lsp", "could not open %s", uri);
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
            Vls.Logger.info ("lsp", "opened %s", uri);
            tdoc.last_saved_content = fileContents;
            bool content_changed = tdoc.content != fileContents;
            Vls.Logger.debug ("context", "didOpen: uri=%s, content_len=%d, content_changed=%s",
                   uri, fileContents.length, content_changed.to_string ());
            if (content_changed) {
                tdoc.content = fileContents;
                tdoc.last_updated = GLib.get_real_time ();
                Vls.Logger.debug ("context", "didOpen: set content, last_updated=%s", Util.ts_to_string (tdoc.last_updated));
                context_manager.request_context_update (client);
            }
        } else {
            Vls.Logger.info ("lsp", "opened read-only %s", uri);
        }

        // add document to open list
        document_manager.add_open_file (uri);
    }

    internal void text_document_did_save (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);

        string? uri = (string) document.lookup_value ("uri", VariantType.STRING);
        if (uri == null) {
            Vls.Logger.warn ("lsp", "null URI sent to vala language server");
            return;
        }

        Project[] all_projects = project_manager.projects.get_keys_as_array ();
        all_projects += project_manager.default_project;

        foreach (var project in all_projects) {
            foreach (var pair in project.lookup_compile_input_source_file (uri)) {
                var text_document = pair.first as TextDocument;

                if (text_document == null) {
                    Vls.Logger.debug ("lsp", "ignoring save to system file");
                    continue;
                }

                // make checkpoint
                text_document.last_saved_content = text_document.content;
                Vls.Logger.debug ("lsp", "last save of %s is now at version %d", uri, text_document.last_saved_version);
            }
        }
    }

    internal void text_document_did_close (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        string? uri = (string) document.lookup_value ("uri", VariantType.STRING);

        if (uri == null) {
            Vls.Logger.warn ("lsp", "null URI sent to vala language server");
            return;
        }

        Project[] all_projects = project_manager.projects.get_keys_as_array ();
        all_projects += project_manager.default_project;

        foreach (var project in all_projects) {
            try {
                if (project.close (uri)) {
                    document_manager.add_discarded_file (uri);
                    context_manager.request_context_update (client);
                }
                Vls.Logger.debug ("lsp", "closed %s", uri);
            } catch (Error e) {
                if (!(e is ProjectError.NOT_FOUND))
                    Vls.Logger.warn ("lsp", "failed to close %s - %s", uri, e.message);
            }
        }
    }

    internal void text_document_did_change (Jsonrpc.Client client, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        var changes = @params.lookup_value ("contentChanges", VariantType.ARRAY);

        var uri = (string) document.lookup_value ("uri", VariantType.STRING);
        var version = (int64) document.lookup_value ("version", VariantType.INT64);

        Project[] all_projects = project_manager.projects.get_keys_as_array ();
        all_projects += project_manager.default_project;

        foreach (var project in all_projects) {
            foreach (Pair<Vala.SourceFile, Compilation> pair in project.lookup_compile_input_source_file (uri)) {
                var source_file = pair.first;

                if (!(source_file is TextDocument)) {
                    Vls.Logger.debug ("lsp", "ignoring change to system file");
                    continue;
                }

                var source = (TextDocument) source_file;
                if (source.version >= version) {
                    Vls.Logger.warn ("lsp", "rejecting outdated version of %s", uri);
                    continue;
                }

                if (source_file.content == null) {
                    Vls.Logger.warn ("lsp", "source content is null!");
                    continue;
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
                        size_t pos_begin = (size_t) source.byte_offset (start.line, start.character);
                        size_t pos_end = (size_t) source.byte_offset (end.line, end.character);
                        sb.erase ((ssize_t) pos_begin, (ssize_t) (pos_end - pos_begin));
                        sb.insert ((ssize_t) pos_begin, changeEvent.text);
                    }
                }
                source.content = sb.str;
                source.last_updated = GLib.get_real_time ();
                source.version = (int) version;

                context_manager.request_context_update (client);
            }
        }
    }

    internal void publish_diagnostics (Project project, Compilation target, Jsonrpc.Client client) {
        var diags_without_source = new Json.Array ();

        Vls.Logger.debug ("compile", "publishing diagnostics for %s", target.name);

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
            if (err.loc.file == null) {
                Vls.Logger.warn ("compile", "diagnostic has null source file");
                return;
            }
            if (!(err.loc.file in target.code_context.get_source_files ())) {
                Vls.Logger.warn ("compile", "diagnostic has source not in compilation: %s", err.message);
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
        foreach (string discarded_uri in document_manager.get_discarded_files ()) {
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
                Vls.Logger.warn ("compile", "failed to publish empty diags for %s: %s", discarded_uri, e.message);
            }
        }
        document_manager.remove_discarded_files (discarded_files_published);

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
                    Vls.Logger.warn ("compile", "failed to deserialize diags for %s: %s", gfile.get_uri (), e.message);
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
                Vls.Logger.warn ("compile", "failed to notify client: %s", e.message);
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
            Vls.Logger.warn ("compile", "failed to publish diags without source: %s", e.message);
        }
    }

    public static Vala.CodeNode get_best (NodeSearch fs, Vala.SourceFile file) {
        return Vls.SymbolResolver.get_best (fs, file);
    }

    // Search for the most relevant code node at the given position. Returns
    // null when nothing is found there. The caller must have pushed the
    // relevant code context.
    public static Vala.CodeNode? resolve_best_node (Vala.SourceFile file, Position pos,
                                                     bool search_multiline = true) {
        return Vls.SymbolResolver.resolve_best_node (file, pos, search_multiline);
    }

    // Resolve an expression / data type / using directive to the symbol it
    // refers to, leaving other node kinds untouched.
    public static Vala.CodeNode? unwrap_to_symbol (Vala.CodeNode node) {
        return Vls.SymbolResolver.unwrap_to_symbol (node);
    }

    /**
     * Resolve the code node at {@link RequestContext.pos} to the symbol it
     * defines, following the same unwrap rules that the navigation handlers
     * used to hand-roll. Unifies `resolve_best_node` with the
     * expression/data-type/using-directive unwrap and the Method/Property
     * base-override + `find_real_symbol` resolution into one tested entry
     * point.
     *
     * Returns the resolved node (or null) and, when a source reference is
     * available, the {@link Lsp.Range} of its definition. Callers turn the
     * range + node file into a `Location`.
     */
    public static Vala.CodeNode? resolve_symbol_at (RequestContext ctx, out Lsp.Range? range) {
        return Vls.SymbolResolver.resolve_symbol_at (ctx, out range);
    }

    void clear_doc_cache () {
        doc_engine.clear_cache ();
    }

    internal void show_completion (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        clear_doc_cache ();
        var p = Util.parse_variant<Lsp.CompletionParams>(@params);

        Compilation compilation;
        Project project;
        Vala.SourceFile? file = project_manager.find_file (p.textDocument.uri, out compilation, out project);
        if (file == null) {
            Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, p.textDocument.uri);
            reply_null (id, client, method);
            return;
        }

        var ctx = new RequestContext (this, client, id, method,
                                      (!) file, compilation, project, p.position);
        with_code_context (compilation.code_context, () => {
            var handler = new CompletionEngine.CompletionHandler (ctx, p.position, p.context);
            handler.run ();
        });
    }

    internal void show_signature_help (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams>(@params);

        Compilation compilation;
        Project project;
        Vala.SourceFile file = project_manager.find_file (p.textDocument.uri, out compilation, out project);
        if (file == null) {
            Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, p.textDocument.uri);
            reply_null (id, client, method);
            return;
        }

        var ctx = new RequestContext (this, client, id, method,
                                      file, compilation, project, p.position);
        with_code_context (compilation.code_context, () => {
            var handler = new SignatureHelpEngine.SignatureHelpHandler (ctx, p.position);
            handler.run ();
        });
    }

    class FormatHandler : RequestHandler {
        private DocumentRangeFormattingParams p;

        public FormatHandler (RequestContext ctx, DocumentRangeFormattingParams p) {
            base (ctx);
            this.p = p;
        }

        public override void run () {
            var json_array = new Json.Array ();
            TextEdit edited;
            var code_style = ctx.compilation.get_analysis_for_file<CodeStyleAnalyzer> (ctx.file);
            try {
                edited = ctx.services.scheduler.run_sync<TextEdit> (() => {
                    return Formatter.format (p.options, code_style, ctx.file,
                                             p.range, cancellable);
                }, cancellable);
            } catch (Error e) {
                reply_error (Jsonrpc.ClientError.INTERNAL_ERROR, e.message);
                Vls.Logger.warn ("lsp", "Formatting failed: %s", e.message);
                return;
            }
            json_array.add_element (Json.gobject_serialize (edited));
            reply_json_array (json_array);
        }
    }

    internal void format (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<DocumentRangeFormattingParams>(@params);

        Compilation compilation;
        Vala.SourceFile? source_file = project_manager.find_file (p.textDocument.uri, out compilation);
        if (source_file == null) {
            Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, p.textDocument.uri);
            reply_null (id, client, method);
            return;
        }

        context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }
            Compilation ctx_compilation;
            Vala.SourceFile? ctx_file = project_manager.find_file (p.textDocument.uri, out ctx_compilation);
            if (ctx_file == null) {
                reply_null (id, client, method);
                return;
            }
            var ctx = new RequestContext (this, client, id, method,
                                          (!) ctx_file, ctx_compilation, null);
            with_code_context (ctx_compilation.code_context, () => {
                var handler = new FormatHandler (ctx, p);
                handler.run ();
            });
        }, compilation, true);
    }

    class CodeActionHandler : RequestHandler {
        private CodeActionParams p;

        public CodeActionHandler (RequestContext ctx, CodeActionParams p) {
            base (ctx);
            this.p = p;
        }

        public override void run () {
            if (!(ctx.file is TextDocument)) {
                reply_null ();
                return;
            }
            var json_array = new Json.Array ();
            var code_actions = CodeActions.extract (p.context, ctx.compilation,
                                                    (TextDocument) ctx.file, p.range,
                                                    Uri.unescape_string (p.textDocument.uri));
            foreach (var action in code_actions)
                json_array.add_element (Json.gobject_serialize (action));
            reply_json_array (json_array);
        }
    }

    internal void code_action (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<CodeActionParams> (@params);

        Compilation compilation;
        Vala.SourceFile? source_file = project_manager.find_file (p.textDocument.uri, out compilation);
        if (source_file == null) {
            Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, p.textDocument.uri);
            reply_null (id, client, method);
            return;
        }

        context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            // Re-resolve after context update so SourceFile belongs to the live CodeContext
            Compilation ctx_compilation;
            Vala.SourceFile? ctx_file = project_manager.find_file (p.textDocument.uri, out ctx_compilation);
            if (ctx_file == null) {
                reply_null (id, client, method);
                return;
            }

            var ctx = new RequestContext (this, client, id, method,
                                          (!) ctx_file, ctx_compilation, null);
            with_code_context (ctx_compilation.code_context, () => {
                var handler = new CodeActionHandler (ctx, p);
                handler.run ();
            });
        }, compilation);
    }

    /**
     * handle an incoming `workspace/symbol` request
     */
    internal void dispatch_workspace_symbol (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var query = (string) @params.lookup_value ("query", VariantType.STRING);
            context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }
            var ctx = new RequestContext (this, client, id, method, null, null, null);
            var handler = new Workspace.WorkspaceSymbolHandler (ctx, query);
            handler.run ();
        });
    }

    internal void dispatch_document_symbol (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams> (@params);

        Compilation compilation;
        Project project;
        Vala.SourceFile? file = project_manager.find_file (p.textDocument.uri, out compilation, out project);
        if (file == null) {
            Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, p.textDocument.uri);
            reply_null (id, client, method);
            return;
        }

        context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }
            Compilation ctx_compilation;
            Project ctx_project;
            Vala.SourceFile? ctx_file = project_manager.find_file (p.textDocument.uri, out ctx_compilation, out ctx_project);
            if (ctx_file == null) {
                reply_null (id, client, method);
                return;
            }

            bool hierarchical = init_params.capabilities.textDocument.documentSymbol.hierarchicalDocumentSymbolSupport;
            var ctx = new RequestContext (this, client, id, method,
                                         (!) ctx_file, ctx_compilation, ctx_project, p.position);
            with_code_context (ctx_compilation.code_context, () => {
                var handler = new DocumentSymbolHandler.DocumentSymbolHandler (ctx, hierarchical);
                handler.run ();
            });
        }, compilation, true);
    }

    internal void dispatch_prepare_rename (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams> (@params);

        Compilation compilation;
        Project project;
        Vala.SourceFile? doc = project_manager.find_file (p.textDocument.uri, out compilation, out project);
        if (doc == null) {
            Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, p.textDocument.uri);
            reply_null (id, client, method);
            return;
        }

        context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }
            Compilation ctx_compilation;
            Project ctx_project;
            Vala.SourceFile? ctx_doc = project_manager.find_file (p.textDocument.uri, out ctx_compilation, out ctx_project);
            if (ctx_doc == null) {
                reply_null (id, client, method);
                return;
            }
            var ctx = new RequestContext (this, client, id, method,
                                         (!) ctx_doc, ctx_compilation, ctx_project, p.position);
            with_code_context (ctx_compilation.code_context, () => {
                var handler = new Rename.PrepareRenameHandler (ctx);
                handler.run ();
            });
        }, compilation, true);
    }

    internal void dispatch_rename (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        string new_name = (string) @params.lookup_value ("newName", VariantType.STRING);

        // before anything, sanity-check the new symbol name
        if (!/^(?=[^\d])[^\s~`!#%^&*()\-\+={}\[\]|\\\/?.>,<'";:]+$/.match (new_name)) {
            client.reply_error_async.begin (
                id,
                Jsonrpc.ClientError.INVALID_REQUEST,
                "Invalid symbol name. Symbol names cannot start with a number and must not contain any operators.",
                Server.cancellable);
            return;
        }

        var p = Util.parse_variant<Lsp.TextDocumentPositionParams> (@params);

        Project project;
        Compilation compilation;
        Vala.SourceFile? doc = project_manager.find_file (p.textDocument.uri, out compilation, out project);
        if (doc == null) {
            Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, p.textDocument.uri);
            reply_null (id, client, method);
            return;
        }

        context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }
            Compilation ctx_compilation;
            Project ctx_project;
            Vala.SourceFile? ctx_doc = project_manager.find_file (p.textDocument.uri, out ctx_compilation, out ctx_project);
            if (ctx_doc == null) {
                reply_null (id, client, method);
                return;
            }
            var ctx = new RequestContext (this, client, id, method,
                                         (!) ctx_doc, ctx_compilation, ctx_project, p.position);
            with_code_context (ctx_compilation.code_context, () => {
                var handler = new Rename.RenameHandler (ctx, new_name);
                handler.run ();
            });
        }, compilation, true);
    }

    internal void dispatch_code_lens (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var document = @params.lookup_value ("textDocument", VariantType.VARDICT);
        string? uri = document != null ? (string?) document.lookup_value ("uri", VariantType.STRING) : null;

        if (document == null || uri == null) {
            Vls.Logger.warn ("lsp", "[%s] `textDocument` or `uri` not provided as expected", method);
            reply_null (id, client, method);
            return;
        }

        Project project;
        Compilation compilation;
        Vala.SourceFile? file = project_manager.find_file (uri, out compilation, out project);
        if (file == null) {
            Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, uri);
            reply_null (id, client, method);
            return;
        }

        context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }
            Compilation ctx_compilation;
            Project ctx_project;
            Vala.SourceFile? ctx_file = project_manager.find_file (uri, out ctx_compilation, out ctx_project);
            if (ctx_file == null) {
                reply_null (id, client, method);
                return;
            }
            var ctx = new RequestContext (this, client, id, method,
                                         ctx_file, ctx_compilation, ctx_project);
            with_code_context (compilation.code_context, () => {
                var handler = new CodeLensEngine.CodeLensHandler (ctx);
                handler.run ();
            });
        }, compilation, true);
    }

    internal void dispatch_semantic_tokens_full (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.SemanticTokensParams> (@params);
        Vls.Logger.debug ("context", "full request: %s",
               p.textDocument.uri);

            context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            Compilation compilation;
            Project project;
            Vala.SourceFile? doc = project_manager.find_file (p.textDocument.uri, out compilation, out project);
            if (doc == null) {
                Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, p.textDocument.uri);
                reply_null (id, client, method);
                return;
            }

            var ctx = new RequestContext (this, client, id, method,
                                         (!) doc, compilation, project);
            with_code_context (compilation.code_context, () => {
                var handler = new SemanticTokensHandler.SemanticTokensFullHandler (ctx, p.textDocument.uri);
                handler.run ();
            });
        });
    }

    internal void dispatch_semantic_tokens_delta (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.SemanticTokensDeltaParams> (@params);
        Vls.Logger.debug ("context", "delta request: uri=%s, prev_id=%s",
               p.textDocument.uri, p.previousResultId ?? "null");

            context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            Compilation compilation;
            Project project;
            Vala.SourceFile? doc = project_manager.find_file (p.textDocument.uri, out compilation, out project);
            if (doc == null) {
                Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, p.textDocument.uri);
                reply_null (id, client, method);
                return;
            }

            var ctx = new RequestContext (this, client, id, method,
                                         (!) doc, compilation, project);
            with_code_context (compilation.code_context, () => {
                var handler = new SemanticTokensHandler.SemanticTokensDeltaHandler (ctx, p.textDocument.uri, p.previousResultId);
                handler.run ();
            });
        });
    }

    internal void dispatch_semantic_tokens_range (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.SemanticTokensRangeParams> (@params);
        Vls.Logger.debug ("context", "range request: %s",
               p.textDocument.uri);

            context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }

            Compilation compilation;
            Project project;
            Vala.SourceFile? doc = project_manager.find_file (p.textDocument.uri, out compilation, out project);
            if (doc == null) {
                Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, p.textDocument.uri);
                reply_null (id, client, method);
                return;
            }

            var ctx = new RequestContext (this, client, id, method,
                                         (!) doc, compilation, project);
            with_code_context (compilation.code_context, () => {
                var handler = new SemanticTokensHandler.SemanticTokensRangeHandler (ctx, p.textDocument.uri, p.range);
                handler.run ();
            });
        });
    }

    internal void dispatch_prepare_call_hierarchy (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams> (@params);

        Project project;
        Compilation compilation;
        Vala.SourceFile? doc = project_manager.find_file (p.textDocument.uri, out compilation, out project);
        if (doc == null) {
            Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, p.textDocument.uri);
            reply_null (id, client, method);
            return;
        }

        context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }
            Compilation ctx_compilation;
            Project ctx_project;
            Vala.SourceFile? ctx_doc = project_manager.find_file (p.textDocument.uri, out ctx_compilation, out ctx_project);
            if (ctx_doc == null) {
                reply_null (id, client, method);
                return;
            }
            var ctx = new RequestContext (this, client, id, method,
                                         (!) ctx_doc, ctx_compilation, ctx_project, p.position);
            with_code_context (ctx_compilation.code_context, () => {
                var handler = new CallHierarchy.PrepareCallHierarchyHandler (ctx, p);
                handler.run ();
            });
        }, compilation, true);
    }

    internal void dispatch_call_hierarchy_incoming_calls (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var itemv = @params.lookup_value ("item", VariantType.VARDICT);
        var item = Util.parse_variant<Lsp.CallHierarchyItem> (itemv);

        Project project;
        Compilation compilation;
        Vala.SourceFile? doc = project_manager.find_file (item.uri, out compilation, out project);
        if (doc == null) {
            Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, item.uri);
            reply_null (id, client, method);
            return;
        }

        context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }
            Compilation ctx_compilation;
            Project ctx_project;
            Vala.SourceFile? ctx_doc = project_manager.find_file (item.uri, out ctx_compilation, out ctx_project);
            if (ctx_doc == null) {
                reply_null (id, client, method);
                return;
            }
            var ctx = new RequestContext (this, client, id, method,
                                         (!) ctx_doc, ctx_compilation, ctx_project);
            with_code_context (ctx_compilation.code_context, () => {
                var handler = new CallHierarchy.CallHierarchyIncomingHandler (ctx, item);
                handler.run ();
            });
        }, compilation, true);
    }

    internal void dispatch_call_hierarchy_outgoing_calls (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var itemv = @params.lookup_value ("item", VariantType.VARDICT);
        var item = Util.parse_variant<Lsp.CallHierarchyItem> (itemv);

        Project project;
        Compilation compilation;
        Vala.SourceFile? doc = project_manager.find_file (item.uri, out compilation, out project);
        if (doc == null) {
            Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, item.uri);
            reply_null (id, client, method);
            return;
        }

        context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }
            Compilation ctx_compilation;
            Project ctx_project;
            Vala.SourceFile? ctx_doc = project_manager.find_file (item.uri, out ctx_compilation, out ctx_project);
            if (ctx_doc == null) {
                reply_null (id, client, method);
                return;
            }
            var ctx = new RequestContext (this, client, id, method,
                                         (!) ctx_doc, ctx_compilation, ctx_project);
            with_code_context (ctx_compilation.code_context, () => {
                var handler = new CallHierarchy.CallHierarchyOutgoingHandler (ctx, item);
                handler.run ();
            });
        }, compilation, true);
    }

    internal void dispatch_inlay_hint (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.InlayHintParams> (@params);

        Compilation? compilation;
        Project? project;
        var file = project_manager.find_file (p.textDocument.uri, out compilation, out project);
        if (file == null) {
            Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, p.textDocument.uri);
            reply_null (id, client, method);
            return;
        }

        context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }
            Compilation? ctx_compilation;
            Project? ctx_project;
            var ctx_file = project_manager.find_file (p.textDocument.uri, out ctx_compilation, out ctx_project);
            if (ctx_file == null) {
                reply_null (id, client, method);
                return;
            }
            var ctx = new RequestContext (this, client, id, method,
                                         (!) ctx_file, ctx_compilation, ctx_project, p.range.start);
            with_code_context (ctx_compilation.code_context, () => {
                var handler = new InlayHints.InlayHintHandler (ctx, p);
                handler.run ();
            });
        }, compilation, true);
    }

    internal void dispatch_prepare_type_hierarchy (Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams> (@params);

        Project project;
        Compilation compilation;
        var doc = project_manager.find_file (p.textDocument.uri, out compilation, out project);
        if (doc == null) {
            Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, p.textDocument.uri);
            reply_null (id, client, method);
            return;
        }

        context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }
            Compilation ctx_compilation;
            Project ctx_project;
            var ctx_doc = project_manager.find_file (p.textDocument.uri, out ctx_compilation, out ctx_project);
            if (ctx_doc == null) {
                reply_null (id, client, method);
                return;
            }
            var ctx = new RequestContext (this, client, id, method,
                                         (!) ctx_doc, ctx_compilation, ctx_project, p.position);
            with_code_context (ctx_compilation.code_context, () => {
                var handler = new TypeHierarchy.PrepareTypeHierarchyHandler (ctx, p);
                handler.run ();
            });
        }, compilation, true);
    }

    internal void dispatch_show_type_hierarchy (Jsonrpc.Client client, string method, Variant id, Variant @params, bool supertypes) {
        var itemv = @params.lookup_value ("item", VariantType.VARDICT);
        var item = Util.parse_variant<Lsp.TypeHierarchyItem> (itemv);

        Project project;
        Compilation compilation;
        var doc = project_manager.find_file (item.uri, out compilation, out project);
        if (doc == null) {
            Vls.Logger.debug ("lsp", "[%s] file `%s' not found", method, item.uri);
            reply_null (id, client, method);
            return;
        }

        context_manager.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                reply_null (id, client, method);
                return;
            }
            Compilation ctx_compilation;
            Project ctx_project;
            var ctx_doc = project_manager.find_file (item.uri, out ctx_compilation, out ctx_project);
            if (ctx_doc == null) {
                reply_null (id, client, method);
                return;
            }
            var ctx = new RequestContext (this, client, id, method,
                                         (!) ctx_doc, ctx_compilation, ctx_project);
            with_code_context (ctx_compilation.code_context, () => {
                var handler = new TypeHierarchy.ShowTypeHierarchyHandler (ctx, item, supertypes);
                handler.run ();
            });
        }, compilation, true);
    }


    internal void shutdown () {
        Vls.Logger.info ("lsp", "shutting down");
        this.shutting_down = true;
        cancellable.cancel ();
        if (client_closed_event_id != 0)
            this.disconnect (client_closed_event_id);
        foreach (var project in project_manager.projects.get_keys_as_array ())
            project.disconnect (project_manager.projects[project]);
        foreach (uint source_id in g_sources)
            Source.remove (source_id);
    }

    internal void exit () {
        loop.quit ();
    }
}

/**
 * Debug logging support (static globals, configured via meson -Ddebug_logging=).
 */
FileStream? vls_log_file = null;

void vls_log_handler (Vls.Server? sv, string? domain, LogLevelFlags levels, string message) {
    if (sv != null) {
        bool is_debug = (levels & LogLevelFlags.LEVEL_DEBUG) != 0;
        bool is_info = (levels & LogLevelFlags.LEVEL_INFO) != 0;
        bool is_message = (levels & LogLevelFlags.LEVEL_MESSAGE) != 0;
        switch (sv.trace) {
            case Lsp.TraceValue.OFF:
                if (is_debug || is_info || is_message) return;
                break;
            case Lsp.TraceValue.MESSAGES:
                if (is_debug) return;
                break;
            default:
                break;
        }
    }
    string thread = Vls.Logger.get_thread_name ();
    string ndc = Vls.Logger.get_context ();
    var dt = new DateTime.now ();
    string ts = dt.format ("%Y-%m-%d %H:%M:%S");
    int ms = (int) (dt.get_microsecond () / 1000);
    var timestamp = "%s.%03d".printf (ts, ms);
    string dom = (domain != null && domain != "") ? domain + ": " : "";
    var formatted = "%s [%s] [%s] %s%s\n".printf (timestamp, thread, ndc, dom, message);
    stderr.printf ("%s", formatted);
    if (vls_log_file != null) {
        vls_log_file.printf ("%s", formatted);
        vls_log_file.flush ();
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

// glibc backtrace helpers (not in Vala Posix VAPI)
[CCode (cname = "backtrace", cheader_filename = "execinfo.h")]
extern int glibc_backtrace ([CCode (array_length = false)] void*[] buffer, int size);
[CCode (cname = "backtrace_symbols_fd", cheader_filename = "execinfo.h")]
extern void glibc_backtrace_symbols_fd ([CCode (array_length = false)] void*[] buffer, int size, int fd);

int main (string[] args) {
    Posix.@signal (Posix.Signal.SEGV, () => {
        stderr.printf ("=== VLS: segmentation fault (internal error) ===\n");
        // Print native backtrace – backtrace_symbols_fd is signal-safe
        void*[] frames = new void*[64];
        int n_frames = glibc_backtrace (frames, 64);
        stderr.printf ("--- backtrace (%d frames) ---\n", n_frames);
        glibc_backtrace_symbols_fd (frames, n_frames, 2);  // fd 2 = stderr
        stderr.printf ("--- end backtrace ---\n");
        Posix.exit (1);
    });
    // Ignore SIGPIPE — the editor may close stdin/stdout while VLS is still
    // writing. Without this, write() returns EPIPE and the kernel delivers
    // SIGPIPE before GLib can observe client_closed, killing the process.
    Posix.@signal (Posix.Signal.PIPE, Posix.SIG_IGN);

    stderr.printf ("=== VLS starting ===\n");
    Vls.Logger.init ();
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

    // Enable debug logging if configured via meson -Ddebug_logging=...
    // or via VLS_LOG_PATH environment variable (runtime override, e.g. for tests).
    string log_path = Environment.get_variable ("VLS_LOG_PATH");
    if (log_path == null)
        log_path = Config.DEBUG_LOGGING;
    if (log_path != null && log_path != "") {
        var log_dir = File.new_for_path (Path.get_dirname (log_path));
        try {
            if (!log_dir.query_exists ())
                log_dir.make_directory_with_parents ();
        } catch (Error e) {
            Vls.Logger.warn ("lsp", "could not create log directory: %s", e.message);
        }
        vls_log_file = FileStream.open (log_path, "a");
        if (vls_log_file != null) {
            vls_log_file.printf ("=== VLS started at %s ===\n", new DateTime.now ().to_string ());
            // Suppress GLib's setenv thread-safety warning during startup
            uint glib_warn_id = GLib.Log.set_handler ("GLib", LogLevelFlags.LEVEL_WARNING, (d, l, m) => {});
            Environment.set_variable ("G_MESSAGES_DEBUG", "all", false);
            GLib.Log.remove_handler ("GLib", glib_warn_id);
        }
    }

    var loop = new MainLoop ();
    var sv = new Vls.Server (loop);
    if (vls_log_file != null)
        GLib.Log.set_default_handler ((domain, levels, message) => {
            vls_log_handler (sv, domain, levels, message);
        });
    try {
        sv.init_scheduler ();
    } catch (ThreadError e) {
        error ("Failed to create scheduler: %s", e.message);
    }
    loop.run ();
    return 0;
}
