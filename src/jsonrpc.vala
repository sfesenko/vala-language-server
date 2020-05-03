using Gee;
namespace Vls {

class JsonrpcClient {
    private Jsonrpc.Client client;
    private Cancellable cancellable;

    public JsonrpcClient (Jsonrpc.Client client, Cancellable cancellable) {
        this.client = client;
        this.cancellable = cancellable;
    }

    [Version (deprecated = true)]
    public Jsonrpc.Client get_client () {
        return this.client;
    }

    // a{sv} only
    Variant buildDict (...) {
        var l = va_list ();
        return build_variant (l);
    }

    // a{sv} only
    Variant build_variant (va_list l) {
        var builder = new VariantBuilder (new VariantType ("a{sv}"));
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

    public void showMessage (string message, LanguageServer.MessageType type) {
        if (type == LanguageServer.MessageType.Error)
            warning (message);
        try {
            client.send_notification ("window/showMessage", buildDict (
                type: new Variant.int16 (type),
                message: new Variant.string (message)
            ), cancellable);
        } catch (Error e) {
            debug (@"showMessage: failed to notify client: $(e.message)");
        }
    }

    public bool reply_variant (Variant id, Variant result) throws Error {
        return client.reply (id, result, cancellable);
    }
}

class JsonrpcServer : Jsonrpc.Server {

    [CCode (has_target = false)]
    public delegate void NotificationHandler (JsonrpcClient client, Variant @params);

    [CCode (has_target = false)]
    public delegate void CallHandler (JsonrpcClient client, Variant id, Variant @params);

    private Cancellable cancellable;
    ulong client_closed_event_id;

    public JsonrpcServer (Cancellable cancellable) throws GLib.Error  {
        this.cancellable = cancellable;

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
        if (!Unix.set_fd_nonblocking (Posix.STDIN_FILENO, true) || !Unix.set_fd_nonblocking (new_stdout_fd, true)) {
            error ("could not set pipes to nonblocking.\n");
        }
#endif
        accept_io_stream (new SimpleIOStream (input_stream, output_stream));

#if WITH_JSONRPC_GLIB_3_30
        client_closed_event_id = client_closed.connect (client => {
            cancellable.cancel ();
        });
#endif
        cancellable.cancelled.connect ( shutdown );
    }

    /**
    * Shutdown rpc server
     */
    void shutdown () {
        debug ("JsonrpcServer.shutdown");
        if (client_closed_event_id != 0) {
            disconnect (client_closed_event_id);
        }
    }
}
} // namespace
