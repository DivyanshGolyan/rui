#!/usr/bin/env python3
"""Render and upsert the screenshot comparison comment for a pull request."""
import argparse
import html
import json
import os
from urllib.parse import quote
from urllib.request import Request, urlopen

MARKER = '<!-- rui-screens -->'
LIMIT = 64999
SIZES = ('140x40', '46x30')


def text(value):
    return html.escape(str(value), quote=True).replace('|', '&#124;').replace('\n', ' ').replace('\r', ' ')


def image(record, repo, pr, head, label):
    if not record:
        return '—'
    path = record.get('files', {}).get('png')
    if not path:
        return '—'
    url = f'https://raw.githubusercontent.com/{repo}/pr-screens/pr-{pr}/{head}/{quote(path, safe="/")}'
    return f'![{label}]({url})'


def render(diff, repo, pr, head, base, shots=(), baseline_shots=()):
    """Build a bounded Markdown comment from the shots diff manifest."""
    groups = {key: diff[key] for key in ('changed', 'new', 'removed', 'failed')}
    counts = f"{len(groups['changed'])} changed, {len(groups['new'])} new, {diff['same_count']} unchanged, {len(groups['failed'])} failed"
    header = f'{MARKER}\n## Screens\n\nHead: `{text(head)}`  \nBase: `{text(base)}`\n\n{counts}\n'
    sections = []
    if groups['failed']:
        sections.append('\n### Failures\n\n')
        for pair in groups['failed']:
            failed = [r for r in (pair.get('before'), pair.get('after')) if r and not r.get('ok', True)]
            for record in failed:
                reason = text(record.get('reason') or 'Capture failed')
                sections.append(f"- **{text(pair['name'])} ({text(pair['size'])})**: {reason}  \n  {image(record, repo, pr, head, 'Last frame')}\n")
    rows = {}
    for category in ('changed', 'new'):
        for pair in groups[category]:
            rows.setdefault(pair['name'], {})[pair['size']] = pair
    current = {(r['name'], r['size']): r for r in shots}
    baseline = {(r['name'], r['size']): {**r, 'files': {
        ext: 'baseline/' + path for ext, path in r.get('files', {}).items()
    }} for r in baseline_shots}
    if rows:
        sections.append('\n### Changed and new screens\n\n| State | 140x40 before / after | 46x30 before / after |\n| --- | --- | --- |\n')
        for name, sizes in sorted(rows.items()):
            cells = []
            for size in SIZES:
                pair = sizes.get(size)
                if pair is None and ((name, size) in current or (name, size) in baseline):
                    pair = {'before': baseline.get((name, size)), 'after': current.get((name, size))}
                if pair is None:
                    cells.append('—')
                else:
                    cells.append(image(pair.get('before'), repo, pr, head, 'Before') + ' / ' +
                                 image(pair.get('after'), repo, pr, head, 'After'))
            sections.append(f'| {text(name)} | {cells[0]} | {cells[1]} |\n')
    if groups['removed']:
        sections.append('\n### Removed screens\n\n')
        for pair in groups['removed']:
            sections.append(f"- {text(pair['name'])} ({text(pair['size'])})\n")
    sections.append(f"\n<details><summary>{diff['same_count']} unchanged captures</summary>\n\nOther unchanged captures are omitted.\n\n</details>\n")
    note = '\n\n*Comment truncated; see the screenshot artifact for the full comparison.*\n'
    result = header
    for section in sections:
        if len(result) + len(section) + len(note) > LIMIT:
            return result[:LIMIT - len(note)] + note
        result += section
    return result


def github(method, path, token, body=None):
    data = None if body is None else json.dumps(body).encode()
    request = Request('https://api.github.com/' + path, data=data, method=method,
                      headers={'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json',
                               'Content-Type': 'application/json', 'X-GitHub-Api-Version': '2022-11-28'})
    with urlopen(request) as response:
        return json.load(response)


def upsert(api, repo, pr, head, body):
    login = 'github-actions[bot]'
    page = 1
    target = None
    while True:
        comments = api('GET', f'repos/{repo}/issues/{pr}/comments?per_page=100&page={page}')
        for comment in comments:
            if comment.get('user', {}).get('login') == login and MARKER in (comment.get('body') or ''):
                target = comment['id']
                break
        if target is not None or len(comments) < 100:
            break
        page += 1
    current = api('GET', f'repos/{repo}/pulls/{pr}')
    if current['state'] != 'open' or current['head']['sha'] != head:
        raise ValueError('pull request closed or head changed before screenshot comment update')
    if target is not None:
        return api('PATCH', f'repos/{repo}/issues/comments/{target}', {'body': body})
    return api('POST', f'repos/{repo}/issues/{pr}/comments', {'body': body})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--diff', required=True)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--pr', required=True, type=int)
    parser.add_argument('--head', required=True)
    parser.add_argument('--base', required=True)
    parser.add_argument('--shots', help='merged shots.json for unchanged sizes')
    parser.add_argument('--baseline-shots', help='baseline shots.json for unchanged sizes')
    args = parser.parse_args()
    with open(args.diff, encoding='utf-8') as source:
        diff = json.load(source)
    def load_optional(path):
        if path is None:
            return []
        with open(path, encoding='utf-8') as source:
            return json.load(source)
    body = render(diff, args.repo, args.pr, args.head, args.base,
                  load_optional(args.shots), load_optional(args.baseline_shots))
    token = os.environ['GITHUB_TOKEN']
    upsert(lambda method, path, body=None: github(method, path, token, body), args.repo, args.pr, args.head, body)


if __name__ == '__main__':
    main()
