/* doccomment.vala
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

using Gee;

/**
 * Represents a documentation comment after it has been
 * formatted into Markdown.
 */
class Vls.DocComment {
    /**
     * The main body of the comment, in Markdown.
     * {@inheritDoc}
     */
    public string body { get; set; default = ""; }

    /**
     * The list of parameters for this symbol. The key is the
     * parameter name and the value is the Markdown documentation for
     * that parameter.
     */
    public HashMap<string, string> parameters { get; private set; default = new HashMap<string, string> (); }

    /**
     * The comment about the return value, if applicable.
     */
    public string? return_body { get; private set; }

    /**
     * Create a documentation comment from a Markdown string. No rendering is done.
     */
    public DocComment (string markdown_doc) {
        body = markdown_doc;
    }

    /**
     * Render a GTK-Doc- or gi-docgen-formatted comment into Markdown.
     *
     * see [[https://developer.gnome.org/gtk-doc-manual/stable/documenting_syntax.html.en]]
     * and [[https://gnome.pages.gitlab.gnome.org/gi-docgen/linking.html]]
     *
     * @param comment           A comment in GTK-Doc or gi-docgen format
     * @param documentation     Holds GIR documentation and renders the comment
     * @param compilation       The current compilation that is the context of the comment
     */
    public DocComment.from_gir_comment (Vala.Comment comment, GirDocumentation documentation, Compilation compilation) throws RegexError {
        init_regexes ();
        body = gir_ref_regex.match (comment.content) ?
            documentation.render_gi_docgen_comment (comment, compilation) :
            documentation.render_gtk_doc_comment (comment, compilation);
        if (comment is Vala.GirComment) {
            var gir_comment = (Vala.GirComment) comment;
            for (var it = gir_comment.parameter_iterator (); it.next (); ) {
                Vala.Comment param_comment = it.get_value ();
                parameters[it.get_key ()] = gir_ref_regex.match (param_comment.content) ?
                    documentation.render_gi_docgen_comment (param_comment, compilation) :
                    documentation.render_gtk_doc_comment (param_comment, compilation);
            }
            if (gir_comment.return_content != null)
                return_body = gir_ref_regex.match (gir_comment.return_content.content) ?
                    documentation.render_gi_docgen_comment (gir_comment.return_content, compilation) :
                    documentation.render_gtk_doc_comment (gir_comment.return_content, compilation);
        }
    }

    /**
     * Render a ValaDoc-formatted comment into Markdown.
     *
     * see [[https://valadoc.org/markup.htm]]
     *
     * @param comment           a comment in ValaDoc format
     * @param symbol            the symbol associated with the comment
     * @param compilation       the current compilation that is the context of the comment
     */
    public DocComment.from_valadoc_comment (Vala.Comment comment, Vala.Symbol symbol, Compilation compilation) throws RegexError {
        body = comment.content;
        init_regexes ();

        // strip the comment of asterisks
        body = strip_asterisks_regex.replace (body, body.length, 0, "\\1");

        // render highlighting hints: bold, underlined, italic, and block quote
        // bold
        body = bold_regex.replace (body, body.length, 0, "**\\1**");
        // underlined
        body = underline_regex.replace (body, body.length, 0, "<ins>\\1</ins>");
        // italic
        body = italic_regex.replace (body, body.length, 0, "_\\1_");
        // quotes
        body = quote_regex.replace_eval (body, body.length, 0, 0, (match_info, result) => {
            string quote = match_info.fetch (1) ?? "";

            if (quote.index_of_char ('\n') == -1) {
                // inline quotes
                result.append_c ('`');
                result.append (quote);
                result.append_c ('`');
            } else {
                // block quotes
                result.append_c ('\n');
                foreach (string line in quote.split ("\n")) {
                    result.append ("> ");
                    result.append (line);
                    result.append_c ('\n');
                }
                result.append_c ('\n');
            }
            return false;
        });

        // TODO: we'll avoid rendering all of the kinds of lists now, since some are already
        // supported by markdown

        // code blocks (with support for a non-standard language specifier)
        body = codeblock_regex.replace (body, body.length, 0, "```\\1\\2```");

        // images and links
        body = link_regex.replace_eval (body, body.length, 0, 0, (match_info, result) => {
            string type = match_info.fetch (1) ?? "";
            string href = match_info.fetch (2) ?? "";
            string name = match_info.fetch (4) ?? "";
            string end = match_info.fetch (5) ?? "";

            if (!(type == "[[" && end == "]]" || type == "{{" && end == "}}")) {
                result.append ((!) match_info.fetch (0));
            } else {                    // image or link
                if (name == "" && type == "[[")
                    result.append (href);
                else {
                    if (type == "{{")
                        result.append_c ('!');
                    result.append_c ('[');
                    result.append (name);
                    result.append ("](");
                    result.append (href);
                    result.append_c (')');
                }
            }
            return false;
        });

        // tables
        body = table_regex.replace_eval (body, body.length, 0, 0, (match_info, result) => {
            string header = match_info.fetch_named ("header") ?? "";
            string rest = match_info.fetch_named ("rest") ?? "";
            MatchInfo header_minfo;

            if (!columns_regex.match (header, 0, out header_minfo)) {
                result.append ("\n\n(failed to render ValaDoc table)\n\n");
                return false;
            }

            try {
                result.append (columns_regex.replace (header, header.length, 0, "|\\1"));
                result.append_c ('|');
                string header_content = "";
                while (header_minfo.matches () && (header_content = (header_minfo.fetch (1) ?? "")).strip () != "") {
                    result.append (string.nfill (header_content.length, '-'));
                    result.append_c ('|');
                    header_minfo.next ();
                }
                result.append_c ('\n');
                result.append (columns_regex.replace (rest, rest.length, 0, "|\\1"));
            } catch (RegexError e) {
                Logger.warn ("lsp", "failed to render ValaDoc table - %s", e.message);
                result.append ("\n\n(failed to render ValaDoc table)\n\n");
            }

            return false;
        });

        // render headlines
        body = headline_regex.replace_eval (body, body.length, 0, 0, (match_info, result) => {
            string prefix = (!) match_info.fetch_named ("prefix");
            string heading = (!) match_info.fetch (2);

            result.append (string.nfill (prefix.length, '#'));
            result.append_c (' ');
            result.append (heading);
            return false;
        });

        // inline taglets
        DocComment? parent_comment = null;
        bool computed_parent = false;
        body = inheritdoc_regex.replace_eval (body, body.length, 0, 0, (match_info, result) => {
            if (!computed_parent) {
                computed_parent = true;
                if (symbol.parent_symbol != null && symbol.parent_symbol.comment != null) {
                    try {
                        parent_comment = new DocComment.from_valadoc_comment (symbol.parent_symbol.comment, symbol.parent_symbol, compilation);
                    } catch (RegexError e) {
                        Logger.warn ("lsp", "could not render parent comment - %s", e.message);
                        result.append ("(could not render parent comment - ");
                        result.append (e.message);
                        result.append_c (')');
                        return true;
                    }
                }
                if (parent_comment != null)
                    result.append (parent_comment.body);
            }
            return false;
        });

        // inline references to other symbols (XXX: should we tranform these into links?)
        body = link_ref_regex.replace (body, body.length, 0, "**\\1**");

        // block taglets: @param
        body = param_regex.replace_eval (body, body.length, 0, 0, (match_info, result) => {
            string param_name = (!) match_info.fetch (1);
            string param_description = (!) match_info.fetch (2);

            parameters[param_name] = param_description;
            return false;
        });

        // block taglets: @return
        body = return_regex.replace_eval (body, body.length, 0, 0, (match_info, result) => {
            return_body = (!) match_info.fetch (1);
            return false;
        });

        // block taglets: @see
        body = see_regex.replace_eval (body, body.length, 0, 0, (match_info, result) => {
            string symbol_name = match_info.fetch (1);
            result.append ("\n\n**see** ");
            result.append ("`");
            result.append (symbol_name);
            result.append ("`");
            return false;
        });

        // block taglets: @since
        body = since_regex.replace_eval (body, body.length, 0, 0, (match_info, result) => {
            string version = match_info.fetch (1);
            result.append ("\n---\n\n**Since** ");
            result.append (version);
            return false;
        });
    }

    // Pre-compiled regexes for GIR and ValaDoc rendering (avoids Vala parser bugs
    // with regex literal flags — see cleanup branch review).
    private static Regex gir_ref_regex;
    private static Regex strip_asterisks_regex;
    private static Regex bold_regex;
    private static Regex underline_regex;
    private static Regex italic_regex;
    private static Regex quote_regex;
    private static Regex codeblock_regex;
    private static Regex link_regex;
    private static Regex table_regex;
    private static Regex headline_regex;
    private static Regex inheritdoc_regex;
    private static Regex link_ref_regex;
    private static Regex param_regex;
    private static Regex return_regex;
    private static Regex see_regex;
    private static Regex since_regex;
    private static Regex columns_regex;

    private static void init_regexes () {
        if (strip_asterisks_regex != null)
            return;
        try {
            gir_ref_regex = new Regex ("""\[(\w+)@(\w+(\.\w+)*)(::?([\w\-]+))?\]""");
            strip_asterisks_regex = new Regex ("""^[\t\f\v ]*\*+[ \t\f]*(.*)$""", RegexCompileFlags.MULTILINE);
            bold_regex = new Regex ("""''(.*?)''""");
            underline_regex = new Regex ("""__(.*)__""");
            italic_regex = new Regex ("""//(.*?)//""");
            quote_regex = new Regex ("""\n?(?<!`)``([^`]+([^`]|`(?!``))*?)``\n{0,2}""", RegexCompileFlags.DOTALL);
            codeblock_regex = new Regex ("""{{{(\w+)?(.*?)}}}""", RegexCompileFlags.DOTALL);
            link_regex = new Regex ("""(\[\[|{{)([~:\/\\\w\-.]+)(\|(.*?))?(\]\]|}})""");
            table_regex = new Regex ("""(?'header'\|\|(.*?\|\|)+(\n|$))(?'rest'(?&header)+)""");
            headline_regex = new Regex ("""^(?<prefix>=+) (.+?) (?P=prefix)$""", RegexCompileFlags.MULTILINE);
            inheritdoc_regex = new Regex ("""{@inheritDoc}""");
            link_ref_regex = new Regex ("""{@link ((?'ident'[A-Za-z_]\w*)(\.(?&ident))*?)}""");
            param_regex = new Regex ("""^@param ([A-Za-z_]\w*)[\t\f\v ]+(.+(\n[\t\f ]?([^@]|@(?!deprecated|see|param|since|return|throws))+)*)$""", RegexCompileFlags.MULTILINE);
            return_regex = new Regex ("""^@return[\t\f\v ]+(.+(\n[\t\f ]?([^@]|@(?!deprecated|see|param|since|return|throws))+)*)$""", RegexCompileFlags.MULTILINE);
            see_regex = new Regex ("""^@see[\t\f ]+((?'ident'[A-Za-z_]\w*)(\.(?&ident))*?)$""", RegexCompileFlags.MULTILINE);
            since_regex = new Regex ("""^@since[\t\f ]+((?'ident'\S+)(\.(?&ident))*?)$""", RegexCompileFlags.MULTILINE);
            columns_regex = new Regex ("""\|\|((([^`\n\r]|`.*?`)*?)(?=\|\|))?""");
        } catch (RegexError e) {
            error ("Failed to compile ValaDoc regex: %s", e.message);
        }
    }
}
