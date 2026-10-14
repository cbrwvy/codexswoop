#!/usr/bin/env python3
"""Check every runtime translation and parameter contract without user storage access."""
from pathlib import Path
import json, re, subprocess
root=Path(__file__).resolve().parents[1]
subprocess.run(['python3',str(root/'scripts/generate-localization.py'),'--check'],check=True)
catalog=json.loads((root/'Resources/Localization/catalog.json').read_text())
checks=0
for key, translations in catalog.items():
    assert set(translations)=={'en','ru','uz-Latn'},key
    normalized={locale: value if isinstance(value,dict) else {'other':value} for locale,value in translations.items()}
    expected=set(re.findall(r'\{\d+\}',normalized['en']['other']))
    for locale,forms in normalized.items():
        assert 'other' in forms and all(isinstance(s,str) and s.strip() for s in forms.values()),key
        for form,value in forms.items():
            assert form in {'one','few','many','other'},(key,form)
            assert set(re.findall(r'\{\d+\}',value))==expected,(key,locale,'parameters')
            assert 'TODO' not in value and not (locale=='uz-Latn' and re.search('[\u0400-\u04ff]',value)),(key,locale)
            checks+=1
    if len(normalized['en'])>1:
        assert {'one','few','many','other'} <= normalized['ru'].keys(),key
references=set()
for source in (root/'Sources').rglob('*.swift'):
    if source.name=='LocalizationCatalog.swift':continue
    text=source.read_text()
    references.update(re.findall(r'L10n\.(?:text|plural|format)\("([^"\n]+)"',text))
assert references <= catalog.keys(),references-catalog.keys()
print(f'PASS {checks} translation forms, {len(catalog)} complete EN/RU/UZ-Latn keys; parameters, plural forms, Latin script, {len(references)} literal references and generated source verified')
