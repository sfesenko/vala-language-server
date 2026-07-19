/* semantictokensresponsebuilder.vala
 *
 * Copyright 2026 sfesenko
 *
 * This file is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
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

using Gee;

namespace Vls.Foundation {
    /**
     * Builds LSP `textDocument/semanticTokens/full` and
     * `textDocument/semanticTokens/full/delta` responses as GVariant values.
     *
     * This class is intentionally server-independent so that it can be
     * unit-tested without spawning a language-server subprocess.
     *
     * Key design choice: all child variants are added via
     * [[VariantBuilder.add_value]] (not `add ("a{sv}", ...)`) to avoid the
     * builder-inconsistency crash that affected delta responses.
     */
    public class SemanticTokensResponseBuilder {
        /**
         * Build a full semantic-tokens response.
         *
         * @param result_id  an opaque string the client sends back on the
         *                   next delta request
         * @param data       the flat delta-encoded token array
         * @return a Variant of type `a{sv}` suitable for `client.reply`
         */
        public static Variant build_full (string result_id, Gee.List<uint> data) {
            var data_builder = new VariantBuilder (new VariantType ("au"));
            foreach (var val in data)
                data_builder.add ("u", val);

            var result_dict = new VariantBuilder (new VariantType ("a{sv}"));
            result_dict.add ("{sv}", "resultId", new Variant.string (result_id));
            result_dict.add ("{sv}", "data", data_builder.end ());
            return result_dict.end ();
        }

        /**
         * Build a semantic-tokens delta response.
         *
         * @param result_id  an opaque string for the next delta request
         * @param old_data   the previous full/delta data (used to compute
         *                   `deleteCount`)
         * @param new_data   the new delta-encoded token array
         * @return a Variant of type `a{sv}` suitable for `client.reply`
         */
        public static Variant build_delta (string result_id,
                                           Gee.List<uint> old_data,
                                           Gee.List<uint> new_data) {
            var data_builder = new VariantBuilder (new VariantType ("au"));
            foreach (var val in new_data)
                data_builder.add ("u", val);

            var edit_builder = new VariantBuilder (new VariantType ("a{sv}"));
            edit_builder.add ("{sv}", "start", new Variant.int32 (0));
            edit_builder.add ("{sv}", "deleteCount", new Variant.int32 ((int) old_data.size));
            // add_value — adding a pre-built child variant to a builder
            // requires add_value, otherwise the builder is left in an
            // inconsistent state and end() aborts the process.
            edit_builder.add ("{sv}", "data", data_builder.end ());

            var edits_builder = new VariantBuilder (new VariantType ("aa{sv}"));
            edits_builder.add_value (edit_builder.end ());

            var result_dict = new VariantBuilder (new VariantType ("a{sv}"));
            result_dict.add ("{sv}", "resultId", new Variant.string (result_id));
            result_dict.add ("{sv}", "edits", edits_builder.end ());
            return result_dict.end ();
        }
    }
}
