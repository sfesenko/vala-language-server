/* documentsymbol.vala
 *
 * Copyright 2017-2020 Princeton Ferro <princetonferro@gmail.com>
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
 * You should have received a copy of the GNU Lesser General
 * License along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

using Vala;
using Lsp;
using Gee;

namespace Vls.DocumentSymbolHandler {
    /**
     * textDocument/documentSymbol handler, piloted through the RequestHandler
     * framework (Stage 1). Validates the framework shape; other handlers keep
     * calling the Server reply helpers directly for now.
     */
    class DocumentSymbolHandler : Server.RequestHandler {
        private bool hierarchical;

        public DocumentSymbolHandler (Server.RequestContext ctx, bool hierarchical) {
            base (ctx);
            this.hierarchical = hierarchical;
        }

        public override void run () {
            var syms = ctx.compilation.get_analysis_for_file<SymbolEnumerator> (ctx.file);
            var items = new Gee.ArrayList<Object> ();
            if (hierarchical)
                foreach (var dsym in syms)
                    items.add (dsym);
            else
                foreach (var dsym in syms.flattened ())
                    items.add (dsym);
            reply_array (items);
        }
    }

    void document_symbol_outline (Server server, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<Lsp.TextDocumentPositionParams> (@params);

        Compilation compilation;
        Project project;
        Vala.SourceFile? file = server.find_file (p.textDocument.uri, out compilation, out project);
        if (file == null) {
            debug ("[%s] file `%s' not found", method, Util.project_uri (p.textDocument.uri));
            Server.reply_null (id, client, method);
            return;
        }

        server.wait_for_context_update (id, request_cancelled => {
            if (request_cancelled) {
                Server.reply_null (id, client, method);
                return;
            }

            bool hierarchical = server.init_params.capabilities.textDocument.documentSymbol.hierarchicalDocumentSymbolSupport;
            var ctx = new Server.RequestContext (server, client, id, method,
                                                 (!) file, compilation, project, p.position);
            Server.with_code_context (compilation.code_context, () => {
                var handler = new DocumentSymbolHandler (ctx, hierarchical);
                handler.run ();
            });
        }, compilation);
    }
}
