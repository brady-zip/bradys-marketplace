"""Describe explicit controls.map entries without guessing Omni's implicit scope."""
import argparse
import json
import sys

from common import Blocked, definition


def explain(value):
    document = value["document"]
    tiles = document["queryPresentations"]["data"]
    data_ids = [key for key in document["queryPresentations"]["order"]
                if tiles[key]["type"] in ("query", "sql", "linked")]
    controls = document["controls"]
    rows = []
    for key in controls["order"]:
        control = controls["data"][key]
        config = control["config"]
        mapping = control.get("map", {})
        if not isinstance(mapping, dict) or set(mapping) - set(tiles):
            raise Blocked("INVALID_CONTROL_MAP", "Control map must reference existing tile keys.")
        if any(field is not False and (not isinstance(field, str) or not field.strip())
               for field in mapping.values()):
            raise Blocked("INVALID_CONTROL_MAP", "Control map values must be field names or false.")
        row = {"id": key, "label": config.get("label") or config.get("fieldName") or key,
               "mapped": [], "excluded": [], "implicit": []}
        for tile_id in data_ids:
            tile = {"id": tile_id, "name": tiles[tile_id].get("name") or tile_id}
            if tile_id not in mapping:
                row["implicit"].append(tile)
            elif mapping[tile_id] is False:
                row["excluded"].append(tile)
            else:
                row["mapped"].append(dict(tile, field=mapping[tile_id]))
        rows.append(row)
    return rows


def prose(rows):
    def names(tiles):
        return ", ".join(f'{tile["name"]} [{tile["id"]}]' for tile in tiles) or "none"

    lines = []
    for row in rows:
        lines.append(f'{row["label"]} [{row["id"]}]: applies to {names(row["mapped"])}; '
                     f'explicitly excludes {names(row["excluded"])}.')
        if row["implicit"]:
            lines.append(f'  No explicit map entry for {names(row["implicit"])}. '
                         'Verify native default scope in the browser; absence does not mean excluded.')
    return "\n".join(lines) or "No controls."


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("definition")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    args = parser.parse_args()
    rows = explain(definition(args.definition))
    print(json.dumps(rows, indent=2) if args.format == "json" else prose(rows))


if __name__ == "__main__":
    try:
        main()
    except (Blocked, KeyError, TypeError) as error:
        code = error.code if isinstance(error, Blocked) else "INVALID_DEFINITION"
        message = error.message if isinstance(error, Blocked) else "Run chart-room validate before explaining controls."
        print(code + ": " + message, file=sys.stderr)
        raise SystemExit(1)
