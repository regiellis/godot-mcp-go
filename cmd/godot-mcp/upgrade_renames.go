package main

// The rename table is hand-kept. Every entry has to be confirmed against the
// target engine before it lands here, with engine search and engine class-info
// against a running editor, because a table built from memory rewrites working
// code into code that compiles and does the wrong thing.
//
// Replace is the mechanical rewrite. An entry with an empty Replace is
// report-only: fix names it and refuses to touch it, which is the honest answer
// for a change that drops an argument or has no replacement at all. Dropping a
// leading layer index out of a call is not a text substitution, because the
// receiver's type decides whether it is correct, and a .gd file is exactly the
// place that type is not written down.
//
// Confirmed against Godot 4.7.2-rc (36a04fe52) on 2026-08-30 with:
//
//	godot-mcp engine class-info --class TileMap --filter layer
//	godot-mcp engine class-info --class TileMapLayer
//	godot-mcp engine class-info --class GDExtension
//	godot-mcp engine search --query close_library
//
// TileMap still carries all 22 of its per-layer methods in 4.7 and TileMapLayer
// carries none of them; the settings they reached are plain Node2D properties
// on the new node. GDExtension is down to get_minimum_library_initialization_level
// and is_library_open, and close_library returns nothing anywhere in ClassDB.

// renameRule is one symbol the supported range changed, matched against
// GDScript source as text.
type renameRule struct {
	Search  string // the literal text that identifies a call site
	Replace string // the mechanical rewrite, or "" for report-only
	Since   string // the release that changed it
	Class   string // the class that owns the symbol, for re-verification
	Detail  string // what a person reading the finding needs to decide
}

// renameTable holds what the craft doc's breakage table justifies for the
// supported 4.3-to-4.7 range. It is deliberately short: an entry that cannot be
// confirmed against the live ClassDB does not belong in it.
var renameTable = []renameRule{
	// 4.3 deprecated TileMap for one TileMapLayer per layer. Every method
	// below exists on TileMap in 4.7 and on TileMapLayer not at all.
	{Search: "get_layers_count(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer has no layer list; each layer is its own node"},
	{Search: "add_layer(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer has no layer list; add another TileMapLayer node"},
	{Search: "move_layer(", Since: "4.3", Class: "TileMap",
		Detail: "layer order is sibling order on TileMapLayer nodes; use node move"},
	{Search: "remove_layer(", Since: "4.3", Class: "TileMap",
		Detail: "delete the TileMapLayer node instead"},
	{Search: "clear_layer(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.clear() clears the one layer the node is"},
	{Search: "get_layer_name(", Since: "4.3", Class: "TileMap",
		Detail: "on TileMapLayer this is the node name"},
	{Search: "set_layer_name(", Since: "4.3", Class: "TileMap",
		Detail: "on TileMapLayer this is the node name"},
	{Search: "get_layer_z_index(", Since: "4.3", Class: "TileMap",
		Detail: "on TileMapLayer this is the node's z_index property"},
	{Search: "set_layer_z_index(", Since: "4.3", Class: "TileMap",
		Detail: "on TileMapLayer this is the node's z_index property"},
	{Search: "get_layer_modulate(", Since: "4.3", Class: "TileMap",
		Detail: "on TileMapLayer this is the node's modulate property"},
	{Search: "set_layer_modulate(", Since: "4.3", Class: "TileMap",
		Detail: "on TileMapLayer this is the node's modulate property"},
	{Search: "get_layer_y_sort_origin(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.get_y_sort_origin() takes no layer index"},
	{Search: "set_layer_y_sort_origin(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.set_y_sort_origin() takes no layer index"},
	{Search: "is_layer_y_sort_enabled(", Since: "4.3", Class: "TileMap",
		Detail: "on TileMapLayer this is the node's y_sort_enabled property"},
	{Search: "set_layer_y_sort_enabled(", Since: "4.3", Class: "TileMap",
		Detail: "on TileMapLayer this is the node's y_sort_enabled property"},
	{Search: "is_layer_enabled(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.is_enabled() takes no layer index"},
	{Search: "set_layer_enabled(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.set_enabled() takes no layer index"},
	{Search: "is_layer_navigation_enabled(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.is_navigation_enabled() takes no layer index"},
	{Search: "set_layer_navigation_enabled(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.set_navigation_enabled() takes no layer index"},
	{Search: "get_layer_navigation_map(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.get_navigation_map() takes no layer index"},
	{Search: "set_layer_navigation_map(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.set_navigation_map() takes no layer index"},
	{Search: "get_layer_for_body_rid(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.has_body_rid() answers this per node"},

	// The cell accessors survive on TileMapLayer without the leading layer
	// index. Which call sites need the argument dropped depends on the
	// receiver's type, so these are reported and ported by hand.
	{Search: ".set_cell(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.set_cell takes no layer index; confirm the receiver's type before dropping it"},
	{Search: ".erase_cell(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.erase_cell takes no layer index"},
	{Search: ".get_cell_source_id(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.get_cell_source_id takes no layer index"},
	{Search: ".get_cell_atlas_coords(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.get_cell_atlas_coords takes no layer index"},
	{Search: ".get_cell_alternative_tile(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.get_cell_alternative_tile takes no layer index"},
	{Search: ".get_used_cells(", Since: "4.3", Class: "TileMap",
		Detail: "TileMapLayer.get_used_cells takes no layer index"},

	// 4.3 removed these three from GDExtension outright. Only the addon's
	// author can answer for them, so they stay a report and preflight refuses
	// to continue past a GDExtension with no build for this machine.
	{Search: "close_library(", Since: "4.3", Class: "GDExtension",
		Detail: "removed from GDExtension in 4.3; the addon needs a rebuild by its author"},
	{Search: "initialize_library(", Since: "4.3", Class: "GDExtension",
		Detail: "removed from GDExtension in 4.3; the addon needs a rebuild by its author"},
	{Search: "open_library(", Since: "4.3", Class: "GDExtension",
		Detail: "removed from GDExtension in 4.3; the addon needs a rebuild by its author"},
}

// fixableRenames returns the table entries carrying a mechanical rewrite, which
// is what decides whether fix --category renames has any work to do. The table
// ships with none: everything the supported range changed either drops an
// argument or has no replacement, and both are ported by hand.
func fixableRenames() []renameRule {
	var out []renameRule
	for _, r := range renameTable {
		if r.Replace != "" {
			out = append(out, r)
		}
	}
	return out
}
