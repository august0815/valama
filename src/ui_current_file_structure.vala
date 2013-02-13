/*
 * src/ui_current_file_structure.vala
 * Copyright (C) 2013, Valama development team
 *
 * Valama is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Valama is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

using Gtk;
using Vala;
using GLib;

/**
 * Show current file's basic structure
 */
public class UiCurrentFileStructure : UiElement {
    public Widget widget;
    TreeView tree_view;

    public UiCurrentFileStructure () {
        element_name = "CurrentFileStructure";
        var vbox = new Box (Orientation.VERTICAL, 0);

        tree_view = new TreeView();
        tree_view.insert_column_with_attributes (-1, _("Symbol"), new CellRendererText(), "text", 0, null);

        var scrw = new ScrolledWindow (null, null);
        scrw.add (tree_view);
        vbox.pack_start (scrw, true, true);

        window_main.notify["current-srcbuffer"].connect(()=>{
            build();
        });

        widget = vbox;
    }

    protected override void build() {
        var store = new TreeStore (1, typeof (string));
        tree_view.set_model (store);
        var focus_file = project.guanako_project.get_source_file_by_name (Path.build_path (Path.DIR_SEPARATOR_S, project.project_path, window_main.current_srcfocus));

        foreach (CodeNode node in focus_file.get_nodes()) {
            if (!(node is Namespace || node is Class || node is Subroutine))
                continue;
            TreeIter parent;
            store.append (out parent, null);
            store.set (parent, 0, ((Symbol)node).name, -1);

            TreeIter[] iters = new TreeIter[0];
            Guanako.iter_symbol ((Symbol)node, (smb, depth) => {
                if (smb.name != null && (smb is Namespace || smb is Class || smb is Subroutine)) {
                    TreeIter next;
                    if (depth == 1)
                        store.append (out next, parent);
                    else
                        store.append (out next, iters[depth - 2]);
                    store.set (next, 0, smb.name, -1);
                    if (iters.length < depth)
                        iters += next;
                    else
                        iters[depth - 1] = next;
                }
                return Guanako.iter_callback_returns.continue;
            });
        }
    }
}

// vim: set ai ts=4 sts=4 et sw=4