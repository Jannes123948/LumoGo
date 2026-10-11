#!/usr/bin/env python3
"""
Übersetzungen von LumoGo (Deutsch = Quellsprache, Englisch) prüfen und ergänzen.

  python3 Tools/l10n.py check            nach einem xcodebuild: fehlende/alte Schlüssel in den
                                         String-Katalogen + deutsche Texte im Code, die (noch) nicht
                                         übersetzbar sind (kein Text(...)/String(localized:)).
  python3 Tools/l10n.py add neu.json     {"deutscher Schlüssel": "English", …} in die Kataloge der
                                         Targets eintragen, in denen der Schlüssel vorkommt.
  python3 Tools/l10n.py prune            Schlüssel entfernen, die der Code nicht mehr benutzt.

Die Schlüssel kommen aus den `.stringsdata`-Dateien, die Xcode beim Bauen erzeugt
(SWIFT_EMIT_LOC_STRINGS). xcodebuild trägt neue Texte NICHT selbst in die Kataloge ein — deshalb dieses Skript.
Siri-Sätze stehen in `OsmNav/Resources/en.lproj/AppShortcuts.strings` (iOS 16 kann keine AppShortcuts.xcstrings).
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOGS = {
    'OsmNav': 'OsmNav/Resources/Localizable.xcstrings',
    'LumoGoWidgets': 'LumoGoWidgets/Localizable.xcstrings',
    'LumoGoShare': 'LumoGoShare/Localizable.xcstrings',
}


def build_dir():
    dirs = glob.glob(os.path.expanduser('~/Library/Developer/Xcode/DerivedData/OsmNav-*/Build/Intermediates.noindex/OsmNav.build/Debug-iphoneos'))
    if not dirs:
        sys.exit('Kein Build gefunden — erst xcodebuild laufen lassen.')
    return max(dirs, key=os.path.getmtime)


def extracted():
    """{target: {key: [(datei, zeile)]}} und {datei: {zeilen mit Schlüsseln}}."""
    keys, covered = {}, {}
    for target in CATALOGS:
        for f in glob.glob(f'{build_dir()}/{target}.build/Objects-normal/arm64/*.stringsdata'):
            data = json.load(open(f))
            for table, items in data['tables'].items():
                if table != 'Localizable':
                    continue
                for item in items:
                    line = item.get('location', {}).get('startingLine', -1)
                    keys.setdefault(target, {}).setdefault(item['key'], []).append((data['source'], line))
                    covered.setdefault(data['source'], set()).add(line)
    return keys, covered


def load(path):
    return json.load(open(os.path.join(ROOT, path)))


def save(path, catalog):
    catalog['strings'] = dict(sorted(catalog['strings'].items()))
    with open(os.path.join(ROOT, path), 'w') as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2)
        f.write('\n')


SPEC = re.compile(r'%(\d+\$)?(lld|@|\.\d+f|d|f|ld)')


def spec_types(s):
    found = [(m.group(1), m.group(2)) for m in SPEC.finditer(s)]
    if any(p for p, _ in found):
        return [t for _, t in sorted(found, key=lambda x: int(x[0][:-1]))]
    return [t for _, t in found]


def entry(key, english):
    return {'localizations': {
        'de': {'stringUnit': {'state': 'translated', 'value': key}},
        'en': {'stringUnit': {'state': 'translated', 'value': english}},
    }}


LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
GERMAN = re.compile(r'[äöüßÄÖÜ]|\b(der|die|das|und|nicht|ein|eine|auf|mit|für|zu|im|von|bei|aus|wird|keine|Kein|Bitte)\b|^[A-ZÄÖÜ][a-zäöüß]{2,}( [a-zäöüßA-Z]|$)')
CODE_CONTEXT = re.compile(r'(forKey:|systemImage:|systemName:|symbol:|URL\(string:|identifier:|forResource:|withIdentifier:|tags\[|case |hasPrefix\(|hasSuffix\(|contains\(|range\(of:|NSSelectorFromString\(|dateFormat = |Locale\(identifier:|kind:|suiteName:|forHTTPHeaderField:|forName:|forConstantValue: \[?|appendingPathComponent\(|replacingOccurrences\(of:|tag\(|verbatim:|String\(localized:)\s*$')
# Bewusst deutsch (eigene englische Grammatik bzw. Siri-Sätze in AppShortcuts.strings).
SKIP_FILES = ('InstructionFormatter.swift', 'AnnouncementPlanner.swift', 'EnglishInstructions.swift', 'Shortcuts.swift', 'GPX.swift', 'Tools/')


def uncovered_german(covered):
    result = []
    for path in glob.glob(ROOT + '/**/*.swift', recursive=True):
        rel = os.path.relpath(path, ROOT)
        if any(s in rel for s in SKIP_FILES):
            continue
        lines = covered.get(path, set())
        for number, line in enumerate(open(path), 1):
            stripped = line.strip()
            if stripped.startswith(('//', '*', '/*')) or 'print(' in line or number in lines:
                continue
            for m in LITERAL.finditer(line):
                text = m.group(1)
                # Einzelne kleingeschriebene Wörter sind Daten (z.B. Zahlwörter der Offline-Suche), kein UI-Text.
                if re.fullmatch(r'[a-zäöüß]+', text):
                    continue
                if CODE_CONTEXT.search(line[:m.start()]) or not GERMAN.search(text):
                    continue
                result.append(f'{rel}:{number}: {text[:100]}')
    return result


def check():
    keys, covered = extracted()
    problems = 0
    for target, path in CATALOGS.items():
        catalog = load(path)['strings']
        missing = [k for k in keys.get(target, {}) if k not in catalog]
        stale = [k for k in catalog if k not in keys.get(target, {})]
        bad = [k for k, v in catalog.items()
               if spec_types(k) != spec_types(v['localizations'].get('en', {}).get('stringUnit', {}).get('value', k))]
        for k in missing:
            print(f'FEHLT ({target}): {k!r}  ← {os.path.relpath(keys[target][k][0][0], ROOT)}:{keys[target][k][0][1]}')
        for k in bad:
            print(f'PLATZHALTER passen nicht ({target}): {k!r}')
        if stale:
            print(f'{len(stale)} alte Schlüssel in {path} (aufräumen mit „prune“)')
        problems += len(missing) + len(bad)
    for item in uncovered_german(covered):
        print('NICHT ÜBERSETZBAR:', item)
        problems += 1
    print('OK — alles übersetzt.' if problems == 0 else f'{problems} Stellen offen.')
    return problems


def add(json_path):
    new = json.load(open(json_path))
    keys, _ = extracted()
    for target, path in CATALOGS.items():
        catalog = load(path)
        added = 0
        for de, en in new.items():
            if de in keys.get(target, {}):
                if spec_types(de) != spec_types(en):
                    sys.exit(f'Platzhalter passen nicht: {de!r} → {en!r}')
                catalog['strings'][de] = entry(de, en)
                added += 1
        save(path, catalog)
        print(f'{path}: {added} eingetragen')


def prune():
    keys, _ = extracted()
    for target, path in CATALOGS.items():
        catalog = load(path)
        before = len(catalog['strings'])
        catalog['strings'] = {k: v for k, v in catalog['strings'].items() if k in keys.get(target, {})}
        save(path, catalog)
        print(f'{path}: {before - len(catalog["strings"])} entfernt')


if __name__ == '__main__':
    command = sys.argv[1] if len(sys.argv) > 1 else 'check'
    if command == 'check':
        sys.exit(1 if check() else 0)
    elif command == 'add' and len(sys.argv) > 2:
        add(sys.argv[2])
    elif command == 'prune':
        prune()
    else:
        print(__doc__)
