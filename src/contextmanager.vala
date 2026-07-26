/* contextmanager.vala
 *
 * Copyright 2024 Vala Language Server Contributors
 *
 * This file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation; either version 2.1 of the
 * License, or (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

using Gee;
using Lsp;

/**
 * Manages compilation scheduling, pending requests, and context updates.
 *
 * The compilation pipeline:
 *   1. edit event -> request_context_update()
 *        - increments update_context_requests, sets deadline
 *        - cancels all in-flight compile_cancellables
 *   2. periodic timer (100ms) -> check_update_context()
 *        - if compiles in-flight: return (keep timer alive)
 *        - reset counters, then for each stale compilation:
 *          - spawn compile_on_worker on scheduler thread
 *   3. async compile callback
 *        - if cancelled: discard result
 *        - if not cancelled: swap_compile_result, publish diagnostics
 *        - when all compilations done: fire_pending_context_updates
 *   4. handler calls wait_for_context_update()
 *        - if context fresh: fire immediately
 *        - else: register as PendingRequest
 */
class Vls.ContextManager : Object {
    public delegate void OnContextUpdatedFunc (bool request_cancelled);

    internal const uint check_update_context_period_ms = 100;
    internal const int64 update_context_delay_inc_us = 500 * 1000;
    internal const int64 update_context_delay_max_us = 1000 * 1000;

    class PendingRequest {
        public Request req;
        public OnContextUpdatedFunc callback;
        public PendingRequest (Request req, owned OnContextUpdatedFunc callback) {
            this.req = req;
            this.callback = (owned) callback;
        }
    }

    private Server _server;
    private Gee.HashMap<Request, PendingRequest> pending_requests;
    private int compile_in_progress_count = 0;
    private Gee.HashMap<Compilation, Cancellable> compile_cancellables = new Gee.HashMap<Compilation, Cancellable> ();
    private Jsonrpc.Client? update_context_client = null;
    private int64 update_context_requests = 0;
    private int64 update_context_time_us = 0;

    public Jsonrpc.Client? last_update_client {
        get { return update_context_client; }
    }

    public ContextManager (Server server) {
        _server = server;
        pending_requests = new Gee.HashMap<Request, PendingRequest> (req => req.hash (), (a, b) => a.equal (b));
    }

    public void request_context_update (Jsonrpc.Client client) {
        update_context_client = client;
        update_context_requests += 1;
        int64 delay_us = int64.min (update_context_delay_inc_us * update_context_requests, update_context_delay_max_us);
        update_context_time_us = get_monotonic_time () + delay_us;
        // Cancel any in-flight compile — newer edits make it stale.
        // The worker will check this and discard its result.
        foreach (var entry in compile_cancellables.entries)
            entry.value.cancel ();
        Vls.Log.debug ("context", "request_context_update: requests=%d, delay=%dms",
                       (int) update_context_requests, (int) (delay_us / 1000));
    }

    public bool check_update_context () {
        if (update_context_requests > 0 && get_monotonic_time () >= update_context_time_us) {
            Vls.Log.debug ("context", "check_update_context: starting rebuild (requests=%d)", (int) update_context_requests);

            Project[] all_projects = _server.project_manager.projects.get_keys_as_array ();
            all_projects += _server.project_manager.default_project;
            bool reconfigured_projects = false;

            // If compiles are already in flight, skip this cycle —
            // the in-flight compiles will swap and re-trigger via pending_requests.
            // Bug #1: Do NOT reset update_context_requests here — new edits
            // arriving during the compile must still see a non-zero counter
            // so they wait instead of proceeding against stale data.
            if (compile_in_progress_count > 0) {
                Vls.Log.debug ("context", "check_update_context: %d compile(s) in progress, deferring", compile_in_progress_count);
                return true;
            }

            // Reset the counters after confirming no compiles are in flight.
            // If reconfigure_if_stale throws, incoming requests are not lost.
            update_context_requests = 0;
            update_context_time_us = 0;

            foreach (var project in all_projects) {
                try {
                    bool reconfigured = project.reconfigure_if_stale (Server.cancellable);
                    reconfigured_projects |= reconfigured;

                    foreach (var compilation in project.get_compilations ()) {
                        if (compilation.is_stale ()) {
                            Vls.Log.debug ("context", "check_update_context: starting async compile for %s", compilation.id);
                            compile_in_progress_count++;
                            // create a fresh cancellable for this compile.
                            // request_context_update() cancels it when new edits arrive.
                            var compile_canc = new Cancellable ();
                            compile_cancellables[compilation] = compile_canc;
                            var captured_project = project;
                            _server.scheduler.run_async.begin<Compilation.CompileResult> (() => {
                                return compilation.compile_on_worker (compile_canc);
                            }, compile_canc, (obj, res) => {
                                bool was_cancelled = false;
                                try {
                                    var result = _server.scheduler.run_async.end<Compilation.CompileResult> (res);
                                    // if the cancellable fired, a newer edit arrived
                                    // while this compile was running — discard the stale result.
                                    was_cancelled = compile_canc.is_cancelled ();
                                    if (was_cancelled) {
                                        Vls.Log.debug ("context", "async compile cancelled for %s (newer edit arrived)", compilation.id);
                                    } else {
                                        bool accepted = compilation.swap_compile_result (result);
                                        Vls.Log.debug ("context", "async compile done for %s (swap %s)",
                                                       compilation.id, accepted ? "accepted" : "rejected: corrupted AST");
                                    }
                                } catch (Error e) {
                                    was_cancelled = compile_canc.is_cancelled ();
                                    if (!was_cancelled)
                                        Vls.Log.warn ("context", "async compile failed: %s", e.message);
                                } finally {
                                    compile_in_progress_count--;
                                    compile_cancellables.unset (compilation);
                                    if (!was_cancelled) {
                                        _server.publish_diagnostics (captured_project, compilation, update_context_client);
                                        if (compile_in_progress_count == 0)
                                            fire_pending_context_updates ();
                                    }
                                }
                            });
                        }
                    }

                    // remove all newly-added files from the default project
                    if (reconfigured && project != _server.project_manager.default_project) {
                        var newly_added = new HashSet<string> ();
                        foreach (var comp in project.get_compilations ())
                            newly_added.add_all_iterator
                                (comp.get_project_files ().map<string> (f => f.filename));
                        foreach (var comp in _server.project_manager.default_project.get_compilations ()) {
                            foreach (var source_file in comp.get_project_files ()) {
                                if (newly_added.contains (source_file.filename)) {
                                    var uri = File.new_for_path (source_file.filename).get_uri ();
                                    try {
                                        _server.project_manager.default_project.close (uri);
                                        _server.document_manager.add_discarded_file (uri);
                                        Vls.Log.debug ("context", "discarding %s from DefaultProject", Util.project_uri (uri));
                                    } catch (Error e) {
                                        // just ignore
                                    }
                                }
                            }
                        }
                    }

                    foreach (var comp in project.get_compilations ())
                        _server.publish_diagnostics (project, comp, update_context_client);
                } catch (Error e) {
                    Vls.Log.warn ("context", "failed to rebuild and/or reconfigure project: %s", e.message);
                    _server.show_message (update_context_client,
                        @"Failed to rebuild/reconfigure project: $(e.message)",
                        MessageType.Error);
                }
            }

            // add open files that do not belong to any project to the default project
            if (reconfigured_projects) {
                var orphaned_files = new HashSet<string> ();
                orphaned_files.add_all (_server.document_manager.get_open_files ());
                foreach (var project in _server.project_manager.projects.get_keys ()) {
                    foreach (var comp in project.get_compilations ()) {
                        foreach (var source_file in comp.code_context.get_source_files ()) {
                            var uri = File.new_for_path (source_file.filename).get_uri ();
                            orphaned_files.remove (uri);
                        }
                    }
                }
                foreach (var uri in orphaned_files) {
                    try {
                        var opened = _server.project_manager.default_project.open (uri, null, Server.cancellable).first ();
                        var doc = opened.first;
                        if (doc.content == null)
                            doc.get_mapped_contents ();
                        if (doc is TextDocument)
                            ((TextDocument)doc).last_saved_content = doc.content;
                        _server.publish_diagnostics (_server.project_manager.default_project, opened.second, update_context_client);
                    } catch (Error e) {
                        Vls.Log.warn ("context", "failed to reopen in default project %s - %s", uri, e.message);
                        try {
                            update_context_client.send_notification (
                                "textDocument/publishDiagnostics",
                                _server.build_dict (
                                    uri: new Variant.string (uri),
                                    diagnostics: new Variant.array (VariantType.VARIANT, {})
                                )
                            );
                        } catch (Error e2) {
                            Vls.Log.warn ("context", "failed to clear diagnostics for %s - %s", uri, e2.message);
                        }
                    }
                }
            }

            // rebuild the documentation
            _server.doc_engine.gir.rebuild_if_stale ();

            // Pending context updates are fired from the async compile
            // callback when compile_in_progress_count reaches 0 — no
            // unconditional fire here to avoid stale-data satisfaction.
        }
        return !_server.shutting_down;
    }

    public void wait_for_context_update (Variant id, owned OnContextUpdatedFunc on_context_updated_func,
                                          Compilation? compilation = null, bool stale_safe = false) {
        Vls.Log.debug ("context", "wait_for_context_update: id=%s, requests=%d, pending=%d, comp=%s stale_safe=%s",
                       id.print (false), (int) update_context_requests, pending_requests.size,
                       compilation != null ? compilation.id : "any", stale_safe.to_string ());
        // Stale-safe requests (hover, symbols, etc.) can use a slightly
        // stale AST, but they must still wait for in-flight compiles to
        // finish so they don't run against a mid-swap AST that's about
        // to be replaced.
        if (stale_safe && compile_in_progress_count == 0) {
            on_context_updated_func (false);
            return;
        }
        // If a specific compilation is known and it's not stale,
        // proceed immediately — edits in other targets don't block this one.
        if (compilation != null && !compilation.is_stale ()) {
            on_context_updated_func (false);
            return;
        }
        // Bug #2: Also check compile_in_progress_count — compiles may be in-flight
        // with the counter already reset (or about to be). If compiles are
        // running, we must wait for them to finish and re-check.
        if (update_context_requests == 0 && compile_in_progress_count == 0) {
            on_context_updated_func (false);
            return;
        }
        var req = new Request (id);
        if (pending_requests.has_key (req))
            Vls.Log.warn ("context", "request %s already in pending requests, this should not happen", req.to_string ());
        else
            pending_requests[req] = new PendingRequest (req, (owned) on_context_updated_func);
        // Safety net: if a rebuild was already in flight when we registered
        // (so fire_pending_context_updates already ran), satisfy on idle.
        Idle.add (() => {
            var pr = find_pending (req);
            if (pr == null) {
                // already fired or cancelled
                return Source.REMOVE;
            }
            // re-check per-compilation staleness on idle
            if (compilation != null && !compilation.is_stale ()) {
                pending_requests.unset (req);
                pr.callback (false);
                return Source.REMOVE;
            }
            // Bug #2: Also check compile_in_progress_count on idle
            if (update_context_requests == 0 && compile_in_progress_count == 0) {
                pending_requests.unset (req);
                pr.callback (false);
            }
            // else: still pending, fire_pending_context_updates will handle it
            return Source.REMOVE;
        });
    }

    public void cancel_request (Variant @params) {
        Variant? id = @params.lookup_value ("id", null);
        if (id == null)
            return;

        var req = new Request (id);
        var pr = find_pending (req);
        if (pr != null) {
            pending_requests.unset (req);
            Vls.Log.debug ("context", "cancelled pending request %s", req.to_string ());
            pr.callback (true);
        }
    }

    PendingRequest? find_pending (Request req) {
        return pending_requests[req];
    }

    void fire_pending_context_updates () {
        if (pending_requests.size == 0)
            return;
        var fired = pending_requests.values.to_array ();
        pending_requests.clear ();
        Vls.Log.debug ("context", "fired %d pending context updates", fired.length);
        foreach (var pr in fired) {
            pr.callback (false);
        }
    }
}
