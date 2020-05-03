using Gee;
namespace Vls {

class JsonrpcClient {
    private Jsonrpc.Client client;

    public JsonrpcClient (Jsonrpc.Client client) {
        this.client = client;
    }
}

class JsonrpcServer : Jsonrpc.Server {

    [CCode (has_target = false)]
    public delegate void NotificationHandler (JsonrpcClient client, Variant @params);

    [CCode (has_target = false)]
    public delegate void CallHandler (JsonrpcClient client, Variant id, Variant @params);

    HashTable<string, NotificationHandler> notification_handlers;
    HashTable<string, CallHandler> call_handlers;

    private Cancellable cancellable;
    ulong client_closed_event_id;

    construct {
        this.notification_handlers = new HashTable<string, NotificationHandler> (str_hash, str_equal);
        this.call_handlers = new HashTable<string, CallHandler> (str_hash, str_equal);
    }

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
        notification.connect ((client, method, @params) => {
            var handler = this.notification_handlers[method];
            if (handler != null) {
                var rpc_client = new JsonrpcClient (client);
                handler (rpc_client, @params);
            } else {
                // debug ( @"ignore notification: [$method]");
            }
        });
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

    /*
    public void attach_notification (string name, NotificationHandler handler) {
        notification_handlers[name] = handler;
    }

    public void attach_call (string name, CallHandler handler) {
        this.call_handlers[name] = handler;
    }
    */
}
} // namespace
