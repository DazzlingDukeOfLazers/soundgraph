# Choosing somebody else's plugin, and saying which of its knobs a slot drives.
#
# Everything here is about editing the document, never about audio. The editor holds a
# patch as a plain dictionary, so a plugin is two writes — an entry in the patch's
# `plugins` table and the node's `plugin` field naming it — and both are ordinary undo
# steps like any other edit.
#
# The list of installed plugins comes from `sg-host --scan`, out of process, because
# opening a stranger's plugin is exactly the act that hangs or crashes and the editor
# should not be the process it happens in. That also means this file never loads a
# plugin, never links the hosting SDKs, and cannot be brought down by one.
#
# See docs/hosted-plugins-design.md.
extends RefCounted


## Where sg-host is, or "" when this machine has no scanner to ask.
##
## SOUNDGRAPH_HOST wins because a test and a developer both need to say. Otherwise the
## usual build directories, relative to the project, which is where it is on the machine
## that built it. Not finding it is a fact to report, never an error to throw: an editor
## on a machine with no plugin host is an editor that cannot offer plugins, and should
## say so rather than break.
static func host_path() -> String:
	var named := OS.get_environment("SOUNDGRAPH_HOST")
	if named != "" and FileAccess.file_exists(named):
		return named
	var suffix := ".exe" if OS.get_name() == "Windows" else ""
	for candidate in [
		"res://../build-clap/bin/sg-host" + suffix,
		"res://../build/bin/sg-host" + suffix,
		"res://../../build-clap/bin/sg-host" + suffix,
	]:
		var absolute := ProjectSettings.globalize_path(candidate)
		if FileAccess.file_exists(absolute):
			return absolute
	return ""


## Turns what the scanner printed into entries this editor can show.
##
## Separate from running it so that the parsing can be tested without a plugin on the
## machine — which is the whole difficulty with testing this feature, and worth designing
## around rather than apologising for.
static func parse_scan(text: String) -> Array:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Array):
		return []
	var entries: Array = []
	for item in parsed:
		if not (item is Dictionary):
			continue
		var identity := str(item.get("identity", ""))
		var format := str(item.get("format", ""))
		if identity == "" or format == "":
			continue  # a plugin that cannot say what it is cannot be named by a patch
		var parameters: Array = []
		for parameter in item.get("parameters", []):
			if parameter is Dictionary:
				parameters.append({
					"id": int(parameter.get("id", -1)),
					"name": str(parameter.get("name", "")),
				})
		entries.append({
			"format": format,
			"identity": identity,
			"name": str(item.get("name", identity)),
			"vendor": str(item.get("vendor", "")),
			"path": str(item.get("path", "")),
			"parameters": parameters,
		})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return entries


## Asks the machine what it has. Slow — it opens every plugin installed — so a caller
## does this once and remembers.
static func scan() -> Array:
	var host := host_path()
	if host == "":
		return []
	var output: Array = []
	var code := OS.execute(host, ["--scan"], output, false)
	if code != 0 or output.is_empty():
		return []
	return parse_scan(str(output[0]))


## A stable key for the patch's plugins table, derived from what the plugin calls itself.
##
## Derived rather than random so that choosing the same plugin twice in one patch reuses
## one entry instead of accumulating near-duplicates that differ only in a number.
static func table_key(entry: Dictionary) -> String:
	var base := str(entry.get("name", "plugin")).to_lower()
	var cleaned := ""
	for i in base.length():
		var c := base[i]
		cleaned += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") else "-"
	while cleaned.contains("--"):
		cleaned = cleaned.replace("--", "-")
	cleaned = cleaned.strip_edges(true, true)
	return cleaned if cleaned != "" and cleaned != "-" else "plugin"


## The entry a patch stores: identity, and the hints that make a failure readable.
##
## The path is remembered and never depended on — the resolver matches identity, and a
## hint that has gone stale is a patch on a different machine, which is the normal case
## rather than an error.
static func table_entry(entry: Dictionary) -> Dictionary:
	return {
		"format": str(entry.get("format", "")),
		"identity": str(entry.get("identity", "")),
		"vendor": str(entry.get("vendor", "")),
		"name": str(entry.get("name", "")),
		"path_hint": str(entry.get("path", "")),
		"slots": [],
	}
