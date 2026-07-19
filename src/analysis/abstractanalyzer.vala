/* abstractanalyzer.vala
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

using Vala;

namespace Vls {
    /**
     * Base class for per-file AST analyzers.  Provides the common boilerplate
     * that every analyzer needs:
     *
     *  - a reference to the [[SourceFile]] being analysed (`file`);
     *  - an `is_in_file` predicate that guards every `visit_*` override;
     *  - the `last_updated` timestamp used by the analysis cache
     *    ([[Compilation.get_analysis_for_file]]).
     *
     * Concrete analyzers extend this class and override the `visit_*` methods
     * they are interested in.  The constructor is responsible for kicking off
     * the traversal (typically `this.visit_source_file (file)`).
     */
    public abstract class AbstractAnalyzer : CodeVisitor {
        /**
         * The source file this analyzer operates on.
         */
        protected SourceFile file;

        public DateTime last_updated { get; set; }

        /**
         * Returns `true` if @a node belongs to the file this analyzer was
         * created for.  Every `visit_*` override should call this as its first
         * guard.
         */
        protected bool is_in_file (CodeNode? node) {
            if (node == null)
                return false;
            var sr = node.source_reference;
            // Identity comparison is sound: SourceFile instances are identity
            // objects within a single compilation, so two references pointing
            // at the same file compare equal by reference.
            return sr != null && sr.file == file;
        }

        /**
         * Recurse into @a node only when it belongs to this analyzer's file.
         *
         * This is the common body of the many `visit_*` overrides that merely
         * traverse the AST without producing output. Subclasses with such a
         * passthrough override can write:
         *
         * ```vala
         * public override void visit_block (Vala.Block b) { descend (b); }
         * ```
         */
        protected void descend (CodeNode? node) {
            if (is_in_file (node))
                node.accept_children (this);
        }
    }
}
