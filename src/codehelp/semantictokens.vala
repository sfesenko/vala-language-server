/* semantictokens.vala
 *
 * Copyright 2026 sfesenko
 *
 * This file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

using Lsp;
using Gee;

namespace Vls.SemanticTokensHandler {
    private const int MAX_CACHED_RESULTS = 20;

    private class CachedResult {
        public Gee.List<uint> data;
        public string uri;
    }

    private Gee.Map<string, CachedResult>? previous_results;
    private int next_result_id = 1;

    private void ensure_previous_results () {
        if (previous_results == null)
            previous_results = new HashMap<string, CachedResult> ();
    }

    private string store_result (string uri, Gee.List<uint> data) {
        ensure_previous_results ();
        string id = "%d".printf (next_result_id++);
        previous_results[id] = new CachedResult () { data = data, uri = uri };
        // Prune oldest entries when over limit
        if (previous_results.size > MAX_CACHED_RESULTS) {
            string oldest = null;
            int oldest_id = int.MAX;
            foreach (var entry in previous_results.entries) {
                int eid = int.parse (entry.key);
                if (eid < oldest_id) {
                    oldest_id = eid;
                    oldest = entry.key;
                }
            }
            if (oldest != null)
                previous_results.unset (oldest);
        }
        return id;
    }

    private Gee.List<uint> filter_to_range (Gee.ArrayList<SemanticToken> tokens, Range range) {
        var filtered = new ArrayList<SemanticToken> ();
        foreach (var token in tokens) {
            if (token.line < range.start.line)
                continue;
            if (token.line > range.end.line)
                continue;
            if (token.line == range.start.line && token.character < range.start.character)
                continue;
            if (token.line == range.end.line && token.character >= range.end.character)
                continue;
            filtered.add (token);
        }
        return Util.delta_encode (filtered);
    }

    private void reply_with_tokens (Server server, Jsonrpc.Client client, string method,
                                    Variant id, Gee.List<uint> data, string? previous_result_id = null,
                                    string? doc_uri = null) {
        ensure_previous_results ();

        // Check for valid delta request
        bool is_delta = previous_result_id != null && doc_uri != null
            && previous_results.has_key (previous_result_id)
            && previous_results[previous_result_id].uri == doc_uri;
        debug ("[SEMTOK] reply_with_tokens: delta=%s, data_size=%d, prev_id=%s",
               is_delta.to_string (), data.size, previous_result_id ?? "null");
        if (is_delta) {
            var old = previous_results[previous_result_id];
            debug ("[SEMTOK] delta: old_size=%d, new_size=%d", old.data.size, data.size);
            string result_id = store_result (doc_uri, data);

            var edits_builder = new VariantBuilder (new VariantType ("aa{sv}"));
            var edit_builder = new VariantBuilder (new VariantType ("a{sv}"));
            edit_builder.add ("{sv}", "start", new Variant.int32 (0));
            edit_builder.add ("{sv}", "deleteCount", new Variant.int32 ((int) old.data.size));
            var data_builder = new VariantBuilder (new VariantType ("au"));
            foreach (var val in data)
                data_builder.add ("u", val);
            edit_builder.add ("{sv}", "data", data_builder.end ());
            // add_value (not add ("a{sv}", ...)) — adding a pre-built child
            // variant to a builder requires add_value, otherwise the builder
            // is left in an inconsistent state and end() aborts the process.
            edits_builder.add_value (edit_builder.end ());

            var result_dict = new VariantBuilder (new VariantType ("a{sv}"));
            result_dict.add ("{sv}", "resultId", new Variant.string (result_id));
            result_dict.add ("{sv}", "edits", edits_builder.end ());

            try {
                client.reply (id, result_dict.end (), Server.cancellable);
            } catch (Error e) {
                debug (@"[$method] failed to reply to client: $(e.message)");
            }
            return;
        }

        // Full response
        debug ("[SEMTOK] full response: data_size=%d", data.size);
        var data_builder = new VariantBuilder (new VariantType ("au"));
        foreach (var val in data)
            data_builder.add ("u", val);

        var result_dict = new VariantBuilder (new VariantType ("a{sv}"));
        string result_id = doc_uri != null ? store_result (doc_uri, data) : "0";
        result_dict.add ("{sv}", "resultId", new Variant.string (result_id));
        result_dict.add ("{sv}", "data", data_builder.end ());

        try {
            client.reply (id, result_dict.end (), Server.cancellable);
        } catch (Error e) {
            debug (@"[$method] failed to reply to client: $(e.message)");
        }
    }

    void full (Server server, Jsonrpc.Client client, string method,
               Variant id, Variant @params) {
        var p = Util.parse_variant<SemanticTokensParams> (@params);
        debug ("[SEMTOK] full request: %s",
               Util.project_uri (p.textDocument.uri));

        server.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.reply_null (id, client, method);
                return;
            }

            Compilation compilation;
            Project project;
            Vala.SourceFile? doc = server.find_file (p.textDocument.uri, out compilation, out project);
            if (doc == null) {
                debug ("[%s] file `%s' not found", method, Util.project_uri (p.textDocument.uri));
                Server.reply_null (id, client, method);
                return;
            }

            Vala.CodeContext.push (compilation.code_context);
            var tokens = compilation.get_analysis_for_file<SemanticTokensAnalyzer> (doc);
            var data = Util.delta_encode (tokens.get_tokens ());
            reply_with_tokens (server, client, method, id, data, null, p.textDocument.uri);
            Vala.CodeContext.pop ();
        });
    }

    void delta (Server server, Jsonrpc.Client client, string method,
                Variant id, Variant @params) {
        var p = Util.parse_variant<SemanticTokensDeltaParams> (@params);
        debug ("[SEMTOK] delta request: uri=%s, prev_id=%s",
               Util.project_uri (p.textDocument.uri), p.previousResultId ?? "null");

        server.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.reply_null (id, client, method);
                return;
            }

            Compilation compilation;
            Project project;
            Vala.SourceFile? doc = server.find_file (p.textDocument.uri, out compilation, out project);
            if (doc == null) {
                debug ("[%s] file `%s' not found", method, Util.project_uri (p.textDocument.uri));
                Server.reply_null (id, client, method);
                return;
            }

            Vala.CodeContext.push (compilation.code_context);
            var tokens = compilation.get_analysis_for_file<SemanticTokensAnalyzer> (doc);
            var data = Util.delta_encode (tokens.get_tokens ());
            reply_with_tokens (server, client, method, id, data, p.previousResultId, p.textDocument.uri);
            Vala.CodeContext.pop ();
        });
    }

    void range (Server server, Jsonrpc.Client client, string method,
                Variant id, Variant @params) {
        var p = Util.parse_variant<SemanticTokensRangeParams> (@params);
        debug ("[SEMTOK] range request: %s",
               Util.project_uri (p.textDocument.uri));

        server.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.reply_null (id, client, method);
                return;
            }

            Compilation compilation;
            Project project;
            Vala.SourceFile? doc = server.find_file (p.textDocument.uri, out compilation, out project);
            if (doc == null) {
                debug ("[%s] file `%s' not found", method, Util.project_uri (p.textDocument.uri));
                Server.reply_null (id, client, method);
                return;
            }

            Vala.CodeContext.push (compilation.code_context);
            var tokens = compilation.get_analysis_for_file<SemanticTokensAnalyzer> (doc);
            var data = filter_to_range (tokens.get_tokens (), p.range);
            reply_with_tokens (server, client, method, id, data, null, p.textDocument.uri);
            Vala.CodeContext.pop ();
        });
    }
}
