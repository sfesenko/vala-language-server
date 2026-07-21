/* inlayhints.vala
 *
 * Copyright 2017-2020 Princeton Ferro <princetonferro@gmail.com>
 *
 * This file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation; either version 2.1 of the
 * License, or (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

using Vala;
using Lsp;

namespace Vls.InlayHints {
    class InlayHintHandler : Server.RequestHandler {
        private InlayHintParams p;

        public InlayHintHandler (Server.RequestContext ctx, InlayHintParams p) {
            base (ctx);
            this.p = p;
        }

        public override void run () {
            var compilation = ctx.compilation;
            var query = new NodeSearch.within (ctx.file, p.range, false);
            if (query.result.is_empty) {
                debug ("[%s] nothing found at %s", ctx.method, p.range.to_string ());
                reply_null ();
                return;
            }

            InlayHint[] hints = {};

        foreach (var item in query.result) {
            Vala.LocalVariable? local = null;
            var representation = CodeHelp.get_code_node_source (item);
            MatchInfo foreach_match;
            if (item is Vala.DeclarationStatement)
                local = ((Vala.DeclarationStatement)item).declaration as Vala.LocalVariable;
            if (local != null && local.source_reference != null
                && !(local.initializer is Vala.ObjectCreationExpression) &&
                local in compilation.var_decls) {
                hints += new InlayHint () {
                    position = new Position.from_libvala (local.source_reference.end),
                    label = ":%s".printf (CodeHelp.get_data_type_representation (local.variable_type, null)),
                    kind = InlayHintKind.TYPE,
                    paddingLeft = true
                };
            } else if (/foreach\s*\(\s*var\s+(\w+)/m.match (representation, 0, out foreach_match)) {
                int start, end;
                if (foreach_match.fetch_pos (1, out start, out end)) {
                    Vala.DataType? element_type = null;
                    if (item is Vala.ForeachStatement && !(((Vala.ForeachStatement)item).type_reference is Vala.VarType) &&
                        ((Vala.ForeachStatement)item).element_variable != null) {
                        element_type = ((Vala.ForeachStatement)item).type_reference;
                    } else if (local != null) {
                        element_type = local.variable_type;
                        bool is_element_var = false;
                        for (Vala.CodeNode? current_node = local; current_node != null; current_node = current_node.parent_node) {
                            if (current_node is Vala.ForeachStatement) {
                                var stmt = (Vala.ForeachStatement)current_node;
                                is_element_var = stmt.variable_name == local.name;
                                break;
                            }
                        }
                        if (!is_element_var)
                            continue;
                    } else {
                        continue;
                    }

                    var range = SymbolReferences.get_narrowed_source_reference (item.source_reference, representation, start, end);
                    hints += new InlayHint () {
                        position = range.end,
                        label = ":%s".printf (CodeHelp.get_data_type_representation (element_type, null)),
                        kind = InlayHintKind.TYPE,
                        paddingLeft = true
                    };
                }
            } else if (item is Vala.LambdaExpression) {
                var lambda = (Vala.LambdaExpression)item;
                foreach (var param in lambda.get_parameters ()) {
                    var range = new Range.from_sourceref (param.source_reference);
                    if (param.variable_type != null) {
                        hints += new InlayHint () {
                            position = range.start,
                            label = CodeHelp.get_data_type_representation (param.variable_type, null),
                            kind = InlayHintKind.PARAMETER,
                            paddingRight = true
                        };
                    }
                }
            } else if ((item is Vala.MethodCall || item is Vala.ObjectCreationExpression) && compilation.method_calls.has_key (item)) {
                Vala.List<Vala.Parameter>? parameters = null;
                if (item is Vala.MethodCall) {
                    var mc = (Vala.MethodCall)item;
                    if (mc.call.value_type != null)
                        parameters = mc.call.value_type.get_parameters ();
                } else {
                    var oce = (Vala.ObjectCreationExpression)item;
                    if (oce.member_name != null && oce.member_name.symbol_reference is Vala.Callable)
                        parameters = ((Vala.Callable)oce.member_name.symbol_reference).get_parameters ();
                    else if (oce.type_reference != null)
                        parameters = oce.type_reference.get_parameters ();
                }
                if (parameters != null) {
                    int orig_param_count = compilation.method_calls[item];
                    var iter = parameters.iterator ();
                    var args_i = 0;
                    Vala.Parameter? last_ellipsis = null;
                    Vala.List<Vala.Expression> argument_list;
                    if (item is Vala.MethodCall)
                        argument_list = ((Vala.MethodCall)item).get_argument_list ();
                    else
                        argument_list = ((Vala.ObjectCreationExpression)item).get_argument_list ();
                    foreach (var arg in argument_list) {
                        if (arg.source_reference == null) {
                            args_i++;
                            continue;
                        }
                        if (args_i >= orig_param_count)
                            break;
                        if (arg is Vala.NamedArgument) {
                            args_i++;
                            continue;
                        }
                        if (!iter.next () && last_ellipsis == null)
                            break;
                        var formal_parameter = last_ellipsis ?? iter.get ();
                        if (formal_parameter.ellipsis)
                            last_ellipsis = formal_parameter;
                        var parameter_name = formal_parameter.name ?? @"arg$args_i";
                        var argument = arg;
                        if (argument is Vala.UnaryExpression &&
                            (((Vala.UnaryExpression)argument).operator == Vala.UnaryOperator.REF|| ((Vala.UnaryExpression)argument).operator == Vala.UnaryOperator.OUT))
                            argument = ((Vala.UnaryExpression)argument).inner;
                        if (CodeHelp.get_code_node_source (argument).casefold () == parameter_name.casefold ()) {
                            args_i++;
                            continue;
                        }
                        var range = new Range.from_sourceref (arg.source_reference);
                        hints += new InlayHint () {
                            position = range.start,
                            label = "%s:".printf (parameter_name),
                            kind = InlayHintKind.PARAMETER,
                            paddingRight = true
                        };
                        args_i++;
                    }
                }
            }
        }

        try {
            Variant[] array = {};
            foreach (var hint in hints)
                array += Util.object_to_variant (hint);
            reply_dict (new Variant.array (VariantType.VARDICT, array));
        } catch (Error e) {
            debug (@"[%s] failed to reply to client: $(e.message)", ctx.method);
        }
        }
    }

    void show_inlay_hints (Server server, Jsonrpc.Client client, string method, Variant id, Variant @params) {
        var p = Util.parse_variant<InlayHintParams> (@params);

        Compilation? compilation;
        var file = server.find_file (p.textDocument.uri, out compilation);
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

            Project project;
            Compilation comp;
            server.find_file (p.textDocument.uri, out comp, out project);
            var ctx = new Server.RequestContext (server, client, id, method,
                                                 (!) file, comp, project, p.range.start);
            Server.with_code_context (comp.code_context, () => {
                var handler = new InlayHintHandler (ctx, p);
                handler.run ();
            });
        }, compilation);
    }
}
