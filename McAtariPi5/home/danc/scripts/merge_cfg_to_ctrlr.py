#!/usr/bin/env python3

import argparse
import copy
import datetime
import glob
import os
import shutil
import sys
import xml.etree.ElementTree as ET


def parse_args():
    parser = argparse.ArgumentParser(
        description="Merge MAME auto cfg input mappings into a target ctrlr cfg"
    )
    parser.add_argument(
        "--source-dir",
        default="/opt/retropie/emulators/mame/cfg",
        help="Directory containing source auto cfg files",
    )
    parser.add_argument(
        "--target",
        required=True,
        help="Target ctrlr cfg file path",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview merge without writing changes",
    )
    return parser.parse_args()


def _indent(elem, level=0):
    indent = "    "
    i = "\n" + level * indent
    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = i + indent
        for child in elem:
            _indent(child, level + 1)
        if not elem[-1].tail or not elem[-1].tail.strip():
            elem[-1].tail = i
    if level and (not elem.tail or not elem.tail.strip()):
        elem.tail = i


def _sig(elem):
    tag = elem.tag
    if tag == "port":
        return (
            tag,
            elem.attrib.get("tag", ""),
            elem.attrib.get("type", ""),
            elem.attrib.get("mask", ""),
            elem.attrib.get("defvalue", ""),
        )
    if tag == "remap":
        return (tag, elem.attrib.get("origcode", ""))
    if tag == "mapdevice":
        return (tag, elem.attrib.get("device", ""), elem.attrib.get("controller", ""))
    items = tuple(sorted(elem.attrib.items()))
    return (tag, items)


def _load_cfg_tree(path):
    try:
        # Keep XML comments from target ctrlr files so merge writes do not
        # strip user-maintained documentation blocks.
        parser = ET.XMLParser(target=ET.TreeBuilder(insert_comments=True))
        tree = ET.parse(path, parser=parser)
    except ET.ParseError as e:
        raise RuntimeError(f"XML parse error in {path}: {e}") from e
    except TypeError:
        # Fallback for environments where insert_comments isn't supported.
        try:
            tree = ET.parse(path)
        except ET.ParseError as e:
            raise RuntimeError(f"XML parse error in {path}: {e}") from e
    root = tree.getroot()
    if root.tag != "mameconfig":
        raise RuntimeError(f"Invalid root tag in {path}: expected mameconfig")
    version = str(root.attrib.get("version", "")).strip()
    if version and version != "10":
        raise RuntimeError(f"Unsupported mameconfig version in {path}: {version}")
    if "version" not in root.attrib:
        root.set("version", "10")
    return tree


def _iter_source_cfg_paths(source_dir):
    pattern = os.path.join(source_dir, "*.cfg")
    return sorted(glob.glob(pattern), key=lambda p: os.path.basename(p).lower())


def _find_system(root, name):
    for node in root.findall("system"):
        if node.attrib.get("name") == name:
            return node
    return None


def _ensure_input(system_node):
    input_node = system_node.find("input")
    if input_node is None:
        input_node = ET.SubElement(system_node, "input")
    return input_node


def _reorder_systems(root):
    systems = [n for n in list(root) if n.tag == "system"]
    others = [n for n in list(root) if n.tag != "system"]

    for node in list(root):
        root.remove(node)

    for node in others:
        root.append(node)

    systems.sort(key=lambda n: (n.attrib.get("name") != "default", n.attrib.get("name", "")))
    for node in systems:
        root.append(node)


def _build_source_input_map(source_dir):
    source_files = _iter_source_cfg_paths(source_dir)
    if not source_files:
        raise RuntimeError(f"No source cfg files found in {source_dir}")

    merged_by_system = {}
    parsed_files = 0
    source_entries = 0

    for cfg_path in source_files:
        try:
            tree = _load_cfg_tree(cfg_path)
        except RuntimeError as e:
            print(f"[WARN] {e}", file=sys.stderr)
            continue

        parsed_files += 1
        root = tree.getroot()

        for system_node in root.findall("system"):
            system_name = (system_node.attrib.get("name") or "").strip()
            if not system_name:
                continue

            input_node = system_node.find("input")
            if input_node is None:
                continue

            bucket = merged_by_system.setdefault(system_name, {})
            for child in list(input_node):
                source_entries += 1
                bucket[_sig(child)] = copy.deepcopy(child)

    if parsed_files == 0:
        raise RuntimeError("No valid source cfg files were parsed")

    return merged_by_system, parsed_files, source_entries


def _load_or_create_target_tree(target_path):
    if os.path.exists(target_path):
        return _load_cfg_tree(target_path)

    root = ET.Element("mameconfig", {"version": "10"})
    default_system = ET.SubElement(root, "system", {"name": "default"})
    ET.SubElement(default_system, "input")
    return ET.ElementTree(root)


def _backup_target(path):
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = f"{path}.bak.{ts}"
    shutil.copy2(path, backup)
    return backup


def merge_cfgs(source_dir, target_path, dry_run=False):
    merged_by_system, parsed_files, source_entries = _build_source_input_map(source_dir)
    target_tree = _load_or_create_target_tree(target_path)
    root = target_tree.getroot()

    systems_created = 0
    entries_added = 0
    entries_replaced = 0

    for system_name, incoming in merged_by_system.items():
        system_node = _find_system(root, system_name)
        if system_node is None:
            system_node = ET.SubElement(root, "system", {"name": system_name})
            systems_created += 1

        input_node = _ensure_input(system_node)

        existing = {}
        for child in list(input_node):
            existing[_sig(child)] = child

        for sig, src_elem in incoming.items():
            if sig in existing:
                input_node.remove(existing[sig])
                entries_replaced += 1
            else:
                entries_added += 1
            input_node.append(copy.deepcopy(src_elem))

    _reorder_systems(root)
    _indent(root)

    backup_path = None
    if not dry_run:
        os.makedirs(os.path.dirname(target_path), exist_ok=True)
        if os.path.exists(target_path):
            backup_path = _backup_target(target_path)
        target_tree.write(target_path, encoding="utf-8", xml_declaration=True)

    return {
        "parsed_files": parsed_files,
        "source_entries": source_entries,
        "target": target_path,
        "systems_merged": len(merged_by_system),
        "systems_created": systems_created,
        "entries_added": entries_added,
        "entries_replaced": entries_replaced,
        "backup": backup_path,
        "dry_run": dry_run,
    }


def main():
    args = parse_args()

    try:
        result = merge_cfgs(args.source_dir, args.target, dry_run=args.dry_run)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    details = [
        f"target={result['target']}",
        f"systems={result['systems_merged']}",
        f"created={result['systems_created']}",
        f"added={result['entries_added']}",
        f"replaced={result['entries_replaced']}",
        f"parsed_files={result['parsed_files']}",
        f"source_entries={result['source_entries']}",
    ]
    if result["dry_run"]:
        details.append("dry_run=1")
    if result["backup"]:
        details.append(f"backup={result['backup']}")

    print("merge_ok " + " ".join(details))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
