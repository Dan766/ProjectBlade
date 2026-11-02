"""Small text checks shared by stage post steps (and the 0.8 validator)."""
from __future__ import annotations

import re

PLACEHOLDER = re.compile(r"\{(\w+)\}")
EMOTICON = re.compile(r"(?<!\w)[:;=8xX>]-?[DPpOo()\[\]/\\|3]+(?!\w)")


def tokens(text: str) -> set[str]:
    return set(re.findall(r"[a-z0-9']+", PLACEHOLDER.sub(" ", text.casefold())))


def jaccard(a: str, b: str) -> float:
    ta, tb = tokens(a), tokens(b)
    return len(ta & tb) / len(ta | tb) if ta and tb else 0.0


def copies_example(line: str, examples: list[str], threshold: float = 0.6) -> str | None:
    """Return the example `line` is a near-copy of (token Jaccard >= threshold)."""
    return next((ex for ex in examples if jaccard(line, ex) >= threshold), None)


def placeholders(text: str) -> set[str]:
    return set(PLACEHOLDER.findall(text))


def stray_brace(text: str) -> bool:
    rest = PLACEHOLDER.sub("", text)
    return "{" in rest or "}" in rest


def blocklist_hit(text: str, blocklist: list[str]) -> str | None:
    low = text.casefold()
    return next((b for b in blocklist if re.search(rf"(?<!\w){re.escape(b)}(?!\w)", low)), None)


GENDERED = re.compile(r"\b(he|she|him|her|his|hers|himself|herself)\b", re.I)
# A named person or animal before the pronoun is its referent ("my horse says he forgives you").
OTHER_REFERENT = re.compile(
    r"\b(horse|donkey|mule|goat|goose|chicken|hen|sheep|dog|cat|scout|dad|mum|mom|father|mother|"
    r"grandfather|grandmother|kinsman|brother|sister|son|daughter|friend|squire|bard|scarecrow|uncle|"
    r"aunt|cousin|lord|king|man|woman|guy|guard|smith|merchant|priest|monk|captain|sergeant|nephew|"
    r"niece|steward|bearer|captive|gerald)\b", re.I)


# Gendered titles or nouns aimed at the player: "Lady {player}", "{player} the one man i wanted to see".
GENDERED_TITLE = re.compile(r"\b(lady|lord|sir|madam|milady|milord|mister|miss)\s+\{(player|rival)\}", re.I)
GENDERED_NOUN_AFTER = re.compile(r"\{(player|rival)\}[^.!?]{0,25}?\b(man|woman|lady|lad|lass|gentleman)\b", re.I)


def assumes_gender(text: str) -> bool:
    """A line that genders the player or a rival (both unknown) - e.g. "{rival} ... when he sees us"."""
    if not (placeholders(text) & {"player", "rival"}):
        return False
    if GENDERED_TITLE.search(text) or GENDERED_NOUN_AFTER.search(text):
        return True
    m = GENDERED.search(text)
    return bool(m) and not OTHER_REFERENT.search(text[:m.start()])


def normalize(text: str) -> str:
    return " ".join(re.findall(r"[a-z0-9']+", PLACEHOLDER.sub(" ", text.casefold())))
