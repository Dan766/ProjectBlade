"""Deterministic stand-in for the model: builds data that satisfies a JSON Schema.

Same schema + seed_text always gives the same output, so resume/hash tests are stable.
Supports the subset of JSON Schema the pipeline uses: object, array, string, integer,
number, boolean, enum, const, minItems/maxItems, minLength/maxLength, minimum/maximum,
local $ref (#/$defs/...), and `pattern` strings via the schema's `examples` (first example).
"""
from __future__ import annotations

import hashlib
import random

_WORDS = ["hail", "traveler", "gold", "banner", "keep", "river", "raid", "steel", "harvest", "oath",
          "march", "ford", "spear", "salt", "tower", "mercy", "wolf", "ember", "crown", "field"]


def generate(schema: dict, seed_text: str = "") -> object:
    seed = int.from_bytes(hashlib.sha256(seed_text.encode("utf-8")).digest()[:8], "big")
    return _gen(schema, random.Random(seed), schema)


def _resolve(s: dict, root: dict) -> dict:
    while "$ref" in s:
        node = root
        for part in s["$ref"].removeprefix("#/").split("/"):
            node = node[part]
        s = node
    return s


def _gen(s: dict, rng: random.Random, root: dict) -> object:
    s = _resolve(s, root)
    if "const" in s:
        return s["const"]
    if "enum" in s:
        return rng.choice(s["enum"])
    t = s.get("type", "object")
    if isinstance(t, list):
        t = next((x for x in t if x != "null"), "null")
    if t == "object":
        props = s.get("properties", {})
        return {k: _gen(v, rng, root) for k, v in props.items()}
    if t == "array":
        lo = s.get("minItems", 1)
        hi = max(lo, min(s.get("maxItems", lo + 2), lo + 2))
        return [_gen(s.get("items", {"type": "string"}), rng, root) for _ in range(rng.randint(lo, hi))]
    if t == "string":
        if "pattern" in s:
            return s["examples"][0]
        lo, hi = s.get("minLength", 1), s.get("maxLength", 60)
        text = " ".join(rng.choice(_WORDS) for _ in range(rng.randint(2, 6)))
        while len(text) < lo:
            text += " " + rng.choice(_WORDS)
        return text[:hi].strip() if len(text[:hi].strip()) >= lo else text[:hi]
    if t == "integer":
        return rng.randint(int(s.get("minimum", 0)), int(s.get("maximum", 100)))
    if t == "number":
        return round(rng.uniform(float(s.get("minimum", 0.0)), float(s.get("maximum", 1.0))), 3)
    if t == "boolean":
        return rng.random() < 0.5
    return None
