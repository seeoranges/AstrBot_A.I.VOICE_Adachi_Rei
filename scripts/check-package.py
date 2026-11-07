"""Check tracked files (or source tree before git init); never print secret values."""
from pathlib import Path
import ast
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DENY_DIRS = {'private', 'plugin_data', 'snapshots', '__pycache__', 'logs', 'downloads', 'node_modules', '.venv'}
DENY_SUFFIXES = {'.exe', '.dll', '.mp3', '.wav', '.mp4', '.db', '.sqlite', '.zip', '.pem', '.pfx', '.key', '.log'}
SECRETS = [re.compile(r'\b(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b')]

def main():
    try:
        result = subprocess.run(['git','ls-files','-z'],cwd=ROOT,capture_output=True,check=True)
        files = [ROOT/p for p in result.stdout.decode('utf-8').split('\0') if p]
    except (subprocess.CalledProcessError, FileNotFoundError):
        files = [p for p in ROOT.rglob('*') if p.is_file() and '.git' not in p.parts and '__pycache__' not in p.parts]
    errors = []
    for p in files:
        rel = p.relative_to(ROOT)
        if set(rel.parts) & DENY_DIRS or p.suffix.lower() in DENY_SUFFIXES or p.name in {'answers.json','session_data.json','backend.txt','owner-qq.txt','deepseek-key.txt'}:
            errors.append((str(rel),'private/runtime file'))
            continue
        text = p.read_text(encoding='utf-8-sig')
        if any(rule.search(text) for rule in SECRETS): errors.append((str(rel),'possible credential'))
        if re.search(r'[A-Za-z]:\\Users\\[^\\\s]+',text): errors.append((str(rel),'personal Windows path'))
        if p.suffix == '.py':
            try: ast.parse(text,filename=str(rel))
            except SyntaxError: errors.append((str(rel),'Python syntax'))
        if p.suffix == '.json':
            try: json.loads(text)
            except json.JSONDecodeError: errors.append((str(rel),'JSON syntax'))
    for rel, reason in errors: print(f'{rel}: {reason}')
    print(f'Checked {len(files)} files; {len(errors)} issues.')
    return int(bool(errors))

if __name__ == '__main__': sys.exit(main())
