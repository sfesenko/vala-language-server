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
        Logger.debug ("lsp", "reply_with_tokens: delta=%s, data_size=%d, prev_id=%s",
               is_delta.to_string (), data.size, previous_result_id ?? "null");
        if (is_delta) {
            var old = previous_results[previous_result_id];
            Logger.debug ("lsp", "delta: old_size=%d, new_size=%d", old.data.size, data.size);
            string result_id = store_result (doc_uri, data);
            var result = Vls.Foundation.SemanticTokensResponseBuilder.build_delta (
                result_id, old.data, data);
            try {
                client.reply (id, result, Server.cancellable);
                Server.cleanup_request (server, id);
            } catch (Error e) {
                Logger.warn ("lsp", "failed to reply to client: %s", e.message);
            }
            return;
        }

        // Full response
        Logger.debug ("lsp", "full response: data_size=%d", data.size);
        string result_id = doc_uri != null ? store_result (doc_uri, data) : "0";
        var result = Vls.Foundation.SemanticTokensResponseBuilder.build_full (result_id, data);
        try {
            client.reply (id, result, Server.cancellable);
            Server.cleanup_request (server, id);
        } catch (Error e) {
            Logger.warn ("lsp", "failed to reply to client: %s", e.message);
        }
    }

    /**
     * textDocument/semanticTokens/full handler, piloted through the
     * RequestHandler framework. The shared result cache lives at module level
     * (it is keyed by document URI across requests), so the handler only reads
     * the analysis and delegates the reply to {@link reply_with_tokens}.
     */
    class SemanticTokensFullHandler : Server.RequestHandler {
        private string doc_uri;

        public SemanticTokensFullHandler (Server.RequestContext ctx, string doc_uri) {
            base (ctx);
            this.doc_uri = doc_uri;
        }

        public override void run () {
            var tokens = ctx.compilation.get_analysis_for_file<SemanticTokensAnalyzer> (ctx.file);
            var data = Util.delta_encode (tokens.get_tokens ());
            reply_with_tokens (ctx.server, ctx.client, ctx.method, ctx.id, data, null, doc_uri);
        }
    }

    class SemanticTokensDeltaHandler : Server.RequestHandler {
        private string doc_uri;
        private string? previous_result_id;

        public SemanticTokensDeltaHandler (Server.RequestContext ctx, string doc_uri, string? previous_result_id) {
            base (ctx);
            this.doc_uri = doc_uri;
            this.previous_result_id = previous_result_id;
        }

        public override void run () {
            var tokens = ctx.compilation.get_analysis_for_file<SemanticTokensAnalyzer> (ctx.file);
            var data = Util.delta_encode (tokens.get_tokens ());
            reply_with_tokens (ctx.server, ctx.client, ctx.method, ctx.id, data, previous_result_id, doc_uri);
        }
    }

    class SemanticTokensRangeHandler : Server.RequestHandler {
        private string doc_uri;
        private Range range;

        public SemanticTokensRangeHandler (Server.RequestContext ctx, string doc_uri, Range range) {
            base (ctx);
            this.doc_uri = doc_uri;
            this.range = range;
        }

        public override void run () {
            var tokens = ctx.compilation.get_analysis_for_file<SemanticTokensAnalyzer> (ctx.file);
            var data = filter_to_range (tokens.get_tokens (), range);
            reply_with_tokens (ctx.server, ctx.client, ctx.method, ctx.id, data, null, doc_uri);
        }
    }
}
