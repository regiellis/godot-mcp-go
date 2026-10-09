extends RefCounted

const PropertyParser := preload("res://addons/swallowtail/utils/property_parser.gd")


func test_json_string_literal_loses_its_quotes(t) -> void:
	t.eq(PropertyParser.parse_value("\"../Child/Target\""), "../Child/Target", "auto-parsed")
	t.eq(PropertyParser.parse_value("\"../Child/Target\"", TYPE_NODE_PATH), NodePath("../Child/Target"), "as a NodePath")
	t.eq(PropertyParser.parse_value("\"hello\"", TYPE_STRING), "hello", "as a String")


func test_escaped_quotes_survive_as_content(t) -> void:
	t.eq(PropertyParser.parse_value("\"say \\\"hi\\\"\""), "say \"hi\"", "escaped quotes inside a JSON string")


func test_strings_that_are_not_json_literals_are_unchanged(t) -> void:
	t.eq(PropertyParser.parse_value("../Child/Target"), "../Child/Target", "bare path")
	t.eq(PropertyParser.parse_value("\"open"), "\"open", "unterminated quote")
	t.eq(PropertyParser.parse_value("\"a\" and \"b\""), "\"a\" and \"b\"", "two quoted words are not one literal")
	t.eq(PropertyParser.parse_value("\""), "\"", "a lone quote")


func test_other_values_still_infer_their_type(t) -> void:
	t.eq(PropertyParser.parse_value("42"), 42, "int")
	t.eq(PropertyParser.parse_value("true"), true, "bool")
	t.eq(PropertyParser.parse_value("Vector2(1, 2)"), Vector2(1, 2), "Vector2 literal")
