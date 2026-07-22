/* completion/providers.vala
 *
 * Copyright 2020 Princeton Ferro <princetonferro@gmail.com>
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

namespace Vls.CompletionEngine {
    /**
     * List all relevant members of a type. This is where completion options are generated.
     *
     * @param is_cm_this_or_base_access     Whether we are accessing `this` or `base` within a creation method.
     */
    void add_completions_for_type (Server.ServiceProvider lang_serv, Project project,
                                   CodeStyleAnalyzer? code_style,
                                   Vala.DataType? type,
                                   Vala.TypeSymbol type_symbol,
                                   Set<CompletionItem> completions,
                                   Vala.Scope current_scope,
                                   bool in_oce,
                                   bool is_cm_this_or_base_access,
                                   Gee.Set<Vala.TypeSymbol> visited_types,
                                   Set<string> seen_props = new HashSet<string> (),
                                   Set<Vala.TypeSymbol> seen_type_symbols = new HashSet<Vala.TypeSymbol> ()) {
        if (type_symbol in seen_type_symbols)
            return;     // bail out for recursive types
        seen_type_symbols.add (type_symbol);
        bool is_instance = type != null;
        uint method_spaces = code_style != null ? code_style.average_spacing_before_parens : 1;

        // Avoid redundant type-hierarchy walks when the same type is
        // encountered at multiple scope levels.
        if (visited_types.contains (type_symbol))
            return;
        visited_types.add (type_symbol);
        if (type_symbol is Vala.ObjectTypeSymbol) {
            /**
             * Complete the members of this object, such as the fields,
             * properties, and methods.
             */
            var object_sym = (Vala.ObjectTypeSymbol) type_symbol;

            // debug (@"type symbol is object $(object_sym.name) (is_instance = $is_instance, in_oce = $in_oce)");

            foreach (var method_sym in object_sym.get_methods ()) {
                if (!should_show_method_for_object_or_struct (type_symbol,
                        method_sym,
                        current_scope,
                        is_instance,
                        in_oce,
                        is_cm_this_or_base_access))
                    continue;
                var completion = new CompletionItem.from_symbol (type, method_sym, current_scope,
                    (method_sym is Vala.CreationMethod) ? CompletionItemKind.Constructor : CompletionItemKind.Method,
                    lang_serv.doc_engine.get_symbol_documentation (project, method_sym));
                completion.insertText = generate_insert_text_for_callable
                    (type, method_sym, current_scope, method_spaces);
                completion.insertTextFormat = InsertTextFormat.Snippet;
                completions.add (completion);
            }

            if (!in_oce) {
                foreach (var field_sym in object_sym.get_fields ()) {
                    if (field_sym.name[0] == '_' && seen_props.contains (field_sym.name[1:field_sym.name.length])
                        || field_sym.is_instance_member () != is_instance
                        || !CodeHelp.is_symbol_accessible (field_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol
                        (type, field_sym, current_scope,
                         CompletionItemKind.Field,
                         lang_serv.doc_engine.get_symbol_documentation (project, field_sym)));
                }
            }

            if (!in_oce && is_instance) {
                foreach (var signal_sym in object_sym.get_signals ()) {
                    if (signal_sym.is_instance_member () != is_instance
                        || !CodeHelp.is_symbol_accessible (signal_sym, current_scope))
                        continue;
                    // generate one completion for invoking the signal and another without, for member access
                    completions.add (new CompletionItem.from_symbol
                        (type, signal_sym, current_scope,
                         CompletionItemKind.Event,
                         lang_serv.doc_engine.get_symbol_documentation (project, signal_sym)));
                    var emitter_documentation = lang_serv.doc_engine.get_symbol_documentation (project, signal_sym);
                    if (emitter_documentation != null)
                        emitter_documentation.body = "_(Invokes this signal)_\n\n" + emitter_documentation.body;
                    completions.add (new CompletionItem.from_symbol (type, signal_sym,
                                                                     current_scope,
                                                                     CompletionItemKind.Method,
                                                                     emitter_documentation) {
                        insertText = generate_insert_text_for_callable (type, signal_sym, current_scope, method_spaces),
                        insertTextFormat = InsertTextFormat.Snippet
                    });
                }

                foreach (var prop_sym in object_sym.get_properties ()) {
                    if (prop_sym.is_instance_member () != is_instance
                        || !CodeHelp.is_symbol_accessible (prop_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol
                        (type, prop_sym, current_scope,
                         CompletionItemKind.Property,
                         lang_serv.doc_engine.get_symbol_documentation (project, prop_sym)));
                    seen_props.add (prop_sym.name);
                }
            }

            // get inner types and constants
            if (!is_instance && !in_oce) {
                foreach (var constant_sym in object_sym.get_constants ()) {
                    if (!CodeHelp.is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol
                        (type, constant_sym, current_scope,
                         CompletionItemKind.Constant,
                         lang_serv.doc_engine.get_symbol_documentation (project, constant_sym)));
                }

                foreach (var enum_sym in object_sym.get_enums ())
                    completions.add (new CompletionItem.from_symbol
                        (type, enum_sym, current_scope,
                         CompletionItemKind.Enum,
                         lang_serv.doc_engine.get_symbol_documentation (project, enum_sym)));

                foreach (var delegate_sym in object_sym.get_delegates ())
                    completions.add (new CompletionItem.from_symbol
                        (type, delegate_sym, current_scope,
                         CompletionItemKind.Interface,
                         lang_serv.doc_engine.get_symbol_documentation (project, delegate_sym)));
            }

            // if we're inside an OCE (which are treated as instances), get only inner types
            if (!is_instance || in_oce) {
                foreach (var class_sym in object_sym.get_classes ())
                    add_class_completion (lang_serv, project, code_style,
                                          class_sym, current_scope, in_oce, completions);

                foreach (var iface_sym in object_sym.get_interfaces ())
                    completions.add (new CompletionItem.from_symbol
                        (type, iface_sym, current_scope,
                         CompletionItemKind.Interface,
                         lang_serv.doc_engine.get_symbol_documentation (project, iface_sym)));

                foreach (var struct_sym in object_sym.get_structs ())
                    completions.add (new CompletionItem.from_symbol
                        (type, struct_sym, current_scope,
                         CompletionItemKind.Struct,
                         lang_serv.doc_engine.get_symbol_documentation (project, struct_sym)));
            }

            // get instance members of supertypes
            if (is_instance && !in_oce) {
                if (object_sym is Vala.Class) {
                    var class_sym = (Vala.Class) object_sym;
                    foreach (var base_type in class_sym.get_base_types ())
                        add_completions_for_type (lang_serv, project, code_style, type, base_type.type_symbol,
                                                  completions, current_scope, in_oce, false,
                                                  visited_types, seen_props, seen_type_symbols);
                }
                if (object_sym is Vala.Interface) {
                    var iface_sym = (Vala.Interface) object_sym;
                    foreach (var base_type in iface_sym.get_prerequisites ())
                        add_completions_for_type (lang_serv, project, code_style, type, base_type.type_symbol,
                                                  completions, current_scope, in_oce, false,
                                                  visited_types, seen_props, seen_type_symbols);
                }
            }
        } else if (type_symbol is Vala.Enum) {
            /**
             * Complete members of this enum, such as the values, methods,
             * and constants.
             */
            var enum_sym = (Vala.Enum) type_symbol;

            foreach (var method_sym in enum_sym.get_methods ()) {
                if (method_sym.is_instance_member () != is_instance
                    || !CodeHelp.is_symbol_accessible (method_sym, current_scope))
                    continue;
                var completion = new CompletionItem.from_symbol (type, method_sym, current_scope, CompletionItemKind.Method, lang_serv.doc_engine.get_symbol_documentation (project, method_sym));
                completion.insertText = generate_insert_text_for_callable
                    (type, method_sym, current_scope, method_spaces);
                completion.insertTextFormat = InsertTextFormat.Snippet;
                completions.add (completion);
            }

            if (!is_instance) {
                foreach (var constant_sym in enum_sym.get_constants ()) {
                    if (!CodeHelp.is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol
                        (type, constant_sym, current_scope,
                         CompletionItemKind.Constant,
                         lang_serv.doc_engine.get_symbol_documentation (project, constant_sym)));
                }
            }

            // Bug #330: Add completions from base enum type (e.g. GLib.Enum)
            Vala.TypeSymbol? base_enum_sym = null;
            if (!is_instance) {
                var topmost = get_topmost_scope (current_scope);
                var glib_ns = topmost.lookup ("GLib");
                if (glib_ns != null) {
                    if (glib_ns.scope != null) {
                        var base_enum_sym_tmp = glib_ns.scope.lookup ("Enum");
                        if (base_enum_sym_tmp is Vala.TypeSymbol)
                            base_enum_sym = (Vala.TypeSymbol) base_enum_sym_tmp;
                    }
                }
            }
            if (base_enum_sym != null && base_enum_sym != type_symbol
                && !seen_type_symbols.contains (base_enum_sym)) {
                seen_type_symbols.add (base_enum_sym);
                add_completions_for_type (lang_serv, project, code_style,
                    type, base_enum_sym, completions,
                    current_scope, in_oce, false, visited_types, seen_props, seen_type_symbols);
            }

            foreach (var value_sym in enum_sym.get_values ())
                completions.add (new CompletionItem.from_symbol
                    (type, value_sym, current_scope,
                     CompletionItemKind.EnumMember,
                     lang_serv.doc_engine.get_symbol_documentation (project, value_sym)));
        } else if (type_symbol is Vala.ErrorDomain) {
            /**
             * Get all the members of the error domain, such as the error
             * codes and the methods.
             */
            var errdomain_sym = (Vala.ErrorDomain) type_symbol;

            foreach (var code_sym in errdomain_sym.get_codes ()) {
                // error codes are treated as non-instance members, but if we're in an OCE they
                // can also be used as pseudo-creation methods
                if (code_sym.is_instance_member () != is_instance && !in_oce)
                    continue;
                completions.add (new CompletionItem.from_symbol
                    (type, code_sym, current_scope, CompletionItemKind.Value,
                     lang_serv.doc_engine.get_symbol_documentation (project, code_sym)));
            }

            if (!in_oce) {
                foreach (var method_sym in errdomain_sym.get_methods ()) {
                    if (method_sym.is_instance_member () != is_instance
                        || !CodeHelp.is_symbol_accessible (method_sym, current_scope))
                        continue;
                    var completion = new CompletionItem.from_symbol
                        (type, method_sym, current_scope, CompletionItemKind.Method,
                         lang_serv.doc_engine.get_symbol_documentation (project, method_sym));
                    completion.insertText = generate_insert_text_for_callable
                        (type, method_sym, current_scope, method_spaces);
                    completion.insertTextFormat = InsertTextFormat.Snippet;
                    completions.add (completion);
                }
            }

            if (is_instance && !in_oce) {
                Vala.Scope topmost = get_topmost_scope (current_scope);

                Vala.Symbol? gerror_sym = topmost.lookup ("GLib");
                if (gerror_sym != null) {
                    if (gerror_sym.scope != null)
                        gerror_sym = gerror_sym.scope.lookup ("Error");
                    else
                        gerror_sym = null;
                    if (gerror_sym == null || !(gerror_sym is Vala.Class))
                        warning ("GLib.Error not found");
                    else
                        add_completions_for_type (lang_serv, project, code_style,
                            type, (Vala.TypeSymbol) gerror_sym, completions,
                            current_scope, in_oce, false, visited_types, seen_props, seen_type_symbols);
                } else
                    warning ("GLib not found");
            }
        } else if (type_symbol is Vala.Struct) {
            /**
             * Gets all of the members of the struct.
             */
            var struct_sym = (Vala.Struct) type_symbol;

            foreach (var field_sym in struct_sym.get_fields ()) {
                // struct fields are always public
                if (field_sym.is_instance_member () != is_instance)
                    continue;
                completions.add (new CompletionItem.from_symbol
                    (type, field_sym, current_scope,
                     CompletionItemKind.Field,
                     lang_serv.doc_engine.get_symbol_documentation (project, field_sym)));
            }

            foreach (var method_sym in struct_sym.get_methods ()) {
                if (!should_show_method_for_object_or_struct (type_symbol,
                        method_sym,
                        current_scope,
                        is_instance,
                        in_oce,
                        is_cm_this_or_base_access))
                    continue;
                var completion = new CompletionItem.from_symbol (type, method_sym, current_scope, CompletionItemKind.Method, lang_serv.doc_engine.get_symbol_documentation (project, method_sym));
                completion.insertText = generate_insert_text_for_callable
                    (type, method_sym, current_scope, method_spaces);
                completion.insertTextFormat = InsertTextFormat.Snippet;
                completions.add (completion);
            }

            foreach (var prop_sym in struct_sym.get_properties ()) {
                if (prop_sym.is_instance_member () != is_instance
                    || !CodeHelp.is_symbol_accessible (prop_sym, current_scope))
                    continue;
                completions.add (new CompletionItem.from_symbol
                    (type, prop_sym, current_scope, CompletionItemKind.Property,
                     lang_serv.doc_engine.get_symbol_documentation (project, prop_sym)));
            }

            if (!is_instance) {
                foreach (var constant_sym in struct_sym.get_constants ()) {
                    if (!CodeHelp.is_symbol_accessible (constant_sym, current_scope))
                        continue;
                    completions.add (new CompletionItem.from_symbol
                        (type, constant_sym, current_scope,
                         CompletionItemKind.Constant,
                         lang_serv.doc_engine.get_symbol_documentation (project, constant_sym)));
                }
            }

            // Bug #300: traverse base struct members
            var base_struct_type = struct_sym.base_type;
            if (base_struct_type != null) {
                var base_type_sym = base_struct_type.type_symbol;
                if (base_type_sym != null && base_type_sym != type_symbol
                    && !seen_type_symbols.contains (base_type_sym)) {
                    seen_type_symbols.add (base_type_sym);
                    add_completions_for_type (lang_serv, project, code_style,
                        type, base_type_sym, completions,
                        current_scope, in_oce, is_instance, visited_types, seen_props, seen_type_symbols);
                }
            }
        } else if (type_symbol is Vala.TypeParameter) {
            var typeparam_sym = (Vala.TypeParameter) type_symbol;
            var generic_type = new Vala.GenericType (typeparam_sym);
            completions.add (new CompletionItem.from_symbol
                (type, generic_type.get_member ("dup"), current_scope,
                 CompletionItemKind.Field,
                 new DocComment (@"a function that knows how to duplicate instances of $(typeparam_sym.name)")));
            completions.add (new CompletionItem.from_symbol
                (type, generic_type.get_member ("destroy"), current_scope,
                 CompletionItemKind.Field,
                 new DocComment (@"a function that knows how to destroy instances of $(typeparam_sym.name)")));
        } else {
            warning (@"other type symbol $type_symbol.\n");
        }
    }

    /**
     * Use this when we're completing members of a namespace.
     */
    void add_completions_for_ns (Server.ServiceProvider lang_serv, Project project, CodeStyleAnalyzer? code_style, Vala.Namespace ns, Vala.Scope scope, Set<CompletionItem> completions, bool in_oce) {
        uint method_spaces = code_style != null ? code_style.average_spacing_before_parens : 1;
        foreach (var class_sym in ns.get_classes ())
            add_class_completion (lang_serv, project, code_style, class_sym, scope, in_oce, completions);
        // this is outside of the OCE check because while we cannot create new instances of
        // raw interfaces, it's possible for interfaces to contain instantiable types declared inside,
        // so that we would call `new Iface.Thing ()'
        foreach (var iface_sym in ns.get_interfaces ())
            completions.add (new CompletionItem.from_symbol (null, iface_sym, scope, CompletionItemKind.Interface, lang_serv.doc_engine.get_symbol_documentation (project, iface_sym)));
        foreach (var struct_sym in ns.get_structs ())
            completions.add (new CompletionItem.from_symbol (null, struct_sym, scope, CompletionItemKind.Struct, lang_serv.doc_engine.get_symbol_documentation (project, struct_sym)));
        foreach (var err_sym in ns.get_error_domains ())
            completions.add (new CompletionItem.from_symbol (null, err_sym, scope, CompletionItemKind.Enum, lang_serv.doc_engine.get_symbol_documentation (project, err_sym)));
        foreach (var ns_sym in ns.get_namespaces ())
            completions.add (new CompletionItem.from_symbol (null, ns_sym, scope, CompletionItemKind.Module, lang_serv.doc_engine.get_symbol_documentation (project, ns_sym)));
        if (!in_oce) {
            foreach (var const_sym in ns.get_constants ())
                completions.add (new CompletionItem.from_symbol (null, const_sym, scope, CompletionItemKind.Constant, lang_serv.doc_engine.get_symbol_documentation (project, const_sym)));
            foreach (var method_sym in ns.get_methods ()) {
                var completion = new CompletionItem.from_symbol (null, method_sym, scope, CompletionItemKind.Method, lang_serv.doc_engine.get_symbol_documentation (project, method_sym));
                completion.insertText = generate_insert_text_for_callable (null, method_sym, scope, method_spaces);
                completion.insertTextFormat = InsertTextFormat.Snippet;
                completions.add (completion);
            }
            foreach (var delg_sym in ns.get_delegates ())
                completions.add (new CompletionItem.from_symbol (null, delg_sym, scope, CompletionItemKind.Interface, lang_serv.doc_engine.get_symbol_documentation (project, delg_sym)));
            foreach (var enum_sym in ns.get_enums ())
                completions.add (new CompletionItem.from_symbol (null, enum_sym, scope, CompletionItemKind.Enum, lang_serv.doc_engine.get_symbol_documentation (project, enum_sym)));
            foreach (var field_sym in ns.get_fields ())
                completions.add (new CompletionItem.from_symbol (null, field_sym, scope, CompletionItemKind.Field, lang_serv.doc_engine.get_symbol_documentation (project, field_sym)));
        }
    }

    /**
     * Use this to complete members of a signal.
     */
    void add_completions_for_signal (CodeStyleAnalyzer? code_style, Vala.DataType? instance_type, Vala.Signal sig, Vala.Scope scope, Set<CompletionItem> completions) {
        uint method_spaces = code_style != null ? code_style.average_spacing_before_parens : 1;
        var sig_type = new Vala.SignalType (sig);
        completions.add_all_array (new CompletionItem []{
            new CompletionItem.from_symbol (instance_type, sig_type.get_member ("connect"), scope, CompletionItemKind.Method,
                new DocComment ("Connect to signal")) {
                insertText = generate_insert_text_for_callable (instance_type, sig_type.get_member ("connect") as Vala.Method, scope, method_spaces),
                insertTextFormat = InsertTextFormat.Snippet
            },
            new CompletionItem.from_symbol (instance_type, sig_type.get_member ("connect_after"), scope, CompletionItemKind.Method,
                new DocComment ("Connect to signal after default handler")) {
                insertText = generate_insert_text_for_callable (instance_type, sig_type.get_member ("connect_after") as Vala.Method, scope, method_spaces),
                insertTextFormat = InsertTextFormat.Snippet
            },
            new CompletionItem.from_symbol (instance_type, sig_type.get_member ("disconnect"), scope, CompletionItemKind.Method,
                new DocComment ("Disconnect signal")) {
                insertText = generate_insert_text_for_callable (instance_type, sig_type.get_member ("disconnect") as Vala.Method, scope, method_spaces),
                insertTextFormat = InsertTextFormat.Snippet
            }
        });
    }

    /**
     * Use this to complete members of an array.
     */
    void add_completions_for_array_type (CodeStyleAnalyzer? code_style,
                                         Vala.ArrayType atype, Vala.Scope scope, Set<CompletionItem> completions) {
        var length_member = atype.get_member ("length");
        uint method_spaces = code_style != null ? code_style.average_spacing_before_parens : 1;
        if (length_member != null)
            completions.add (new CompletionItem.from_symbol (
                atype,
                length_member,
                scope,
                CompletionItemKind.Property,
                (atype.fixed_length && atype.length != null ?
                    new DocComment (@"(= $(CodeHelp.get_code_node_source (atype.length)))") : null)));
        foreach (string method_name in new string[] {"copy", "move", "resize"}) {
            var method = atype.get_member (method_name);
            if (method is Vala.Method) {
                completions.add (new CompletionItem.from_symbol (
                        atype,
                        method,
                        scope,
                        CompletionItemKind.Method,
                        null) {
                    insertText = generate_insert_text_for_callable (atype, (Vala.Method)method, scope, method_spaces),
                    insertTextFormat = InsertTextFormat.Snippet
                });
            }
        }
    }

    /**
     * Use this to complete members of an async method.
     */
    void add_completions_for_async_method (CodeStyleAnalyzer? code_style,
                                           Vala.DataType? instance_type, Vala.Method m, Vala.Scope scope, Set<CompletionItem> completions) {
        Vala.Scope topmost = get_topmost_scope (scope);
        Vala.Symbol? glib_ns = topmost.lookup ("GLib");
        // don't show async members if we don't have GAsyncResult available (included in gio-2.0)
        if (glib_ns != null && glib_ns.scope != null && glib_ns.scope.lookup ("AsyncResult") != null) {
            completions.add_all_array(new CompletionItem []{
                new CompletionItem.from_symbol (instance_type, m, scope, CompletionItemKind.Method,
                    new DocComment ("Begin asynchronous operation"), "begin") {
                    insertText = generate_insert_text_for_callable (instance_type, m, scope, code_style.average_spacing_before_parens, "begin"),
                    insertTextFormat = InsertTextFormat.Snippet
                },
                new CompletionItem.from_symbol (instance_type, m.get_end_method (), scope, CompletionItemKind.Method,
                    new DocComment ("Get results of asynchronous operation")) {
                    insertText = generate_insert_text_for_callable (instance_type, m.get_end_method (), scope, code_style.average_spacing_before_parens),
                    insertTextFormat = InsertTextFormat.Snippet
                },
                new CompletionItem.from_symbol (instance_type, m.get_callback_method (), scope, CompletionItemKind.Field,
                    new DocComment ("Callback into asynchronous method"))
            });
        }
    }

    void add_completions_for_class_access (Server.ServiceProvider lang_serv, Project project,
                                           CodeStyleAnalyzer? code_style,
                                           Vala.Class class_sym, Vala.Scope current_scope,
                                           Set<CompletionItem> completions) {
        uint method_spaces = code_style != null ? code_style.average_spacing_before_parens : 1;
        var klasses = new GLib.Queue<Vala.Class> ();
        var seen_klasses = new HashSet<Vala.Class> ();
        klasses.push_tail (class_sym);

        while (!klasses.is_empty ()) {
            var ks = klasses.pop_head ();
            if (ks in seen_klasses)     // work around recursive types
                break;
            seen_klasses.add (ks);
            foreach (var method_sym in ks.get_methods ()) {
                if (!(method_sym is Vala.CreationMethod) && method_sym.is_class_member ()) {
                    var completion = new CompletionItem.from_symbol (null,
                                                                     method_sym, current_scope,
                                                                     CompletionItemKind.Method,
                                                                     lang_serv.doc_engine.get_symbol_documentation (project, method_sym));
                    completion.insertText = generate_insert_text_for_callable (null, method_sym, current_scope, method_spaces);
                    completion.insertTextFormat = InsertTextFormat.Snippet;
                    completions.add (completion);
                }
            }
            foreach (var field_sym in ks.get_fields ()) {
                if (field_sym.is_class_member ())
                    completions.add (new CompletionItem.from_symbol (null,
                                                                     field_sym, current_scope,
                                                                     CompletionItemKind.Field,
                                                                     lang_serv.doc_engine.get_symbol_documentation (project, field_sym)));
            }
            foreach (var prop_sym in ks.get_properties ()) {
                if (prop_sym.is_class_member ())
                    completions.add (new CompletionItem.from_symbol (null,
                                                                     prop_sym, current_scope,
                                                                     CompletionItemKind.Property,
                                                                     lang_serv.doc_engine.get_symbol_documentation (project, prop_sym)));
            }
            // look at base types
            foreach (var base_type in ks.get_base_types ()) {
                if (base_type.type_symbol is Vala.Class)
                    klasses.push_tail ((Vala.Class) base_type.type_symbol);
            }
        }
    }

    /**
     * Show a suggestion for a class symbol and/or the default class
     * constructor, depending on the context.
     */
    void add_class_completion (Server.ServiceProvider lang_serv, Project project,
                               Vls.CodeStyleAnalyzer? code_style,
                               Vala.Class class_sym, Vala.Scope scope,
                               bool in_oce, Set<CompletionItem> completions) {
        uint method_spaces = code_style != null ? code_style.average_spacing_before_parens : 1;

        bool has_named_ctors = false;
        foreach (var method in class_sym.get_methods ()) {
            if (method is Vala.CreationMethod && method.name != ".new") {
                has_named_ctors = true;
                break;
            }
        }

        if (!in_oce || has_named_ctors
            || !class_sym.get_classes ().is_empty || !class_sym.get_interfaces ().is_empty
            || !class_sym.get_structs ().is_empty) {
            completions.add (new CompletionItem.from_symbol (
                null,
                class_sym,
                scope,
                CompletionItemKind.Class,
                lang_serv.doc_engine.get_symbol_documentation (project, class_sym)) {
                insertText = generate_insert_text_for_type_symbol (class_sym, scope, method_spaces),
                insertTextFormat = InsertTextFormat.Snippet
            });
        }

        if (in_oce && !class_sym.is_abstract && class_sym.default_construction_method != null) {
            var ctor_documentation = lang_serv.doc_engine.get_symbol_documentation (project, class_sym.default_construction_method);
            if (ctor_documentation == null)
                ctor_documentation = lang_serv.doc_engine.get_symbol_documentation (project, class_sym);
            completions.add (new CompletionItem.from_symbol (
                null,
                class_sym.default_construction_method,
                scope,
                CompletionItemKind.Constructor,
                ctor_documentation,
                class_sym.name) {
                insertText = generate_insert_text_for_callable (null, class_sym.default_construction_method, scope, method_spaces),
                insertTextFormat = InsertTextFormat.Snippet
            });
        }
    }
}
