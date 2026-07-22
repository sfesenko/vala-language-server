/* completion/symbols.vala
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
     * Fill the completion list with all scope-visible symbols
     */
    void list_symbols (Server.ServiceProvider lang_serv, Project project,
                       Compilation compilation,
                       Vala.SourceFile doc, Position pos,
                       Vala.Scope best_scope,
                       Set<CompletionItem> completions,
                       bool in_oce) {
        string method = "textDocument/completion";
        var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (doc);
        bool in_instance = false;
        bool inside_static_or_class_construct_block = false;
        var seen_props = new HashSet<string> ();
        var visited_types = new HashSet<Vala.TypeSymbol> ();

        // if (best_scope.owner.source_reference != null)
        //     debug (@"[$method] best scope SR is $(best_scope.owner.source_reference)");
        // else
        //     debug (@"[$method] listing symbols from $(best_scope.owner)");
        for (Vala.Scope? current_scope = best_scope;
                current_scope != null;
                current_scope = current_scope.parent_scope) {
            Vala.Symbol owner = current_scope.owner;
            if (owner is Vala.Callable || owner is Vala.Statement || owner is Vala.Block ||
                owner is Vala.Subroutine) {
                Vala.Parameter? this_param = null;
                if (owner is Vala.Method)
                    this_param = ((Vala.Method)owner).this_parameter;
                else if (owner is Vala.PropertyAccessor)
                    this_param = ((Vala.PropertyAccessor)owner).prop.this_parameter;
                else if (owner is Vala.Constructor)
                    this_param = ((Vala.Constructor)owner).this_parameter;
                else if (owner is Vala.Destructor)
                    this_param = ((Vala.Destructor)owner).this_parameter;
                in_instance = this_param != null;
                if (in_instance) {
                    string instance_type_string = "type";
                    Vala.DataType? base_type = null;

                    if (this_param.variable_type != null && this_param.variable_type.type_symbol is Vala.Class) {
                        foreach (var class_base_type
                                 in ((Vala.Class)this_param.variable_type.type_symbol).get_base_types ())
                            if (class_base_type.type_symbol is Vala.Class) {
                                base_type = class_base_type;
                                break;
                            }
                        instance_type_string = "class";
                    } else if (this_param.variable_type != null
                               && this_param.variable_type.type_symbol is Vala.Struct) {
                        base_type = ((Vala.Struct)this_param.variable_type.type_symbol).base_type;
                        instance_type_string = "struct";
                    } else {
                        // this_param can't be anything else
                    }

                    // add `this' parameter
                    completions.add (new CompletionItem.from_symbol (
                                        null,
                                        this_param,
                                        current_scope,
                                        CompletionItemKind.Keyword,
                                        new DocComment (@"Access the current instance of this $instance_type_string")));

                    // add `base` parameter if this is a subtype
                    if (base_type != null) {
                        completions.add (new CompletionItem.from_synthetic_symbol
                            (base_type, "base", current_scope,
                             CompletionItemKind.Keyword,
                             new DocComment (@"Accesses the base $instance_type_string")));
                    }
                }
                var symtab = current_scope.get_symbol_table ();
                if (symtab != null) {
                    foreach (Vala.Symbol sym in symtab.get_values ()) {
                        if (sym.name == null || sym.name[0] == '.')
                            continue;
                        var sr = sym.source_reference;
                        if (sr == null)
                            continue;
                        var sr_begin = new Position.from_libvala (sr.begin);

                        // don't show local variables that are declared ahead of the cursor
                        if (sr_begin.compare_to (pos) > 0)
                            continue;
                        completions.add (new CompletionItem.from_symbol (null, sym, current_scope,
                            (sym is Vala.Constant) ? CompletionItemKind.Constant : CompletionItemKind.Variable,
                            lang_serv.doc_engine.get_symbol_documentation (project, sym)));
                    }
                }

                // Show `class` methods for static/class constructor blocks.
                // These members should only be referenced implicitly from the
                // subclass, or from an explicit class access expression.
                if (owner is Vala.Constructor && ((Vala.Constructor)owner).binding != Vala.MemberBinding.INSTANCE)
                    inside_static_or_class_construct_block = true;
            } else if (owner is Vala.TypeSymbol) {
                if (in_instance)
                    add_completions_for_type (lang_serv, project, code_style,
                                              Vala.SemanticAnalyzer.get_data_type_for_symbol (owner),
                                              (Vala.TypeSymbol) owner, completions,
                                              best_scope, in_oce, false,
                                              visited_types, seen_props);
                // always show static members
                add_completions_for_type (lang_serv, project, code_style,
                                          null, (Vala.TypeSymbol) owner, completions,
                                          best_scope, in_oce, false,
                                          visited_types, seen_props);
                // suggest class members to implicitly access
                if ((in_instance || inside_static_or_class_construct_block) && owner is Vala.Class)
                    add_completions_for_class_access (lang_serv, project, code_style,
                                                      (Vala.Class) owner, best_scope, completions);
                // once we leave a type symbol, we're no longer in an instance
                in_instance = false;
            } else if (owner is Vala.Namespace) {
                add_completions_for_ns (lang_serv, project, code_style,
                                        (Vala.Namespace) owner, best_scope, completions, in_oce);
            } else {
                debug (@"[$method] ignoring owner ($owner) ($(owner.type_name)) of scope");
            }
        }
        // show members of all imported namespaces
        foreach (var ud in doc.current_using_directives) {
            if (ud.namespace_symbol is Vala.Namespace)
                add_completions_for_ns (lang_serv, project, code_style,
                                        (Vala.Namespace) ud.namespace_symbol,
                                        best_scope, completions, in_oce);
        }
    }

    /**
     * Fill the completion list with keywords.
     */
    void list_keywords (Server.ServiceProvider lang_serv,
                        Vala.SourceFile doc,
                        Vala.Symbol? nearest_symbol, bool in_loop,
                        Set<CompletionItem> completions) {
        if (nearest_symbol is Vala.TypeSymbol) {
            completions.add_all_array({
                new CompletionItem.keyword ("async"),
                new CompletionItem.keyword ("override"),
                new CompletionItem.keyword ("protected"),
                new CompletionItem.keyword ("weak"),
            });
        }

        if (nearest_symbol is Vala.Namespace) {
            completions.add_all_array ({
                new CompletionItem.keyword ("delegate"),
                new CompletionItem.keyword ("errordomain", "errordomain $0"),
                new CompletionItem.keyword ("internal"),
                new CompletionItem.keyword ("namespace", "namespace $0"),
                new CompletionItem.keyword ("params"),
                new CompletionItem.keyword ("private"),
                new CompletionItem.keyword ("public"),
                new CompletionItem.keyword ("unowned"),
                new CompletionItem.keyword ("void"),
            });
        }

        if (nearest_symbol is Vala.Namespace || nearest_symbol is Vala.ObjectTypeSymbol) {
            completions.add_all_array ({
                new CompletionItem.keyword ("abstract"),
                new CompletionItem.keyword ("class", "class $0"),
                new CompletionItem.keyword ("enum", "enum $0"),
                new CompletionItem.keyword ("interface", "interface $0"),
                new CompletionItem.keyword ("struct", "struct $0"),
                new CompletionItem.keyword ("throws", "throws $0"),
                new CompletionItem.keyword ("virtual")
            });
        }

        if (nearest_symbol is Vala.Callable) {
            completions.add_all_array ({
                new CompletionItem.keyword ("catch", "catch ($1) {$2}$0"),
                new CompletionItem.keyword ("delete", "delete $1;$0"),
                new CompletionItem.keyword ("do", "do {$2} while (${1:<condition>});$0"),
                new CompletionItem.keyword ("else"),
                new CompletionItem.keyword ("else if", "else if (${1:<condition>})$0"),
                new CompletionItem.keyword ("finally", "finally {$1}$0"),
                new CompletionItem.keyword ("false"),
                new CompletionItem.keyword ("for",
                    "for (${3:var} ${1:i} = ${2:<expression>}; ${4:<condition>}; ${5:<expression>})$0"),
                new CompletionItem.keyword ("foreach", "foreach (${3:var} ${1:item} in ${2:<expression>})$0"),
                new CompletionItem.keyword ("if", "if (${1:<condition>})$0"),
                new CompletionItem.keyword ("in", "in ${1:<expression>}$0"),
                new CompletionItem.keyword ("is", "is ${1:<type>}$0"),
                new CompletionItem.keyword ("new"),
                new CompletionItem.keyword ("null"),
                new CompletionItem.keyword ("return", "return ${1:<expression>};$0"),
                new CompletionItem.keyword ("switch", "switch (${1:<expression>}) {$0}"),
                new CompletionItem.keyword ("throw"),
                new CompletionItem.keyword ("true"),
                new CompletionItem.keyword ("try", "try {$1} catch ($2) {$3}$0"),
                new CompletionItem.keyword ("var", "var ${1:<var-name>} = $0"),
                new CompletionItem.keyword ("while", "while (${1:<condition>})$0"),
#if VALA_0_50
                new CompletionItem.keyword ("with", "with (${1:<expression>}) {$0}"),
#endif
                new CompletionItem.keyword ("yield"),
            });
        }

        if (nearest_symbol == Vala.CodeContext.get ().root)
            completions.add (new CompletionItem.keyword ("using", "using ${1:<namespace>};$0"));

        if (in_loop) {
            completions.add_all_array ({
                new CompletionItem.keyword ("break"),
                new CompletionItem.keyword ("continue"),
            });
        }

        completions.add_all_array ({
            new CompletionItem.keyword ("global", "global::")
        });
    }

    /**
     * List symbols that to implement from base classes and interfaces.
     */
    void list_implementable_symbols (Server.ServiceProvider lang_serv, Project project, Compilation compilation,
                                     Vala.SourceFile doc, Vala.TypeSymbol type_symbol, Vala.Scope scope,
                                     Vala.List<Pair<Vala.DataType?, Vala.Symbol>> missing_symbols,
                                     Set<CompletionItem> completions, string prefix = "") {
        var code_style = compilation.get_analysis_for_file<CodeStyleAnalyzer> (doc);
        string spaces = " ";

        if (code_style != null)
            spaces = string.nfill (code_style.average_spacing_before_parens, ' ');

        foreach (var pair in missing_symbols) {
            var instance_type = pair.first;
            var sym = pair.second;
            var kind = CompletionItemKind.Method;

            if (sym is Vala.Property)
                kind = CompletionItemKind.Property;

            var label = new StringBuilder ();
            var insert_text = new StringBuilder ();

            label.append (sym.access.to_string ());
            label.append_c (' ');
            insert_text.append (sym.access.to_string ());
            insert_text.append_c (' ');

            if (sym.hides) {
                label.append ("new ");
                insert_text.append ("new ");
            }

            if (sym is Vala.Method && ((Vala.Method)sym).coroutine) {
                label.append ("async ");
                insert_text.append ("async ");
            }

            if (sym is Vala.Method && CodeHelp.base_method_requires_override ((Vala.Method)sym) ||
                sym is Vala.Property && CodeHelp.base_property_requires_override ((Vala.Property)sym)) {
                label.append ("override ");
                insert_text.append ("override ");
            }

            Vala.DataType? return_type = null;
            if (sym is Vala.Callable)
                return_type = ((Vala.Callable)sym).return_type.get_actual_type (instance_type, null, null);
            else if (sym is Vala.Property)
                return_type = ((Vala.Property)sym).property_type.get_actual_type (instance_type, null, null);

            if (return_type != null) {
                string? return_type_representation = CodeHelp.get_data_type_representation (return_type, scope);
                label.append (return_type_representation);
                label.append_c (' ');
                insert_text.append (return_type_representation);
                insert_text.append_c (' ');
            } else {
                warning ("no return type for symbol %s", sym.name);
            }

            label.append (sym.name);
            insert_text.append (sym.name);

            if (sym is Vala.Callable) {
                // display type arguments
                Vala.List<Vala.TypeParameter>? type_parameters = null;
                if (sym is Vala.Delegate)
                    type_parameters = ((Vala.Delegate)sym).get_type_parameters ();
                else if (sym is Vala.Method)
                    type_parameters = ((Vala.Method)sym).get_type_parameters ();

                if (type_parameters != null && !type_parameters.is_empty) {
                    label.append_c ('<');
                    insert_text.append_c ('<');
                    int i = 1;
                    foreach (var type_parameter in type_parameters) {
                        if (i > 1) {
                            label.append_c (',');
                            insert_text.append_c (',');
                        }
                        label.append (type_parameter.name);
                        insert_text.append (type_parameter.name);
                    }
                    label.append_c ('>');
                    insert_text.append_c ('>');
                }

                label.append (spaces);
                insert_text.append (spaces);

                label.append_c ('(');
                insert_text.append_c ('(');
                int i = 1;
                foreach (Vala.Parameter param in ((Vala.Callable) sym).get_parameters ()) {
                    if (i > 1) {
                        insert_text.append (", ");
                        label.append (", ");
                    }
                    insert_text.append (CodeHelp.get_symbol_representation
                        (instance_type, param, scope, false, null,
                         "${" + @"$i:$(param.name)}"));
                    label.append (CodeHelp.get_symbol_representation (instance_type, param, scope, false));
                    i++;
                }
                insert_text.append_c(')');
                label.append_c (')');
            } else if (sym is Vala.Property) {
                var prop = (Vala.Property)sym;
                label.append (" {");
                insert_text.append (" {");
                int count = 1;
                if (prop.get_accessor != null) {
                    if (prop.get_accessor.value_type is Vala.ReferenceType
                        && prop.get_accessor.value_type.value_owned) {
                        label.append (" owned");
                        insert_text.append (" owned");
                    }
                    label.append (" get;");
                    insert_text.append_printf (" get${%d:;}", count);
                    count++;
                }
                if (prop.set_accessor != null) {
                    if (prop.set_accessor.value_type is Vala.ReferenceType
                        && prop.set_accessor.value_type.value_owned) {
                        label.append (" owned");
                        insert_text.append (" owned");
                    }
                    label.append (" set;");
                    insert_text.append_printf (" set${%d:;}", count);
                    count++;
                }
                label.append (" }");
                insert_text.append (" }");
            }

            insert_text.append ("$0");

            // Use prefix to avoid inserting part of the method signature
            // that has already been typed
            string final_insert_text = insert_text.str;
            if (prefix.length > 0 && final_insert_text.has_prefix (prefix)) {
                final_insert_text = final_insert_text.substring (prefix.length);
            }

            completions.add (
                new CompletionItem.from_unimplemented_symbol (
                    sym, label.str, kind, final_insert_text,
                    lang_serv.doc_engine.get_symbol_documentation (project, sym)
                ));
        }
    }
}
